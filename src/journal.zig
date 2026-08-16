//! The shared file layer under Nulya's durable JSONL journals (DESIGN §3.3).
//!
//! Two journals live in `.nulya/`: tool usage (`tool_stats.zig`) and session
//! outcomes (`outcome.zig`). They record different facts and neither knows the
//! other's schema — what they genuinely share is the FILE discipline:
//!
//!   * one complete JSON line per event, appended at the end, never rewritten;
//!   * a journal is written by MANY processes (every `session step`, every
//!     `ext run`, every `session outcome`), so an append holds a short exclusive
//!     lease on the sidecar `<journal>.lock` while it measures, repairs and
//!     writes — two appends can never land on the same offset. Readers take no
//!     lock: they only ever see whole lines plus, at worst, one torn tail;
//!   * an append interrupted by cancel or crash can leave a partial final line,
//!     so the next append first drops that tail back to the last `\n` — a
//!     truncated event can never be glued onto a later one into a permanently
//!     malformed middle line — and a READ ignores that torn tail as well, so a
//!     crash between two appends never blocks `session list` until someone
//!     writes again. A malformed COMPLETE line is still the consumer's error:
//!     the tail rule forgives an interrupted write, not a bad journal;
//!   * a missing journal file reads as "no facts yet", while a missing workspace
//!     (or any other host fault) propagates.
//!
//! Only that I/O is shared. There is deliberately no `Journal(T)`: each journal
//! owns its own encode/parse, its own schema version, and its own error set.

const std = @import("std");

/// Directory holding every journal, relative to the workspace root.
pub const journal_dir = ".nulya";

/// Append `line` (which must already end with `\n`) as a complete line to the
/// journal at `file_rel` under `cwd`. Creates `.nulya` and the file when
/// missing; opens an existing journal without truncating and writes at its end,
/// after repairing any partial trailing line. Holds the journal's writer lease
/// (`<file_rel>.lock`, exclusive, blocking — the critical section is a stat and
/// one write) for the duration, so concurrent appenders serialize instead of
/// overwriting each other.
pub fn appendLine(io: std.Io, cwd: []const u8, file_rel: []const u8, line: []const u8) !void {
    var workspace = try openWorkspace(io, cwd);
    defer workspace.close(io);
    try workspace.createDirPath(io, journal_dir);

    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_rel = try std.fmt.bufPrint(&lock_buf, "{s}.lock", .{file_rel});
    var lease = try workspace.createFile(io, lock_rel, .{ .truncate = false, .read = true, .lock = .exclusive });
    defer lease.close(io);

    var file = try workspace.createFile(io, file_rel, .{ .truncate = false, .read = true });
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const end = try repairCrashTail(file, io, size);
    if (end != size) try file.setLength(io, end);
    try file.writePositionalAll(io, line, end);
}

/// Read the whole journal at `file_rel` under `cwd`, minus a torn final line
/// (bytes after the last `\n` — an append that was interrupted, or is in flight
/// right now). A missing journal file returns null ("no facts yet"); a missing
/// workspace is a host fault and propagates. Caller owns the bytes.
pub fn readAll(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, file_rel: []const u8) !?[]u8 {
    var workspace = try openWorkspace(io, cwd);
    defer workspace.close(io);
    const bytes = workspace.readFileAlloc(io, file_rel, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer alloc.free(bytes);
    const end = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |i| i + 1 else 0;
    return if (end == bytes.len) bytes else try alloc.realloc(bytes, end);
}

fn openWorkspace(io: std.Io, cwd: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(cwd)) {
        return std.Io.Dir.openDirAbsolute(io, cwd, .{});
    }
    return std.Io.Dir.cwd().openDir(io, cwd, .{});
}

