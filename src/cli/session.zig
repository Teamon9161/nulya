//! `nulya session …` (DESIGN §14, PLAN §3.2): the one session driver surface.
//! There is deliberately no setTools / setModel / replaceHistory — changing
//! composition means a new session. Only `step` ever writes the session file;
//! everything else deposits into its siblings or reads it back.

const std = @import("std");
const environment = @import("../environment.zig");
const roots_mod = @import("../extension/roots.zig");
const outcome = @import("../outcome.zig");
const config = @import("../config.zig");
const ledger = @import("../ledger.zig");
const session = @import("../session.zig");
const loop = @import("../loop.zig");
const provider = @import("../provider.zig");
const composition = @import("../composition.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");
const RootSearch = common.RootSearch;
const cwdRealPath = common.cwdRealPath;
const flagValue = common.flagValue;
const sliceHasFlag = common.sliceHasFlag;
const withRef = common.withRef;
const envSessionId = common.envSessionId;
const printOut = common.printOut;
const printRaw = common.printRaw;
const printErr = common.printErr;

// ── `nulya session *` (DESIGN §14, PLAN §3.2) ───────────────────────────────
//
// The one session driver surface. There is deliberately no setTools / setModel /
// replaceHistory: changing composition means a new session. Each subcommand is a
// separate process over the durable session file, and only `step` ever WRITES
// that file: `append` and `cancel` deposit into the session's siblings
// (`<id>.inbox/`, `<id>.cancel`) for `step` to consume at its next step
// boundary, and `events` tails the file read-only. `step` streams the events it
// appends as JSONL; its `--max-steps` budget is enforced by the kernel.

pub fn dispatchSession(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return sessionUsage(io);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "new")) return sessionNew(alloc, io, rest);
    if (std.mem.eql(u8, sub, "append")) return sessionAppend(alloc, io, rest);
    if (std.mem.eql(u8, sub, "step")) return sessionStep(alloc, io, rest);
    if (std.mem.eql(u8, sub, "events")) return sessionEvents(alloc, io, rest);
    if (std.mem.eql(u8, sub, "cancel")) return sessionCancel(alloc, io, rest);
    if (std.mem.eql(u8, sub, "outcome")) return sessionOutcome(alloc, io, rest);
    if (std.mem.eql(u8, sub, "list")) return sessionList(alloc, io, sliceHasFlag(rest, "--json"));
    try printErr(io, "unknown `session` subcommand; try new|append|step|events|cancel|outcome|list\n");
    return 1;
}

// ── `nulya session list` (DESIGN §14) ───────────────────────────────────────
//
// A READ-ONLY projection of `.nulya/sessions/`: what was composed, what it cost,
// how it turned out. It decides nothing and writes nothing — same standing as
// `config show`. Its first consumers are the evolution skill (which needs to see
// many sessions at once without reading every ledger) and the TUI's `/sessions`.

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
    /// Which binary created it (DESIGN §3.4). Empty for a pre-stamp session.
    nulya: ledger.Stamp,
    events: usize,
    composition: Composition,
    /// Sum of every assistant event's recorded usage (DESIGN §3.1). Steps whose
    /// provider reported nothing contribute nothing.
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
        /// `<id>@<version>/<path>` (DESIGN §7.5). A package that rewrites the
        /// system blocks of every session it is in should be readable from the
        /// listing, not only from the manifest.
        system_prompts: []const []const u8,
    };

    const OutcomeView = struct {
        verdict: []const u8,
        note: ?[]const u8,
        at: []const u8,
        /// `human` or `agent` (DESIGN §3.3) — an agent's verdict is a claim.
        source: []const u8,
        /// The session whose shell wrote it; equal to `id` means a self-grade.
        by: ?[]const u8,
    };
};

/// How much of the opening user turn `session list` carries. Long enough to tell
/// two sessions apart, short enough that a hundred of them stay readable.
const first_text_limit: usize = 120;

