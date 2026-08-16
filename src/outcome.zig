//! Durable, append-only journal of session outcomes — the ground truth a slow
//! loop evaluates skills, prompts and drivers against (DESIGN §3.3, PLAN §3.7).
//!
//! An outcome is a JUDGMENT about a finished session, not a conversation turn,
//! so it is a second journal beside tool usage rather than a ledger event: a
//! session's tail usually has no next step to drain an inbox through, the
//! verdict is evidence for policy rather than model-visible text, and the ledger
//! gains no "stored but never projected" event kind. Same principle as the usage
//! journal: **persist facts, derive stats**.
//!
//! Format: one JSON object per line in `<workspace>/.nulya/session-outcomes.jsonl`:
//!
//!   {"v":1,"session":"s-…","verdict":"success","note":"…","at":"2026-08-16T09:31:00Z"}
//!
//! `note` is optional. A session may be judged more than once — every line is
//! kept and readers take the LAST one for a session (`latestFor`), because a
//! correction is an append like everywhere else in Nulya. **No line at all means
//! UNKNOWN, never failure.** There is deliberately no `source` field: today only
//! a person writes these (through the CLI or a front end), so recording that
//! would be a constant; when a driver starts writing them automatically it adds
//! `source`, and a v1 line without one still reads as "judged by a person".
//!
//! The file discipline (append one complete line under the journal's writer
//! lease, repair a torn crash tail on write and skip it on read, a missing file
//! means "no verdicts yet") is shared with `tool_stats.zig` through
//! `journal.zig`; the schema below is this module's alone.

const std = @import("std");
const journal = @import("journal.zig");

/// Journal path, relative to the workspace root.
pub const journal_rel = journal.journal_dir ++ std.fs.path.sep_str ++ "session-outcomes.jsonl";

/// Journal schema version, written into every line and required on read.
pub const journal_schema_version: u8 = 1;

pub const Error = error{
    /// A complete journal line is not a valid outcome (malformed JSON, missing
    /// field, wrong type, unknown verdict).
    InvalidOutcomeJournal,
    /// A journal line carries a schema version this build does not understand.
    UnsupportedOutcomeVersion,
};

/// How a session turned out. Three values on purpose: a binary verdict pushes
/// every mixed result into one of two lies, and a finer scale invites scoring a
/// session instead of judging it.
pub const Verdict = enum {
    success,
    partial,
    failure,

    pub fn parse(text: []const u8) ?Verdict {
        return std.meta.stringToEnum(Verdict, text);
    }
};

/// One recorded judgment. Strings are owned by whoever received this from
/// `readAll` (free the slice with `freeAll`).
pub const Outcome = struct {
    session: []const u8,
    verdict: Verdict,
    note: ?[]const u8 = null,
    /// RFC3339 UTC instant the judgment was recorded, as the writer saw it.
    at: []const u8,
};

/// Append one judgment as a complete line. `at` is supplied by the caller (the
/// CLI passes the current instant; tests pass a fixed one), so this module stays
/// a pure encoder over the journal file.
pub fn append(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    session: []const u8,
    verdict: Verdict,
    note: ?[]const u8,
    at: []const u8,
) !void {
    const line = try encodeOutcome(alloc, session, verdict, note, at);
    defer alloc.free(line);
    try journal.appendLine(io, cwd, journal_rel, line);
}

/// Read every judgment in journal order. A missing journal reads as empty; a
/// missing *workspace* is a host fault and propagates. Blank lines and a torn
/// final line (`journal.readAll`) are ignored; any malformed COMPLETE line is an
/// explicit error, never silently skipped.
pub fn readAll(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]Outcome {
    const bytes = (try journal.readAll(alloc, io, cwd, journal_rel)) orelse return alloc.alloc(Outcome, 0);
    defer alloc.free(bytes);

    var outcomes: std.ArrayList(Outcome) = .empty;
    errdefer freeAll(alloc, outcomes.items);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try appendParsed(alloc, &outcomes, line);
    }
    return outcomes.toOwnedSlice(alloc);
}

