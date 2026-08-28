//! The directory walk under `grep` and `glob`: one thread, gitignore-aware,
//! a fixed prune table, a wall-clock deadline, and a callback per regular file.
//!
//! Ported from tcode search.rs (`walk_builder`, `PRUNE_DIRS`, `PruneReport`,
//! `path_arg_allows_pruned_descend`, `SEARCH_DEADLINE`), where the walk itself
//! was the `ignore` crate's parallel walker with `.hidden(false)`. Here it is a
//! recursive `std.Io.Dir` iteration, entries in byte order — so a partial
//! result under the deadline is deterministic — with `vendor/ignore.zig` for
//! the gitignore rules and `vendor/globpat.zig` beneath that.
//!
//! What is skipped, in the order it is decided for each entry:
//!   1. the deadline: past it, the walk stops where it is and the report says so;
//!   2. an entry excluded by `.gitignore` / `.rgignore` / `.ignore` (its own
//!      directory's files and every ancestor's, outermost first, last match wins;
//!      an ignored directory is never entered, so nothing below it can come back);
//!   3. a directory named in `prune_dirs` (VCS metadata, build outputs, caches),
//!      unless the caller's `path` argument pointed inside one — counted for
//!      the "[N pruned directories were skipped …]" note;
//!   4. a symlink: a directory symlink is skipped and counted unless
//!      `follow_symlinks` (then entered once — a loop guard remembers the real
//!      paths it has entered through links); a file symlink is followed only
//!      under `follow_symlinks`; a dangling one is skipped silently.
//! Dotfiles and dot-directories are searched (`.github/`, `.config/`): only the
//! prune table and ignore files decide.
//!
//! The tail of the file holds what both search tools need to SHOW a walked
//! path (`relDisplay` / `display`, tcode's `rel_display`) and to hand any text
//! to the model as valid UTF-8 (`lossyUtf8` / `sanitize`).

const std = @import("std");
const rpc = @import("rpc.zig");
const ignore = @import("vendor/ignore.zig");

/// Directories never descended into, regardless of .gitignore. The safety net
/// for searches pointed OUTSIDE a git repo (a home directory), where gitignore
/// pruning does not apply and the walk would otherwise dive into VCS metadata
/// and caches with hundreds of thousands of files. (tcode search.rs PRUNE_DIRS)
pub const prune_dirs = [_][]const u8{
    // version control
    ".git",
    ".svn",
    ".hg",
    ".bzr",
    ".jj",
    ".sl",
    // build outputs
    "node_modules",
    "target",
    "dist",
    "build",
    "zig-cache",
    "zig-out",
    ".zig-cache",
    // language / tool caches
    ".venv",
    "venv",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".tox",
    ".nox",
    ".cargo",
    ".rustup",
    ".cache",
    ".npm",
    ".pnpm-store",
    ".yarn",
    ".gradle",
    ".m2",
    ".next",
    ".nuxt",
    ".svelte-kit",
    ".turbo",
    ".parcel-cache",
    // OS
    "AppData",
};

/// Wall-clock ceiling for one search: past it the walk returns a
/// clearly-marked partial result instead of hanging. (tcode SEARCH_DEADLINE)
pub const deadline_seconds: u64 = 10;
pub const deadline_ms: u64 = deadline_seconds * 1000;

pub fn isPrunedDirName(name: []const u8) bool {
    return pruneIndex(name) != null;
}

fn pruneIndex(name: []const u8) ?usize {
    for (prune_dirs, 0..) |d, i| {
        if (std.mem.eql(u8, d, name)) return i;
    }
    return null;
}

