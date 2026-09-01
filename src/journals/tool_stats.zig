//! Durable, append-only journal of completed tool-call facts.
//!
//! Recorded as an observation after execution: the loop runs, the ledger
//! records the batch, and `AgentSession` resolves each model-facing call name
//! to its stable `ToolDefinition.id` and appends one `UseEvent` line. Ranking,
//! recency, and promotion policy are derived later from `aggregate` or
//! `readAll`, never stored here.
//!
//! One JSON object per line in `<workspace>/.nulya/tool-usage.jsonl`:
//!   {"v":1,"at":"2026-08-17T09:31:07Z","session":"s-1786-3f",
//!    "tool_id":"ext:web.search/web_search","version":"v-3f9c…","ok":true,
//!    "duration_ms":812}
//!
//! `v` is the schema version; a bump fails old journals with a precise error
//! instead of misreading them. `tool_id` is the durable identity, never the
//! model-facing name, so history accumulates across implementation versions
//! while `version` (below) records which one served a given call. Every
//! column beyond `tool_id`/`ok` is optional both ways: absent on read means
//! "not recorded" (never a zero), and a writer may genuinely have nothing to
//! say for one.
//!
//! An append interrupted by cancel or crash can leave a partial final line;
//! the next append drops that tail back to the last `\n` (shared discipline
//! with the outcome journal, `journal.zig`) before writing, and a read skips
//! it. A malformed COMPLETE line is an explicit error.

const std = @import("std");
const journal = @import("journal.zig");

/// Directory for the journal, relative to the workspace root.
pub const journal_dir = journal.journal_dir;
/// Journal path, relative to the workspace root.
pub const journal_rel = journal_dir ++ std.fs.path.sep_str ++ "tool-usage.jsonl";

/// Journal schema version, written into every line and required on read.
pub const journal_schema_version: u8 = 1;

pub const Error = error{
    /// A complete journal line is not a valid event (malformed JSON, missing
    /// field, wrong type).
    InvalidStatsJournal,
    /// A journal line carries a schema version this build does not understand.
    UnsupportedStatsVersion,
};

/// One recorded tool call as it was READ BACK. `tool_id` and `ok` are the two
/// facts every line has ever carried; the rest are null when the line predates
/// them or the writer had nothing to say (see the module header). Owned by the
/// caller that received it from `readAll`; free with `freeEvents`.
pub const UseEvent = struct {
    tool_id: []const u8,
    ok: bool,
    /// When the call was recorded, RFC3339 UTC — the same stamp the outcome
    /// journal writes, so the two can be read on one timeline.
    at: ?[]const u8 = null,
    /// The durable session the call ran in.
    session: ?[]const u8 = null,
    /// The frozen extension version that served the call (`v-<hash>`). Null is
    /// honest in two different ways: an old line never recorded one (unknown),
    /// and a new line for a builtin has none to record.
    version: ?[]const u8 = null,
    /// Wall-clock milliseconds the call itself took.
    duration_ms: ?u64 = null,
};

/// What one `append` records. Only the caller can know the three optional
/// columns: `session` is the session id when there is a durable one,
/// `version` is the frozen extension version the caller resolved this call
/// against, and `duration_ms` is a measurement taken around the executor, at
/// the one place that brackets it (`loop.zig`).
pub const Append = struct {
    tool_id: []const u8,
    ok: bool,
    session: ?[]const u8 = null,
    version: ?[]const u8 = null,
    duration_ms: ?u64 = null,
};

/// Aggregated facts for one stable tool id. Derived state (success rate,
/// recency, rank) is computed from this, never persisted.
pub const Stats = struct {
    /// Durable stable id. Owned by the caller that received this from `aggregate`.
    tool_id: []const u8,
    uses_total: u64,
    successes: u64,
    /// 0-based index of this tool's last event within the input slice.
    last_used_seq: u64,

    pub fn successRate(self: Stats) f64 {
        if (self.uses_total == 0) return 0;
        return @as(f64, @floatFromInt(self.successes)) / @as(f64, @floatFromInt(self.uses_total));
    }
};