/// If the journal does not end with a complete line (a previous append was
/// interrupted), return the byte offset just past the last `\n` — where the
/// next event must be written — dropping the partial trailing bytes. Returns 0
/// when no line in the file is complete. Events are single-line JSON (a
/// literal newline can never appear inside one), so `\n` always separates
/// events. The intact case (last byte `\n`) costs one read; the backward scan
/// only runs after a truncated tail.
fn repairCrashTail(file: std.Io.File, io: std.Io, size: u64) !u64 {
    if (size == 0) return 0;
    var last: [1]u8 = undefined;
    const n = try file.readPositionalAll(io, &last, size - 1);
    if (n == 1 and last[0] == '\n') return size;

    var chunk: [4096]u8 = undefined;
    var pos = size;
    while (pos > 0) {
        const read_len = @min(chunk.len, pos);
        const start = pos - read_len;
        const got = try file.readPositionalAll(io, chunk[0..read_len], start);
        var i = got;
        while (i > 0) {
            i -= 1;
            if (chunk[i] == '\n') return start + i + 1;
        }
        pos = start;
    }
    return 0; // no complete line anywhere: the whole file is a partial first event
}

fn tmpCwd(alloc: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

const test_rel = journal_dir ++ std.fs.path.sep_str ++ "probe.jsonl";

test "appendLine creates the journal, appends in order, and readAll returns every byte" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try std.testing.expect((try readAll(alloc, io, cwd, test_rel)) == null);

    try appendLine(io, cwd, test_rel, "{\"a\":1}\n");
    try appendLine(io, cwd, test_rel, "{\"a\":2}\n");

    const bytes = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n", bytes);
    // The lease is a sidecar next to the journal, never inside it.
    try tmp.dir.access(io, test_rel ++ ".lock", .{});
}

test "appendLine drops a truncated crash tail instead of gluing onto it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);
    try ws.writeFile(io, .{ .sub_path = test_rel, .data = "{\"a\":1}\n{\"a\":2" });

    try appendLine(io, cwd, test_rel, "{\"a\":3}\n");
    const bytes = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"a\":3}\n", bytes);

    // A file that is one partial first event keeps nothing.
    try ws.writeFile(io, .{ .sub_path = test_rel, .data = "{\"a\":1" });
    try appendLine(io, cwd, test_rel, "{\"a\":4}\n");
    const after = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(after);
    try std.testing.expectEqualStrings("{\"a\":4}\n", after);
}

test "readAll ignores a torn final line but returns a malformed complete one for the consumer to judge" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    try ws.createDirPath(io, journal_dir);

    try ws.writeFile(io, .{ .sub_path = test_rel, .data = "{\"a\":1}\n{\"a\":2" });
    const torn = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(torn);
    try std.testing.expectEqualStrings("{\"a\":1}\n", torn);

    // Nothing complete at all reads as an empty journal, not a missing one.
    try ws.writeFile(io, .{ .sub_path = test_rel, .data = "{\"a\":1" });
    const only_torn = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(only_torn);
    try std.testing.expectEqualStrings("", only_torn);

    // A complete but malformed line is not the tail rule's business.
    try ws.writeFile(io, .{ .sub_path = test_rel, .data = "{\"a\":1}\nnot json\n" });
    const bad = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(bad);
    try std.testing.expectEqualStrings("{\"a\":1}\nnot json\n", bad);
}

test "appendLine takes the journal's writer lease: a held lease blocks a second appender until released" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    try appendLine(io, cwd, test_rel, "{\"a\":1}\n");

    // Hold the lease from outside, exactly as another process's append would.
    var ws = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer ws.close(io);
    var held = try ws.createFile(io, test_rel ++ ".lock", .{ .truncate = false, .read = true, .lock = .exclusive });

    var fut = try io.concurrent(appendLine, .{ io, cwd, test_rel, "{\"a\":2}\n" });
    // While the lease is held, the appender is parked: the journal is unchanged.
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    const before = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(before);
    try std.testing.expectEqualStrings("{\"a\":1}\n", before);

    held.close(io);
    try fut.await(io);
    const after = (try readAll(alloc, io, cwd, test_rel)).?;
    defer alloc.free(after);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n", after);
}

test "a missing workspace is a host fault, never an empty journal" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.FileNotFound, readAll(alloc, io, "nulya-absent-workspace", test_rel));
    try std.testing.expectError(error.FileNotFound, appendLine(io, "nulya-absent-workspace", test_rel, "x\n"));
}
