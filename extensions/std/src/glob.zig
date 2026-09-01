//! `glob` — find files by name pattern, ported from tcode search.rs (`GlobTool`).
//!
//! Walk `path` (default cwd) with `walk.zig` — gitignore, prune table, 10 s
//! deadline, directory symlinks skipped and counted unless `follow_symlinks` —
//! and keep every regular file whose path relative to the base matches
//! `pattern` (`vendor/globpat.zig`: a pattern with no `/` matches the basename
//! anywhere; `**`, `?`, `[...]`, `{a,b}`). Newest first by modification time,
//! ties broken by path so two identical calls agree and `offset` paging never
//! skips or repeats; at most `max_results` per page.

const std = @import("std");
const rpc = @import("rpc.zig");
const walk = @import("walk.zig");
const globpat = @import("vendor/globpat.zig");

/// Page size (tcode: `.take(200)`).
pub const max_results: usize = 200;

pub fn run(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    // Paths reach the model as valid UTF-8 whatever the file system named them.
    return walk.sanitize(ctx.alloc, try answer(ctx, args));
}

fn answer(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    const alloc = ctx.alloc;
    const io = ctx.io;

    const pattern = switch (try rpc.requireString(alloc, args, "pattern")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    const path_arg: ?[]const u8 = switch (args.get("path") orelse std.json.Value.null) {
        .null => null,
        .string => |s| s,
        else => return rpc.refuse(alloc, "path must be a string", .{}),
    };
    const offset = (rpc.optionalUnsigned(args, "offset") catch return rpc.refuse(alloc, "offset must be a non-negative integer", .{})) orelse 0;
    const follow_links = rpc.optionalBool(args, "follow_symlinks", false) catch return rpc.refuse(alloc, "follow_symlinks must be a boolean", .{});

    const base = if (path_arg) |p| try ctx.resolve(p) else ctx.cwd;
    const base_display = try walk.relDisplay(alloc, base, ctx.cwd);

    var finder: Finder = .{ .alloc = alloc, .io = io, .pattern = pattern, .base_display = base_display };
    var report: walk.Report = .{};
    const base_stat: ?std.Io.File.Stat = std.Io.Dir.cwd().statFile(io, base, .{}) catch null;
    if (base_stat) |st| {
        if (st.kind == .file) {
            // A base that is one file yields that file, matched by name (the
            // walker in tcode yields its root as an entry).
            if (globpat.matchPath(pattern, std.fs.path.basename(base))) {
                try finder.hits.append(alloc, .{ .mtime = st.mtime.nanoseconds, .path = base_display });
            }
        } else {
            report = try walk.walk(alloc, io, base, .{
                .follow_symlinks = follow_links,
                .allow_pruned_descend = walk.pathArgAllowsPrunedDescend(path_arg),
            }, &finder);
        }
    }
    // A base that does not exist walks nothing and answers "no files match",
    // as tcode's walker did.

    const prune_note = try report.pruned.note(alloc);
    const hits = finder.hits.items;
    if (hits.len == 0) {
        var m: std.Io.Writer.Allocating = .init(alloc);
        try m.writer.print("no files match {s} under {s}", .{ pattern, if (base_display.len == 0) "." else base_display });
        if (report.skipped_directory_links > 0) {
            const noun = if (report.skipped_directory_links == 1) "directory symlink was" else "directory symlinks were";
            try m.writer.print("\n[{d} {s} skipped — set follow_symlinks=true to search their targets]", .{ report.skipped_directory_links, noun });
        }
        if (prune_note) |note| try m.writer.print("\n{s}", .{note});
        if (report.timed_out) try m.writer.print("\n[search timed out after {d}s before finishing]", .{walk.deadline_seconds});
        return .{ .text = try m.toOwnedSlice() };
    }

    // Newest first, ties broken by path.
    std.mem.sort(Hit, hits, {}, hitLess);
    const total = hits.len;
    if (offset >= total) {
        return .{ .text = try std.fmt.allocPrint(alloc, "offset={d} is past the last of {d} matches for {s} — lower offset or drop it", .{ offset, total, pattern }) };
    }
    const page = hits[offset..@min(total, offset + max_results)];
    const shown = page.len;

    var out: std.Io.Writer.Allocating = .init(alloc);
    for (page, 0..) |h, i| {
        if (i > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(h.path);
    }
    if (report.timed_out) {
        try out.writer.print("\n[search timed out after {d}s — partial results]", .{walk.deadline_seconds});
    } else if (total > offset + shown) {
        try out.writer.print("\n[{d} matches; showing {d}-{d} — set offset={d} for more]", .{ total, offset + 1, offset + shown, offset + shown });
    }
    if (prune_note) |note| try out.writer.print("\n{s}", .{note});
    return .{ .text = try out.toOwnedSlice() };
}

const Hit = struct { mtime: i96, path: []const u8 };

fn hitLess(_: void, a: Hit, b: Hit) bool {
    if (a.mtime != b.mtime) return a.mtime > b.mtime;
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The walker's callback: match, stat for mtime, keep.
const Finder = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    base_display: []const u8,
    hits: std.ArrayList(Hit) = .empty,

    pub fn visit(self: *Finder, entry: walk.Entry) anyerror!void {
        if (!globpat.matchPath(self.pattern, entry.rel)) return;
        // Unreadable metadata sorts as the epoch, as tcode's `unwrap_or(UNIX_EPOCH)`.
        const mtime: i96 = if (entry.dir.statFile(self.io, entry.name, .{})) |st| st.mtime.nanoseconds else |_| 0;
        try self.hits.append(self.alloc, .{ .mtime = mtime, .path = try walk.display(self.alloc, self.base_display, entry.rel) });
    }
};

test {
    std.testing.refAllDecls(@This());
}

const TestCtx = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    cwd_buf: [std.fs.max_path_bytes]u8,
    ctx: rpc.Ctx,

    fn init(self: *TestCtx) !void {
        self.arena = .init(std.testing.allocator);
        self.env = try std.testing.environ.createMap(self.arena.allocator());
        self.tmp = std.testing.tmpDir(.{});
        // The fixture is a repository root, because the walk it drives loads the
        // ignore files of every directory from the nearest `.git` above down to
        // base (`walk.loadAncestors`). Without this marker the answers depend on
        // where `std.testing.tmpDir` happened to land — `.zig-cache/tmp` under
        // whichever directory `zig build` was invoked from — so a fixture that
        // writes `node_modules/` gets different results in a checkout whose
        // ancestor `.gitignore` already hides that name. A file rather than a
        // directory (`hasGit` takes either, as git does for worktrees): a `.git`
        // DIRECTORY here would also be walked and pruned, which is a fact about
        // the fixture leaking into every prune note these tests assert.
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git", .data = "" });
        const n = try self.tmp.dir.realPath(std.testing.io, &self.cwd_buf);
        self.ctx = .{
            .alloc = self.arena.allocator(),
            .io = std.testing.io,
            .cwd = self.cwd_buf[0..n],
            .env = &self.env,
            .session_id = null,
        };
    }

    fn deinit(self: *TestCtx) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn write(self: *TestCtx, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(std.testing.io, d);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = data });
    }

    fn glob(self: *TestCtx, args_json: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), args_json, .{});
        return switch (try run(&self.ctx, parsed.object)) {
            .text => |t| t,
            .failed => |message| message,
        };
    }
};