/// Does a `path` argument point INSIDE a pruned directory? Then the caller
/// asked for it and the walk may descend into pruned names. `node_modules`
/// alone is not enough — a package under it is. (tcode
/// path_arg_allows_pruned_descend)
pub fn pathArgAllowsPrunedDescend(path: ?[]const u8) bool {
    const p = path orelse return false;
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitAny(u8, p, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (n == parts.len) break;
        parts[n] = part;
        n += 1;
    }
    var pruned_index: ?usize = null;
    for (parts[0..n], 0..) |part, i| {
        if (isPrunedDirName(part)) {
            pruned_index = i;
            break;
        }
    }
    const i = pruned_index orelse return false;
    return !std.mem.eql(u8, parts[i], "node_modules") or i + 1 < n;
}

/// How many times each pruned name was skipped, and the note that says so.
/// (tcode PruneReport)
pub const PruneReport = struct {
    counts: [prune_dirs.len]usize = @splat(0),

    pub fn record(self: *PruneReport, name: []const u8) void {
        if (pruneIndex(name)) |i| self.counts[i] += 1;
    }

    pub fn total(self: *const PruneReport) usize {
        var sum: usize = 0;
        for (self.counts) |c| sum += c;
        return sum;
    }

    /// `[N pruned directories were skipped: a/ × 2, b/ — set `path` inside one
    /// explicitly to search it]`, names in byte order; null when nothing was
    /// pruned. Owned by `alloc`.
    pub fn note(self: *const PruneReport, alloc: std.mem.Allocator) !?[]const u8 {
        const sum = self.total();
        if (sum == 0) return null;
        // Byte order over the names, as tcode's BTreeMap gave.
        var order: [prune_dirs.len]usize = undefined;
        for (&order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, &order, {}, struct {
            fn lt(_: void, a: usize, b: usize) bool {
                return std.mem.lessThan(u8, prune_dirs[a], prune_dirs[b]);
            }
        }.lt);
        var out: std.Io.Writer.Allocating = .init(alloc);
        const noun = if (sum == 1) "directory was" else "directories were";
        try out.writer.print("[{d} pruned {s} skipped: ", .{ sum, noun });
        var first = true;
        for (order) |i| {
            const c = self.counts[i];
            if (c == 0) continue;
            if (!first) try out.writer.writeAll(", ");
            first = false;
            if (c == 1) {
                try out.writer.print("{s}/", .{prune_dirs[i]});
            } else {
                try out.writer.print("{s}/ × {d}", .{ prune_dirs[i], c });
            }
        }
        try out.writer.writeAll(" — set `path` inside one explicitly to search it]");
        return try out.toOwnedSlice();
    }
};

pub const Options = struct {
    follow_symlinks: bool = false,
    allow_pruned_descend: bool = false,
    deadline_ms: u64 = deadline_ms,
};

/// One regular file the walk reached.
pub const Entry = struct {
    /// `/`-separated path relative to the walk base, on every platform.
    rel: []const u8,
    name: []const u8,
    /// The directory holding it, open for the duration of the callback.
    dir: std.Io.Dir,
};

pub const Report = struct {
    pruned: PruneReport = .{},
    timed_out: bool = false,
    skipped_directory_links: usize = 0,
};

/// Walk the directory at `base_abs`, calling `visitor.visit(Entry)` for every
/// regular file that survives the rules above. `visitor` is a pointer to any
/// struct with `pub fn visit(self, Entry) anyerror!void`. Everything the walk
/// allocates (entry names, ignore rules) comes from `alloc` and is not freed
/// individually — a per-call arena is expected.
pub fn walk(alloc: std.mem.Allocator, io: std.Io, base_abs: []const u8, options: Options, visitor: anytype) !Report {
    var w: Walker(@TypeOf(visitor)) = .{
        .alloc = alloc,
        .io = io,
        .options = options,
        .visitor = visitor,
        .started = .now(io, .awake),
        .ignores = .init(alloc),
    };
    var base = try std.Io.Dir.openDirAbsolute(io, base_abs, .{ .iterate = true });
    defer base.close(io);
    const above = try w.loadAncestors(base_abs);
    w.descend(base, "", above.prefix, above.node) catch |err| switch (err) {
        error.WalkTimedOut => w.report.timed_out = true,
        else => return err,
    };
    return w.report;
}

