//! Vendored from https://github.com/piranha/zeegrep — `src/core/ignore.zig` (master, fetched
//! 2026-08-18). MIT License, Copyright (c) 2026 Oleksandr Solovyov.
//!
//! gitignore semantics for a directory walk: `.gitignore` / `.rgignore` / `.ignore` per
//! directory, negation (`!`), directory-only (`foo/`), anchored (`/foo`), patterns with a
//! slash relative to their own file, outermost rules applied first, last match wins.
//!
//! Changes from the original, for `std`'s `grep` / `glob` (nulya `extensions/std`):
//!   - Zig 0.16: `std.fs.Dir` → `std.Io.Dir` (+ an `io` parameter), `std.ArrayListUnmanaged`
//!     → `std.ArrayList(T) = .empty`;
//!   - single-threaded: the mutex is gone (the walk is one thread; nodes stay immutable), and
//!     `Set` takes a plain allocator — the caller's per-call arena — instead of owning one;
//!   - separators: relative paths and patterns are `/`-separated on every platform (the
//!     original used `std.fs.path.sep`, so a `.gitignore` written with `/` — every one of
//!     them — matched nothing on Windows); `Rule.target`, `has_slash` and `matchPat` all say `/`;
//!   - no `defaultSkip` (VCS directories) and no hidden-file rule: `std` searches dotfiles
//!     and prunes VCS / build / cache directories by a fixed table in `walk.zig`, so
//!     `Node.ignored` takes only (rel_path, is_dir). The walker prunes an ignored directory
//!     instead of descending, which is what makes "an ignored parent hides everything below,
//!     negation cannot bring it back" hold — the same as git;
//!   - `Set.pushText` parses ignore-file bytes directly (unit tests without a filesystem; the
//!     file-reading `push` is a thin layer over it).

const std = @import("std");
const glob = @import("globpat.zig");

/// Per-directory ignore files, in load order.
pub const names = [_][]const u8{ ".gitignore", ".rgignore", ".ignore" };
pub const Found = [names.len]bool;
pub const all_found: Found = .{true} ** names.len;
pub const none_found: Found = .{false} ** names.len;

/// Index into `names` if `name` is an ignore file.
pub fn nameIndex(name: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) return i;
    }
    return null;
}

/// One directory's ignore rules, linked to the enclosing directory's node.
/// Immutable once built; a walker only carries the leaf pointer.
pub const Node = struct {
    parent: ?*const Node,
    /// `/`-separated path of the directory holding these rules, relative to
    /// the walk's ignore root ("" for the root itself).
    base: []const u8,
    rules: []const Rule,

    /// Is `rel_path` (relative to the ignore root, `/`-separated) excluded by
    /// this node and its ancestors?
    pub fn ignored(node: ?*const Node, rel_path: []const u8, is_dir: bool) bool {
        return apply(node, rel_path, is_dir);
    }

    /// Outermost rules first, last match wins (gitignore precedence). Recursion
    /// depth is the number of ancestors that actually have ignore files.
    fn apply(node: ?*const Node, rel_path: []const u8, is_dir: bool) bool {
        const n = node orelse return false;
        var ignored_ = apply(n.parent, rel_path, is_dir);
        for (n.rules) |r| {
            if (r.dir_only and !is_dir) continue;
            const target = r.target(rel_path, n.base) orelse continue;
            if (!matchPat(r.pat, r.kind, target, r.anchored or r.has_slash)) continue;
            ignored_ = !r.neg;
        }
        return ignored_;
    }
};