/// Append one event as a complete line, stamped with the current instant —
/// `at` is when the fact was recorded, which only this function is in a position
/// to know, so no caller passes one and no caller can forget one. Creates
/// `.nulya` and the journal when missing; opens an existing journal without
/// truncating and writes at its end. If a previous append was interrupted
/// (cancel/crash) and left a partial final line, that tail is dropped back to
/// the last complete line first, so the new event can never be glued onto it
/// into a permanently malformed middle line. Host faults (missing workspace,
/// permission, I/O, OOM, cancellation) propagate — only the *journal file* being
/// absent is a normal "no stats yet", and that is handled by `readAll`, not here.
pub fn append(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, event: Append) !void {
    const at = try journal.rfc3339Now(alloc, io);
    defer alloc.free(at);
    const line = try encodeEvent(alloc, event, at);
    defer alloc.free(line);
    try journal.appendLine(io, cwd, journal_rel, line);
}

/// Read every event in journal order. A missing journal file reads as empty; a
/// missing *workspace* is a host fault and propagates. Blank lines and a torn
/// final line (`journal.readAll`) are ignored; any malformed COMPLETE line is an
/// explicit error, never silently skipped.
pub fn readAll(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]UseEvent {
    const bytes = (try journal.readAll(alloc, io, cwd, journal_rel)) orelse return alloc.alloc(UseEvent, 0);
    defer alloc.free(bytes);

    var events: std.ArrayList(UseEvent) = .empty;
    errdefer freeEvents(alloc, events.items);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try appendParsedEvent(alloc, &events, line);
    }
    return events.toOwnedSlice(alloc);
}