fn Walker(comptime V: type) type {
    return struct {
        alloc: std.mem.Allocator,
        io: std.Io,
        options: Options,
        visitor: V,
        report: Report = .{},
        started: std.Io.Timestamp,
        ignores: ignore.Set,
        /// Real paths of directories entered through a symlink, so a link
        /// cycle is walked once.
        visited_links: std.ArrayList([]const u8) = .empty,

        const Self = @This();
        const Item = struct { name: []const u8, kind: std.Io.File.Kind };
        const Above = struct { node: ?*const ignore.Node, prefix: []const u8 };

        /// gitignore rules are meaningful inside a repository, so the walk
        /// looks upward from base for the nearest directory holding `.git` (a
        /// directory, or a file for worktrees) and loads the ignore files of
        /// every directory from there down to base's parent, outermost first.
        /// Without a `.git` above, only base and below count. Returns the leaf
        /// node and base's `/`-separated path relative to that root ("" when
        /// base is the root or nothing was found).
        fn loadAncestors(self: *Self, base_abs: []const u8) !Above {
            const none: Above = .{ .node = null, .prefix = "" };
            if (self.hasGit(base_abs)) return none;
            var chain: std.ArrayList([]const u8) = .empty;
            var cur = base_abs;
            var root: ?usize = null;
            while (std.fs.path.dirname(cur)) |parent| : (cur = parent) {
                try chain.append(self.alloc, parent);
                if (self.hasGit(parent)) {
                    root = chain.items.len - 1;
                    break;
                }
            }
            const r = root orelse return none;
            const root_abs = chain.items[r];
            var node: ?*const ignore.Node = null;
            var i = r + 1;
            while (i > 0) {
                i -= 1;
                const dir_abs = chain.items[i];
                var dir = std.Io.Dir.openDirAbsolute(self.io, dir_abs, .{}) catch continue;
                defer dir.close(self.io);
                node = try self.ignores.push(self.io, node, dir, try relSlashed(self.alloc, root_abs, dir_abs), ignore.all_found);
            }
            return .{ .node = node, .prefix = try relSlashed(self.alloc, root_abs, base_abs) };
        }

        fn hasGit(self: *Self, dir_abs: []const u8) bool {
            const marker = std.fs.path.join(self.alloc, &.{ dir_abs, ".git" }) catch return false;
            std.Io.Dir.accessAbsolute(self.io, marker, .{}) catch return false;
            return true;
        }

        fn checkDeadline(self: *Self) !void {
            const ms = self.started.durationTo(.now(self.io, .awake)).toMilliseconds();
            if (ms > 0 and @as(u64, @intCast(ms)) > self.options.deadline_ms) return error.WalkTimedOut;
        }

        fn descend(self: *Self, dir: std.Io.Dir, rel: []const u8, ig_rel: []const u8, parent_node: ?*const ignore.Node) anyerror!void {
            // Names are invalidated by the next `next`, and the ignore files
            // must be known before any sibling is judged: list first.
            var items: std.ArrayList(Item) = .empty;
            var found: ignore.Found = ignore.none_found;
            var it = dir.iterate();
            while (try it.next(self.io)) |e| {
                if (ignore.nameIndex(e.name)) |i| found[i] = true;
                try items.append(self.alloc, .{ .name = try self.alloc.dupe(u8, e.name), .kind = e.kind });
            }
            std.mem.sort(Item, items.items, {}, struct {
                fn lt(_: void, a: Item, b: Item) bool {
                    return std.mem.lessThan(u8, a.name, b.name);
                }
            }.lt);
            const node = try self.ignores.push(self.io, parent_node, dir, ig_rel, found);

            for (items.items) |item| {
                try self.checkDeadline();
                var kind = item.kind;
                if (kind == .sym_link) kind = self.resolveLink(dir, item.name) orelse continue;
                switch (kind) {
                    .directory => {
                        const child_ig = try join(self.alloc, ig_rel, item.name);
                        if (ignore.Node.ignored(node, child_ig, true)) continue;
                        if (!self.options.allow_pruned_descend and isPrunedDirName(item.name)) {
                            self.report.pruned.record(item.name);
                            continue;
                        }
                        var child = dir.openDir(self.io, item.name, .{ .iterate = true }) catch continue;
                        defer child.close(self.io);
                        try self.descend(child, try join(self.alloc, rel, item.name), child_ig, node);
                    },
                    .file => {
                        if (ignore.Node.ignored(node, try join(self.alloc, ig_rel, item.name), false)) continue;
                        try self.visitor.visit(.{ .rel = try join(self.alloc, rel, item.name), .name = item.name, .dir = dir });
                    },
                    else => {},
                }
            }
        }

        /// What a `.sym_link` entry stands for, or null to skip it. Windows
        /// reports every reparse point as a symlink; one `readLink` cannot
        /// read (a cloud placeholder, say) is treated as the plain entry it
        /// resolves to.
        fn resolveLink(self: *Self, dir: std.Io.Dir, name: []const u8) ?std.Io.File.Kind {
            const st = dir.statFile(self.io, name, .{ .follow_symlinks = true }) catch return null;
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const is_link = if (dir.readLink(self.io, name, &link_buf)) |_| true else |err| switch (err) {
                error.NotLink, error.UnsupportedReparsePointType => false,
                else => return null,
            };
            if (!is_link) return st.kind;
            switch (st.kind) {
                .directory => {
                    if (!self.options.follow_symlinks) {
                        self.report.skipped_directory_links += 1;
                        return null;
                    }
                    const real = dir.realPathFileAlloc(self.io, name, self.alloc) catch return null;
                    for (self.visited_links.items) |seen| {
                        if (std.mem.eql(u8, seen, real)) return null;
                    }
                    self.visited_links.append(self.alloc, real) catch return null;
                    return .directory;
                },
                .file => return if (self.options.follow_symlinks) .file else null,
                else => return null,
            }
        }
    };
}

