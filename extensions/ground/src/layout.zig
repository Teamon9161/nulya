//! The two-level project map.
//!
//! Ported from tcode's `grounding.rs::dir_tree`, budgets included. What differs
//! is where the file list comes from: tcode walks with the `ignore` crate, we
//! ask `git ls-files` (see `git.zig` — gitignore is git's algorithm, and this
//! package has no reason to own a second answer to it). Outside a working tree
//! there is nothing to ask, so a plain two-level read stands in.

const std = @import("std");
const git = @import("git.zig");

/// Overall budget for the layout section.
const max_entries: usize = 80;
/// One crowded directory (generated assets, fixtures…) must not spend the whole
/// budget before its siblings appear, so children are capped per directory.
const max_per_dir: usize = 20;

/// Directories that are build output or a dependency cache: present in most
/// checkouts, uninformative in all of them. Only consulted outside a git
/// working tree — inside one, `.gitignore` has already said so.
const uninformative = [_][]const u8{
    "node_modules", "target", "zig-out", "build", "dist", "vendor", "__pycache__",
};

/// Two levels of names, in the shape they are printed in: a directory carries
/// its trailing separator, a file does not.
const Tree = struct {
    alloc: std.mem.Allocator,
    /// Top-level entry → its children. A file's set stays empty.
    tops: std.StringArrayHashMapUnmanaged(Children) = .empty,

    const Children = std.StringArrayHashMapUnmanaged(void);

    fn top(self: *Tree, name: []const u8) !*Children {
        const gop = try self.tops.getOrPut(self.alloc, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        return gop.value_ptr;
    }

    /// One path relative to this directory, `/`-separated. Everything below the
    /// second level is folded into the second-level directory it lives in.
    fn addPath(self: *Tree, path: []const u8) !void {
        // This harness's own directory is not this project's layout. It shows up
        // here only in a checkout that has not gitignored it, and a map that
        // depends on whether somebody remembered to is not a map.
        if (std.mem.startsWith(u8, path, ".nulya/")) return;
        const first = split(path);
        if (first.rest.len == 0) {
            _ = try self.top(first.head);
            return;
        }
        const parent = try self.top(try dirName(self.alloc, first.head));
        const second = split(first.rest);
        const child = if (second.rest.len == 0)
            second.head
        else
            try dirName(self.alloc, second.head);
        try parent.put(self.alloc, child, {});
    }

    fn write(self: *Tree, w: *std.Io.Writer) !void {
        const names = try sortedKeys(self.alloc, self.tops.keys());
        var written: usize = 0;
        for (names[0..@min(names.len, max_per_dir)]) |name| {
            try w.print("{s}\n", .{name});
            written += 1;
            const children = self.tops.get(name).?;
            if (children.count() != 0) {
                const kids = try sortedKeys(self.alloc, children.keys());
                var shown: usize = 0;
                // Checked before each child, not once per top-level entry. The
                // ported version checked after the whole child loop, so one
                // crowded directory could carry the count from 79 to 99 and the
                // "overall budget" was not one.
                while (shown < kids.len and shown < max_per_dir and written < max_entries) : (shown += 1) {
                    try w.print("  {s}\n", .{kids[shown]});
                    written += 1;
                }
                if (kids.len > shown)
                    try w.print("  … (+{d} more)\n", .{kids.len - shown});
            }
            if (written >= max_entries) {
                try w.writeAll("… (truncated)\n");
                return;
            }
        }
        if (names.len > max_per_dir)
            try w.print("… (+{d} more top-level entries)\n", .{names.len - max_per_dir});
    }
};

/// The layout section, or false when there is nothing to say — an empty
/// directory gets no heading rather than a heading over nothing.
pub fn render(alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, repo: git.Repo) !bool {
    var tree: Tree = .{ .alloc = alloc };

    if (repo.within() != null) {
        // Tracked plus untracked-but-not-ignored, which is exactly "the files
        // somebody working here would see". Paths come back relative to this
        // directory, which is what a map of this directory wants.
        const listing = git.ask(alloc, io, &.{
            "ls-files", "--cached", "--others", "--exclude-standard",
        }) orelse "";
        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            const path = std.mem.trim(u8, line, " \t\r");
            if (path.len != 0) try tree.addPath(path);
        }
    } else {
        try readTwoLevels(alloc, io, &tree);
    }

    if (tree.tops.count() == 0) return false;
    // The heading only claims gitignore when git actually drew the list. The
    // stand-in below skips what a checkout usually ignores, but it is guessing,
    // and a map that overstates how it was made is worse than one that does not
    // say.
    try w.writeAll(if (repo.within() != null)
        "# Project layout (2 levels, gitignore-aware)\n\n"
    else
        "# Project layout (2 levels)\n\n");
    try tree.write(w);
    return true;
}