fn sessionList(alloc: std.mem.Allocator, io: std.Io, as_json: bool) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    const outcomes = try outcome.readAll(a, io, cwd_path);

    // The store roots are opened once for the whole listing: a session's frozen
    // `active` versions are content-addressed, so their manifests are read here
    // only to say what they contribute (best effort — see `PromptIndex`).
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

    // Sessions fork (`session new --parent`, DESIGN §11), so one task can span
    // several files; the episode is joined HERE, in the projection, and nowhere
    // else — an outcome stays recorded against the id it was given.
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
    const clean_end: usize = @intCast(ledger.lastCompleteLineEnd(bytes));

    var lines = std.mem.splitScalar(u8, bytes[0..clean_end], '\n');
    var header: ?ledger.OwnedHeader = null;
    var events: usize = 0;
    var total: ledger.Usage = .{};
    var first_user_text: []const u8 = "";

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (header == null) {
            header = try ledger.parseHeaderLine(a, line);
            continue;
        }
        events += 1;
        // Only lines that MAY carry what this view needs are parsed; the rest are
        // just counted, so listing does not cost a full decode of every ledger.
        // The substring tests are a pre-filter, never the decision: what counts
        // is the decoded line's own `kind` / `usage`.
        const may_have_usage = std.mem.indexOf(u8, line, "\"usage\":") != null;
        const may_be_first_text = first_user_text.len == 0 and std.mem.indexOf(u8, line, "\"kind\":\"user_text\"") != null;
        if (!may_have_usage and !may_be_first_text) continue;
        const parsed = ledger.parseEventLine(a, line) catch continue;
        if (parsed.value.usage) |u| addUsage(&total, u);
        if (first_user_text.len == 0 and std.mem.eql(u8, parsed.value.kind, "user_text")) {
            if (parsed.value.text) |t| first_user_text = try summarize(a, t);
        }
    }

    const h = (header orelse return error.MissingHeader).value;
    const active = try a.alloc([]const u8, h.composition.active.len);
    for (h.composition.active, active) |ref, *out| out.* = try std.fmt.allocPrint(a, "{s}@{s}", .{ ref.id, ref.version });

    const id = file_name[0 .. file_name.len - ".jsonl".len];
    const latest = outcome.latestFor(outcomes, id);
    return .{
        .id = id,
        .created = h.created,
        .parent = h.parent,
        // The episode is resolved once the whole listing is known; until then a
        // session is its own root, which is also the final answer for most.
        .root = id,
        .model = h.model,
        .provider = h.model_identity.provider,
        .model_id = h.model_identity.model,
        .nulya = h.nulya,
        .events = events,
        .composition = .{
            .active = active,
            .native_tools = h.composition.native_tools,
            .system_prompts = try prompts.forActive(a, h.composition.active),
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

fn addUsage(total: *ledger.Usage, u: ledger.Usage) void {
    total.input_tokens += u.input_tokens;
    total.output_tokens += u.output_tokens;
    total.cache_read_tokens += u.cache_read_tokens;
    total.cache_write_tokens += u.cache_write_tokens;
}

/// Which system prompts a frozen `id@version` contributes (DESIGN §7.5), read
/// from its manifest and memoized by `id@version` — versions are
/// content-addressed, so one read answers for every session pinning it.
///
/// Best effort throughout: a version this machine no longer holds (built in
/// another checkout, deactivated and pruned) contributes nothing rather than
/// failing the listing. Absence here means "unknown", not "none".
const PromptIndex = struct {
    roots: ?*const roots_mod.Roots,
    cache: std.StringHashMap([]const []const u8),

    fn forActive(self: *PromptIndex, a: std.mem.Allocator, active: []const ledger.PinnedExtensionRef) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (active) |ref| {
            for (try self.forOne(a, ref)) |p| try out.append(a, p);
        }
        return out.toOwnedSlice(a);
    }

    fn forOne(self: *PromptIndex, a: std.mem.Allocator, ref: ledger.PinnedExtensionRef) ![]const []const u8 {
        const roots = self.roots orelse return &.{};
        const key = try std.fmt.allocPrint(a, "{s}@{s}", .{ ref.id, ref.version });
        const gop = try self.cache.getOrPut(key);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = &.{};

        const resolved = roots.resolveVersion(a, ref.id, ref.version) catch return gop.value_ptr.*;
        defer resolved.deinit(a);
        const paths = try a.alloc([]const u8, resolved.manifest.system_prompts.len);
        // The manifest owns its strings; the listing outlives it, so copy while
        // stamping each one with the version it came from.
        for (resolved.manifest.system_prompts, paths) |p, *slot| {
            slot.* = try std.fmt.allocPrint(a, "{s}/{s}", .{ key, p });
        }
        gop.value_ptr.* = paths;
        return paths;
    }
};

/// Fill in each view's `root` (the oldest listed ancestor through `parent`) and
/// `episode_usage` (that episode's total). Sessions fork for compaction and
/// handoff, so the cost of a task is spread over a chain of files; joining them
/// is a projection, never a change to what any journal recorded.
///
/// A parent that is not in the listing (another workspace, a deleted file) makes
/// its child the root of its own episode: a listing must not fail because a file
/// it cannot see is gone.
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
        addUsage(gop.value_ptr, v.usage);
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
            // Who judged belongs next to the verdict: a session that graded
            // itself must not read like someone else's assessment of it.
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
            if (v.nulya.version.len != 0) try out.writer.print("  nulya {s}", .{v.nulya.version});
            if (v.first_user_text.len != 0) try out.writer.print("  {s}", .{v.first_user_text});
            try out.writer.writeByte('\n');
        }
        if (views.len == 0) try out.writer.writeAll("no sessions\n");
    }
    try printRaw(io, out.written());
}

