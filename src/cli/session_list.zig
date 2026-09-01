//! `nulya session list`: a READ-ONLY projection of `.nulya/sessions/` — what
//! was composed, what it cost, how it turned out. It decides nothing and writes
//! nothing.
//!
//! A reader, not a verb: the rest of `session.zig` drives one session, while
//! everything here walks every session file at once and joins it with the
//! outcome journal and the store roots.

const std = @import("std");
const roots_mod = @import("../extension/roots.zig");
const outcome = @import("../journals/outcome.zig");
const ledger = @import("../ledger.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");
const RootSearch = common.RootSearch;
const cwdRealPath = common.cwdRealPath;
const printRaw = common.printRaw;

const SessionView = struct {
    id: []const u8,
    /// RFC3339 UTC, or empty for a session created before headers carried it.
    created: []const u8,
    parent: ?ledger.ParentRef,
    /// The oldest ancestor reachable through `parent` among the LISTED sessions
    /// — the episode this file belongs to (`id` itself when it forks nothing).
    root: []const u8,
    /// The provider PROFILE name, then the frozen identity behind it.
    model: []const u8,
    provider: []const u8,
    model_id: []const u8,
    /// Which binary created it. Empty for a pre-stamp session.
    nulya: ledger.Stamp,
    /// Where its `shell` commands run. Empty = this host, which is almost every
    /// session, so the human table only spends a column on it when there is
    /// something to say.
    environment: []const u8,
    /// The workspace on that machine, when `environment` names a remote one.
    remote_workspace: []const u8,
    events: usize,
    composition: Composition,
    /// Sum of every assistant event's recorded usage. Steps whose provider
    /// reported nothing contribute nothing.
    usage: ledger.Usage,
    /// The same sum over every listed session sharing this `root`: what the whole
    /// episode cost, which is the number a compacted task actually spent.
    episode_usage: ledger.Usage,
    /// The opening user turn, truncated — enough to recognize the session by.
    first_user_text: []const u8,
    /// The verdict that stands, or null for "not judged" — which is NOT failure.
    outcome: ?OutcomeView,

    const Composition = struct {
        active: []const []const u8,
        native_tools: []const []const u8,
        /// Every system prompt those frozen versions contribute, as
        /// `<id>@<version>/<path>`.
        system_prompts: []const []const u8,
        /// The per-session prompts frozen into the header by `--prompt` — their
        /// labels and sizes only. The text itself is session content, which
        /// `nulya session events` is for.
        prompts: []const InlinePromptView,
    };

    const InlinePromptView = struct {
        source: []const u8,
        bytes: usize,
    };

    const OutcomeView = struct {
        verdict: []const u8,
        note: ?[]const u8,
        at: []const u8,
        /// `human` or `agent` — an agent's verdict is a claim, not ground truth.
        source: []const u8,
        /// The session whose shell wrote it; equal to `id` means a self-grade.
        by: ?[]const u8,
    };
};

/// How much of the opening user turn `session list` carries. Long enough to tell
/// two sessions apart, short enough that a hundred of them stay readable.
const first_text_limit: usize = 120;

pub fn sessionList(alloc: std.mem.Allocator, io: std.Io, as_json: bool) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    const outcomes = try outcome.readAll(a, io, cwd_path);

    // Opened once for the whole listing; frozen versions are content-addressed,
    // so one manifest read answers for every session naming it.
    var search = RootSearch.open(a, io, cwd_path) catch null;
    defer if (search) |*s| s.deinit(a);
    var prompts: PromptIndex = .{ .roots = if (search) |*s| &s.roots else null, .cache = .init(a) };
    defer prompts.cache.deinit();

    var views: std.ArrayList(SessionView) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, launch.sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try printSessionList(alloc, io, &.{}, as_json);
            return 0;
        },
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        // The iterator reuses its name buffer, and the view keeps a slice of the
        // name as the session id — so copy it before the next `next()`.
        const name = try a.dupe(u8, entry.name);
        const view = readSessionView(a, io, dir, name, outcomes, &prompts) catch continue; // a corrupt file is not a reason to hide the rest
        try views.append(a, view);
    }

    // Sessions fork (`session new --parent`), so one task can span several
    // files; the episode is joined HERE, in the projection, and nowhere else —
    // an outcome stays recorded against the id it was given.
    try resolveEpisodes(a, views.items);

    // Newest first. `created` is the fact to sort on; sessions written before it
    // existed fall back to their id, which embeds the creation time anyway.
    std.mem.sort(SessionView, views.items, {}, struct {
        fn lessThan(_: void, x: SessionView, y: SessionView) bool {
            const xa = if (x.created.len != 0) x.created else x.id;
            const ya = if (y.created.len != 0) y.created else y.id;
            if (!std.mem.eql(u8, xa, ya)) return std.mem.order(u8, xa, ya) == .gt;
            return std.mem.order(u8, x.id, y.id) == .gt;
        }
    }.lessThan);

    try printSessionList(alloc, io, views.items, as_json);
    return 0;
}

