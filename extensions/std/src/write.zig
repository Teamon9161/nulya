//! `write` — create or overwrite a whole file, behind the read-in-full gate.
//! Port of tcode `fs/write.rs` (`{path, content}`); `putFile` / `writeError`
//! are `fs/mod.rs`'s `write_with_windows_retry` / `write_error`, shared with
//! `append`.

const std = @import("std");
const builtin = @import("builtin");
const rpc = @import("rpc.zig");
const text = @import("text.zig");
const freshness = @import("freshness.zig");

pub fn run(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    const alloc = ctx.alloc;
    const io = ctx.io;

    const path_arg = switch (try rpc.requireString(alloc, args, "path")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    const content = switch (try rpc.requireString(alloc, args, "content")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    // `write` replaces the whole file from context, and the read-in-full gate
    // only tracks line ranges — it cannot tell that a line the model saw was
    // clipped inside. Without this check the marker `read` adds is a
    // data-corruption seed.
    if (text.hasReadMarker(content)) return rpc.refuse(alloc, "{s}", .{try text.markerError(alloc, "content")});

    const path = try ctx.resolve(path_arg);
    const shown = text.rel(path, ctx.cwd);
    const cwd = std.Io.Dir.cwd();

    var journal = try freshness.Journal.open(alloc, io, ctx.cwd, ctx.session_id);
    if (journal) |*j| {
        // Only an existing, readable file is gated (tcode: `if let Ok(existing)`).
        if (cwd.readFileAlloc(io, path, alloc, .unlimited)) |existing| {
            switch (j.visibility(path, freshness.contentHash(existing))) {
                .full => {},
                .partial => |ranges| {
                    var seen: std.ArrayList(u8) = .empty;
                    for (ranges, 0..) |r, i| {
                        if (i != 0) try seen.appendSlice(alloc, ", ");
                        try seen.print(alloc, "{d}-{d}", .{ r.start, r.end });
                    }
                    return rpc.refuse(alloc, "{s} already exists and you have only seen lines {s} of its current version; `write` replaces the whole file. Read the remaining lines first, or use `edit`/`append` for a targeted change.", .{ shown, seen.items });
                },
                .stale => return rpc.refuse(alloc, "{s} changed on disk since you last read it; re-read it before overwriting so the external changes are not destroyed unknowingly.", .{shown}),
                .unseen => return rpc.refuse(alloc, "{s} already exists and you have not read its current version; read it first so no content is destroyed unknowingly.", .{shown}),
            }
        } else |_| {}
    }

    if (std.fs.path.dirname(path)) |parent| {
        cwd.createDirPath(io, parent) catch |err| return rpc.refuse(alloc, "cannot create {s}: {s}", .{ parent, @errorName(err) });
    }
    putFile(io, path, content) catch |err| return rpc.refuse(alloc, "{s}", .{try writeError(alloc, path, err)});
    if (journal) |*j| try j.recordWrite(path, freshness.contentHash(content));
    return .{ .text = try std.fmt.allocPrint(alloc, "wrote {s} ({d} lines)", .{ shown, text.countLines(content) }) };
}

/// Windows rejects a write while another process has the file memory-mapped
/// (`ERROR_USER_MAPPED_FILE`, 1224), normally transiently — an editor or
/// indexer releasing a just-read file. This runtime reports that status as
/// `AccessDenied`, so that is what is retried once after 50 ms, on Windows only.
/// tcode fs/mod.rs `write_with_windows_retry`.
pub fn putFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| switch (err) {
        error.AccessDenied => if (builtin.os.tag == .windows) {
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
            return cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
        } else return err,
        else => return err,
    };
}

/// tcode fs/mod.rs `write_error`.
pub fn writeError(alloc: std.mem.Allocator, path: []const u8, err: anyerror) ![]const u8 {
    if (builtin.os.tag == .windows and err == error.AccessDenied) {
        return std.fmt.allocPrint(alloc, "cannot write {s}: {s}. Windows may have the file temporarily mapped or locked (os error 1224); retried once after 50ms. Close the program holding it and retry.", .{ path, @errorName(err) });
    }
    return std.fmt.allocPrint(alloc, "cannot write {s}: {s}", .{ path, @errorName(err) });
}

// ------------------------------------------------------------------ tests

test {
    std.testing.refAllDecls(@This());
}

const TestFixture = @import("read.zig").TestFixture;
const read = @import("read.zig");

test "write: a new file (parent dirs created) reports its line count; content with a read marker is refused before anything is written" {
    const f = try TestFixture.init("s-w");
    defer f.deinit();
    const io = std.testing.io;
    const ok = try f.call(run, "{{\"path\":\"a/b/new.txt\",\"content\":\"one\\ntwo\\n\"}}", .{});
    try std.testing.expectEqualStrings("wrote a" ++ std.fs.path.sep_str ++ "b" ++ std.fs.path.sep_str ++ "new.txt (2 lines)", ok.text);
    const bytes = try f.tmp.dir.readFileAlloc(io, "a/b/new.txt", f.arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("one\ntwo\n", bytes);

    const marked = try f.call(run, "{{\"path\":\"m.txt\",\"content\":\"x{s}12 bytes]\"}}", .{text.marker_open});
    try std.testing.expectEqual(rpc.code_refused, marked.failed.code);
    try std.testing.expect(std.mem.startsWith(u8, marked.failed.message, "content contains a truncation marker"));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "m.txt", .{}));
}