/// `nulya session outcome <id> <verdict> [--note <text>] [--seq N]` — record how
/// a session turned out (DESIGN §3.3). The verdict is a judgment ABOUT the
/// session, not a turn IN it, so this writes only the outcome journal: it never
/// opens the session file and never takes its writer lease, which is what lets a
/// session still running (or being stepped by another process) be judged right
/// now. `--seq` narrows a line to one assistant turn; it stays a projection, so
/// the number is validated as a positive integer and NOT checked against the
/// session's length — reading the ledger to bounds-check it would trade the one
/// property that makes this command safe on a live session for a fact the reader
/// can derive itself.
fn sessionOutcome(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try printErr(io, "usage: nulya session outcome <id> <success|partial|failure> [--note <text>] [--seq N]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const verdict = outcome.Verdict.parse(args[1]) orelse {
        try printOut(alloc, io, "invalid verdict '{s}' (want success|partial|failure)\n", .{args[1]});
        return 1;
    };
    const note = flagValue(args[2..], "--note");
    var seq: ?u64 = null;
    if (flagValue(args[2..], "--seq")) |v| {
        const n = std.fmt.parseInt(u64, v, 10) catch 0;
        if (n == 0) {
            try printErr(io, "--seq must be a positive integer\n");
            return 1;
        }
        seq = n;
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    // Who is judging. This command reaches the model through `shell`, whose env
    // names the live session — so a session grading itself is a fact the journal
    // can record instead of a fact the slow loop has to guess (DESIGN §3.3).
    const by = try envSessionId(alloc);
    defer if (by) |b| alloc.free(b);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const at = try launch.rfc3339Now(alloc, io);
    defer alloc.free(at);
    try outcome.append(alloc, io, cwd_path, .{
        .session = id,
        .verdict = verdict,
        .note = note,
        .at = at,
        .source = if (by != null) .agent else .human,
        .by = by,
        .seq = seq,
    });

    try printOut(alloc, io, "{s}: {s}\n", .{ id, @tagName(verdict) });
    return 0;
}

/// Collect every `--with <id>[@<version>]` (the flag is repeatable). Slices
/// borrow `args`; the caller owns only the returned array.
fn withRefs(alloc: std.mem.Allocator, args: []const []const u8) ![]composition.WithRef {
    var out: std.ArrayList(composition.WithRef) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--with")) continue;
        try out.append(alloc, withRef(args[i + 1]));
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// The session's native tool pins: the config's `registry.pinned_native_tools`
/// first, then every `--pin <ext:id/tool>` in argv order (the flag is
/// repeatable). Both spellings mean the same thing and are equally strict —
/// config says "in this workspace, always", `--pin` says "for this session"
/// (DESIGN §5.1). An id already present is not added twice, so naming a
/// configured pin again is a no-op rather than a `DuplicateToolId`. Slices
/// borrow `configured` and `args`; the caller owns only the returned array.
fn pinRefs(alloc: std.mem.Allocator, configured: []const []const u8, args: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (configured) |pin| {
        if (!containsString(out.items, pin)) try out.append(alloc, pin);
    }
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--pin")) continue;
        if (!containsString(out.items, args[i + 1])) try out.append(alloc, args[i + 1]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn sessionNew(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const id = (try createSession(alloc, io, args)) orelse return 1;
    defer alloc.free(id);
    try printOut(alloc, io, "{s}\n", .{id});
    return 0;
}

/// Create a durable session file from `session new`'s own flags and return its
/// id (owned by the caller), or null when the request was refused and the
/// reason has already been printed. `session new` is a thin printer over this;
/// the bare-`nulya` demo is its other caller, so the two cannot drift on how a
/// session is composed (DESIGN §14).
pub fn createSession(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !?[]u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // `--parent <id>:<seq>` names the lineage this session continues — a fork,
    // or the new file a compaction opens (DESIGN §3.4, §11). The parent must
    // exist: a lineage pointer into nothing is not provenance. Its header is
    // also where an unnamed model comes from, below.
    var parent: ?ledger.ParentRef = null;
    var parent_header: ?ledger.OwnedHeader = null;
    defer if (parent_header) |*h| h.deinit();
    if (flagValue(args, "--parent")) |p| {
        const ref = parseParent(p) orelse {
            try printErr(io, "invalid --parent (want <session>:<seq>)\n");
            return null;
        };
        if (!launch.isValidSessionId(ref.session)) {
            try printErr(io, "invalid --parent session id\n");
            return null;
        }
        const ppath = try launch.sessionPath(alloc, ref.session);
        defer alloc.free(ppath);
        parent_header = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), ppath) catch |err| {
            if (err == error.UnsupportedLedgerVersion) {
                try printOut(alloc, io, "session '{s}' was written by a newer nulya; this binary reads ledger v{d}\n", .{ ref.session, ledger.format_version });
            } else {
                try printOut(alloc, io, "cannot read parent session '{s}': {s}\n", .{ ref.session, @errorName(err) });
            }
            return null;
        };
        parent = ref;
    }

    // `--profile` names HOW to reach a provider, `--model` WHICH of its ids to
    // run (default: the profile's own default). A typo'd profile is refused
    // rather than silently frozen as scripted; a real profile whose credential
    // is missing still resolves scripted (the offline stand-in) but says so.
    const named_profile = flagValue(args, "--profile");
    const model_id = flagValue(args, "--model");

    // A fork continues its parent's model unless told otherwise: a compaction
    // opens a new file for the same conversation, and who that conversation is
    // with must not change because `active_profile` moved meanwhile (physics §2
    // in spirit — the identity was frozen once, at the root). Composition
    // deliberately does NOT come along: a new session is exactly where today's
    // pins and newly activated versions are meant to take hold (DESIGN §5.1,
    // §7.5), and a fork is a session boundary like any other.
    //
    // Two levels of continuing, because the two flags mean different things:
    // `--profile` names a different way to reach a provider, so it replaces the
    // parent's; `--model` only picks another id WITHIN a profile, so the
    // parent's profile still carries. Naming either re-resolves the identity
    // against today's config; naming neither takes the parent's frozen
    // descriptor verbatim, which is the compaction case.
    // An empty one is a legacy header that never recorded a profile: absent, not
    // a profile named "".
    const parent_profile: ?[]const u8 = if (parent_header) |h|
        (if (h.value.model.len != 0) h.value.model else null)
    else
        null;
    const inherited: ?ledger.ModelDescriptor = if (parent_header) |h| blk: {
        if (named_profile != null or model_id != null) break :blk null;
        break :blk if (h.value.model_identity.provider.len != 0) h.value.model_identity else null;
    } else null;

    const profile = named_profile orelse parent_profile orelse
        (if (cfg.provider.active_profile.len != 0) cfg.provider.active_profile else "scripted");

    // An inherited identity needs no resolution — and no credential warning: it
    // never degrades to scripted, so there is nothing to explain here. A missing
    // credential is reported, loudly and once, by the `step` that needs it.
    var identity: ledger.ModelDescriptor = undefined;
    if (inherited) |d| {
        identity = d;
    } else {
        const profile_cfg = cfg.provider.findProfile(profile) orelse {
            try printOut(alloc, io, "no such profile '{s}' (see `nulya config show`)\n", .{profile});
            return null;
        };
        if (!launch.credentialAvailable(alloc, io, profile_cfg, &host)) {
            var paths = try config.ConfigPaths.init(alloc, &host);
            defer paths.deinit(alloc);
            const warn = if (profile_cfg.kind == .codex)
                try std.fmt.allocPrint(alloc, "warning: profile '{s}' has no credential (run `codex login`); session frozen as scripted\n", .{profile})
            else
                try std.fmt.allocPrint(alloc, "warning: profile '{s}' has no credential (put api_key in {s}, or set {s}); session frozen as scripted\n", .{ profile, paths.user, profile_cfg.api_key_env });
            defer alloc.free(warn);
            try printErr(io, warn);
        }
        // Freeze the RESOLVED model identity now: config chooses the model at
        // creation, and a later config edit can never change this session's
        // model (DESIGN §3).
        identity = launch.resolveDescriptor(alloc, io, cfg.provider, &host, profile, model_id);
    }

    const id = try launch.genSessionId(alloc, io);
    defer alloc.free(id);
    const created = try launch.rfc3339Now(alloc, io);
    defer alloc.free(created);
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    try std.Io.Dir.cwd().createDirPath(io, launch.sessions_dir);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    var lenv = launch.localEnvironment(alloc, io, &cfg) catch |err| switch (err) {
        error.UnsupportedEnvironmentBackend => {
            try printOut(alloc, io, "environment backend '{s}' is not implemented; only local\n", .{@tagName(cfg.environment.backend)});
            return null;
        },
        else => return err,
    };
    defer lenv.deinit();

    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);

    // `--with <id>[@<version>]` (repeatable) brings a BUILT version into this
    // one session's composition without activating it anywhere (DESIGN §14).
    const with = try withRefs(alloc, args);
    defer alloc.free(with);

    // `--pin ext:<id>/<tool>` (repeatable), unioned with the configured pins:
    // the whole native tool selection, and the only one there is — the usage
    // journal never puts a tool on the model's face by itself (DESIGN §5.1).
    const pins = try pinRefs(alloc, cfg.registry.pinned_native_tools, args);
    defer alloc.free(pins);

    // A placeholder handle is enough since `new` never steps.
    var holder: launch.ModelHolder = .{ .scripted = .{} };
    const scratch = try launch.sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    var sess = session.AgentSession.createDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = scratch,
        },
        .extension_roots = ext_roots,
        .registry = .{
            .pinned_native_tools = pins,
            .max_tools = cfg.registry.max_tools,
            .with = with,
        },
    }, .{
        .workspace = std.Io.Dir.cwd(),
        .session_path = spath,
        .session_id = id,
        .model_profile = profile,
        .model_identity = identity,
        .created = created,
        .nulya_version = launch.version,
        .parent = parent,
    }) catch |err| switch (err) {
        // The caller named these extensions, so an unusable one is not a warning.
        error.WithVersionNotFound => {
            try printOut(alloc, io, "session new failed: --with names an extension with no such built version (see `nulya ext list`)\n", .{});
            return null;
        },
        // Same rule for pins: a session missing a tool the operator asked for is
        // not the session that was asked for. Name the pins so the fix is
        // obvious — the bad one is in that list, in `.nulya/config.toml` or on
        // the command line.
        error.PinnedExtensionNotActive => {
            try printPinFailure(alloc, io, pins, "names an extension with no active version here (see `nulya ext list`)");
            return null;
        },
        error.PinnedToolNotDeclared => {
            try printPinFailure(alloc, io, pins, "names a tool its active version does not declare (see `nulya ext inspect <id>`)");
            return null;
        },
        error.InvalidStableToolId => {
            try printPinFailure(alloc, io, pins, "is not a stable tool id (want ext:<extension-id>/<tool-name>)");
            return null;
        },
        error.ToolBudgetExceeded => {
            try printPinFailure(alloc, io, pins, "does not fit registry.max_tools (builtins included)");
            return null;
        },
        else => {
            try printOut(alloc, io, "session new failed: {s}\n", .{@errorName(err)});
            return null;
        },
    };
    sess.deinit();

    return try alloc.dupe(u8, id);
}