/// The judgment that stands for `session`: the LAST line naming it, since a
/// later append corrects an earlier one. Null means unknown — which is not the
/// same as failure.
pub fn latestFor(outcomes: []const Outcome, session: []const u8) ?Outcome {
    var found: ?Outcome = null;
    for (outcomes) |o| {
        if (std.mem.eql(u8, o.session, session)) found = o;
    }
    return found;
}

pub fn freeAll(alloc: std.mem.Allocator, outcomes: []Outcome) void {
    for (outcomes) |o| {
        alloc.free(o.session);
        if (o.note) |n| alloc.free(n);
        alloc.free(o.at);
    }
    alloc.free(outcomes);
}

/// The flat wire shape of one journal line. Unknown fields are ignored so a
/// newer writer's extra columns never break this reader.
const WireOutcome = struct {
    v: u8,
    session: []const u8,
    verdict: []const u8,
    note: ?[]const u8 = null,
    at: []const u8 = "",
};

fn encodeOutcome(
    alloc: std.mem.Allocator,
    session: []const u8,
    verdict: Verdict,
    note: ?[]const u8,
    at: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(journal_schema_version);
    try jw.objectField("session");
    try jw.write(session);
    try jw.objectField("verdict");
    try jw.write(@tagName(verdict));
    if (note) |n| {
        try jw.objectField("note");
        try jw.write(n);
    }
    try jw.objectField("at");
    try jw.write(at);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn appendParsed(alloc: std.mem.Allocator, outcomes: *std.ArrayList(Outcome), line: []const u8) !void {
    const parsed = std.json.parseFromSlice(WireOutcome, alloc, line, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        // A host OOM is a resource fault, never a malformed journal.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidOutcomeJournal,
    };
    defer parsed.deinit();

    if (parsed.value.v != journal_schema_version) return error.UnsupportedOutcomeVersion;
    if (parsed.value.session.len == 0) return error.InvalidOutcomeJournal;
    const verdict = Verdict.parse(parsed.value.verdict) orelse return error.InvalidOutcomeJournal;

    const session = try alloc.dupe(u8, parsed.value.session);
    errdefer alloc.free(session);
    const note: ?[]const u8 = if (parsed.value.note) |n| try alloc.dupe(u8, n) else null;
    errdefer if (note) |n| alloc.free(n);
    const at = try alloc.dupe(u8, parsed.value.at);
    errdefer alloc.free(at);
    try outcomes.append(alloc, .{ .session = session, .verdict = verdict, .note = note, .at = at });
}

fn tmpCwd(alloc: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

test "append and read round-trip preserves order, the optional note, and the exact line shape" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try append(alloc, io, cwd, "s-1", .success, "went fine", "2026-08-16T09:00:00Z");
    try append(alloc, io, cwd, "s-2", .failure, null, "2026-08-16T09:05:00Z");
    // A session may be judged twice; both lines survive.
    try append(alloc, io, cwd, "s-1", .partial, "on reflection", "2026-08-16T09:10:00Z");

    const outcomes = try readAll(alloc, io, cwd);
    defer freeAll(alloc, outcomes);
    try std.testing.expectEqual(@as(usize, 3), outcomes.len);
    try std.testing.expectEqualStrings("s-1", outcomes[0].session);
    try std.testing.expectEqual(Verdict.success, outcomes[0].verdict);
    try std.testing.expectEqualStrings("went fine", outcomes[0].note.?);
    try std.testing.expectEqualStrings("2026-08-16T09:00:00Z", outcomes[0].at);
    try std.testing.expect(outcomes[1].note == null);

    // The later judgment stands; an unjudged session is unknown, not a failure.
    try std.testing.expectEqual(Verdict.partial, latestFor(outcomes, "s-1").?.verdict);
    try std.testing.expectEqual(Verdict.failure, latestFor(outcomes, "s-2").?.verdict);
    try std.testing.expect(latestFor(outcomes, "s-3") == null);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    const raw = try ws.readFileAlloc(io, journal_rel, alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"session\":\"s-1\",\"verdict\":\"success\",\"note\":\"went fine\",\"at\":\"2026-08-16T09:00:00Z\"}\n" ++
            "{\"v\":1,\"session\":\"s-2\",\"verdict\":\"failure\",\"at\":\"2026-08-16T09:05:00Z\"}\n" ++
            "{\"v\":1,\"session\":\"s-1\",\"verdict\":\"partial\",\"note\":\"on reflection\",\"at\":\"2026-08-16T09:10:00Z\"}\n",
        raw,
    );
}

test "a missing journal reads as empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    const outcomes = try readAll(alloc, io, cwd);
    defer freeAll(alloc, outcomes);
    try std.testing.expectEqual(@as(usize, 0), outcomes.len);
}