fn join(alloc: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return name;
    return std.mem.concat(alloc, u8, &.{ prefix, "/", name });
}

// ---------------------------------------------------------------- display

/// `path` as the model should see it: relative to `cwd` when under it, ""
/// for cwd itself, otherwise the path unchanged. (tcode `rel_display`; kept
/// here — `text.zig` belongs to the fs half.)
pub fn relDisplay(alloc: std.mem.Allocator, path: []const u8, cwd: []const u8) ![]const u8 {
    var root = cwd;
    while (root.len > 0 and (root[root.len - 1] == '/' or root[root.len - 1] == '\\')) root = root[0 .. root.len - 1];
    if (std.mem.eql(u8, path, root) or std.mem.eql(u8, path, cwd)) return "";
    if (path.len > root.len and std.mem.startsWith(u8, path, root) and (path[root.len] == '/' or path[root.len] == '\\')) {
        return alloc.dupe(u8, path[root.len + 1 ..]);
    }
    return alloc.dupe(u8, path);
}

/// A walked file as the model should see it: `<base display><sep><rel>` with
/// the platform's separator throughout — the same string `rel_display(path,
/// cwd)` gives for `base/rel` in tcode. `base_display` is `relDisplay(base, cwd)`.
pub fn display(alloc: std.mem.Allocator, base_display: []const u8, rel: []const u8) ![]const u8 {
    const native = try alloc.dupe(u8, rel);
    if (std.fs.path.sep != '/') {
        for (native) |*c| {
            if (c.* == '/') c.* = std.fs.path.sep;
        }
    }
    if (base_display.len == 0) return native;
    return std.mem.concat(alloc, u8, &.{ base_display, std.fs.path.sep_str, native });
}