/// One line for a refused pin: what went wrong plus the pins this session asked
/// for, so the reader does not have to guess which of the two sources carried it.
fn printPinFailure(alloc: std.mem.Allocator, io: std.Io, pins: []const []const u8, reason: []const u8) !void {
    const listed = try std.mem.join(alloc, " ", pins);
    defer alloc.free(listed);
    try printOut(alloc, io, "session new failed: a pin {s}; pinned: {s}\n", .{ reason, listed });
}

fn sessionAppend(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session append <id> <text> | --file <path>\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }

    const text = if (flagValue(args[1..], "--file")) |path|
        std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch {
            try printOut(alloc, io, "cannot read --file '{s}'\n", .{path});
            return 1;
        }
    else if (args.len >= 2)
        try alloc.dupe(u8, args[1])
    else {
        try printErr(io, "usage: nulya session append <id> <text> | --file <path>\n");
        return 1;
    };
    defer alloc.free(text);

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    // `append` never writes the session file (its one writer is `step`): the
    // user turn is deposited into the session inbox under a fresh name and
    // appended at the next step boundary — including mid-run, if a step
    // process is going right now.
    var nonce: [4]u8 = undefined;
    io.random(&nonce);
    const name = try std.fmt.allocPrint(alloc, "msg-{d}-{x}", .{
        std.Io.Timestamp.now(io, .real).toNanoseconds(),
        std.mem.readInt(u32, &nonce, .little),
    });
    defer alloc.free(name);
    try ledger.depositEvent(alloc, io, std.Io.Dir.cwd(), spath, name, .{ .user_text = text });
    return 0;
}

/// The `session step --stream` line protocol (tui.md §2.2): one JSON object per
/// line on stdout, written AS the step runs instead of once it is over. Lines
/// carrying a `stream` field are transient observations; lines without one are
/// ledger events in exactly the `session events` shape. Under `--stream` stdout
/// carries nothing else — diagnostics become `{"stream":"run","event":"error"}`.
///
/// This is the whole protocol in one place: `loop.StepObserver` hands it facts,
/// it turns them into lines. It never touches the session, so it stays pure
/// observation (physics: model-visible state changes only by `append`).
const StepStream = struct {
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    /// Ledger index of the first event not yet flushed as a line.
    printed: usize = 0,
    /// How the most recent step ended, for the `run done` line's `stopped`.
    last_status: loop.StepStatus = .completed,
    /// First write failure, if any. An observer must not fail the step, so the
    /// error is parked here and reported by the caller as a non-zero exit.
    err: ?anyerror = null,

    fn note(self: *StepStream, e: anyerror) void {
        if (self.err == null) self.err = e;
    }

    fn observer(self: *StepStream) loop.StepObserver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: loop.StepObserver.VTable = .{
        .modelEvent = onModelEvent,
        .modelRetry = onModelRetry,
        .toolBegin = onToolBegin,
        .toolEnd = onToolEnd,
        .stepEnd = onStepEnd,
    };

    fn onModelEvent(ptr: *anyopaque, event: provider.StreamEvent) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        // A complete reasoning item is opaque provider bytes kept for replay, not
        // something to render; `thinking_delta` is the display channel (§2.2).
        if (event == .reasoning_item) return;
        self.modelLine(event) catch |e| self.note(e);
    }

    fn onModelRetry(ptr: *anyopaque, retry: loop.RetryNotice) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.retryLine(retry) catch |e| self.note(e);
    }

    fn onToolBegin(ptr: *anyopaque, call: ledger.ToolCall) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.toolBeginLine(call) catch |e| self.note(e);
    }

    fn onToolEnd(ptr: *anyopaque, call: ledger.ToolCall, ok: bool) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.toolEndLine(call, ok) catch |e| self.note(e);
    }

    fn onStepEnd(ptr: *anyopaque, events: []const ledger.Event, step_outcome: loop.StepOutcome) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.last_status = step_outcome.status;
        // Ledger lines first, then the boundary marker: a reader that has seen
        // `step end` knows it has every event of that step.
        self.flushEvents(events) catch |e| self.note(e);
        self.stepEndLine(step_outcome) catch |e| self.note(e);
    }

    /// Emit every ledger event not yet reported, in `session events` shape. The
    /// seq of view index i is i+1 — the same numbering the session file uses.
    fn flushEvents(self: *StepStream, events: []const ledger.Event) !void {
        while (self.printed < events.len) : (self.printed += 1) {
            const line = try ledger.encodeEventLine(self.alloc, events[self.printed], self.printed + 1);
            defer self.alloc.free(line);
            try self.out.writeAll(line);
        }
        try self.out.flush();
    }

    fn modelLine(self: *StepStream, event: provider.StreamEvent) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("model");
        try jw.objectField("event");
        switch (event) {
            .started => try jw.write("started"),
            .text_delta => |t| {
                try jw.write("text_delta");
                try jw.objectField("text");
                try jw.write(t);
            },
            .thinking_delta => |t| {
                try jw.write("thinking_delta");
                try jw.objectField("text");
                try jw.write(t);
            },
            .reasoning_item => unreachable, // filtered in onModelEvent
            .tool_use_start => |s| {
                try jw.write("tool_use_start");
                try jw.objectField("index");
                try jw.write(s.index);
                try jw.objectField("id");
                try jw.write(s.id);
                try jw.objectField("name");
                try jw.write(s.name);
            },
            .tool_use_input_delta => |d| {
                try jw.write("tool_use_input_delta");
                try jw.objectField("index");
                try jw.write(d.index);
                try jw.objectField("fragment");
                try jw.write(d.fragment);
            },
            .usage => |u| {
                try jw.write("usage");
                try jw.objectField("input_tokens");
                try jw.write(u.input_tokens);
                try jw.objectField("output_tokens");
                try jw.write(u.output_tokens);
                try jw.objectField("cache_read_tokens");
                try jw.write(u.cache_read_tokens);
                try jw.objectField("cache_write_tokens");
                try jw.write(u.cache_write_tokens);
            },
            .done => |stop| {
                try jw.write("done");
                try jw.objectField("stop");
                try jw.write(@tagName(stop));
            },
        }
        try jw.endObject();
        try self.endLine();
    }

    /// The model request failed transiently; the loop is about to send it again.
    /// A reader drops whatever this turn streamed so far — the retry starts over.
    fn retryLine(self: *StepStream, retry: loop.RetryNotice) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("model");
        try jw.objectField("event");
        try jw.write("retry");
        try jw.objectField("attempt");
        try jw.write(retry.attempt);
        try jw.objectField("max_retries");
        try jw.write(retry.max_retries);
        try jw.objectField("delay_ms");
        try jw.write(retry.delay_ms);
        try jw.objectField("error");
        try jw.write(@errorName(retry.err));
        try jw.endObject();
        try self.endLine();
    }

    fn toolBeginLine(self: *StepStream, call: ledger.ToolCall) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("tool");
        try jw.objectField("event");
        try jw.write("begin");
        try jw.objectField("call_id");
        try jw.write(call.id);
        try jw.objectField("tool");
        try jw.write(call.tool);
        try jw.endObject();
        try self.endLine();
    }

    /// `call_id` alone identifies the call — the reader already learned its tool
    /// from the matching `begin` (and from `tool_use_start` before that).
    fn toolEndLine(self: *StepStream, call: ledger.ToolCall, ok: bool) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("tool");
        try jw.objectField("event");
        try jw.write("end");
        try jw.objectField("call_id");
        try jw.write(call.id);
        try jw.objectField("ok");
        try jw.write(ok);
        try jw.endObject();
        try self.endLine();
    }

    fn stepEndLine(self: *StepStream, step_outcome: loop.StepOutcome) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("step");
        try jw.objectField("event");
        try jw.write("end");
        try jw.objectField("status");
        try jw.write(@tagName(step_outcome.status));
        // Only the reply-was-cut fact is worth a column: end_turn / tool_use are
        // already visible from the events, and the line stays as it was for them.
        if (step_outcome.stop_reason == .max_tokens) {
            try jw.objectField("stop");
            try jw.write("max_tokens");
        }
        try jw.endObject();
        try self.endLine();
    }

    fn runDone(self: *StepStream, steps: usize, stopped: []const u8) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("run");
        try jw.objectField("event");
        try jw.write("done");
        try jw.objectField("steps");
        try jw.write(steps);
        try jw.objectField("stopped");
        try jw.write(stopped);
        try jw.endObject();
        try self.endLine();
    }

    fn runError(self: *StepStream, message: []const u8) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("run");
        try jw.objectField("event");
        try jw.write("error");
        try jw.objectField("message");
        try jw.write(message);
        try jw.endObject();
        try self.endLine();
    }

    /// One line, flushed: the reader consumes stdout line by line as it arrives.
    fn endLine(self: *StepStream) !void {
        try self.out.writeByte('\n');
        try self.out.flush();
    }
};