test "write: the visibility gate — unseen, partial (with the seen ranges), stale are refused; full passes; the write itself counts as a full read" {
    const f = try TestFixture.init("s-gate");
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i <= 300) : (i += 1) try body.print(alloc, "line {d}\n", .{i});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = body.items });

    const unseen = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"new\\n\"}}", .{});
    try std.testing.expectEqualStrings("g.txt already exists and you have not read its current version; read it first so no content is destroyed unknowingly.", unseen.failed.message);

    _ = try f.call(read.run, "{{\"path\":\"g.txt\",\"offset\":1,\"limit\":120}}", .{});
    const partial = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"new\\n\"}}", .{});
    try std.testing.expectEqualStrings("g.txt already exists and you have only seen lines 1-120 of its current version; `write` replaces the whole file. Read the remaining lines first, or use `edit`/`append` for a targeted change.", partial.failed.message);

    _ = try f.call(read.run, "{{\"path\":\"g.txt\",\"offset\":121}}", .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = "changed behind your back\n" });
    const stale = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"new\\n\"}}", .{});
    try std.testing.expectEqualStrings("g.txt changed on disk since you last read it; re-read it before overwriting so the external changes are not destroyed unknowingly.", stale.failed.message);

    _ = try f.call(read.run, "{{\"path\":\"g.txt\"}}", .{});
    const ok = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"new\\n\"}}", .{});
    try std.testing.expectEqualStrings("wrote g.txt (1 lines)", ok.text);
    // What we wrote is what the model has: an immediate re-read is a stub.
    const stub = try f.call(read.run, "{{\"path\":\"g.txt\"}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, stub.text, "unchanged: g.txt"));
    // And a second overwrite goes straight through.
    const again = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"newer\\n\"}}", .{});
    try std.testing.expectEqualStrings("wrote g.txt (1 lines)", again.text);
}

test "write: without a session an existing unread file is simply overwritten" {
    const f = try TestFixture.init(null);
    defer f.deinit();
    const io = std.testing.io;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "u.txt", .data = "old\n" });
    const ok = try f.call(run, "{{\"path\":\"u.txt\",\"content\":\"a\\r\\nb\\r\\n\"}}", .{});
    try std.testing.expectEqualStrings("wrote u.txt (2 lines)", ok.text);
    const bytes = try f.tmp.dir.readFileAlloc(io, "u.txt", f.arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("a\r\nb\r\n", bytes);
}