/// Walk up from `path` (which need not exist, and neither need any of its
/// ancestors) to the nearest one that IS an existing directory. A filesystem
/// root always exists, so this terminates. Used when a search `path` names
/// something absent: the answer can then point at real ground — "here is
/// what actually exists" — instead of just saying no. (docs/goals/std.md,
/// the "existence answers" note: no tcode equivalent, since tcode always
/// searched a workspace root that existed by construction.)
pub fn nearestExistingAncestor(io: std.Io, path: []const u8) []const u8 {
    var candidate = path;
    while (true) {
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |st| {
            if (st.kind == .directory) return candidate;
        } else |_| {}
        const parent = std.fs.path.dirname(candidate) orelse return candidate;
        if (std.mem.eql(u8, parent, candidate)) return candidate;
        candidate = parent;
    }
}

/// `s` with every invalid UTF-8 sequence replaced by U+FFFD; `s` itself when it
/// is already valid. A tool's text answer must be valid UTF-8 — the JSON encoder
/// would otherwise emit a byte array instead of a string — and a searched file
/// (Latin-1, a stray byte, a truncated multibyte char under the line cap) or a
/// path need not be.
pub fn lossyUtf8(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.Io.Writer.Allocating = .init(alloc);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try out.writer.writeAll(s[i .. i + n]);
            i += n;
        } else {
            try out.writer.writeAll("\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

/// Every string a tool answers with, made valid UTF-8 (see `lossyUtf8`).
pub fn sanitize(alloc: std.mem.Allocator, outcome: rpc.Outcome) !rpc.Outcome {
    return switch (outcome) {
        .text => |t| .{ .text = try lossyUtf8(alloc, t) },
        .failed => |message| .{ .failed = try lossyUtf8(alloc, message) },
    };
}

/// `path` relative to `root` (an ancestor or itself), `/`-separated; "" when equal.
fn relSlashed(alloc: std.mem.Allocator, root: []const u8, path: []const u8) ![]const u8 {
    var rel = path[root.len..];
    while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
    const out = try alloc.dupe(u8, rel);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

test {
    std.testing.refAllDecls(@This());
}

test "path_arg_allows_pruned_descend: inside a pruned dir yes, node_modules itself no" {
    try std.testing.expect(!pathArgAllowsPrunedDescend(null));
    try std.testing.expect(!pathArgAllowsPrunedDescend("src"));
    try std.testing.expect(!pathArgAllowsPrunedDescend("."));
    try std.testing.expect(pathArgAllowsPrunedDescend("target"));
    try std.testing.expect(pathArgAllowsPrunedDescend("./dist"));
    try std.testing.expect(pathArgAllowsPrunedDescend("dist/index.js"));
    try std.testing.expect(!pathArgAllowsPrunedDescend("node_modules"));
    try std.testing.expect(!pathArgAllowsPrunedDescend("./node_modules/"));
    try std.testing.expect(pathArgAllowsPrunedDescend("node_modules/@codemirror/lang-markdown"));
    try std.testing.expect(pathArgAllowsPrunedDescend("a\\node_modules\\pkg"));
    try std.testing.expect(pathArgAllowsPrunedDescend("C:\\repo\\.git\\hooks"));
}

test "relDisplay strips cwd and keeps outsiders absolute; display joins with the native separator" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("", try relDisplay(alloc, "/w/repo", "/w/repo"));
    try std.testing.expectEqualStrings("src/a.zig", try relDisplay(alloc, "/w/repo/src/a.zig", "/w/repo"));
    try std.testing.expectEqualStrings("src\\a.zig", try relDisplay(alloc, "C:\\w\\repo\\src\\a.zig", "C:\\w\\repo"));
    try std.testing.expectEqualStrings("/w/other/x", try relDisplay(alloc, "/w/other/x", "/w/repo"));
    try std.testing.expectEqualStrings("/w/repository", try relDisplay(alloc, "/w/repository", "/w/repo"));
    try std.testing.expectEqualStrings("a", try relDisplay(alloc, "/w/repo/a", "/w/repo/"));

    const sep = std.fs.path.sep_str;
    try std.testing.expectEqualStrings("a" ++ sep ++ "b.zig", try display(alloc, "", "a/b.zig"));
    try std.testing.expectEqualStrings("src" ++ sep ++ "a" ++ sep ++ "b.zig", try display(alloc, "src", "a/b.zig"));
}

test "nearestExistingAncestor climbs past absent and non-directory ancestors to the nearest real directory" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/file.txt", .data = "" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    // One missing level under a real directory: that directory itself.
    const one = try std.fs.path.join(alloc, &.{ root, "a", "b", "missing" });
    try std.testing.expectEqualStrings(try std.fs.path.join(alloc, &.{ root, "a", "b" }), nearestExistingAncestor(io, one));

    // Several missing levels: climbs all the way to the real ancestor, not
    // just the immediate parent.
    const deep = try std.fs.path.join(alloc, &.{ root, "a", "x", "y", "z" });
    try std.testing.expectEqualStrings(try std.fs.path.join(alloc, &.{ root, "a" }), nearestExistingAncestor(io, deep));

    // A path component that exists but is a FILE, not a directory, is skipped
    // like an absent one.
    const through_file = try std.fs.path.join(alloc, &.{ root, "a", "file.txt", "sub" });
    try std.testing.expectEqualStrings(try std.fs.path.join(alloc, &.{ root, "a" }), nearestExistingAncestor(io, through_file));

    // A path that already exists (as a directory) answers itself.
    try std.testing.expectEqualStrings(root, nearestExistingAncestor(io, root));
}

test "lossyUtf8 keeps valid text as is and replaces every bad sequence with U+FFFD" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const fine = "plain ünïcödé — ok";
    try std.testing.expect((try lossyUtf8(alloc, fine)).ptr == fine.ptr);
    // A Latin-1 byte, a truncated 3-byte sequence, a lone continuation byte.
    const bad = "caf\xe9 \xe2\x82 x\x80y";
    const fixed = try lossyUtf8(alloc, bad);
    try std.testing.expectEqualStrings("caf\u{FFFD} \u{FFFD}\u{FFFD} x\u{FFFD}y", fixed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(fixed));
    const s = try sanitize(alloc, .{ .failed = "path \xff" });
    try std.testing.expectEqualStrings("path \u{FFFD}", s.failed);
}