/// Owns every Node for one walk. Nodes are never freed individually: only
/// directories that actually contain rules allocate one.
pub const Set = struct {
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Set {
        return .{ .alloc = alloc };
    }

    /// Returns the node covering `dir`, or `parent` when `dir` adds no rules.
    /// `found` tells which ignore files the caller saw in the directory
    /// listing, so we don't pay an open per missing one.
    pub fn push(self: *Set, io: std.Io, parent: ?*const Node, dir: std.Io.Dir, base_rel: []const u8, found: Found) !?*const Node {
        var any = false;
        for (found) |f| any = any or f;
        if (!any) return parent;

        var rules: std.ArrayList(Rule) = .empty;
        for (names, found) |name, present| {
            if (!present) continue;
            const data = dir.readFileAlloc(io, name, self.alloc, .limited(1 << 20)) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            try parseInto(self.alloc, &rules, data);
        }
        return self.link(parent, base_rel, rules);
    }

    /// Like `push`, from ignore-file bytes already in hand.
    pub fn pushText(self: *Set, parent: ?*const Node, base_rel: []const u8, text: []const u8) !?*const Node {
        var rules: std.ArrayList(Rule) = .empty;
        try parseInto(self.alloc, &rules, text);
        return self.link(parent, base_rel, rules);
    }

    fn link(self: *Set, parent: ?*const Node, base_rel: []const u8, rules: std.ArrayList(Rule)) !?*const Node {
        var owned = rules;
        if (owned.items.len == 0) return parent;
        const node = try self.alloc.create(Node);
        node.* = .{
            .parent = parent,
            .base = try self.alloc.dupe(u8, base_rel),
            .rules = try owned.toOwnedSlice(self.alloc),
        };
        return node;
    }
};

fn parseInto(alloc: std.mem.Allocator, rules: *std.ArrayList(Rule), data: []const u8) !void {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '\\' and line.len >= 2 and (line[1] == '#' or line[1] == '!')) {
            line = line[1..];
        } else if (line[0] == '#') continue;

        var neg = false;
        if (line[0] == '!') {
            neg = true;
            line = line[1..];
            if (line.len == 0) continue;
        }

        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = line[1..];
            if (line.len == 0) continue;
        }

        var dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
            if (line.len == 0) continue;
        }

        try rules.append(alloc, .{
            .pat = try alloc.dupe(u8, line),
            .neg = neg,
            .dir_only = dir_only,
            .anchored = anchored,
            .has_slash = std.mem.indexOfScalar(u8, line, '/') != null,
            .kind = glob.classify(line),
        });
    }
}

const Rule = struct {
    pat: []const u8,
    neg: bool,
    dir_only: bool,
    anchored: bool,
    has_slash: bool,
    kind: glob.PatKind,

    /// `rel_path` relative to the directory this rule's file lives in, or null
    /// when the path is not under it.
    fn target(self: Rule, rel_path: []const u8, base: []const u8) ?[]const u8 {
        _ = self;
        if (base.len == 0) return if (std.mem.startsWith(u8, rel_path, "./")) rel_path[2..] else rel_path;
        if (std.mem.eql(u8, rel_path, base)) return "";
        if (rel_path.len <= base.len + 1) return null;
        if (!std.mem.startsWith(u8, rel_path, base)) return null;
        if (rel_path[base.len] != '/') return null;
        return rel_path[base.len + 1 ..];
    }
};

fn matchPat(pat: []const u8, kind: glob.PatKind, target: []const u8, full_path: bool) bool {
    if (!full_path and std.mem.indexOfScalar(u8, pat, '/') == null) {
        const base = glob.basename(target);
        return glob.fastMatch(kind, pat, base);
    }
    return glob.fastMatch(kind, pat, target);
}

test {
    std.testing.refAllDecls(@This());
}

test "chain honors per-dir ignore" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set = Set.init(arena.allocator());

    const root = try set.pushText(null, "", "*.log\n");
    try std.testing.expect(Node.ignored(root, "x.log", false));
    try std.testing.expect(Node.ignored(root, "a/x.log", false));
    try std.testing.expect(!Node.ignored(root, "a/x.txt", false));

    const node_a = try set.pushText(root, "a", "!keep.log\n");
    try std.testing.expect(!Node.ignored(node_a, "a/keep.log", false));
    try std.testing.expect(Node.ignored(node_a, "a/nope.log", false));
    // The inner negation does not reach outside its own directory.
    try std.testing.expect(Node.ignored(node_a, "keep.log", false));

    // A dir without rules must not allocate a node.
    try std.testing.expectEqual(node_a, try set.pushText(node_a, "a/b", "# only a comment\n\n"));
}