/// Why the run stopped, from facts the kernel already reports: a canceled step
/// short-circuits `run`; a reply cut by `max_tokens` is not a finished turn
/// (whether it stopped the run alone or as the second in a row); an assistant
/// turn with no calls ends the turn; anything else means the step budget ran out.
fn stoppedReason(last_status: loop.StepStatus, last_stop: provider.StopReason, turn_done: bool) []const u8 {
    if (last_status == .canceled) return "canceled";
    if (last_stop == .max_tokens) return "max_tokens";
    return if (turn_done) "end_turn" else "budget";
}

/// A `session step` diagnostic. Plain text without `--stream` (byte-identical to
/// what it has always printed); a `run error` line with it.
fn stepFail(
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: ?*StepStream,
    comptime fmt: []const u8,
    args: anytype,
) !u8 {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    if (stream) |s| {
        try s.runError(msg);
    } else {
        try printOut(alloc, io, "{s}\n", .{msg});
    }
    return 1;
}

/// Say once, on resume, that this binary's kernel prompt / builtin definitions
/// are not the ones frozen into the session (DESIGN §3.4). Those constants enter
/// the session's model-visible state but live in the BINARY, so an upgrade moves
/// them under an existing session — the stamp is what makes that visible.
///
/// It is provenance, not a gate: nothing is refused, and a header with no stamp
/// (written before this existed) says nothing, so it warns about nothing. The
/// line goes to stderr, which keeps `--stream` stdout pure JSON (DESIGN §14).
fn warnKernelDrift(alloc: std.mem.Allocator, io: std.Io, id: []const u8, stamp: ledger.Stamp) !void {
    if (stamp.kernel_hash.len == 0) return;
    const mine = try composition.kernelHash(alloc);
    defer alloc.free(mine);
    if (std.mem.eql(u8, mine, stamp.kernel_hash)) return;
    const by = if (stamp.version.len != 0) stamp.version else "unknown";
    const msg = try std.fmt.allocPrint(
        alloc,
        "warning: session {s} was created by nulya {s} whose kernel prompt/builtins differ from this binary's; its frozen system prompt has changed\n",
        .{ id, by },
    );
    defer alloc.free(msg);
    try printErr(io, msg);
}

