//! `read` — a text file, verbatim and self-paginating, with the freshness
//! short-circuit. Port of tcode `fs/read.rs` minus images. Every number and
//! every sentence the model sees is tcode's unless a comment says otherwise;
//! `{path, offset?, limit?, force?}`.
//!
//! Order of checks, as there: stat first (a huge file is refused before it is
//! loaded), directory / too large / binary, then the window, then freshness.
//! The output is capped below the host's own budget so its footer
//! (`continue with offset=…`) always survives.
//!
//! A missing file is an ANSWER, not a refusal (docs/goals/std.md "existence
//! answers"): the caller named the wrong path, and `notFoundHelp`'s listing of
//! the parent directory is exactly the correction a model needs — the same
//! genre as `grep`'s "no matches". A directory in place of a file, a file too
//! large or binary, and a bad argument are still refusals: those are shape
//! mismatches or malfunctions, not "nothing there".

const std = @import("std");
const rpc = @import("rpc.zig");
const text = @import("text.zig");
const freshness = @import("freshness.zig");

/// tcode fs/mod.rs DEFAULT_READ_LIMIT.
pub const default_limit: usize = 2000;
/// Requests below this are widened: extra lines are cheap, but a model walking
/// a file in 10-line slices costs a round-trip per slice. tcode fs/mod.rs
/// MIN_READ_WINDOW.
pub const min_window: usize = 120;
/// Files above this are never slurped into memory. A range read of a giant
/// log/dataset belongs to grep or `sed -n`, not a full load. tcode fs/mod.rs
/// MAX_READ_FILE_BYTES.
pub const max_file_bytes: u64 = 10 * 1024 * 1024;
/// Cap on the bytes a single read emits, independent of the line count.
/// tcode fs/mod.rs MAX_READ_OUTPUT_BYTES is 128 KB; this is 8 KB under the
/// host's per-result budget (docs/goals/std.md D5) so the host never truncates
/// a read and its footer stays where the model can see it.
pub const max_output_bytes: usize = 120 * 1024;
/// A NUL in the first 8 KB means binary. tcode fs/read.rs.
const binary_probe_bytes: usize = 8192;