/// Group events by stable tool id, in deterministic lexical `tool_id` order.
/// Each returned `Stats` owns its `tool_id`; free with `freeStats`.
pub fn aggregate(alloc: std.mem.Allocator, events: []const UseEvent) ![]Stats {
    var out: std.ArrayList(Stats) = .empty;
    errdefer freeStats(alloc, out.items);
    for (events, 0..) |e, i| {
        var found = false;
        for (out.items) |*s| {
            if (std.mem.eql(u8, s.tool_id, e.tool_id)) {
                s.uses_total += 1;
                if (e.ok) s.successes += 1;
                s.last_used_seq = i;
                found = true;
                break;
            }
        }
        if (found) continue;
        const tool_id = try alloc.dupe(u8, e.tool_id);
        errdefer alloc.free(tool_id);
        try out.append(alloc, .{
            .tool_id = tool_id,
            .uses_total = 1,
            .successes = if (e.ok) 1 else 0,
            .last_used_seq = i,
        });
    }
    std.mem.sort(Stats, out.items, {}, struct {
        fn lessThan(_: void, a: Stats, b: Stats) bool {
            return std.mem.lessThan(u8, a.tool_id, b.tool_id);
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

/// Free an events slice returned by `readAll` (every string is owned).
pub fn freeEvents(alloc: std.mem.Allocator, events: []UseEvent) void {
    for (events) |e| freeEvent(alloc, e);
    alloc.free(events);
}

/// Free a stats slice returned by `aggregate` (each `tool_id` is owned).
pub fn freeStats(alloc: std.mem.Allocator, stats: []Stats) void {
    for (stats) |s| alloc.free(s.tool_id);
    alloc.free(stats);
}

/// Optional columns are written only when the caller had something to say, so a
/// line carries exactly the facts that exist — and a workspace whose tools are
/// all invoked outside a session keeps writing the shape it always did.
fn encodeEvent(alloc: std.mem.Allocator, event: Append, at: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(journal_schema_version);
    try jw.objectField("at");
    try jw.write(at);
    if (event.session) |s| {
        try jw.objectField("session");
        try jw.write(s);
    }
    try jw.objectField("tool_id");
    try jw.write(event.tool_id);
    // Beside the identity it qualifies: the same call, by this implementation.
    if (event.version) |v| {
        try jw.objectField("version");
        try jw.write(v);
    }
    try jw.objectField("ok");
    try jw.write(event.ok);
    if (event.duration_ms) |ms| {
        try jw.objectField("duration_ms");
        try jw.write(ms);
    }
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// One journal line's shape. The two original columns are REQUIRED — a complete
/// line missing either is malformed, not a line with defaults — and the four
/// added ones default to null, which is how an old line reads back unchanged.
/// Unknown fields are ignored so a newer writer at the same `v` never breaks an
/// older reader.
const WireEvent = struct {
    /// Wider than `journal_schema_version` on purpose: a number this build does
    /// not understand must reach the version check as a version, not fail
    /// parsing as if the line were malformed.
    v: u32,
    tool_id: []const u8,
    ok: bool,
    at: ?[]const u8 = null,
    session: ?[]const u8 = null,
    version: ?[]const u8 = null,
    duration_ms: ?u64 = null,
};

const json_opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };

fn appendParsedEvent(alloc: std.mem.Allocator, events: *std.ArrayList(UseEvent), line: []const u8) !void {
    const parsed = std.json.parseFromSlice(WireEvent, alloc, line, json_opts) catch |err| switch (err) {
        // A host OOM is a resource fault, never a malformed journal.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStatsJournal,
    };
    defer parsed.deinit();
    if (parsed.value.v != journal_schema_version) return error.UnsupportedStatsVersion;

    const owned = try dupeEvent(alloc, parsed.value);
    errdefer freeEvent(alloc, owned);
    try events.append(alloc, owned);
}

/// Copy a parsed line out of its transient arena into caller-owned memory.
fn dupeEvent(alloc: std.mem.Allocator, w: WireEvent) !UseEvent {
    var e: UseEvent = .{ .tool_id = "", .ok = w.ok, .duration_ms = w.duration_ms };
    errdefer freeEvent(alloc, e);
    e.tool_id = try alloc.dupe(u8, w.tool_id);
    if (w.at) |s| e.at = try alloc.dupe(u8, s);
    if (w.session) |s| e.session = try alloc.dupe(u8, s);
    if (w.version) |s| e.version = try alloc.dupe(u8, s);
    return e;
}

fn freeEvent(alloc: std.mem.Allocator, e: UseEvent) void {
    alloc.free(e.tool_id);
    if (e.at) |s| alloc.free(s);
    if (e.session) |s| alloc.free(s);
    if (e.version) |s| alloc.free(s);
}

fn tmpCwd(alloc: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

test "append and read roundtrip preserves order and every column" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try append(alloc, io, cwd, .{ .tool_id = "ext:a.pkg/alpha", .ok = true, .session = "s-1", .version = "v-3f9c", .duration_ms = 812 });
    try append(alloc, io, cwd, .{ .tool_id = "ext:b.pkg/beta", .ok = false });
    try append(alloc, io, cwd, .{ .tool_id = "ext:a.pkg/alpha", .ok = true, .duration_ms = 0 });

    const events = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[0].tool_id);
    try std.testing.expect(events[0].ok);
    try std.testing.expectEqualStrings("s-1", events[0].session.?);
    try std.testing.expectEqualStrings("v-3f9c", events[0].version.?);
    try std.testing.expectEqual(@as(?u64, 812), events[0].duration_ms);

    // A writer with nothing to say about a column simply omits it, and the
    // reader gives back "not recorded" — not a zero, and not an empty id.
    try std.testing.expectEqualStrings("ext:b.pkg/beta", events[1].tool_id);
    try std.testing.expect(!events[1].ok);
    try std.testing.expect(events[1].session == null);
    try std.testing.expect(events[1].version == null);
    try std.testing.expect(events[1].duration_ms == null);

    // …which is a different fact from a measured zero.
    try std.testing.expectEqual(@as(?u64, 0), events[2].duration_ms);

    // Every line is stamped, in the outcome journal's format.
    for (events) |e| {
        try std.testing.expectEqual(@as(usize, 20), e.at.?.len);
        try std.testing.expectEqual(@as(u8, 'Z'), e.at.?[19]);
    }

    // The journal is exactly one complete JSON line per event (`encodeEvent`'s
    // own test pins the column order).
    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    const raw = try ws.readFileAlloc(io, journal_rel, alloc, .unlimited);
    defer alloc.free(raw);
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, "\n"), '\n');
    while (lines.next()) |line| : (count += 1) {
        try std.testing.expect(std.mem.startsWith(u8, line, "{\"v\":1,\"at\":\""));
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "the line carries its columns in a fixed order, and only the ones that exist" {
    const alloc = std.testing.allocator;
    const full = try encodeEvent(alloc, .{
        .tool_id = "ext:a.pkg/alpha",
        .ok = true,
        .session = "s-1",
        .version = "v-3f9c",
        .duration_ms = 812,
    }, "2026-08-17T09:31:07Z");
    defer alloc.free(full);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"at\":\"2026-08-17T09:31:07Z\",\"session\":\"s-1\"," ++
            "\"tool_id\":\"ext:a.pkg/alpha\",\"version\":\"v-3f9c\",\"ok\":true,\"duration_ms\":812}\n",
        full,
    );

    // A builtin has no implementation version, so the column is simply not
    // there — the shape a pre-`version` writer produced, byte for byte.
    const bare = try encodeEvent(alloc, .{ .tool_id = "builtin.shell", .ok = false }, "2026-08-17T09:31:07Z");
    defer alloc.free(bare);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"at\":\"2026-08-17T09:31:07Z\",\"tool_id\":\"builtin.shell\",\"ok\":false}\n",
        bare,
    );
}

test "a line written before the added columns reads back with them absent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);
    // Byte-for-byte what every pre-widening append wrote. Still `v:1`: the two
    // facts it carries mean exactly what they always did.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n" });

    const events = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[0].tool_id);
    try std.testing.expect(events[0].ok);
    try std.testing.expect(events[0].at == null);
    try std.testing.expect(events[0].session == null);
    // Unknown, not "no version": evidence cannot be backfilled, so a call
    // recorded before the column existed stays unattributed forever.
    try std.testing.expect(events[0].version == null);
    try std.testing.expect(events[0].duration_ms == null);

    // A column this build does not know is ignored, not an error: a newer writer
    // at the same `v` may add one, and the facts here still hold.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"tool_id\":\"x\",\"ok\":true,\"future\":1}\n" });
    const newer = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, newer);
    try std.testing.expectEqual(@as(usize, 1), newer.len);
}