/// Project one session file. Reads its bytes once: the first line is the header,
/// the rest are events — counted, summed, and scanned for the opening user turn.
fn readSessionView(
    a: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    file_name: []const u8,
    outcomes: []const outcome.Outcome,
    prompts: *PromptIndex,
) !SessionView {
    const bytes = try dir.readFileAlloc(io, file_name, a, .unlimited);

    var lines = ledger.completeLines(bytes);
    var header: ?ledger.OwnedHeader = null;
    var events: usize = 0;
    var total: ledger.Usage = .{};
    var first_user_text: []const u8 = "";
    var rebound: ?ledger.Identity = null;

    while (lines.next()) |line| {
        if (header == null) {
            header = try ledger.parseHeaderLine(a, line);
            continue;
        }
        events += 1;
        // Only lines that MAY carry what this view needs are parsed, so listing
        // does not cost a full decode of every ledger. The substring tests are a
        // pre-filter, never the decision: what counts is the decoded line.
        const may_have_usage = std.mem.indexOf(u8, line, "\"usage\":") != null;
        const may_be_first_text = first_user_text.len == 0 and std.mem.indexOf(u8, line, "\"kind\":\"user_text\"") != null;
        // A session may have changed model since its header was written;
        // "what does this session run on" means the one in force.
        const may_be_rebind = std.mem.indexOf(u8, line, "\"kind\":\"model_rebind\"") != null;
        if (!may_have_usage and !may_be_first_text and !may_be_rebind) continue;
        const parsed = ledger.parseEventLine(a, line) catch continue;
        if (parsed.value.usage) |u| total.add(u);
        if (first_user_text.len == 0 and std.mem.eql(u8, parsed.value.kind, "user_text")) {
            if (parsed.value.text) |t| first_user_text = try summarize(a, t);
        }
        if (std.mem.eql(u8, parsed.value.kind, "model_rebind")) {
            if (parsed.value.identity) |identity| rebound = .{ .profile = parsed.value.profile orelse "", .identity = identity };
        }
    }

    const h = (header orelse return error.MissingHeader).value;
    const active = try a.alloc([]const u8, h.composition.active.len);
    for (h.composition.active, active) |ref, *out| out.* = try std.fmt.allocPrint(a, "{s}@{s}", .{ ref.id, ref.version });

    const inline_prompts = try a.alloc(SessionView.InlinePromptView, h.composition.prompts.len);
    for (h.composition.prompts, inline_prompts) |p, *out| out.* = .{ .source = p.source, .bytes = p.text.len };

    const id = file_name[0 .. file_name.len - ".jsonl".len];
    const latest = outcome.latestFor(outcomes, id);
    return .{
        .id = id,
        .created = h.created,
        .parent = h.parent,
        // The episode is resolved once the whole listing is known; until then a
        // session is its own root, which is also the final answer for most.
        .root = id,
        // The identity in force: the header's until a rebind said otherwise —
        // the same question `session step` asks.
        .model = if (rebound) |r| r.profile else h.model,
        .provider = if (rebound) |r| r.identity.provider else h.model_identity.provider,
        .model_id = if (rebound) |r| r.identity.model else h.model_identity.model,
        .nulya = h.nulya,
        .environment = h.environment,
        .remote_workspace = h.remote_workspace,
        .events = events,
        .composition = .{
            .active = active,
            .native_tools = h.composition.native_tools,
            .system_prompts = try prompts.forActive(a, h.composition.active),
            .prompts = inline_prompts,
        },
        .usage = total,
        .episode_usage = total,
        .first_user_text = first_user_text,
        .outcome = if (latest) |o| .{
            .verdict = @tagName(o.verdict),
            .note = o.note,
            .at = o.at,
            .source = @tagName(o.source),
            .by = o.by,
        } else null,
    };
}