pub fn run(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    const alloc = ctx.alloc;
    const io = ctx.io;

    const path_arg = switch (try rpc.requireString(alloc, args, "path")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    const offset_arg = rpc.optionalUnsigned(args, "offset") catch return rpc.refuse(alloc, "offset must be a non-negative integer", .{});
    const limit_arg = rpc.optionalUnsigned(args, "limit") catch return rpc.refuse(alloc, "limit must be a non-negative integer", .{});
    const force = rpc.optionalBool(args, "force", false) catch return rpc.refuse(alloc, "force must be a boolean", .{});

    const path = try ctx.resolve(path_arg);
    const shown = text.rel(path, ctx.cwd);
    const cwd = std.Io.Dir.cwd();

    // Stat first so a huge file is rejected before it is loaded into memory.
    // A missing file is not a malfunction — the caller named the wrong path —
    // so this is an answer (what the parent directory actually holds), not a
    // refusal. A directory in place of a file, or an unreadable path, still
    // is: those are host faults or a shape mismatch, not "nothing there".
    const st = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .text = try text.notFoundHelp(alloc, io, path) },
        else => return rpc.refuse(alloc, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    if (st.kind == .directory) {
        const names = (try text.listDir(alloc, io, path, .{ .mark_dirs = false, .sorted = false, .max = 50 })) orelse &.{};
        const listing = try std.mem.join(alloc, ", ", names);
        return rpc.refuse(alloc, "{s} is a directory, not a file. It contains: {s}", .{ path, listing });
    }
    if (st.size > max_file_bytes) return tooLarge(alloc, shown, st.size);

    const bytes = cwd.readFileAlloc(io, path, alloc, .limited(max_file_bytes + 1)) catch |err| switch (err) {
        // It vanished between stat and read — same non-refusal as above.
        error.FileNotFound => return .{ .text = try text.notFoundHelp(alloc, io, path) },
        // It grew past the limit between stat and read.
        error.StreamTooLong => return tooLarge(alloc, shown, max_file_bytes + 1),
        else => return rpc.refuse(alloc, "cannot read {s}: {s}", .{ path, @errorName(err) }),
    };
    if (bytes.len > max_file_bytes) return tooLarge(alloc, shown, bytes.len);
    if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, binary_probe_bytes)], 0) != null) {
        return rpc.refuse(alloc, "{s} is a binary file ({d} bytes); refusing to dump it into context.", .{ path, bytes.len });
    }

    const lines = try text.lines(alloc, try text.lossyUtf8(alloc, bytes));
    const total = lines.len;

    const offset: usize = @max(@as(usize, @intCast(@min(offset_arg orelse 1, std.math.maxInt(usize)))), 1);
    const limit: usize = @max(@as(usize, @intCast(@min(limit_arg orelse default_limit, std.math.maxInt(usize)))), min_window);
    const start = @min(offset - 1, total);
    const end = @min(start +| limit, total);
    if (start == end and total != 0) {
        return .{ .text = try std.fmt.allocPrint(alloc, "{s} has {d} lines; offset {d} is past the end of the file.", .{ shown, total, offset }) };
    }
    const whole_file = start == 0 and end == total;
    const range: ?freshness.Range = if (whole_file) null else .{ .start = start + 1, .end = end };

    const hash = freshness.contentHash(bytes);
    var journal = try freshness.Journal.open(alloc, io, ctx.cwd, ctx.session_id);
    const status: freshness.ReadStatus = if (journal) |*j| j.checkRead(path, hash, range) else .new;
    if (status == .unchanged and !force) {
        return .{ .text = try std.fmt.allocPrint(alloc, "unchanged: {s} has not changed since you last read it; the content is already in your context above. (force=true overrides.)", .{shown}) };
    }

    // Overlapping re-read (e.g. same offset, wider window): return only the
    // unseen slice so already-seen lines are not re-appended to the ledger.
    // Full reads and fragmented gaps fall through to the request.
    var view_start = start;
    var view_end = end;
    var overlap_note: ?[]const u8 = null;
    if (status == .new_range and !force) {
        if (range) |r| if (journal.?.uncoveredGap(path, hash, r)) |gap| {
            view_start = gap.start - 1;
            view_end = gap.end;
            overlap_note = try std.fmt.allocPrint(alloc, "note: showing only the new lines {d}-{d}; the rest of the requested range {d}-{d} is already in your context from an earlier read.\n", .{ gap.start, gap.end, start + 1, end });
        };
    }

    var out: std.ArrayList(u8) = .empty;
    if (status == .changed_on_disk) try out.appendSlice(alloc, "note: this file changed on disk since you last read it.\n");
    if (overlap_note) |note| try out.appendSlice(alloc, note);

    const rendered = try text.render(alloc, lines[view_start..view_end], view_start + 1, max_output_bytes, false);
    try out.appendSlice(alloc, rendered.text);
    const shown_end = view_start + rendered.emitted;
    // Freshness represents what reached the model, not what was requested:
    // the render can stop early on the output-byte budget.
    const recorded: ?freshness.Range = if (view_start == 0 and shown_end == total) null else .{ .start = view_start + 1, .end = shown_end };
    if (journal) |*j| try j.recordRead(path, hash, recorded);

    if (shown_end < total) {
        try out.print(alloc, "[showing lines {d}-{d} of {d}; continue with offset={d}]", .{ view_start + 1, shown_end, total, shown_end + 1 });
    } else if (view_start > 0) {
        // Without a gutter this footer is the only thing that says where the
        // window starts. Omitted for a whole-file read, where the first line
        // is line 1 and saying so is noise.
        try out.print(alloc, "[showing lines {d}-{d} of {d}]", .{ view_start + 1, shown_end, total });
    }
    if (try text.clipNote(alloc, rendered.clipped)) |note| {
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, note);
    }
    if (out.items.len == 0) try out.appendSlice(alloc, "(empty file)");
    return .{ .text = try out.toOwnedSlice(alloc) };
}