test "negation, dir-only, anchored and slash-bearing patterns" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set = Set.init(arena.allocator());

    const root = try set.pushText(null, "",
        \\# build output
        \\build/
        \\/top.txt
        \\doc/frozen
        \\*.tmp
        \\!important.tmp
        \\logs/**
        \\**/generated
        \\\#literal
        \\
    );
    // `build/` is directory-only: a file named build survives, the dir does not, anywhere.
    try std.testing.expect(Node.ignored(root, "build", true));
    try std.testing.expect(Node.ignored(root, "src/build", true));
    try std.testing.expect(!Node.ignored(root, "build", false));
    // `/top.txt` is anchored to the root.
    try std.testing.expect(Node.ignored(root, "top.txt", false));
    try std.testing.expect(!Node.ignored(root, "sub/top.txt", false));
    // A slash in the middle anchors the pattern to the ignore file's directory.
    try std.testing.expect(Node.ignored(root, "doc/frozen", false));
    try std.testing.expect(Node.ignored(root, "doc/frozen", true));
    try std.testing.expect(!Node.ignored(root, "x/doc/frozen", false));
    // Last match wins: `!important.tmp` re-includes one name.
    try std.testing.expect(Node.ignored(root, "a.tmp", false));
    try std.testing.expect(!Node.ignored(root, "important.tmp", false));
    try std.testing.expect(!Node.ignored(root, "deep/important.tmp", false));
    // `logs/**` matches everything under logs; `**/generated` at any depth.
    try std.testing.expect(Node.ignored(root, "logs/today.txt", false));
    try std.testing.expect(!Node.ignored(root, "logs", true));
    try std.testing.expect(Node.ignored(root, "generated", true));
    try std.testing.expect(Node.ignored(root, "a/b/generated", false));
    // `\#literal` is the name `#literal`, not a comment.
    try std.testing.expect(Node.ignored(root, "#literal", false));
}

test "nesting: inner files override outer ones, outer rules still apply below" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set = Set.init(arena.allocator());

    const root = try set.pushText(null, "", "*.log\nsecret/\n");
    const sub = try set.pushText(root, "sub", "!debug.log\n*.bak\n");
    const deep = try set.pushText(sub, "sub/deep", "debug.log\n");

    try std.testing.expect(Node.ignored(sub, "sub/x.log", false));
    try std.testing.expect(!Node.ignored(sub, "sub/debug.log", false));
    try std.testing.expect(Node.ignored(sub, "sub/x.bak", false));
    try std.testing.expect(!Node.ignored(root, "x.bak", false));
    try std.testing.expect(Node.ignored(sub, "sub/secret", true));
    // The deepest file has the final word for its own subtree only.
    try std.testing.expect(Node.ignored(deep, "sub/deep/debug.log", false));
    try std.testing.expect(!Node.ignored(sub, "sub/other/debug.log", false));
}

test "push reads the ignore files a directory listing said were there" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ignore", .data = "!keep.log\nnotes.txt\n" });

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var set = Set.init(arena.allocator());
    const node = try set.push(io, null, tmp.dir, "", all_found);
    try std.testing.expect(Node.ignored(node, "x.log", false));
    try std.testing.expect(!Node.ignored(node, "keep.log", false));
    try std.testing.expect(Node.ignored(node, "notes.txt", false));
    // Nothing found → the parent comes back, no file is opened.
    try std.testing.expectEqual(node, try set.push(io, node, tmp.dir, "", none_found));
    try std.testing.expectEqual(@as(?usize, 0), nameIndex(".gitignore"));
    try std.testing.expectEqual(@as(?usize, null), nameIndex("README"));
}