/// The stand-in for `git ls-files` outside a working tree. Hidden entries are
/// skipped the way tcode's walker skips them, and `uninformative` covers what
/// `.gitignore` would have covered had there been one.
fn readTwoLevels(alloc: std.mem.Allocator, io: std.Io, tree: *Tree) !void {
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (skip(entry.name)) continue;
        const name = try alloc.dupe(u8, entry.name);
        if (entry.kind != .directory) {
            _ = try tree.top(name);
            continue;
        }
        const children = try tree.top(try dirName(alloc, name));
        var sub = dir.openDir(io, name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (try sub_it.next(io)) |child| {
            if (skip(child.name)) continue;
            const kid = try alloc.dupe(u8, child.name);
            try children.put(alloc, if (child.kind == .directory) try dirName(alloc, kid) else kid, {});
        }
    }
}

fn skip(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    for (uninformative) |bad| if (std.mem.eql(u8, name, bad)) return true;
    return false;
}

fn dirName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/", .{name});
}

const Split = struct { head: []const u8, rest: []const u8 };

fn split(path: []const u8) Split {
    const at = std.mem.indexOfScalar(u8, path, '/') orelse return .{ .head = path, .rest = "" };
    return .{ .head = path[0..at], .rest = path[at + 1 ..] };
}

fn sortedKeys(alloc: std.mem.Allocator, keys: []const []const u8) ![][]const u8 {
    const copy = try alloc.dupe([]const u8, keys);
    std.mem.sort([]const u8, copy, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return copy;
}

test "a path deeper than two levels folds into the directory it lives in" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tree: Tree = .{ .alloc = arena.allocator() };

    try tree.addPath("src/cli/session/step.zig");
    try tree.addPath("src/main.zig");
    try tree.addPath("build.zig");

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try tree.write(&out.writer);

    // Two top-level entries, and the third level is represented by `cli/`
    // rather than by any of the files under it.
    try std.testing.expectEqualStrings("build.zig\nsrc/\n  cli/\n  main.zig\n", out.writer.buffered());
}

test "the overall cap is a cap: no directory carries the count past it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tree: Tree = .{ .alloc = alloc };

    // Enough top-level directories, each full, that the count reaches the
    // ceiling in the middle of one of them.
    for (0..max_per_dir) |d| {
        for (0..max_per_dir) |f| {
            try tree.addPath(try std.fmt.allocPrint(alloc, "d{d:0>2}/f{d:0>2}.txt", .{ d, f }));
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    try tree.write(&out.writer);

    // Every line is one entry except the marker lines this counts by hand, so
    // the assertion is on the thing the constant claims: it is an upper bound.
    var entries: usize = 0;
    var lines = std.mem.splitScalar(u8, out.writer.buffered(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "…") != null) continue;
        entries += 1;
    }
    try std.testing.expect(entries <= max_entries);
}

test "one crowded directory cannot spend the whole budget" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tree: Tree = .{ .alloc = alloc };

    for (0..max_per_dir * 3) |i|
        try tree.addPath(try std.fmt.allocPrint(alloc, "fixtures/f{d}.txt", .{i}));
    try tree.addPath("README.md");

    var out: std.Io.Writer.Allocating = .init(alloc);
    try tree.write(&out.writer);
    const text = out.writer.buffered();

    // The sibling still appears, and the overflow says how much was left out.
    try std.testing.expect(std.mem.indexOf(u8, text, "README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "more)") != null);
}