/// Which system prompts a frozen `id@version` contributes, read from its
/// manifest and memoized by `id@version` — versions are content-addressed, so
/// one read answers for every session pinning it.
///
/// Best effort throughout: a version this machine no longer holds (built in
/// another checkout, deactivated and pruned) contributes nothing rather than
/// failing the listing. Absence here means "unknown", not "none".
const PromptIndex = struct {
    roots: ?*const roots_mod.Roots,
    cache: std.StringHashMap([]const []const u8),

    fn forActive(self: *PromptIndex, a: std.mem.Allocator, active: []const ledger.ExtensionRef) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (active) |ref| {
            for (try self.forOne(a, ref)) |p| try out.append(a, p);
        }
        return out.toOwnedSlice(a);
    }

    fn forOne(self: *PromptIndex, a: std.mem.Allocator, ref: ledger.ExtensionRef) ![]const []const u8 {
        const roots = self.roots orelse return &.{};
        const key = try std.fmt.allocPrint(a, "{s}@{s}", .{ ref.id, ref.version });
        const gop = try self.cache.getOrPut(key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = &.{};

        // `.structural`: nothing in a listing runs, so a version whose bytes
        // cannot be verified still contributes its declaration.
        const resolved = roots.resolveVersion(a, ref.id, ref.version, .structural) catch return gop.value_ptr.*;
        defer resolved.deinit(a);
        const paths = try a.alloc([]const u8, resolved.manifest.system_prompts.len);
        // The manifest owns its strings; the listing outlives it, so copy while
        // stamping each one with the version it came from.
        for (resolved.manifest.system_prompts, paths) |p, *slot| {
            slot.* = try std.fmt.allocPrint(a, "{s}/{s}", .{ key, p.path });
        }
        gop.value_ptr.* = paths;
        return paths;
    }
};

/// Fill in each view's `root` (the oldest listed ancestor through `parent`) and
/// `episode_usage` (that episode's total). Joining them is a projection, never
/// a change to what any journal recorded.
///
/// A parent that is not in the listing (another workspace, a deleted file)
/// makes its child the root of its own episode.
fn resolveEpisodes(a: std.mem.Allocator, views: []SessionView) !void {
    var index: std.StringHashMap(usize) = .init(a);
    defer index.deinit();
    for (views, 0..) |v, i| try index.put(v.id, i);

    for (views, 0..) |*v, i| {
        var at = i;
        var hops: usize = 0;
        while (views[at].parent) |p| {
            const next = index.get(p.session) orelse break;
            at = next;
            hops += 1;
            if (hops > views.len) break; // a cycle can only come from a hand-edited header
        }
        v.root = views[at].id;
    }

    var totals: std.StringHashMap(ledger.Usage) = .init(a);
    defer totals.deinit();
    for (views) |v| {
        const gop = try totals.getOrPut(v.root);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.add(v.usage);
    }
    for (views) |*v| v.episode_usage = totals.get(v.root) orelse v.usage;
}

/// One line of text, truncated on a UTF-8 boundary, with newlines flattened.
fn summarize(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var end = @min(text.len, first_text_limit);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    const cut = try a.dupe(u8, text[0..end]);
    for (cut) |*c| {
        if (c.* == '\n' or c.* == '\r' or c.* == '\t') c.* = ' ';
    }
    return cut;
}