test "PruneReport: counts by name, note in byte order with × for repeats" {
    const alloc = std.testing.allocator;
    var report: PruneReport = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), try report.note(alloc));
    report.record("dist");
    const one = (try report.note(alloc)).?;
    defer alloc.free(one);
    try std.testing.expectEqualStrings("[1 pruned directory was skipped: dist/ — set `path` inside one explicitly to search it]", one);
    report.record("node_modules");
    report.record(".git");
    report.record("dist");
    report.record("not-in-the-table");
    const many = (try report.note(alloc)).?;
    defer alloc.free(many);
    try std.testing.expectEqualStrings("[4 pruned directories were skipped: .git/, dist/ × 2, node_modules/ — set `path` inside one explicitly to search it]", many);
}

const Collector = struct {
    alloc: std.mem.Allocator,
    seen: std.ArrayList([]const u8) = .empty,

    pub fn visit(self: *Collector, entry: Entry) anyerror!void {
        try self.seen.append(self.alloc, try self.alloc.dupe(u8, entry.rel));
    }

    fn has(self: *const Collector, rel: []const u8) bool {
        for (self.seen.items) |s| {
            if (std.mem.eql(u8, s, rel)) return true;
        }
        return false;
    }
};

test "walk: prune table counted, gitignore honored, dotfiles searched, an explicit pruned path descends" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.createDirPath(io, "src");
    try ws.createDirPath(io, ".git/objects");
    try ws.createDirPath(io, "node_modules/pkg/dist");
    try ws.createDirPath(io, "zig-out/bin");
    try ws.createDirPath(io, ".hidden");
    try ws.createDirPath(io, "logs");
    try ws.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\nlogs/\n" });
    try ws.writeFile(io, .{ .sub_path = "src/a.txt", .data = "a\n" });
    try ws.writeFile(io, .{ .sub_path = "src/b.log", .data = "b\n" });
    try ws.writeFile(io, .{ .sub_path = "logs/c.txt", .data = "c\n" });
    try ws.writeFile(io, .{ .sub_path = ".hidden/d.txt", .data = "d\n" });
    try ws.writeFile(io, .{ .sub_path = ".git/objects/e", .data = "e\n" });
    try ws.writeFile(io, .{ .sub_path = "node_modules/pkg/dist/f.js", .data = "f\n" });
    try ws.writeFile(io, .{ .sub_path = "zig-out/bin/g", .data = "g\n" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try ws.realPath(io, &buf)];

    var c: Collector = .{ .alloc = alloc };
    const report = try walk(alloc, io, base, .{}, &c);
    try std.testing.expect(!report.timed_out);
    try std.testing.expectEqual(@as(usize, 0), report.skipped_directory_links);
    try std.testing.expect(c.has(".gitignore"));
    try std.testing.expect(c.has("src/a.txt"));
    try std.testing.expect(c.has(".hidden/d.txt"));
    try std.testing.expect(!c.has("src/b.log"));
    try std.testing.expect(!c.has("logs/c.txt"));
    try std.testing.expect(!c.has(".git/objects/e"));
    try std.testing.expect(!c.has("node_modules/pkg/dist/f.js"));
    try std.testing.expect(!c.has("zig-out/bin/g"));
    try std.testing.expectEqual(@as(usize, 3), c.seen.items.len);
    try std.testing.expectEqual(@as(usize, 3), report.pruned.total());
    const note = (try report.pruned.note(alloc)).?;
    try std.testing.expectEqualStrings("[3 pruned directories were skipped: .git/, node_modules/, zig-out/ — set `path` inside one explicitly to search it]", note);

    // Pointed inside a pruned directory, the walk descends through nested
    // pruned names too (`dist` under `pkg`) and prunes nothing.
    const inside = try std.fs.path.join(alloc, &.{ base, "node_modules", "pkg" });
    var c2: Collector = .{ .alloc = alloc };
    const r2 = try walk(alloc, io, inside, .{ .allow_pruned_descend = true }, &c2);
    try std.testing.expect(c2.has("dist/f.js"));
    try std.testing.expectEqual(@as(usize, 0), r2.pruned.total());
}