test "an old line and a new one live in the same journal, each honest about its version" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);
    // A line from before this column existed — still `v:1`, still true.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"at\":\"2026-08-17T09:31:07Z\",\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n" });

    try append(alloc, io, cwd, .{ .tool_id = "ext:a.pkg/alpha", .ok = true, .version = "v-3f9c" });

    const events = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    // Same tool, one history — and no retroactive attribution: the old call
    // stays unknown, because evidence is append-only and cannot be backfilled.
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[0].tool_id);
    try std.testing.expect(events[0].version == null);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[1].tool_id);
    try std.testing.expectEqualStrings("v-3f9c", events[1].version.?);

    // And the addition changes nothing about how calls are counted: `aggregate`
    // still groups the whole history under the one stable id.
    const stats = try aggregate(alloc, events);
    defer freeStats(alloc, stats);
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectEqual(@as(u64, 2), stats[0].uses_total);
}

test "aggregate groups by stable id in lexical order" {
    const events = [_]UseEvent{
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        .{ .tool_id = "ext:b.pkg/beta", .ok = false },
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
    };
    const stats = try aggregate(std.testing.allocator, &events);
    defer freeStats(std.testing.allocator, stats);

    try std.testing.expectEqual(@as(usize, 2), stats.len);
    // Lexical order, independent of first-seen order.
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", stats[0].tool_id);
    try std.testing.expectEqual(@as(u64, 2), stats[0].uses_total);
    try std.testing.expectEqual(@as(u64, 2), stats[0].successes);
    try std.testing.expectEqual(@as(u64, 2), stats[0].last_used_seq);
    try std.testing.expectEqual(@as(f64, 1.0), stats[0].successRate());

    try std.testing.expectEqualStrings("ext:b.pkg/beta", stats[1].tool_id);
    try std.testing.expectEqual(@as(u64, 1), stats[1].uses_total);
    try std.testing.expectEqual(@as(u64, 0), stats[1].successes);
    try std.testing.expectEqual(@as(u64, 1), stats[1].last_used_seq);
    try std.testing.expectEqual(@as(f64, 0.0), stats[1].successRate());
}

