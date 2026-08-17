//! `append` — extend a UTF-8 file with text written exactly as given, behind
//! the any-visibility gate, echoing back where the text landed. Port of tcode
//! `fs/append.rs` (`{path, content}`, content non-empty).

const std = @import("std");
const rpc = @import("rpc.zig");
const text = @import("text.zig");
const freshness = @import("freshness.zig");
const write = @import("write.zig");

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
    if (content.len == 0) return rpc.refuse(alloc, "content must not be empty", .{});

    const path = try ctx.resolve(path_arg);
    const shown = text.rel(path, ctx.cwd);
    const cwd = std.Io.Dir.cwd();
    var journal = try freshness.Journal.open(alloc, io, ctx.cwd, ctx.session_id);

    const old = cwd.readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            // Missing file: create it. Everything in it is model-authored, so
            // the new version counts as fully seen.
            if (std.fs.path.dirname(path)) |parent| {
                cwd.createDirPath(io, parent) catch |e| return rpc.refuse(alloc, "cannot create {s}: {s}", .{ parent, @errorName(e) });
            }
            write.putFile(io, path, content) catch |e| return rpc.refuse(alloc, "{s}", .{try write.writeError(alloc, path, e)});
            if (journal) |*j| try j.recordWrite(path, freshness.contentHash(content));
            const lines = try text.lines(alloc, content);
            const snippet = try text.numbered(alloc, lines, 1);
            return .{ .text = try std.fmt.allocPrint(alloc, "created new file {s} ({d} line{s}). Result:\n{s}", .{ shown, lines.len, plural(lines.len), snippet }) };
        },
        else => return rpc.refuse(alloc, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    if (!std.unicode.utf8ValidateSlice(old)) {
        return rpc.refuse(alloc, "{s} is not valid UTF-8; append only supports text files and will not extend bytes lossily", .{shown});
    }
    // Gate: the model must have seen the current version (a partial read
    // counts — append destroys nothing, it only needs to know what it is
    // extending).
    if (journal) |*j| switch (j.visibility(path, freshness.contentHash(old))) {
        .full, .partial => {},
        .stale => return rpc.refuse(alloc, "{s} changed on disk since you last read it; re-read it before appending.", .{shown}),
        .unseen => return rpc.refuse(alloc, "{s} already exists and you have not read its current version; read it (even partially) before appending so you know what you are extending.", .{shown}),
    };

    // Read-modify-write rather than an append handle: the old bytes are
    // already in hand for the gate, and this reuses the Windows retry path.
    const new_text = try std.mem.concat(alloc, u8, &.{ old, content });
    write.putFile(io, path, new_text) catch |err| return rpc.refuse(alloc, "{s}", .{try write.writeError(alloc, path, err)});

    const old_lines = text.countLines(old);
    const merged = !(old.len == 0 or old[old.len - 1] == '\n');
    const appended_start = if (merged) old_lines else old_lines + 1;
    const new_total = @max(text.countLines(new_text), appended_start);
    // Echo the tail so the model sees where its text landed: the appended
    // lines plus up to 3 lines of prior context.
    const start = @max(appended_start -| 3, 1);
    // Record what reaches the model: the appendix plus the echoed context
    // lines, under the new hash. Prior visibility carries forward inside
    // `recordAppend`; a partial view never silently becomes full.
    if (journal) |*j| try j.recordAppend(path, freshness.contentHash(new_text), .{ .start = start, .end = new_total });
    const all = try text.lines(alloc, new_text);
    const snippet = try text.numbered(alloc, all[@min(start - 1, all.len)..], start);
    const count = text.countLines(content);
    const merge_note: []const u8 = if (merged) "\nnote: the file did not end with a newline; the appended text continues its last line." else "";
    return .{ .text = try std.fmt.allocPrint(alloc, "appended {d} line{s} to {s} (now {d} lines).{s} Result:\n{s}", .{ count, plural(count), shown, new_total, merge_note, snippet }) };
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// ------------------------------------------------------------------ tests

test {
    std.testing.refAllDecls(@This());
}

const TestFixture = @import("read.zig").TestFixture;
const read = @import("read.zig");

test "append: a missing file is created (parent dirs too) and echoed numbered; empty content is refused" {
    const f = try TestFixture.init("s-ap");
    defer f.deinit();
    const io = std.testing.io;
    const empty = try f.call(run, "{{\"path\":\"n/new.txt\",\"content\":\"\"}}", .{});
    try std.testing.expectEqualStrings("content must not be empty", empty.failed.message);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "n", .{}));

    const created = try f.call(run, "{{\"path\":\"n/new.txt\",\"content\":\"a\\nb\\n\"}}", .{});
    try std.testing.expectEqualStrings("created new file n" ++ std.fs.path.sep_str ++ "new.txt (2 lines). Result:\n     1\ta\n     2\tb\n", created.text);
    // Created content counts as fully seen: a follow-up append needs no read.
    const more = try f.call(run, "{{\"path\":\"n/new.txt\",\"content\":\"c\\n\"}}", .{});
    try std.testing.expectEqualStrings("appended 1 line to n" ++ std.fs.path.sep_str ++ "new.txt (now 3 lines). Result:\n     1\ta\n     2\tb\n     3\tc\n", more.text);
    const bytes = try f.tmp.dir.readFileAlloc(io, "n/new.txt", f.arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("a\nb\nc\n", bytes);
}