test "walk: ancestor ignore files apply below the nearest .git root and stop there" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.createDirPath(io, "repo/.git");
    try ws.createDirPath(io, "repo/src/gen");
    try ws.writeFile(io, .{ .sub_path = "repo/.gitignore", .data = "gen/\n*.tmp\n" });
    try ws.writeFile(io, .{ .sub_path = "repo/src/.gitignore", .data = "!keep.tmp\n" });
    try ws.writeFile(io, .{ .sub_path = "repo/src/a.zig", .data = "a\n" });
    try ws.writeFile(io, .{ .sub_path = "repo/src/x.tmp", .data = "x\n" });
    try ws.writeFile(io, .{ .sub_path = "repo/src/keep.tmp", .data = "k\n" });
    try ws.writeFile(io, .{ .sub_path = "repo/src/gen/out.zig", .data = "o\n" });
    // The tmp dir is a repository root of its own (so this test does not
    // depend on where the checkout's `.git` is), with a rule that would hide
    // every .zig file below it — and a nested repository root beneath it.
    try ws.createDirPath(io, ".git");
    try ws.createDirPath(io, "own/.git");
    try ws.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.zig\n" });
    try ws.writeFile(io, .{ .sub_path = "own/b.zig", .data = "b\n" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try ws.realPath(io, &buf)];

    // base = repo/src: repo/.gitignore (an ancestor inside the repo) prunes gen/
    // and *.tmp; the inner file re-includes keep.tmp.
    const src = try std.fs.path.join(alloc, &.{ root, "repo", "src" });
    var c: Collector = .{ .alloc = alloc };
    _ = try walk(alloc, io, src, .{}, &c);
    try std.testing.expect(c.has("a.zig"));
    try std.testing.expect(c.has("keep.tmp"));
    try std.testing.expect(c.has(".gitignore"));
    try std.testing.expect(!c.has("x.tmp"));
    try std.testing.expect(!c.has("gen/out.zig"));

    // base = own, itself a repository root: the search for ancestors stops at
    // its `.git`, so the tmp root's `*.zig` rule one level up does not reach in.
    // (The tmp dir lives inside this repository's checkout, so "no `.git`
    // anywhere above" cannot be staged here — the nearest-root rule is what
    // is testable, and it is the rule that matters.)
    const own = try std.fs.path.join(alloc, &.{ root, "own" });
    var c2: Collector = .{ .alloc = alloc };
    _ = try walk(alloc, io, own, .{}, &c2);
    try std.testing.expect(c2.has("b.zig"));
    // And a sibling with no `.git` of its own does see the tmp root's rule.
    try ws.createDirPath(io, "plain");
    try ws.writeFile(io, .{ .sub_path = "plain/c.zig", .data = "c\n" });
    try ws.writeFile(io, .{ .sub_path = "plain/c.txt", .data = "c\n" });
    const plain = try std.fs.path.join(alloc, &.{ root, "plain" });
    var c3: Collector = .{ .alloc = alloc };
    _ = try walk(alloc, io, plain, .{}, &c3);
    try std.testing.expect(!c3.has("c.zig"));
    try std.testing.expect(c3.has("c.txt"));
}