test "missing journal reads as empty and append creates it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    const before = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, before);
    try std.testing.expectEqual(@as(usize, 0), before.len);

    try append(alloc, io, cwd, .{ .tool_id = "ext:a.pkg/alpha", .ok = true });
    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.access(io, journal_rel, .{}); // journal now exists under .nulya

    const after = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
}

test "blank lines are ignored" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "\n{\"v\":1,\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n\n   \n" });

    const events = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[0].tool_id);
}

test "malformed journal lines produce an explicit error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);

    // Not JSON.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "not json\n" });
    try std.testing.expectError(error.InvalidStatsJournal, readAll(alloc, io, cwd));

    // Missing / mistyped field.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"tool_id\":\"x\"}\n" });
    try std.testing.expectError(error.InvalidStatsJournal, readAll(alloc, io, cwd));
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"tool_id\":\"x\",\"ok\":\"yes\"}\n" });
    try std.testing.expectError(error.InvalidStatsJournal, readAll(alloc, io, cwd));

    // Unsupported schema version.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":2,\"tool_id\":\"x\",\"ok\":true}\n" });
    try std.testing.expectError(error.UnsupportedStatsVersion, readAll(alloc, io, cwd));

    // A torn final line (interrupted or in-flight append) is skipped, not an error.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"tool_id\":\"x\",\"ok\":true}\n{\"v\":1,\"tool_id\":\"x\",\"ok\":tru" });
    const torn = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, torn);
    try std.testing.expectEqual(@as(usize, 1), torn.len);
}

test "append repairs a truncated crash tail before writing" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);
    // A previous append was interrupted mid-write: the final line is partial.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n{\"v\":1,\"tool_id\":\"ext:b.pkg/beta\",\"ok\":false}\n{\"v\":1,\"tool_id\":\"ext:c.pkg/gamma\",\"ok\":tru" });

    try append(alloc, io, cwd, .{ .tool_id = "ext:d.pkg/delta", .ok = true });

    // The partial line was dropped back to the last '\n'; delta follows the
    // complete events, and the journal parses cleanly again.
    const raw = try ws.readFileAlloc(io, journal_rel, alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.startsWith(
        u8,
        raw,
        "{\"v\":1,\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n" ++
            "{\"v\":1,\"tool_id\":\"ext:b.pkg/beta\",\"ok\":false}\n{\"v\":1,\"at\":\"",
    ));
    try std.testing.expect(std.mem.indexOf(u8, raw, "gamma") == null);

    const events = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[0].tool_id);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", events[1].tool_id);
    try std.testing.expectEqualStrings("ext:d.pkg/delta", events[2].tool_id);
}

test "append repairs a tail with no complete line at all" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);
    // The whole file is a partial first event; appending must not glue onto it.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"tool_id\":\"ext:a.pkg/alph" });

    try append(alloc, io, cwd, .{ .tool_id = "ext:d.pkg/delta", .ok = true });

    const events = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:d.pkg/delta", events[0].tool_id);
}

test "host filesystem faults propagate, never read as empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // A missing workspace is a host fault, not "no stats yet".
    try std.testing.expectError(error.FileNotFound, readAll(alloc, io, "nulya-absent-workspace"));
    try std.testing.expectError(error.FileNotFound, append(alloc, io, "nulya-absent-workspace", .{ .tool_id = "ext:a.pkg/alpha", .ok = true }));
}

test "an allocation failure propagates as OutOfMemory" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    // append: the timestamp is the first allocation, and it must propagate
    // rather than be swallowed into an unstamped line.
    var failing_stamp = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, append(failing_stamp.allocator(), io, cwd, .{ .tool_id = "ext:a.pkg/alpha", .ok = true }));

    // The line encode is next. The allocating JSON writer folds OOM into
    // error.WriteFailed (its only failure mode), the same host-resource-fault
    // treatment protocol.zig gives it — it must propagate too.
    var failing_encode = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.WriteFailed, encodeEvent(
        failing_encode.allocator(),
        .{ .tool_id = "ext:a.pkg/alpha", .ok = true },
        "2026-08-17T09:31:07Z",
    ));

    // readAll on a present journal: the file read is the first allocation.
    try append(alloc, io, cwd, .{ .tool_id = "ext:a.pkg/alpha", .ok = true });
    var failing_read = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, readAll(failing_read.allocator(), io, cwd));
}