fn tooLarge(alloc: std.mem.Allocator, shown: []const u8, size: u64) !rpc.Outcome {
    const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
    return rpc.refuse(alloc, "{s} is {d:.1} MB — too large to load into context. Search it with grep, or read a specific range via shell, e.g. `sed -n '2000,2100p'`.", .{ shown, mb });
}

// ------------------------------------------------------------------ tests
// In-process, through `run` with a real directory: the wire and the binary are
// `tests/e2e/std_fs.zig`'s business.

test {
    std.testing.refAllDecls(@This());
}

/// A scratch workspace as one call sees it — a `Ctx` over a temp directory,
/// with or without a session — for the in-process tests of all three file
/// tools (`write.zig` / `append.zig` import it). Test-only.
pub const TestFixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    ctx: rpc.Ctx,

    pub fn init(session_id: ?[]const u8) !*TestFixture {
        const f = try std.testing.allocator.create(TestFixture);
        f.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const alloc = f.arena.allocator();
        f.tmp = std.testing.tmpDir(.{});
        f.env = std.process.Environ.Map.init(alloc);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try alloc.dupe(u8, buf[0..try f.tmp.dir.realPath(std.testing.io, &buf)]);
        f.ctx = .{ .alloc = alloc, .io = std.testing.io, .cwd = cwd, .env = &f.env, .session_id = session_id };
        return f;
    }

    pub fn deinit(f: *TestFixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
        std.testing.allocator.destroy(f);
    }

    /// Call `tool` with the arguments `json` formats to (`{{`/`}}` for braces).
    pub fn call(f: *TestFixture, tool: anytype, comptime json: []const u8, args: anytype) !rpc.Outcome {
        const s = try std.fmt.allocPrint(f.arena.allocator(), json, args);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), s, .{});
        return tool(&f.ctx, parsed.object);
    }
};

test "read: whole file verbatim without gutter, then unchanged stub in a session, force overrides" {
    const f = try TestFixture.init("s-read");
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "one\r\ntwo\nthree" });

    const first = try f.call(run, "{{\"path\":\"a.txt\"}}", .{});
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", first.text);
    const again = try f.call(run, "{{\"path\":\"a.txt\"}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, again.text, "unchanged: a.txt has not changed since you last read it"));
    const forced = try f.call(run, "{{\"path\":\"a.txt\",\"force\":true}}", .{});
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", forced.text);
}

test "read: without a session every read returns content" {
    const f = try TestFixture.init(null);
    defer f.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x\n" });
    const first = try f.call(run, "{{\"path\":\"a.txt\"}}", .{});
    try std.testing.expectEqualStrings("x\n", first.text);
    const again = try f.call(run, "{{\"path\":\"a.txt\"}}", .{});
    try std.testing.expectEqualStrings("x\n", again.text);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(std.testing.io, ".nulya", .{}));
}

