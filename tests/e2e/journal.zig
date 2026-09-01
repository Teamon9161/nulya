//! `nulya journal append|read` end to end: the CLI exposure of the
//! append-only JSONL discipline `journals/journal.zig` already implements for
//! the three kernel journals — a real process appends, a real process reads,
//! and two real processes racing the same file never tear a line.

const std = @import("std");
const support = @import("support.zig");

const runCli = support.runCli;
const runCliStdin = support.runCliStdin;

/// The absolute path of the binary under test, or a skip.
fn nulyaExe(alloc: std.mem.Allocator, host_env: *const std.process.Environ.Map) ![]u8 {
    const rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    return std.fs.path.resolve(alloc, &.{rel});
}

fn append(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe: []const u8, path: []const u8, record: []const u8) !support.CliRun {
    return runCliStdin(alloc, io, ws, &.{ exe, "journal", "append", path }, record, &.{});
}

fn read(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe: []const u8, path: []const u8) !support.CliRun {
    return runCli(alloc, io, ws, &.{ exe, "journal", "read", path });
}

test "journal append/read: two appends round-trip byte for byte through a real process on each side" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const a1 = try append(alloc, io, ws, exe, "log.jsonl", "{\"a\":1}");
    defer alloc.free(a1.stdout);
    try std.testing.expectEqual(@as(u8, 0), a1.code);
    try std.testing.expectEqualStrings("", a1.stdout);

    const a2 = try append(alloc, io, ws, exe, "log.jsonl", "{\"a\":2}\n");
    defer alloc.free(a2.stdout);
    try std.testing.expectEqual(@as(u8, 0), a2.code);

    const back = try read(alloc, io, ws, exe, "log.jsonl");
    defer alloc.free(back.stdout);
    try std.testing.expectEqual(@as(u8, 0), back.code);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n", back.stdout);
}

test "journal append: a crash-left half line is repaired, not glued onto, and never reaches a reader" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Simulate a process that died mid-write: one complete line, then a torn tail.
    try ws.writeFile(io, .{ .sub_path = "tail.jsonl", .data = "{\"a\":1}\n{\"a\":2" });

    const a3 = try append(alloc, io, ws, exe, "tail.jsonl", "{\"a\":3}");
    defer alloc.free(a3.stdout);
    try std.testing.expectEqual(@as(u8, 0), a3.code);

    const back = try read(alloc, io, ws, exe, "tail.jsonl");
    defer alloc.free(back.stdout);
    try std.testing.expectEqual(@as(u8, 0), back.code);
    // The torn line is gone, the new record is not glued onto it, and both
    // complete lines survive in order.
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"a\":3}\n", back.stdout);
}

test "journal append: non-JSON and multi-line stdin refuse without touching the file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Not valid JSON at all.
    {
        const bad = try append(alloc, io, ws, exe, "j.jsonl", "not json");
        defer alloc.free(bad.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad.code);
        try std.testing.expectEqualStrings("", bad.stdout);
        // Nothing was ever written: the file does not exist.
        try std.testing.expectError(error.FileNotFound, ws.access(io, "j.jsonl", .{}));
    }

    // Valid JSON, but two lines of it — not one record.
    {
        const good = try append(alloc, io, ws, exe, "j.jsonl", "{\"a\":1}");
        defer alloc.free(good.stdout);
        try std.testing.expectEqual(@as(u8, 0), good.code);

        const multiline = try append(alloc, io, ws, exe, "j.jsonl", "{\"a\":2}\n{\"a\":3}\n");
        defer alloc.free(multiline.stdout);
        try std.testing.expectEqual(@as(u8, 1), multiline.code);
        try std.testing.expectEqualStrings("", multiline.stdout);

        // The one valid record from before is still the whole file.
        const back = try read(alloc, io, ws, exe, "j.jsonl");
        defer alloc.free(back.stdout);
        try std.testing.expectEqualStrings("{\"a\":1}\n", back.stdout);
    }
}

test "journal read: a file that was never appended to is empty output, exit 0 — not an error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const back = try read(alloc, io, ws, exe, "never-written.jsonl");
    defer alloc.free(back.stdout);
    try std.testing.expectEqual(@as(u8, 0), back.code);
    try std.testing.expectEqualStrings("", back.stdout);
}

/// One "process": N real `nulya journal append` invocations against the same
/// file, run one after another (a real process is its own serialization, so
/// what this races against the other call of this function is purely the
/// journal's own writer lease, `<file>.lock`).
fn appendMany(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe: []const u8, path: []const u8, tag: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [64]u8 = undefined;
        const record = try std.fmt.bufPrint(&buf, "{{\"tag\":\"{c}\",\"n\":{d}}}", .{ tag, i });
        const r = try append(alloc, io, ws, exe, path, record);
        defer alloc.free(r.stdout);
        if (r.code != 0) return error.TestUnexpectedResult;
    }
}

test "journal append: two real processes racing the same file never tear or drop a line" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const count = 20;
    var fut_a = try io.concurrent(appendMany, .{ alloc, io, ws, exe, "race.jsonl", 'a', count });
    var fut_b = try io.concurrent(appendMany, .{ alloc, io, ws, exe, "race.jsonl", 'b', count });
    try fut_a.await(io);
    try fut_b.await(io);

    const back = try read(alloc, io, ws, exe, "race.jsonl");
    defer alloc.free(back.stdout);
    try std.testing.expectEqual(@as(u8, 0), back.code);

    // Every line is a complete, parseable record — a torn write would leave a
    // line that fails to parse, or glue two records into one.
    var seen_a: usize = 0;
    var seen_b: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, back.stdout, "\n"), '\n');
    var total: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        total += 1;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
            std.debug.print("unparseable line: {s}\n", .{line});
            return error.TestUnexpectedResult;
        };
        defer parsed.deinit();
        const tag = parsed.value.object.get("tag").?.string;
        if (std.mem.eql(u8, tag, "a")) seen_a += 1 else if (std.mem.eql(u8, tag, "b")) seen_b += 1;
    }
    try std.testing.expectEqual(@as(usize, count * 2), total);
    try std.testing.expectEqual(@as(usize, count), seen_a);
    try std.testing.expectEqual(@as(usize, count), seen_b);
}