fn sessionStep(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session step <id> [--max-steps N] [--effort E] [--stream]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const streaming = sliceHasFlag(args[1..], "--stream");
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var stream_state: StepStream = .{ .alloc = alloc, .out = &stdout.interface };
    const stream: ?*StepStream = if (streaming) &stream_state else null;
    // The kernel clamps this to `session.max_steps_ceiling`: a driver can lower
    // the budget, never raise it.
    var max_steps: usize = session.max_steps_ceiling;
    if (flagValue(args[1..], "--max-steps")) |v| {
        max_steps = std.fmt.parseInt(usize, v, 10) catch 0;
        if (max_steps == 0) {
            try printErr(io, "--max-steps must be a positive integer\n");
            return 1;
        }
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();

    var hdr = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), spath) catch |err| {
        // A file this binary is too old to read is not a missing session: say
        // which format it reads, so upgrading is the obvious answer.
        if (err == error.UnsupportedLedgerVersion) {
            return stepFail(alloc, io, stream, "session '{s}' was written by a newer nulya; this binary reads ledger v{d}", .{ id, ledger.format_version });
        }
        return stepFail(alloc, io, stream, "no such session '{s}': {s}", .{ id, @errorName(err) });
    };
    defer hdr.deinit();
    try warnKernelDrift(alloc, io, id, hdr.value.nulya);

    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    var lenv = launch.localEnvironment(alloc, io, &cfg) catch |err| switch (err) {
        error.UnsupportedEnvironmentBackend => {
            return stepFail(alloc, io, stream, "environment backend '{s}' is not implemented; only local", .{@tagName(cfg.environment.backend)});
        },
        else => return err,
    };
    defer lenv.deinit();
    // Let shell children (e.g. `nulya ext activate`) find the live session so
    // they can deposit capability notes into its inbox (DESIGN §5.3).
    try lenv.env.put("NULYA_SESSION", spath);

    // Reconstruct the model frozen at creation, re-resolving only the credential.
    // No silent fallback: a real session whose key is gone fails loudly rather
    // than quietly becoming a scripted session (DESIGN §3). The session id is
    // also the prompt-cache scope, so a provider that keys its cache explicitly
    // keeps hitting it across separate `step` processes.
    // The credential is re-resolved every step: the profile's own `api_key`
    // (user config, found by the header's profile name), else the env var the
    // header names, else the Codex auth file.
    const inline_key = if (cfg.provider.findProfile(hdr.value.model)) |p| p.api_key else null;
    var holder = launch.buildFromDescriptor(alloc, io, hdr.value.model_identity, &host, .{ .cache_key = id, .inline_key = inline_key }) catch |err| switch (err) {
        error.MissingCredential => {
            const credential = if (hdr.value.model_identity.api_key_env.len != 0) hdr.value.model_identity.api_key_env else "codex login";
            return stepFail(alloc, io, stream, "session '{s}' is a '{s}' session but its credential (profile '{s}' api_key, or {s}) is not available; refusing to run (no silent fallback)", .{ id, hdr.value.model_identity.provider, hdr.value.model, credential });
        },
        error.ProviderUnavailable => {
            return stepFail(alloc, io, stream, "session '{s}' was created with provider '{s}', which this build cannot construct", .{ id, hdr.value.model_identity.provider });
        },
        else => return err,
    };
    defer holder.deinit();

    // Effort is a generation option, not identity (DESIGN §3): the driver may
    // set it per step; otherwise the profile / catalog default applies.
    const effort = flagValue(args[1..], "--effort") orelse
        cfg.defaultEffort(hdr.value.model, hdr.value.model_identity.model);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);

    const scratch = try launch.sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    var sess = session.AgentSession.openDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = scratch,
            .retry = cfg.provider.retry,
            .observer = if (stream) |s| s.observer() else null,
        },
        .model_options = .{ .effort = effort },
        .extension_roots = ext_roots,
    }, .{ .workspace = std.Io.Dir.cwd(), .session_path = spath }) catch |err| {
        return stepFail(alloc, io, stream, "session open failed: {s}", .{@errorName(err)});
    };
    defer sess.deinit();

    const before = sess.l.len();
    if (stream) |s| s.printed = before;
    const steps = sess.run(max_steps) catch |err| {
        // Whatever this run did append before it faulted is still fact; report
        // those lines, then the error.
        if (stream) |s| s.flushEvents(sess.l.view()) catch {};
        // Not a fault but a state: the last reply was cut off, and stepping it
        // again would send it back as a prefill (DESIGN §4). Say what to do
        // instead of naming an error code the caller has to look up.
        if (err == error.TruncatedTurnNeedsInput) {
            return stepFail(alloc, io, stream, "the last reply was cut off at its output cap; append a message before stepping again", .{});
        }
        return stepFail(alloc, io, stream, "session step failed: {s}", .{@errorName(err)});
    };

    if (stream) |s| {
        // Every event was already flushed at its step boundary; only the run
        // verdict is left.
        try s.runDone(steps, stoppedReason(s.last_status, sess.lastStopReason(), sess.lastAssistantDone()));
        // A dropped observation is not a broken step, but the reader's picture is
        // incomplete — say so on stderr (stdout stays pure JSON) and exit non-zero.
        if (s.err) |e| {
            try printErr(io, "stream write failed: ");
            try printErr(io, @errorName(e));
            try printErr(io, "\n");
            return 1;
        }
        return 0;
    }

    // stdout is the events this invocation appended, as one JSONL line each.
    for (sess.l.view()[before..], before..) |ev, i| {
        const line = try ledger.encodeEventLine(alloc, ev, i + 1);
        defer alloc.free(line);
        try printRaw(io, line);
    }
    return 0;
}

fn sessionEvents(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session events <id> [--since N] [--follow]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    var since: u64 = 0;
    if (flagValue(args[1..], "--since")) |v| since = std.fmt.parseInt(u64, v, 10) catch 0;
    const follow = sliceHasFlag(args[1..], "--follow");

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var tail: EventTail = .{ .since = since };
    try tail.dump(alloc, io, std.Io.Dir.cwd(), spath, &stdout.interface);
    try stdout.interface.flush();
    if (!follow) return 0;

    // Poll for newly appended events (DESIGN §14 / PLAN §3.2: polling is enough).
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        try tail.dump(alloc, io, std.Io.Dir.cwd(), spath, &stdout.interface);
        try stdout.interface.flush();
    }
}

/// A read-only tail over a session file's raw lines. `events` never opens the
/// file for writing and never parses or re-encodes events: the file IS the wire
/// format, and its writer already validated that event line k carries seq k, so
/// selecting by seq is counting complete lines past the header.
const EventTail = struct {
    since: u64,
    /// Byte offset of the first unread line.
    offset: usize = 0,
    /// Event lines consumed so far (== the seq of the last one).
    seq: u64 = 0,
    header_seen: bool = false,

    /// Write every complete, not-yet-seen event line with seq > `since` to `out`.
    fn dump(self: *EventTail, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, spath: []const u8, out: *std.Io.Writer) !void {
        const bytes = try dir.readFileAlloc(io, spath, alloc, .unlimited);
        defer alloc.free(bytes);
        const clean_end: usize = @intCast(ledger.lastCompleteLineEnd(bytes));
        if (clean_end < self.offset) return error.SessionFileShrank;
        var pos = self.offset;
        while (pos < clean_end) {
            // `clean_end` sits just past a newline, so one exists at or after `pos`.
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n').?;
            const line = bytes[pos .. nl + 1];
            pos = nl + 1;
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            if (!self.header_seen) {
                self.header_seen = true;
                continue;
            }
            self.seq += 1;
            if (self.seq > self.since) try out.writeAll(line);
        }
        self.offset = pos;
    }
};