test "append: the gate — unseen and stale refuse, a partial read passes; the echo is the tail with 3 lines of context; a missing trailing newline merges and is noted" {
    const f = try TestFixture.init("s-ag");
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i <= 200) : (i += 1) try body.print(alloc, "line {d}\n", .{i});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = body.items });

    const unseen = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"x\\n\"}}", .{});
    try std.testing.expectEqualStrings("g.txt already exists and you have not read its current version; read it (even partially) before appending so you know what you are extending.", unseen.failed.message);

    _ = try f.call(read.run, "{{\"path\":\"g.txt\",\"offset\":1,\"limit\":120}}", .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = "changed\n" });
    const stale = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"x\\n\"}}", .{});
    try std.testing.expectEqualStrings("g.txt changed on disk since you last read it; re-read it before appending.", stale.failed.message);

    try f.tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = body.items });
    _ = try f.call(read.run, "{{\"path\":\"g.txt\",\"offset\":1,\"limit\":120}}", .{});
    const ok = try f.call(run, "{{\"path\":\"g.txt\",\"content\":\"x\\ny\\n\"}}", .{});
    try std.testing.expectEqualStrings("appended 2 lines to g.txt (now 202 lines). Result:\n   198\tline 198\n   199\tline 199\n   200\tline 200\n   201\tx\n   202\ty\n", ok.text);
    // Partial stays partial: a whole-file write is still refused, naming both ranges.
    const w = try f.call(@import("write.zig").run, "{{\"path\":\"g.txt\",\"content\":\"z\\n\"}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, w.failed.message, "only seen lines 1-120, 198-202 of its current version") != null);

    try f.tmp.dir.writeFile(io, .{ .sub_path = "m.txt", .data = "no newline" });
    _ = try f.call(read.run, "{{\"path\":\"m.txt\"}}", .{});
    const merged = try f.call(run, "{{\"path\":\"m.txt\",\"content\":\" here\\nnext\\n\"}}", .{});
    try std.testing.expectEqualStrings("appended 2 lines to m.txt (now 2 lines).\nnote: the file did not end with a newline; the appended text continues its last line. Result:\n     1\tno newline here\n     2\tnext\n", merged.text);
    const bytes = try f.tmp.dir.readFileAlloc(io, "m.txt", alloc, .unlimited);
    try std.testing.expectEqualStrings("no newline here\nnext\n", bytes);
    // Full sight carries forward: a re-read is a stub.
    const stub = try f.call(read.run, "{{\"path\":\"m.txt\"}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, stub.text, "unchanged: m.txt"));
}

test "append: not valid UTF-8 is refused; CRLF content is written byte-exact; no session means no gate" {
    const f = try TestFixture.init(null);
    defer f.deinit();
    const io = std.testing.io;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "\xff\xfe" });
    const bad = try f.call(run, "{{\"path\":\"b.txt\",\"content\":\"x\"}}", .{});
    try std.testing.expectEqualStrings("b.txt is not valid UTF-8; append only supports text files and will not extend bytes lossily", bad.failed.message);

    try f.tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "a\r\n" });
    const ok = try f.call(run, "{{\"path\":\"c.txt\",\"content\":\"b\\r\\n\"}}", .{});
    try std.testing.expectEqualStrings("appended 1 line to c.txt (now 2 lines). Result:\n     1\ta\n     2\tb\n", ok.text);
    const bytes = try f.tmp.dir.readFileAlloc(io, "c.txt", f.arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("a\r\nb\r\n", bytes);
}