fn printSessionList(alloc: std.mem.Allocator, io: std.Io, views: []const SessionView, as_json: bool) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (as_json) {
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("sessions");
        try jw.write(views);
        try jw.endObject();
        try out.writer.writeByte('\n');
    } else {
        for (views) |v| {
            try out.writer.print("{s}  {s: <20}  {s: <10}  {d: >4} ev  in {d: >7} cache {d: >7} out {d: >6}  {s: <7}", .{
                v.id,
                if (v.created.len != 0) v.created else "-",
                if (v.model.len != 0) v.model else "-",
                v.events,
                v.usage.input_tokens,
                v.usage.cache_read_tokens,
                v.usage.output_tokens,
                if (v.outcome) |o| o.verdict else "-",
            });
            // A session that graded itself must not read like someone else's
            // assessment of it.
            if (v.outcome) |o| {
                if (o.source.len != 0 and !std.mem.eql(u8, o.source, "human")) {
                    const self_graded = if (o.by) |b| std.mem.eql(u8, b, v.id) else false;
                    try out.writer.writeAll(if (self_graded) " (self)" else " (by agent)");
                }
            }
            if (v.parent) |p| try out.writer.print("  <- {s}:{d}", .{ p.session, p.seq });
            // Only a fork says anything here; for everyone else root == id.
            if (!std.mem.eql(u8, v.root, v.id)) try out.writer.print("  root {s}", .{v.root});
            if (v.composition.active.len != 0) {
                try out.writer.writeAll("  [");
                for (v.composition.active, 0..) |ref, i| {
                    if (i != 0) try out.writer.writeAll(", ");
                    try out.writer.writeAll(ref);
                }
                try out.writer.writeAll("]");
            }
            // Same rule as `root`: nothing to say costs no width.
            if (v.environment.len != 0) try out.writer.print("  env {s}", .{v.environment});
            if (v.nulya.version.len != 0) try out.writer.print("  nulya {s}", .{v.nulya.version});
            if (v.first_user_text.len != 0) try out.writer.print("  {s}", .{v.first_user_text});
            try out.writer.writeByte('\n');
        }
        if (views.len == 0) try out.writer.writeAll("no sessions\n");
    }
    try printRaw(io, out.written());
}

test "resolveEpisodes walks a fork chain to its root and totals the episode's usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const mk = struct {
        fn v(id: []const u8, parent: ?ledger.ParentRef, input: u64) SessionView {
            return .{
                .id = id,
                .created = "",
                .parent = parent,
                .root = id,
                .model = "",
                .provider = "",
                .model_id = "",
                .nulya = .{},
                .environment = "",
                .remote_workspace = "",
                .events = 0,
                .composition = .{ .active = &.{}, .native_tools = &.{}, .system_prompts = &.{}, .prompts = &.{} },
                .usage = .{ .input_tokens = input },
                .episode_usage = .{},
                .first_user_text = "",
                .outcome = null,
            };
        }
    };

    var views = [_]SessionView{
        mk.v("a", null, 1),
        mk.v("b", .{ .session = "a", .seq = 3 }, 2),
        mk.v("c", .{ .session = "b", .seq = 4 }, 4),
        // A parent nobody here can see (another workspace, a deleted file): its
        // child is the root of its own episode rather than a broken listing.
        mk.v("orphan", .{ .session = "gone", .seq = 1 }, 8),
        // Only a hand-edited header can say this; it must terminate, not hang.
        mk.v("loop", .{ .session = "loop", .seq = 1 }, 16),
    };
    try resolveEpisodes(arena.allocator(), &views);

    try std.testing.expectEqualStrings("a", views[0].root);
    try std.testing.expectEqualStrings("a", views[1].root);
    try std.testing.expectEqualStrings("a", views[2].root); // two hops up the chain
    try std.testing.expectEqualStrings("orphan", views[3].root);
    try std.testing.expectEqualStrings("loop", views[4].root);

    // Every session in an episode reports the episode's total, not just its own.
    for (views[0..3]) |v| try std.testing.expectEqual(@as(u64, 7), v.episode_usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 1), views[0].usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 8), views[3].episode_usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 16), views[4].episode_usage.input_tokens);
}