test "verdict parsing accepts exactly the three values" {
    try std.testing.expectEqual(Verdict.success, Verdict.parse("success").?);
    try std.testing.expectEqual(Verdict.partial, Verdict.parse("partial").?);
    try std.testing.expectEqual(Verdict.failure, Verdict.parse("failure").?);
    try std.testing.expect(Verdict.parse("ok") == null);
    try std.testing.expect(Verdict.parse("SUCCESS") == null);
    try std.testing.expect(Verdict.parse("") == null);
}

test "malformed lines are explicit errors; unknown fields and blank lines are tolerated" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal.journal_dir);

    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "not json\n" });
    try std.testing.expectError(error.InvalidOutcomeJournal, readAll(alloc, io, cwd));

    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"session\":\"s-1\"}\n" });
    try std.testing.expectError(error.InvalidOutcomeJournal, readAll(alloc, io, cwd));

    // An unknown verdict is not silently coerced.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"session\":\"s-1\",\"verdict\":\"great\",\"at\":\"\"}\n" });
    try std.testing.expectError(error.InvalidOutcomeJournal, readAll(alloc, io, cwd));

    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":2,\"session\":\"s-1\",\"verdict\":\"success\",\"at\":\"\"}\n" });
    try std.testing.expectError(error.UnsupportedOutcomeVersion, readAll(alloc, io, cwd));

    // A torn final line (an interrupted or in-flight append) is skipped by the
    // reader — `session list` must not go dark until the next append repairs it.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"session\":\"s-0\",\"verdict\":\"success\",\"at\":\"t\"}\n{\"v\":1,\"session\":\"s-1\",\"verdict\":\"succ" });
    const torn = try readAll(alloc, io, cwd);
    defer freeAll(alloc, torn);
    try std.testing.expectEqual(@as(usize, 1), torn.len);
    try std.testing.expectEqualStrings("s-0", torn[0].session);

    // A newer writer's extra column, and blank lines, read cleanly.
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "\n{\"v\":1,\"session\":\"s-1\",\"verdict\":\"success\",\"at\":\"t\",\"source\":\"driver\"}\n  \n" });
    const outcomes = try readAll(alloc, io, cwd);
    defer freeAll(alloc, outcomes);
    try std.testing.expectEqual(@as(usize, 1), outcomes.len);
    try std.testing.expectEqual(Verdict.success, outcomes[0].verdict);
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
    try ws.createDirPath(io, journal.journal_dir);
    try ws.writeFile(io, .{ .sub_path = journal_rel, .data = "{\"v\":1,\"session\":\"s-1\",\"verdict\":\"success\",\"at\":\"t\"}\n{\"v\":1,\"session\":\"s-2\",\"verd" });

    try append(alloc, io, cwd, "s-3", .partial, null, "t");

    const outcomes = try readAll(alloc, io, cwd);
    defer freeAll(alloc, outcomes);
    try std.testing.expectEqual(@as(usize, 2), outcomes.len);
    try std.testing.expectEqualStrings("s-1", outcomes[0].session);
    try std.testing.expectEqualStrings("s-3", outcomes[1].session);
}