test "walk: a directory symlink is skipped and counted by default, followed once on request" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.createDirPath(io, "root");
    try ws.createDirPath(io, "skill");
    try ws.writeFile(io, .{ .sub_path = "skill/SKILL.md", .data = "skill\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_abs = buf[0..try ws.realPath(io, &buf)];
    const target = try std.fs.path.join(alloc, &.{ ws_abs, "skill" });
    // Creating a symlink needs a privilege Windows does not always grant.
    ws.symLink(io, target, "root/arbor", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    // A link back up: with follow_symlinks the loop guard must end it.
    ws.symLink(io, ws_abs, "skill/up", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const root = try std.fs.path.join(alloc, &.{ ws_abs, "root" });

    var c: Collector = .{ .alloc = alloc };
    const r = try walk(alloc, io, root, .{}, &c);
    try std.testing.expectEqual(@as(usize, 0), c.seen.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.skipped_directory_links);

    var c2: Collector = .{ .alloc = alloc };
    const r2 = try walk(alloc, io, root, .{ .follow_symlinks = true }, &c2);
    try std.testing.expect(!r2.timed_out);
    try std.testing.expect(c2.has("arbor/SKILL.md"));
    try std.testing.expectEqual(@as(usize, 0), r2.skipped_directory_links);
    // Through `up` the walk reaches the tmp root once (its files, e.g. under
    // `skill` again — the real path is remembered, so no second visit) and
    // then stops; a runaway loop would either hang or hit the deadline.
    for (c2.seen.items) |s| try std.testing.expect(std.mem.count(u8, s, "arbor/") <= 1);
}

test "walk: the deadline stops the walk and says so" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.createDirPath(io, "d");
    for (0..8) |i| {
        const name = try std.fmt.allocPrint(alloc, "d/f{d}.txt", .{i});
        try ws.writeFile(io, .{ .sub_path = name, .data = "x\n" });
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try ws.realPath(io, &buf)];

    const Slow = struct {
        io: std.Io,
        calls: usize = 0,
        pub fn visit(self: *@This(), entry: Entry) anyerror!void {
            _ = entry;
            self.calls += 1;
            // Burn wall-clock time so a zero deadline is crossed by the next entry.
            try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(5) }, self.io);
        }
    };
    var slow: Slow = .{ .io = io };
    const report = try walk(alloc, io, base, .{ .deadline_ms = 0 }, &slow);
    try std.testing.expect(report.timed_out);
    try std.testing.expect(slow.calls < 8);
}