test "read: window footers, minimum window, offset past the end, new range returns only the gap" {
    const f = try TestFixture.init("s-win");
    defer f.deinit();
    const alloc = f.arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i <= 300) : (i += 1) try body.print(alloc, "line {d}\n", .{i});
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.txt", .data = body.items });

    // limit 10 is widened to 120.
    const w1 = try f.call(run, "{{\"path\":\"big.txt\",\"offset\":1,\"limit\":10}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, w1.text, "line 1\n"));
    try std.testing.expect(std.mem.endsWith(u8, w1.text, "line 120\n[showing lines 1-120 of 300; continue with offset=121]"));

    // Same offset, wider window: only the unseen tail comes back, with a note.
    const w2 = try f.call(run, "{{\"path\":\"big.txt\",\"offset\":1,\"limit\":150}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, w2.text, "note: showing only the new lines 121-150; the rest of the requested range 1-150 is already in your context from an earlier read.\nline 121\n"));
    try std.testing.expect(std.mem.endsWith(u8, w2.text, "line 150\n[showing lines 121-150 of 300; continue with offset=151]"));

    // A window that ends at the last line gets the plain footer.
    const w3 = try f.call(run, "{{\"path\":\"big.txt\",\"offset\":200}}", .{});
    try std.testing.expect(std.mem.endsWith(u8, w3.text, "line 300\n[showing lines 200-300 of 300]"));

    const past = try f.call(run, "{{\"path\":\"big.txt\",\"offset\":301}}", .{});
    try std.testing.expectEqualStrings("big.txt has 300 lines; offset 301 is past the end of the file.", past.text);
}

test "read: changed on disk is noted; a directory and a binary file are refused, a missing file answers with what its parent holds" {
    const f = try TestFixture.init("s-chg");
    defer f.deinit();
    const io = std.testing.io;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "v1\n" });
    _ = try f.call(run, "{{\"path\":\"c.txt\"}}", .{});
    try f.tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "v2\n" });
    const changed = try f.call(run, "{{\"path\":\"c.txt\"}}", .{});
    try std.testing.expectEqualStrings("note: this file changed on disk since you last read it.\nv2\n", changed.text);

    try f.tmp.dir.createDirPath(io, "d");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "d/inner.txt", .data = "" });
    const dir = try f.call(run, "{{\"path\":\"d\"}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, dir.failed, "is a directory, not a file. It contains: inner.txt") != null);

    const missing = try f.call(run, "{{\"path\":\"d/nope.txt\"}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, missing.text, "File not found: "));
    try std.testing.expect(std.mem.endsWith(u8, missing.text, "exists and contains: inner.txt"));

    try f.tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "abc\x00def" });
    const bin = try f.call(run, "{{\"path\":\"bin.dat\"}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, bin.failed, "is a binary file (7 bytes); refusing to dump it into context.") != null);

    const empty_path = try f.call(run, "{{\"path\":\"e.txt\"}}", .{});
    try std.testing.expect(std.mem.startsWith(u8, empty_path.text, "File not found: "));
    try f.tmp.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "" });
    const empty = try f.call(run, "{{\"path\":\"e.txt\"}}", .{});
    try std.testing.expectEqualStrings("(empty file)", empty.text);
}

test "read: a file over 10 MB is refused before it is loaded; a long line is clipped inside the host's line limit and the note names it" {
    const f = try TestFixture.init(null);
    defer f.deinit();
    const io = std.testing.io;
    const alloc = f.arena.allocator();

    const huge = try alloc.alloc(u8, max_file_bytes + 1);
    @memset(huge, 'h');
    try f.tmp.dir.writeFile(io, .{ .sub_path = "huge.txt", .data = huge });
    const refused = try f.call(run, "{{\"path\":\"huge.txt\"}}", .{});
    try std.testing.expectEqualStrings("huge.txt is 10.0 MB — too large to load into context. Search it with grep, or read a specific range via shell, e.g. `sed -n '2000,2100p'`.", refused.failed);

    const long = try alloc.alloc(u8, 40_000);
    @memset(long, 'l');
    const body = try std.mem.concat(alloc, u8, &.{ "short\n", long, "\nafter\n" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "long.txt", .data = body });
    const clipped = try f.call(run, "{{\"path\":\"long.txt\"}}", .{});
    var lines = std.mem.splitScalar(u8, clipped.text, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= text.max_line_bytes);
    try std.testing.expect(std.mem.indexOf(u8, clipped.text, text.marker_open) != null);
    try std.testing.expect(std.mem.indexOf(u8, clipped.text, "\nafter\nnote: line 2 was clipped at 16364 of 40000 bytes; the ") != null);
    try std.testing.expect(std.mem.indexOf(u8, clipped.text, "[showing") == null);
}

test "read: bad argument types are refused, a missing path too" {
    const f = try TestFixture.init(null);
    defer f.deinit();
    const no_path = try f.call(run, "{{}}", .{});
    try std.testing.expectEqualStrings("missing required parameter: path", no_path.failed);
    const bad_offset = try f.call(run, "{{\"path\":\"x\",\"offset\":\"1\"}}", .{});
    try std.testing.expect(std.mem.indexOf(u8, bad_offset.failed, "offset") != null);
}