fn slashed(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

test "glob run: name patterns match anywhere, path patterns from the base; pruned dirs are skipped and reported; an explicit pruned path descends" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    const alloc = t.arena.allocator();
    try t.write("a.rs", "a\n");
    try t.write("src/app.rs", "b\n");
    try t.write("src/deep/x.rs", "c\n");
    try t.write("package.json", "{}\n");
    try t.write("dist/index.d.ts", "export {};\n");
    try t.write("node_modules/@codemirror/lang-markdown/README.md", "docs\n");
    try t.write("node_modules/@codemirror/lang-markdown/dist/index.d.ts", "export {};\n");

    const rs = try slashed(alloc, try t.glob("{\"pattern\":\"*.rs\"}"));
    try std.testing.expect(std.mem.indexOf(u8, rs, "a.rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs, "src/app.rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs, "src/deep/x.rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, rs, "[2 pruned directories were skipped: dist/, node_modules/ — set `path` inside one explicitly to search it]") != null);

    const direct = try slashed(alloc, try t.glob("{\"pattern\":\"src/*.rs\"}"));
    try std.testing.expect(std.mem.indexOf(u8, direct, "src/app.rs") != null);
    try std.testing.expect(std.mem.indexOf(u8, direct, "x.rs") == null);

    const star = try slashed(alloc, try t.glob("{\"pattern\":\"*\"}"));
    try std.testing.expect(std.mem.indexOf(u8, star, "package.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, star, "dist/index.d.ts") == null);

    const inside = try slashed(alloc, try t.glob("{\"path\":\"node_modules/@codemirror/lang-markdown\",\"pattern\":\"**/*.d.ts\"}"));
    try std.testing.expectEqualStrings("node_modules/@codemirror/lang-markdown/dist/index.d.ts", inside);

    const none = try t.glob("{\"pattern\":\"*.nothing\"}");
    try std.testing.expect(std.mem.startsWith(u8, none, "no files match *.nothing under ."));
    try std.testing.expect(std.mem.indexOf(u8, none, "[2 pruned directories were skipped") != null);

    // A base that does not exist finds nothing, and says so under its own name.
    const gone = try slashed(alloc, try t.glob("{\"pattern\":\"*\",\"path\":\"nowhere\"}"));
    try std.testing.expect(std.mem.startsWith(u8, gone, "no files match * under nowhere"));
}

test "glob run: newest first with a stable path tie-break, 200 per page, offset paging and past-the-end" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    const alloc = t.arena.allocator();
    const io = std.testing.io;

    for (0..250) |i| try t.write(try std.fmt.allocPrint(alloc, "f{d:0>3}.rs", .{i}), "x\n");
    // Pin every mtime to the same instant, then make one file newer.
    const stamp: std.Io.Timestamp = .now(io, .real);
    for (0..250) |i| {
        const name = try std.fmt.allocPrint(alloc, "f{d:0>3}.rs", .{i});
        var f = try t.tmp.dir.openFile(io, name, .{ .mode = .read_write });
        defer f.close(io);
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = stamp } });
    }
    {
        var f = try t.tmp.dir.openFile(io, "f123.rs", .{ .mode = .read_write });
        defer f.close(io);
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = stamp.addDuration(.fromSeconds(60)) } });
    }

    const first = try t.glob("{\"pattern\":\"*.rs\"}");
    try std.testing.expect(std.mem.startsWith(u8, first, "f123.rs\nf000.rs\nf001.rs\n"));
    try std.testing.expect(std.mem.endsWith(u8, first, "\n[250 matches; showing 1-200 — set offset=200 for more]"));
    var lines = std.mem.splitScalar(u8, first, '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        if (std.mem.endsWith(u8, l, ".rs")) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 200), n);
    // The same call again agrees line for line.
    try std.testing.expectEqualStrings(first, try t.glob("{\"pattern\":\"*.rs\"}"));

    const second = try t.glob("{\"pattern\":\"*.rs\",\"offset\":200}");
    try std.testing.expect(std.mem.startsWith(u8, second, "f200.rs\n"));
    try std.testing.expect(std.mem.endsWith(u8, second, "f249.rs"));
    try std.testing.expect(std.mem.indexOf(u8, second, "set offset=") == null);

    const past = try t.glob("{\"pattern\":\"*.rs\",\"offset\":900}");
    try std.testing.expect(std.mem.startsWith(u8, past, "offset=900 is past the last of 250 matches for *.rs"));
}
