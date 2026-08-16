//! Durable, append-only journal of completed tool-call facts.
//!
//! Stats are an OBSERVATION after tool execution, never an executor concern:
//! the loop runs, the ledger records the factual batch, and `AgentSession`
//! resolves each model-facing call name to its stable `ToolDefinition.id` and
//! appends one `UseEvent` line per completed call. The journal persists raw
//! facts only (`tool_id`, `ok`); ranking, recency windows, and promotion policy
//! are derived later from `aggregate`, never stored.
//!
//! Format: one JSON object per line in `<workspace>/.nulya/tool-usage.jsonl`:
//!
//!   {"v":1,"tool_id":"ext:web.search/web_search","ok":true}
//!
//! `v` is the journal schema version; a future format change bumps it so old
//! journals fail with a precise error instead of garbage. `tool_id` is the
//! durable identity (`ext:<id>/<tool>`, `builtin.shell`, ...), never the
//! model-facing name, so stats accumulate across implementation versions.
//!
//! Only complete events count: an append interrupted by cancel or crash can
//! leave a partial final line; the next append first drops that tail back to
//! the last `\n` so it can never be glued onto a later event into a permanently
//! malformed middle line, and a read skips it (that file discipline — plus the
//! per-journal writer lease that serializes concurrent appenders — is
//! `journal.zig`, shared with the outcome journal). The reader stays strict
//! about COMPLETE lines: a malformed one is an explicit error.

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

/// One recorded tool call: a durable identity plus whether the call succeeded.
pub const UseEvent = struct {
    tool_id: []const u8,
    ok: bool,
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

/// Append one event as a complete line. Creates `.nulya` and the journal when
/// missing; opens an existing journal without truncating and writes at its end.
/// If a previous append was interrupted (cancel/crash) and left a partial final
/// line, that tail is dropped back to the last complete line first, so the new
/// event can never be glued onto it into a permanently malformed middle line.
/// Host faults (missing workspace, permission, I/O, OOM, cancellation)
/// propagate — only the *journal file* being absent is a normal "no stats yet",
/// and that is handled by `readAll`, not here.
pub fn append(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, tool_id: []const u8, ok: bool) !void {
    const line = try encodeEvent(alloc, tool_id, ok);
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

/// Free an events slice returned by `readAll` (each `tool_id` is owned).
pub fn freeEvents(alloc: std.mem.Allocator, events: []UseEvent) void {
    for (events) |e| alloc.free(e.tool_id);
    alloc.free(events);
}

/// Free a stats slice returned by `aggregate` (each `tool_id` is owned).
pub fn freeStats(alloc: std.mem.Allocator, stats: []Stats) void {
    for (stats) |s| alloc.free(s.tool_id);
    alloc.free(stats);
}

fn encodeEvent(alloc: std.mem.Allocator, tool_id: []const u8, ok: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(journal_schema_version);
    try jw.objectField("tool_id");
    try jw.write(tool_id);
    try jw.objectField("ok");
    try jw.write(ok);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn appendParsedEvent(alloc: std.mem.Allocator, events: *std.ArrayList(UseEvent), line: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch |err| switch (err) {
        // A host OOM is a resource fault, never a malformed journal.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStatsJournal,
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidStatsJournal,
    };
    const version = switch (obj.get("v") orelse return error.InvalidStatsJournal) {
        .integer => |i| i,
        else => return error.InvalidStatsJournal,
    };
    if (version != journal_schema_version) return error.UnsupportedStatsVersion;
    const tool_id = switch (obj.get("tool_id") orelse return error.InvalidStatsJournal) {
        .string => |s| s,
        else => return error.InvalidStatsJournal,
    };
    const ok = switch (obj.get("ok") orelse return error.InvalidStatsJournal) {
        .bool => |b| b,
        else => return error.InvalidStatsJournal,
    };

    const owned_id = try alloc.dupe(u8, tool_id);
    errdefer alloc.free(owned_id);
    try events.append(alloc, .{ .tool_id = owned_id, .ok = ok });
}

fn tmpCwd(alloc: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

test "append and read roundtrip preserves order and format" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try append(alloc, io, cwd, "ext:a.pkg/alpha", true);
    try append(alloc, io, cwd, "ext:b.pkg/beta", false);
    try append(alloc, io, cwd, "ext:a.pkg/alpha", true);

    const events = try readAll(alloc, io, cwd);
    defer freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[0].tool_id);
    try std.testing.expect(events[0].ok);
    try std.testing.expectEqualStrings("ext:b.pkg/beta", events[1].tool_id);
    try std.testing.expect(!events[1].ok);
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", events[2].tool_id);
    try std.testing.expect(events[2].ok);

    // The journal is exactly one complete JSON line per event.
    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    const raw = try ws.readFileAlloc(io, journal_rel, alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n" ++
            "{\"v\":1,\"tool_id\":\"ext:b.pkg/beta\",\"ok\":false}\n" ++
            "{\"v\":1,\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n",
        raw,
    );
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

    try append(alloc, io, cwd, "ext:a.pkg/alpha", true);
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

    try append(alloc, io, cwd, "ext:d.pkg/delta", true);

    // The partial line was dropped back to the last '\n'; delta follows the
    // complete events, and the journal parses cleanly again.
    const raw = try ws.readFileAlloc(io, journal_rel, alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"tool_id\":\"ext:a.pkg/alpha\",\"ok\":true}\n" ++
            "{\"v\":1,\"tool_id\":\"ext:b.pkg/beta\",\"ok\":false}\n" ++
            "{\"v\":1,\"tool_id\":\"ext:d.pkg/delta\",\"ok\":true}\n",
        raw,
    );

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

    try append(alloc, io, cwd, "ext:d.pkg/delta", true);

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
    try std.testing.expectError(error.FileNotFound, append(alloc, io, "nulya-absent-workspace", "ext:a.pkg/alpha", true));
}

test "an allocation failure propagates as OutOfMemory" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    // append: the line encode is the first allocation. The allocating JSON
    // writer folds OOM into error.WriteFailed (its only failure mode), the same
    // host-resource-fault treatment protocol.zig gives it — it must propagate,
    // never be swallowed.
    var failing_append = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.WriteFailed, append(failing_append.allocator(), io, cwd, "ext:a.pkg/alpha", true));

    // readAll on a present journal: the file read is the first allocation.
    try append(alloc, io, cwd, "ext:a.pkg/alpha", true);
    var failing_read = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, readAll(failing_read.allocator(), io, cwd));
}