fn sessionCancel(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session cancel <id>\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }
    // The kernel consumes the marker at the session's next step boundary —
    // between steps of a run already going, or at the start of the next `step`.
    try session.requestCancel(alloc, io, std.Io.Dir.cwd(), spath);
    try printOut(alloc, io, "cancel requested for {s}\n", .{id});
    return 0;
}

fn sessionExists(io: std.Io, spath: []const u8) bool {
    std.Io.Dir.cwd().access(io, spath, .{}) catch return false;
    return true;
}

fn parseParent(s: []const u8) ?ledger.ParentRef {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const session_id = s[0..colon];
    if (session_id.len == 0) return null;
    const seq = std.fmt.parseInt(u64, s[colon + 1 ..], 10) catch return null;
    return .{ .session = session_id, .seq = seq };
}

fn sessionUsage(io: std.Io) !u8 {
    try printRaw(io,
        \\usage:
        \\  nulya session new [--profile P] [--model ID] [--parent <id>:<seq>] [--with <id>[@<ver>]]… [--pin ext:<id>/<tool>]…
        \\                                                             freeze composition + model, print a new session id
        \\                                                             (P: a config profile, default active_profile; ID: one of its
        \\                                                             models, default the profile's — see `nulya config show`)
        \\                                                             --with composes a built version into this session (membership)
        \\                                                             --pin puts an extension tool on the model's tool face for this
        \\                                                             session, on top of registry.pinned_native_tools; strict
        \\  nulya session append <id> <text> | --file <path>           queue a user turn (appended at the next step boundary)
        \\  nulya session step <id> [--max-steps N] [--effort E] [--stream]
        \\                                                             run to turn end (or the budget); stdout = event JSONL
        \\                                                             --effort overrides the profile/catalog default for this run
        \\                                                             --stream also emits transient model/tool lines as they happen
        \\  nulya session events <id> [--since N] [--follow]           print events as JSONL (read-only tail)
        \\  nulya session cancel <id>                                  request cancel at the next step boundary
        \\  nulya session list [--json]                                read-only projection of every session here: composition,
        \\                                                             event count, usage (own + episode), latest verdict
        \\  nulya session outcome <id> <success|partial|failure> [--note <text>] [--seq N]
        \\                                                             record how the session turned out (journal only — never
        \\                                                             touches the session file, so a running one can be judged)
        \\                                                             --seq judges ONE assistant turn instead of the session
        \\
    );
    return 0;
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
                .events = 0,
                .composition = .{ .active = &.{}, .native_tools = &.{}, .system_prompts = &.{} },
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

test "EventTail prints raw event lines past --since, skips the header and a torn tail, and resumes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = try ledger.encodeHeaderLine(alloc, .{ .session = "s" });
    defer alloc.free(header);
    const e1 = try ledger.encodeEventLine(alloc, .{ .user_text = "one" }, 1);
    defer alloc.free(e1);
    const e2 = try ledger.encodeEventLine(alloc, .{ .user_text = "two" }, 2);
    defer alloc.free(e2);
    const e3 = try ledger.encodeEventLine(alloc, .{ .user_text = "three" }, 3);
    defer alloc.free(e3);

    // Header, two complete events, and a torn third being written right now.
    const first = try std.mem.concat(alloc, u8, &.{ header, e1, e2, e3[0 .. e3.len / 2] });
    defer alloc.free(first);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = first });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var tail: EventTail = .{ .since = 1 };
    try tail.dump(alloc, io, tmp.dir, "s.jsonl", &out.writer);
    try std.testing.expectEqualStrings(e2, out.written()); // seq 1 filtered, torn 3 withheld

    // The writer finishes the line; a follow-up dump prints only what is new,
    // and the file was never modified by the reader.
    const whole = try std.mem.concat(alloc, u8, &.{ header, e1, e2, e3 });
    defer alloc.free(whole);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = whole });
    out.clearRetainingCapacity();
    try tail.dump(alloc, io, tmp.dir, "s.jsonl", &out.writer);
    try std.testing.expectEqualStrings(e3, out.written());
    const on_disk = try tmp.dir.readFileAlloc(io, "s.jsonl", alloc, .unlimited);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings(whole, on_disk);
}

test "--with is repeatable and splits <id>[@<version>]" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{
        "--profile",      "scripted",
        "--with",         "evolution",
        "--with",         "web.search@v-0123456789abcdef01234567",
        "--parent",       "s-1:4",
        "--with-nothing", "ignored",
        "--with",
    }; // a trailing --with with no value is not a ref
    const refs = try withRefs(alloc, &args);
    defer alloc.free(refs);

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("evolution", refs[0].id);
    try std.testing.expect(refs[0].version == null); // no @version = its current
    try std.testing.expectEqualStrings("web.search", refs[1].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", refs[1].version.?);

    const none = try withRefs(alloc, &.{ "--profile", "scripted" });
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "--pin unions with the configured pins, in order, without duplicating one" {
    const alloc = std.testing.allocator;
    const configured = [_][]const u8{ "ext:web.search/web_search", "ext:notes/append" };
    const args = [_][]const u8{
        "--profile", "scripted",
        "--pin",     "ext:demo/greet",
        // Re-naming a configured pin is a no-op, not a duplicate id.
        "--pin",     "ext:notes/append",
        "--pinned",  "ignored",
        "--pin",
    }; // a trailing --pin with no value is not a pin
    const pins = try pinRefs(alloc, &configured, &args);
    defer alloc.free(pins);

    try std.testing.expectEqual(@as(usize, 3), pins.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", pins[0]);
    try std.testing.expectEqualStrings("ext:notes/append", pins[1]);
    try std.testing.expectEqualStrings("ext:demo/greet", pins[2]);

    // Neither source: an empty native selection, which is the default face.
    const none = try pinRefs(alloc, &.{}, &.{ "--profile", "scripted" });
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // Config alone is enough; the flag is only the per-session addition.
    const configured_only = try pinRefs(alloc, &configured, &.{});
    defer alloc.free(configured_only);
    try std.testing.expectEqual(@as(usize, 2), configured_only.len);
}

test "parseParent parses <session>:<seq> and rejects malformed input" {
    const p = parseParent("s-123:41").?;
    try std.testing.expectEqualStrings("s-123", p.session);
    try std.testing.expectEqual(@as(u64, 41), p.seq);
    try std.testing.expect(parseParent("no-seq") == null);
    try std.testing.expect(parseParent(":41") == null);
    try std.testing.expect(parseParent("s:notnum") == null);
}

test "session step --stream emits the tui.md §2.2 line protocol in order" {
    const tool = @import("../tool.zig");
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = cwd_buf[0..try tmp.dir.realPath(io, &cwd_buf)];

    // A stand-in for `shell` so the protocol test never spawns a subprocess; the
    // scripted provider (the same one `NULYA_SCRIPTED_MODE` selects) drives it.
    const FakeShell = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            _ = req;
            return .{ .ok = true, .output = try a.dupe(u8, "ok") };
        }
    };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "nulya.shell", .name = "shell", .description = "shell", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = FakeShell.call },
        },
    };

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    var scripted: launch.ScriptedProvider = .{ .mode = .finish };
    var sess: session.AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .pinned_extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = scripted.handle(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = "/tmp",
            .observer = stream.observer(),
        },
        .model_options = .{},
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    stream.printed = sess.l.len(); // as `session step` does: only this run's events
    const steps = try sess.run(5);
    try stream.runDone(steps, stoppedReason(stream.last_status, sess.lastStopReason(), sess.lastAssistantDone()));
    try std.testing.expect(stream.err == null);

    // Step 1 calls a tool, step 2 addresses the user. Per step: model deltas →
    // tool begin/end → the ledger events that step appended → the step boundary.
    // Then one run verdict for the whole invocation.
    const expected =
        \\{"stream":"model","event":"started"}
        \\{"stream":"model","event":"text_delta","text":"Let me probe the environment."}
        \\{"stream":"model","event":"tool_use_start","index":0,"id":"c1","name":"shell"}
        \\{"stream":"model","event":"tool_use_input_delta","index":0,"fragment":"{\"command\":\"echo hello-from-nulya\"}"}
        \\{"stream":"model","event":"done","stop":"tool_use"}
        \\{"stream":"tool","event":"begin","call_id":"c1","tool":"shell"}
        \\{"stream":"tool","event":"end","call_id":"c1","ok":true}
        \\{"seq":2,"kind":"assistant","text":"Let me probe the environment.","calls":[{"id":"c1","tool":"shell","args":"{\"command\":\"echo hello-from-nulya\"}"}]}
        \\{"seq":3,"kind":"tool_results","results":[{"call_id":"c1","ok":true,"output":"ok","spill_path":null}]}
        \\{"stream":"step","event":"end","status":"completed"}
        \\{"stream":"model","event":"started"}
        \\{"stream":"model","event":"text_delta","text":"done"}
        \\{"stream":"model","event":"done","stop":"end_turn"}
        \\{"seq":4,"kind":"assistant","text":"done","calls":[]}
        \\{"stream":"step","event":"end","status":"completed"}
        \\{"stream":"run","event":"done","steps":2,"stopped":"end_turn"}
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a reply cut by max_tokens is recorded replayable, closed with a marker, retried once, and the run stops with stopped=max_tokens" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = cwd_buf[0..try tmp.dir.realPath(io, &cwd_buf)];
    const tool = @import("../tool.zig");

    const Boom = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            _ = req;
            _ = a;
            return error.TestUnexpectedResult; // a truncated call must never reach its executor
        }
    };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "nulya.shell", .name = "shell", .description = "shell", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = Boom.call },
        },
    };
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    var scripted: launch.ScriptedProvider = .{ .mode = .truncate };
    var sess: session.AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .pinned_extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = scripted.handle(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = "/tmp",
            .observer = stream.observer(),
        },
        .model_options = .{},
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    stream.printed = sess.l.len();
    // Budget 5, but two truncated replies in a row stop the run on their own.
    const steps = try sess.run(5);
    try stream.runDone(steps, stoppedReason(stream.last_status, sess.lastStopReason(), sess.lastAssistantDone()));
    try std.testing.expect(stream.err == null);
    try std.testing.expectEqual(@as(usize, session.max_truncated_streak), steps);

    // Per step: the ledger line records the torn args exactly as the model
    // produced them, the batch is closed by a marker result, and the boundary
    // line says the reply was cut.
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"calls\":[{\"id\":\"c1\",\"tool\":\"shell\",\"args\":\"{\\\"command\\\":\\\"echo hel\"}]") != null);
    // …and the projection — what a provider would be sent — carries a complete
    // JSON value in their place (DESIGN §4).
    const prompt = @import("../prompt.zig");
    const ir = try prompt.project(alloc, sess.l.view());
    defer ir.deinit(alloc);
    try std.testing.expectEqualStrings("{}", ir.turns[1].assistant.calls[0].args_json);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"ok\":false,\"output\":\"not executed: the reply hit its output cap (max_tokens)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "{\"stream\":\"step\",\"event\":\"end\",\"status\":\"completed\",\"stop\":\"max_tokens\"}") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "{\"stream\":\"run\",\"event\":\"done\",\"steps\":2,\"stopped\":\"max_tokens\"}\n"));
    // user + 2 × (assistant, marker batch): the model never got past its cap.
    try std.testing.expectEqual(@as(usize, 5), sess.l.len());
}

test "a run stopped by the step budget reports stopped=budget, a canceled step reports canceled, a truncated reply reports max_tokens" {
    try std.testing.expectEqualStrings("end_turn", stoppedReason(.completed, .end_turn, true));
    try std.testing.expectEqualStrings("budget", stoppedReason(.completed, .tool_use, false));
    try std.testing.expectEqualStrings("canceled", stoppedReason(.canceled, .tool_use, false));
    // A cancel at the boundary wins even when the last assistant turn was clean.
    try std.testing.expectEqualStrings("canceled", stoppedReason(.canceled, .end_turn, true));
    // A cut-off reply is not a finished turn, with or without calls in it.
    try std.testing.expectEqualStrings("max_tokens", stoppedReason(.completed, .max_tokens, true));
    try std.testing.expectEqualStrings("max_tokens", stoppedReason(.completed, .max_tokens, false));
}

test "under --stream a diagnostic is a run error line, never a bare text line" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    const code = try stepFail(alloc, io, &stream, "session open failed: {s}", .{"SessionBusy"});
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings(
        "{\"stream\":\"run\",\"event\":\"error\",\"message\":\"session open failed: SessionBusy\"}\n",
        out.written(),
    );
}
