//! `grep` — regex search over a directory tree or one file, ported from tcode
//! search.rs (`GrepTool`): the numbers, the notes and the output shape are its.
//!
//! What a call does: resolve `path` (default cwd); compile the pattern under
//! smart case (`regex.zig`); walk the base with `walk.zig` (gitignore, prune
//! table, 10 s deadline) or read the one explicit file; skip files over the
//! size cap, files with a NUL in their first 8 KB, and files the `glob` filter
//! rejects; collect every file's matches into groups (a run of match and
//! context lines with no gap between them); sort groups by file then line;
//! apply the per-file cap (only when results span more than one file); page by
//! MATCHES with `head_limit` / `offset`, cutting the groups that straddle a page
//! edge so no context line dangles; render `file:` headings, `N: text` for
//! matches, `N- text` for context, `--` between disjoint context blocks of one
//! file; append the notes that explain what was left out.
//!
//! One thing tcode did not have: a total output budget of `max_output_bytes`
//! (docs/goals/std.md D5). The page is cut at match granularity to fit under it,
//! so the paging note's `offset=` is exact and the kernel's own output guard
//! never has to clip a listing and eat the notes.
//!
//! Every answer that is not a host fault is TEXT: "no matches" and "offset past
//! the end" are results a model can act on, not errors. Only a missing path and
//! a pattern that will not compile are refusals.

const std = @import("std");
const rpc = @import("rpc.zig");
const walk = @import("walk.zig");
const regex = @import("regex.zig");
const globpat = @import("vendor/globpat.zig");

// tcode search.rs constants, verbatim.
pub const default_match_limit: usize = 200;
/// Cap each matched line so a single giant line (minified JS, JSONL session
/// transcripts, data blobs) cannot flood the context. head_limit bounds the
/// match COUNT; this bounds the BYTES per match.
pub const max_line_bytes: usize = 512;
/// grep never reads directory-scanned files larger than this — content search
/// across multi-MB files is both slow and usually useless. This still admits
/// ordinary source files when a narrow glob selects them.
pub const max_file_bytes: u64 = 512 * 1024;
/// A larger cap for a `path` that resolves to one exact file: the search is
/// intentional and still bounded by head_limit, per-line caps, context caps
/// and the deadline.
pub const max_explicit_file_bytes: u64 = 10 * 1024 * 1024;
/// Ceiling on -A/-B/-C context so a wide window over many matches cannot
/// balloon the output.
pub const max_context: u64 = 30;
/// Per-file ceiling on matches. head_limit alone is not enough: files are
/// emitted in path order, so one file with hundreds of hits eats the whole
/// budget and the model never learns the pattern also occurs in ten other
/// places. Trades depth in one file — reachable with `path` — for breadth.
pub const max_matches_per_file: usize = 30;

/// Whole-answer ceiling (docs/goals/std.md D5): below the kernel's 128 KB
/// output guard, so a listing is cut here, at match granularity, and its notes
/// always arrive.
pub const max_output_bytes: usize = 100 * 1024;
/// Room kept for the notes after the listing body.
const note_reserve_bytes: usize = 1536;
/// A file with a NUL byte in this prefix is binary and not searched.
pub const binary_probe_bytes: usize = 8 * 1024;

pub const Line = struct { lnum: u64, text: []const u8, is_match: bool };

/// A contiguous block of lines (matches plus any merged context), as delimited
/// by context breaks. Paging counts `matches`, not lines, so context never
/// distorts head_limit / offset. (tcode `Group`)
pub const Group = struct {
    file: []const u8,
    first: u64,
    matches: usize,
    lines: std.ArrayList(Line),
};

pub fn run(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    // Whatever the answer quotes — a matched line, a path — must reach the
    // model as valid UTF-8; the files it came from need not be.
    return walk.sanitize(ctx.alloc, try answer(ctx, args));
}

fn answer(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    const alloc = ctx.alloc;
    const io = ctx.io;

    const pattern = switch (try rpc.requireString(alloc, args, "pattern")) {
        .ok => |s| s,
        .failed => |f| return f,
    };
    const path_arg = optionalString(args, "path") catch return rpc.invalidParams(alloc, "path must be a string", .{});
    const glob_arg = optionalString(args, "glob") catch return rpc.invalidParams(alloc, "glob must be a string", .{});
    const case_insensitive = rpc.optionalBool(args, "case_insensitive", false) catch return rpc.invalidParams(alloc, "case_insensitive must be a boolean", .{});
    const limit = @max((rpc.optionalUnsigned(args, "head_limit") catch return rpc.invalidParams(alloc, "head_limit must be a non-negative integer", .{})) orelse default_match_limit, 1);
    const offset = (rpc.optionalUnsigned(args, "offset") catch return rpc.invalidParams(alloc, "offset must be a non-negative integer", .{})) orelse 0;
    // -C sets both sides; -A/-B override it. Capped so context can't blow up
    // the output. (tcode)
    const ctx_c = (rpc.optionalUnsigned(args, "context") catch return rpc.invalidParams(alloc, "context must be a non-negative integer", .{})) orelse 0;
    const before: usize = @intCast(@min((rpc.optionalUnsigned(args, "before") catch return rpc.invalidParams(alloc, "before must be a non-negative integer", .{})) orelse ctx_c, max_context));
    const after: usize = @intCast(@min((rpc.optionalUnsigned(args, "after") catch return rpc.invalidParams(alloc, "after must be a non-negative integer", .{})) orelse ctx_c, max_context));

    const base = if (path_arg) |p| try ctx.resolve(p) else ctx.cwd;
    const base_stat = std.Io.Dir.cwd().statFile(io, base, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return rpc.refuse(alloc, "search path does not exist: {s}", .{base}),
        else => return rpc.refuse(alloc, "search path could not be read: {s} ({s})", .{ base, @errorName(err) }),
    };

    // Smart case: an all-lowercase pattern searches case-insensitively, an
    // uppercase-bearing one stays exact; `case_insensitive` wins outright.
    const compiled = (try regex.compile(alloc, pattern, case_insensitive)) orelse
        return rpc.refuse(alloc, "{s}", .{try regex.invalidMessage(alloc, pattern)});

    const glob_note = if (glob_arg) |g| try std.fmt.allocPrint(alloc, ", glob {s}", .{g}) else "";
    const explicit_file = base_stat.kind == .file;

    var search: Search = .{
        .alloc = alloc,
        .io = io,
        .regex = compiled,
        .before = before,
        .after = after,
        .glob = glob_arg,
        .base_display = try walk.relDisplay(alloc, base, ctx.cwd),
        .max_file_bytes = if (explicit_file) max_explicit_file_bytes else max_file_bytes,
        .scratch = .init(std.heap.page_allocator),
    };
    defer search.scratch.deinit();

    var report: walk.Report = .{};
    if (explicit_file) {
        // The glob filters an explicit file too, on its basename: relative to
        // itself the file's path is empty, so only the name can match. A
        // rejected file is never opened and never counted, so the answer is
        // the ordinary "no matches ... (0 files scanned, glob g)". (tcode
        // `glob_matches`, which the walk applies to a single-file base alike.)
        const admitted = if (glob_arg) |g| globpat.matchPath(g, std.fs.path.basename(base)) else true;
        if (admitted) try search.searchFile(std.Io.Dir.cwd(), base, search.base_display);
    } else {
        report = try walk.walk(alloc, io, base, .{
            .follow_symlinks = false,
            .allow_pruned_descend = walk.pathArgAllowsPrunedDescend(path_arg),
        }, &search);
    }

    var groups = search.groups;
    // Files arrive in walk order; sort for stable output by file then line.
    std.mem.sort(Group, groups.items, {}, groupLess);

    // Apply the per-file cap before paging, so head_limit/offset count the
    // matches actually reachable through this tool and paging stays
    // self-consistent. Single-file results are exempt — nothing can be crowded
    // out, and a search aimed at one file should page rather than lose its tail.
    const cap = try applyPerFileCap(alloc, &groups);
    const total: usize = countMatches(groups.items);
    const prune_note = try report.pruned.note(alloc);

    // Page by MATCHES, cutting the groups that straddle a window edge instead
    // of keeping them whole (with no context lines a file's every match merges
    // into one group, so "keep whole groups" would ignore head_limit).
    var selected = try pageGroups(alloc, groups.items, offset, limit, before, after);

    if (selected.items.len == 0 and total > 0) {
        // Matches exist, the requested page is past the end. Saying "no
        // matches" here would send the model hunting for a bad pattern.
        return .{ .text = try std.fmt.allocPrint(alloc, "offset={d} is past the last of {d} matches for /{s}/{s} — lower offset or drop it", .{ offset, total, pattern, glob_note }) };
    }
    if (selected.items.len == 0) {
        var m: std.Io.Writer.Allocating = .init(alloc);
        try m.writer.print("no matches for /{s}/ ({d} files scanned{s})", .{ pattern, search.files, glob_note });
        if (search.skipped_oversized > 0) {
            const noun = if (search.skipped_oversized == 1) "file" else "files";
            if (explicit_file) {
                try m.writer.print("\n[{d} {s} over {d} KiB skipped — use shell for an unbounded search]", .{ search.skipped_oversized, noun, search.max_file_bytes / 1024 });
            } else {
                try m.writer.print("\n[{d} {s} over {d} KiB skipped — set `path` to a specific file up to {d} KiB, or use shell for an unbounded search]", .{ search.skipped_oversized, noun, search.max_file_bytes / 1024, max_explicit_file_bytes / 1024 });
            }
        }
        if (prune_note) |note| try m.writer.print("\n{s}", .{note});
        try m.writer.writeAll("\n[.gitignore entries are excluded]");
        if (report.timed_out) try m.writer.print("\n[search timed out after {d}s before finishing — narrow the path or glob]", .{walk.deadline_seconds});
        return .{ .text = try m.toOwnedSlice() };
    }

    // A path is needed to locate a hit, but repeating it on every line is
    // costly for files with many matches or context lines. Groups are sorted
    // by file and line, so emit one heading per file and keep the `--`
    // separator only between disjoint context blocks in that same file.
    const rendered = try renderPage(alloc, &selected, before, after);

    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeAll(rendered.body);
    if (report.timed_out) {
        try out.writer.print("\n[search timed out after {d}s — partial results; narrow the path or glob]", .{walk.deadline_seconds});
    } else if (total > offset + rendered.shown) {
        try out.writer.print("\n[more matches beyond this page — raise head_limit or set offset={d}]", .{offset + rendered.shown});
    }
    if (cap.hidden > 0) {
        const noun = if (cap.capped_files == 1) "file" else "files";
        try out.writer.print("\n[{d} further matches in {d} {s} not shown — over {d} per file; re-run with `path` set to one of them for the rest]", .{ cap.hidden, cap.capped_files, noun, max_matches_per_file });
    }
    if (prune_note) |note| try out.writer.print("\n{s}", .{note});
    return .{ .text = try out.toOwnedSlice() };
}

fn optionalString(args: std.json.ObjectMap, key: []const u8) error{BadType}!?[]const u8 {
    return switch (args.get(key) orelse return null) {
        .null => null,
        .string => |s| s,
        else => error.BadType,
    };
}

// ---------------------------------------------------------------- the search

/// State for one call: what to match, how much context, where results go.
/// `visit` is the walker's callback.
const Search = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    regex: regex.Compiled,
    before: usize,
    after: usize,
    glob: ?[]const u8,
    /// The base as the model will see it (relative to cwd, "" for cwd itself).
    base_display: []const u8,
    max_file_bytes: u64,
    /// File contents and per-file line tables live here and are dropped after
    /// each file: a whole tree's bytes must not accumulate in the call arena.
    scratch: std.heap.ArenaAllocator,

    groups: std.ArrayList(Group) = .empty,
    files: usize = 0,
    skipped_oversized: usize = 0,

    pub fn visit(self: *Search, entry: walk.Entry) anyerror!void {
        if (self.glob) |g| {
            if (!globpat.matchPath(g, entry.rel)) return;
        }
        try self.searchFile(entry.dir, entry.name, try walk.display(self.alloc, self.base_display, entry.rel));
    }

    /// Search one file, appending its groups. Unreadable files are skipped
    /// silently (tcode ignored `search_path` errors the same way).
    fn searchFile(self: *Search, dir: std.Io.Dir, name: []const u8, display: []const u8) !void {
        var file = dir.openFile(self.io, name, .{}) catch return;
        defer file.close(self.io);
        const st = file.stat(self.io) catch return;
        if (st.size > self.max_file_bytes) {
            self.skipped_oversized += 1;
            return;
        }
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();
        var reader = file.reader(self.io, &.{});
        const bytes = reader.interface.allocRemaining(scratch, .limited(@intCast(self.max_file_bytes + 1))) catch return;
        if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, binary_probe_bytes)], 0) != null) return;
        self.files += 1;
        try self.scan(bytes, display, scratch);
    }

    /// The line loop: matches, before/after context, group breaks on gaps.
    /// Mirrors grep_searcher's sink calls as tcode consumed them: with no
    /// context requested a file's matches all land in ONE group; with context,
    /// a new group starts whenever a line was skipped between two blocks.
    fn scan(self: *Search, bytes: []const u8, display: []const u8, scratch: std.mem.Allocator) !void {
        if (bytes.len == 0) return;
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |raw| try lines.append(scratch, raw);
        if (bytes[bytes.len - 1] == '\n') _ = lines.pop();

        const lower_buf: []u8 = if (self.regex.fold_case) try scratch.alloc(u8, bytes.len) else &.{};
        const with_context = self.before > 0 or self.after > 0;

        var cur: ?*Group = null;
        var last_emitted: u64 = 0;
        var after_until: u64 = 0;
        for (lines.items, 0..) |raw, idx| {
            const lnum: u64 = idx + 1;
            const line = stripCr(raw);
            const hay = if (self.regex.fold_case) regex.lowerInto(lower_buf[0..line.len], line) else line;
            if (self.regex.isMatch(hay)) {
                var lo: u64 = if (lnum > self.before) lnum - @as(u64, self.before) else 1;
                if (lo <= last_emitted) lo = last_emitted + 1;
                const gap = last_emitted != 0 and lo > last_emitted + 1;
                if (cur != null and with_context and gap) cur = null;
                if (cur == null) cur = try self.newGroup(display);
                var l = lo;
                while (l < lnum) : (l += 1) try self.push(cur.?, l, stripCr(lines.items[l - 1]), false);
                try self.push(cur.?, lnum, line, true);
                cur.?.matches += 1;
                last_emitted = lnum;
                after_until = lnum + @as(u64, self.after);
            } else if (lnum <= after_until) {
                try self.push(cur.?, lnum, line, false);
                last_emitted = lnum;
            }
        }
    }

    fn newGroup(self: *Search, display: []const u8) !*Group {
        try self.groups.append(self.alloc, .{ .file = display, .first = 0, .matches = 0, .lines = .empty });
        return &self.groups.items[self.groups.items.len - 1];
    }

    fn push(self: *Search, g: *Group, lnum: u64, text: []const u8, is_match: bool) !void {
        if (g.lines.items.len == 0) g.first = lnum;
        try g.lines.append(self.alloc, .{ .lnum = lnum, .text = try capLine(self.alloc, text), .is_match = is_match });
    }
};

/// A CRLF file's lines are matched and shown without their `\r`, so `foo$`
/// works and the output carries no stray carriage returns.
fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// Trim trailing whitespace and cap the line at a byte budget on a UTF-8
/// boundary, so a single enormous line can't blow up the tool result.
/// (tcode `cap_line`, minus its credential redaction — not in scope.)
pub fn capLine(alloc: std.mem.Allocator, line: []const u8) ![]const u8 {
    const s = std.mem.trimEnd(u8, line, " \t\r\n\x0b\x0c");
    if (s.len <= max_line_bytes) return alloc.dupe(u8, s);
    var end = max_line_bytes;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(alloc, "{s}…[+{d} bytes]", .{ s[0..end], s.len - end });
}

fn groupLess(_: void, a: Group, b: Group) bool {
    return switch (std.mem.order(u8, a.file, b.file)) {
        .lt => true,
        .gt => false,
        .eq => a.first < b.first,
    };
}

fn countMatches(groups: []const Group) usize {
    var n: usize = 0;
    for (groups) |g| n += g.matches;
    return n;
}

/// Cut a group down to `take` matches starting at its `skip`-th, so a group
/// that straddles a page edge contributes only the matches inside the window.
/// The kept matches keep their context: the cut runs from `before` lines ahead
/// of the first one to `after` lines past the last — exactly the block those
/// matches would have produced had they been the only ones in the file.
/// Nothing dangles at either end. (tcode `clip_to_window`)
pub fn clipToWindow(g: *Group, skip: usize, take: usize, before: usize, after: usize) void {
    if (skip == 0 and take >= g.matches) return;
    const items = g.lines.items;
    var seen: usize = 0;
    var first: ?usize = null;
    var last: usize = 0;
    var kept: usize = 0;
    for (items, 0..) |l, i| {
        if (!l.is_match) continue;
        if (seen == skip) first = i;
        if (seen >= skip and seen < skip + take) {
            last = i;
            kept += 1;
        }
        seen += 1;
    }
    const f = first orelse {
        g.lines.clearRetainingCapacity();
        g.matches = 0;
        return;
    };
    const lo = f -| before;
    const hi = @min(last + after, items.len - 1);
    const n = hi + 1 - lo;
    std.mem.copyForwards(Line, items[0..n], items[lo .. hi + 1]);
    g.lines.shrinkRetainingCapacity(n);
    g.first = g.lines.items[0].lnum;
    g.matches = kept;
}

pub const CapReport = struct { hidden: usize = 0, capped_files: usize = 0 };

/// The per-file cap, at match granularity, applied only when the results span
/// more than one file. Trailing after-context past the last kept match goes
/// too, leaving no dangling context. (tcode, inline in `GrepTool::run`)
pub fn applyPerFileCap(alloc: std.mem.Allocator, groups: *std.ArrayList(Group)) !CapReport {
    var report: CapReport = .{};
    var multi = false;
    var i: usize = 1;
    while (i < groups.items.len) : (i += 1) {
        if (!std.mem.eql(u8, groups.items[i - 1].file, groups.items[i].file)) {
            multi = true;
            break;
        }
    }
    if (!multi) return report;

    var kept: std.ArrayList(Group) = .empty;
    var file: []const u8 = "";
    var in_file: usize = 0;
    for (groups.items) |*g| {
        if (!std.mem.eql(u8, g.file, file)) {
            file = g.file;
            in_file = 0;
        }
        const allowance = max_matches_per_file -| in_file;
        if (allowance == 0) {
            report.hidden += g.matches;
            continue;
        }
        if (g.matches <= allowance) {
            in_file += g.matches;
            try kept.append(alloc, g.*);
            continue;
        }
        // First group to cross the cap for this file: keep matches up to the
        // allowance, then cut.
        report.capped_files += 1;
        var taken: usize = 0;
        var cut = g.lines.items.len;
        for (g.lines.items, 0..) |line, idx| {
            if (line.is_match) {
                taken += 1;
                if (taken == allowance) {
                    cut = idx + 1;
                    break;
                }
            }
        }
        report.hidden += g.matches - taken;
        g.lines.shrinkRetainingCapacity(cut);
        g.matches = taken;
        in_file = max_matches_per_file;
        try kept.append(alloc, g.*);
    }
    groups.* = kept;
    return report;
}

/// The groups of the page `[offset, offset+limit)` counted in matches, edge
/// groups clipped. (tcode, inline in `GrepTool::run`)
pub fn pageGroups(alloc: std.mem.Allocator, groups: []const Group, offset: usize, limit: usize, before: usize, after: usize) !std.ArrayList(Group) {
    const window_end = offset +| limit;
    var seen: usize = 0;
    var selected: std.ArrayList(Group) = .empty;
    for (groups) |g_in| {
        var g = g_in;
        const start = seen;
        seen += g.matches;
        if (start >= window_end) break;
        if (seen <= offset) continue;
        if (start < offset or seen > window_end) {
            // The clip rewrites the line list in place; work on a copy so the
            // caller's groups stay whole.
            g.lines = try g_in.lines.clone(alloc);
            clipToWindow(&g, offset -| start, @min(seen, window_end) - @max(offset, start), before, after);
        }
        try selected.append(alloc, g);
    }
    return selected;
}

const Rendered = struct { body: []const u8, shown: usize };

/// The listing body under the output budget. Groups are written in order; the
/// first one that does not fit is clipped to the leading matches that do, and
/// rendering stops there. `shown` counts the matches actually written, so the
/// paging note's `offset=` stays exact.
fn renderPage(alloc: std.mem.Allocator, selected: *std.ArrayList(Group), before: usize, after: usize) !Rendered {
    const budget = max_output_bytes - note_reserve_bytes;
    const with_context = before > 0 or after > 0;
    var out: std.Io.Writer.Allocating = .init(alloc);
    var previous_file: ?[]const u8 = null;
    var shown: usize = 0;
    for (selected.items) |*g| {
        const same_file = if (previous_file) |p| std.mem.eql(u8, p, g.file) else false;
        const leading = out.written().len == 0;
        var piece: std.Io.Writer.Allocating = .init(alloc);
        try writeGroup(&piece.writer, g, same_file, leading, with_context);
        if (out.written().len + piece.written().len <= budget) {
            try out.writer.writeAll(piece.written());
            shown += g.matches;
            previous_file = g.file;
            continue;
        }
        // Over budget: keep as many of this group's leading matches as fit.
        var k = g.matches;
        while (k > 1) {
            k -= 1;
            var probe: Group = g.*;
            probe.lines = try g.lines.clone(alloc);
            clipToWindow(&probe, 0, k, before, after);
            var attempt: std.Io.Writer.Allocating = .init(alloc);
            try writeGroup(&attempt.writer, &probe, same_file, leading, with_context);
            if (out.written().len + attempt.written().len <= budget) {
                try out.writer.writeAll(attempt.written());
                shown += k;
                break;
            }
        }
        break;
    }
    return .{ .body = try out.toOwnedSlice(), .shown = shown };
}

fn writeGroup(w: *std.Io.Writer, g: *const Group, same_file: bool, leading: bool, with_context: bool) !void {
    if (!leading) {
        if (same_file and with_context) {
            try w.writeAll("\n--\n");
        } else {
            try w.writeAll("\n");
        }
    }
    if (!same_file) try w.print("{s}:\n", .{g.file});
    for (g.lines.items, 0..) |line, index| {
        if (index > 0) try w.writeAll("\n");
        const sep: u8 = if (line.is_match) ':' else '-';
        try w.print("{d}{c} {s}", .{ line.lnum, sep, line.text });
    }
}

// ---------------------------------------------------------------- tests

test {
    std.testing.refAllDecls(@This());
}

fn testGroup(alloc: std.mem.Allocator, file: []const u8, spec: []const u8) !Group {
    // spec: one char per line, 'M' = match, 'c' = context; line numbers 1..n.
    var g: Group = .{ .file = file, .first = 1, .matches = 0, .lines = .empty };
    for (spec, 0..) |c, i| {
        const is_match = c == 'M';
        if (is_match) g.matches += 1;
        try g.lines.append(alloc, .{ .lnum = i + 1, .text = try std.fmt.allocPrint(alloc, "L{d}", .{i + 1}), .is_match = is_match });
    }
    return g;
}

fn lnums(alloc: std.mem.Allocator, g: Group) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    for (g.lines.items) |l| try out.append(alloc, l.lnum);
    return out.toOwnedSlice(alloc);
}

test "clipToWindow keeps the window's matches with their own context and nothing dangling" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // x1 TARGET x3 x4 TARGET x6 x7 TARGET x9 with context 1: one merged group.
    var g = try testGroup(alloc, "a", "cMccMccMc");
    clipToWindow(&g, 1, 1, 1, 1);
    try std.testing.expectEqualSlices(u64, &.{ 4, 5, 6 }, try lnums(alloc, g));
    try std.testing.expectEqual(@as(usize, 1), g.matches);
    try std.testing.expectEqual(@as(u64, 4), g.first);

    // skip=0 take≥matches → untouched.
    var whole = try testGroup(alloc, "a", "cMccMccMc");
    clipToWindow(&whole, 0, 3, 1, 1);
    try std.testing.expectEqual(@as(usize, 9), whole.lines.items.len);

    // take past the end clamps; skip past the end empties.
    var tail = try testGroup(alloc, "a", "cMccMccMc");
    clipToWindow(&tail, 2, 5, 1, 1);
    try std.testing.expectEqualSlices(u64, &.{ 7, 8, 9 }, try lnums(alloc, tail));
    try std.testing.expectEqual(@as(usize, 1), tail.matches);
    var none = try testGroup(alloc, "a", "cMccMccMc");
    clipToWindow(&none, 3, 1, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), none.lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), none.matches);

    // No context: a straddling page keeps exactly the matches asked for.
    var bare = try testGroup(alloc, "a", "MMMMMMMM");
    clipToWindow(&bare, 3, 3, 0, 0);
    try std.testing.expectEqualSlices(u64, &.{ 4, 5, 6 }, try lnums(alloc, bare));
}

test "per-file cap: only across files, at match granularity, trailing context dropped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // One file alone is exempt however crowded.
    var single: std.ArrayList(Group) = .empty;
    try single.append(alloc, try testGroup(alloc, "a", "M" ** 35));
    const r0 = try applyPerFileCap(alloc, &single);
    try std.testing.expectEqual(@as(usize, 0), r0.hidden);
    try std.testing.expectEqual(@as(usize, 35), single.items[0].matches);

    // Two files: a's 35 matches (in two groups, the second with trailing
    // context) become 30, the rest is counted hidden; z survives whole.
    var groups: std.ArrayList(Group) = .empty;
    try groups.append(alloc, try testGroup(alloc, "a", "M" ** 20));
    try groups.append(alloc, try testGroup(alloc, "a", "M" ** 15 ++ "cc"));
    try groups.append(alloc, try testGroup(alloc, "a", "MM"));
    try groups.append(alloc, try testGroup(alloc, "z", "M"));
    const r = try applyPerFileCap(alloc, &groups);
    try std.testing.expectEqual(@as(usize, 7), r.hidden);
    try std.testing.expectEqual(@as(usize, 1), r.capped_files);
    try std.testing.expectEqual(@as(usize, 3), groups.items.len);
    try std.testing.expectEqual(@as(usize, 20), groups.items[0].matches);
    try std.testing.expectEqual(@as(usize, 10), groups.items[1].matches);
    try std.testing.expectEqual(@as(usize, 10), groups.items[1].lines.items.len);
    try std.testing.expectEqualStrings("z", groups.items[2].file);
    try std.testing.expectEqual(@as(usize, 31), countMatches(groups.items));
}

test "pageGroups counts matches, clips both edges, and can straddle two files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var groups: std.ArrayList(Group) = .empty;
    try groups.append(alloc, try testGroup(alloc, "a", "MMMM"));
    try groups.append(alloc, try testGroup(alloc, "b", "MMMM"));
    const page = try pageGroups(alloc, groups.items, 2, 4, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualSlices(u64, &.{ 3, 4 }, try lnums(alloc, page.items[0]));
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, try lnums(alloc, page.items[1]));
    // The originals are untouched.
    try std.testing.expectEqual(@as(usize, 4), groups.items[0].lines.items.len);
    // Past the end → empty.
    const past = try pageGroups(alloc, groups.items, 50, 4, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), past.items.len);
}

test "capLine trims, caps at 512 bytes on a UTF-8 boundary and marks the rest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("abc", try capLine(alloc, "abc  \t\r"));
    const long = try alloc.alloc(u8, 600);
    @memset(long, 'x');
    const capped = try capLine(alloc, long);
    try std.testing.expect(std.mem.endsWith(u8, capped, "…[+88 bytes]"));
    try std.testing.expectEqual(@as(usize, 512 + "…[+88 bytes]".len), capped.len);
    // A 3-byte character straddling the cap is not split.
    const mixed = try alloc.alloc(u8, 520);
    @memset(mixed, 'y');
    @memcpy(mixed[511..514], "€");
    const c2 = try capLine(alloc, mixed);
    try std.testing.expect(std.mem.indexOf(u8, c2, "yyy…[+") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c2));
}

// In-process runs against a scratch tree: the same tcode cases, without a
// child process. (The e2e suite covers the real binary.)
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

    fn grep(self: *TestCtx, args_json: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), args_json, .{});
        return switch (try run(&self.ctx, parsed.object)) {
            .text => |t| t,
            .failed => |f| f.message,
        };
    }
};

test "grep run: bare match, context shape, before/after, --, smart case, paging inside one file" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.write("a.rs", "line1\nline2\nTARGET\nline4\nline5\n");

    try std.testing.expectEqualStrings("a.rs:\n3: TARGET", try t.grep("{\"pattern\":\"TARGET\"}"));
    try std.testing.expectEqualStrings("a.rs:\n2- line2\n3: TARGET\n4- line4", try t.grep("{\"pattern\":\"TARGET\",\"context\":1}"));
    try std.testing.expectEqualStrings("a.rs:\n2- line2\n3: TARGET", try t.grep("{\"pattern\":\"TARGET\",\"before\":1,\"after\":0}"));
    try std.testing.expectEqualStrings("a.rs:\n3: TARGET\n4- line4\n5- line5", try t.grep("{\"pattern\":\"TARGET\",\"after\":2,\"before\":0}"));

    try t.write("a.rs", "hit\nx\nx\nx\nx\nx\nhit\n");
    try std.testing.expectEqualStrings("a.rs:\n1: hit\n2- x\n--\n6- x\n7: hit", try t.grep("{\"pattern\":\"hit\",\"context\":1}"));

    try t.write("a.rs", "Target\nTARGET\ntarget\n");
    try std.testing.expectEqualStrings("a.rs:\n1: Target\n2: TARGET\n3: target", try t.grep("{\"pattern\":\"target\"}"));
    try std.testing.expectEqualStrings("a.rs:\n1: Target", try t.grep("{\"pattern\":\"Target\"}"));
    try std.testing.expectEqualStrings("a.rs:\n1: Target\n2: TARGET\n3: target", try t.grep("{\"pattern\":\"Target\",\"case_insensitive\":true}"));

    try t.write("a.rs", "TARGET 1\nTARGET 2\nTARGET 3\nTARGET 4\nTARGET 5\nTARGET 6\nTARGET 7\nTARGET 8\n");
    try std.testing.expectEqualStrings("a.rs:\n1: TARGET 1\n2: TARGET 2\n3: TARGET 3\n[more matches beyond this page — raise head_limit or set offset=3]", try t.grep("{\"pattern\":\"TARGET\",\"head_limit\":3}"));
    try std.testing.expectEqualStrings("a.rs:\n7: TARGET 7\n8: TARGET 8", try t.grep("{\"pattern\":\"TARGET\",\"head_limit\":3,\"offset\":6}"));
    try std.testing.expect(std.mem.startsWith(u8, try t.grep("{\"pattern\":\"TARGET\",\"offset\":50}"), "offset=50 is past the last of 8 matches for /TARGET/"));

    // A clipped page keeps the context of the matches it kept.
    try t.write("a.rs", "x1\nTARGET a\nx3\nx4\nTARGET b\nx6\nx7\nTARGET c\nx9\n");
    try std.testing.expectEqualStrings("a.rs:\n4- x4\n5: TARGET b\n6- x6\n[more matches beyond this page — raise head_limit or set offset=2]", try t.grep("{\"pattern\":\"TARGET\",\"context\":1,\"head_limit\":1,\"offset\":1}"));
}

test "grep run: no matches / oversized / explicit file / invalid regex / missing path" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.write("a.rs", "miss\n");
    const big = try t.arena.allocator().alloc(u8, max_file_bytes + 8);
    @memset(big, 'x');
    @memcpy(big[big.len - 8 ..], "\nTARGET\n");
    try t.write("large.rs", big);

    const none = try t.grep("{\"pattern\":\"TARGET\",\"glob\":\"large.rs\"}");
    try std.testing.expect(std.mem.startsWith(u8, none, "no matches for /TARGET/ (0 files scanned, glob large.rs)"));
    try std.testing.expect(std.mem.indexOf(u8, none, "[1 file over 512 KiB skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, none, "set `path` to a specific file up to 10240 KiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, none, "[.gitignore entries are excluded]") != null);

    // Named explicitly, the same file is searched under the larger cap.
    try std.testing.expectEqualStrings("large.rs:\n2: TARGET", try t.grep("{\"pattern\":\"TARGET\",\"path\":\"large.rs\"}"));

    // A glob filters the explicit file too, by basename: rejected means it is
    // never opened, so it is not among the files scanned.
    const filtered = try t.grep("{\"pattern\":\"TARGET\",\"path\":\"large.rs\",\"glob\":\"*.zig\"}");
    try std.testing.expect(std.mem.startsWith(u8, filtered, "no matches for /TARGET/"));
    try std.testing.expect(std.mem.indexOf(u8, filtered, ", glob *.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "(0 files scanned") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "over 512 KiB skipped") == null);
    // A glob it does match leaves the search alone.
    try std.testing.expectEqualStrings("large.rs:\n2: TARGET", try t.grep("{\"pattern\":\"TARGET\",\"path\":\"large.rs\",\"glob\":\"*.rs\"}"));

    std.testing.log_level = .err; // mvzr warns about the pattern it rejects; expected here
    const bad = try t.grep("{\"pattern\":\"foo(bar\"}");
    try std.testing.expect(std.mem.startsWith(u8, bad, "invalid regex:"));
    try std.testing.expect(std.mem.indexOf(u8, bad, "escape literal ( ) [ ] { } . * + ? with a backslash") != null);

    const missing = try t.grep("{\"pattern\":\"x\",\"path\":\"nowhere\"}");
    try std.testing.expect(std.mem.startsWith(u8, missing, "search path does not exist: "));
}

test "grep run: per-file cap across files, single file exempt, binary and CRLF files" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    const alloc = t.arena.allocator();

    var crowded: std.Io.Writer.Allocating = .init(alloc);
    for (0..max_matches_per_file + 5) |i| try crowded.writer.print("TARGET {d}\n", .{i});
    try t.write("a.rs", crowded.written());
    try t.write("z.rs", "TARGET tail\n");
    try t.write("bin.dat", "TARGET\x00binary\n");
    try t.write("crlf.txt", "one\r\nTARGET end\r\nthree\r\n");

    const out = try t.grep("{\"pattern\":\"TARGET\"}");
    var a_matches: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next(); // "a.rs:"
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, "crlf.txt:")) break;
        if (line.len > 0 and std.ascii.isDigit(line[0])) a_matches += 1;
    }
    try std.testing.expectEqual(max_matches_per_file, a_matches);
    try std.testing.expect(std.mem.indexOf(u8, out, "z.rs:\n1: TARGET tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[5 further matches in 1 file not shown") != null);
    // The CRLF line matches `end$` and shows without its \r; the binary file is skipped.
    try std.testing.expect(std.mem.indexOf(u8, out, "crlf.txt:\n2: TARGET end\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bin.dat") == null);
    try std.testing.expectEqualStrings("crlf.txt:\n2: TARGET end", try t.grep("{\"pattern\":\"target end$\"}"));

    // A Latin-1 line is quoted as valid UTF-8 (the encoder would otherwise
    // turn the whole answer into a byte array).
    try t.write("latin1.txt", "TARGET caf\xe9\n");
    const latin = try t.grep("{\"pattern\":\"TARGET\",\"path\":\"latin1.txt\"}");
    try std.testing.expectEqualStrings("latin1.txt:\n1: TARGET caf\u{FFFD}", latin);
    try std.testing.expect(std.unicode.utf8ValidateSlice(latin));
    try t.tmp.dir.deleteFile(std.testing.io, "latin1.txt");

    // Alone, a crowded file is exempt.
    try t.tmp.dir.deleteFile(std.testing.io, "z.rs");
    try t.tmp.dir.deleteFile(std.testing.io, "crlf.txt");
    const alone = try t.grep("{\"pattern\":\"TARGET\"}");
    try std.testing.expect(std.mem.indexOf(u8, alone, "not shown") == null);
    try std.testing.expect(std.mem.indexOf(u8, alone, "35: TARGET 34") != null);
}

test "grep run: the whole answer stays under the output budget and pages by matches" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    const alloc = t.arena.allocator();
    // 60 files × 30 lines of ~400 bytes, head_limit 400: ~165 KB if the whole
    // page were shown at full width.
    const filler = try alloc.alloc(u8, 400);
    @memset(filler, 'w');
    for (0..60) |f| {
        var body: std.Io.Writer.Allocating = .init(alloc);
        for (0..30) |l| try body.writer.print("TARGET {d}-{d} {s}\n", .{ f, l, filler });
        try t.write(try std.fmt.allocPrint(alloc, "f{d:0>2}.txt", .{f}), body.written());
    }
    const out = try t.grep("{\"pattern\":\"TARGET\",\"head_limit\":400}");
    try std.testing.expect(out.len <= max_output_bytes);
    try std.testing.expect(out.len > max_output_bytes - 4096);
    try std.testing.expect(std.mem.indexOf(u8, out, "[more matches beyond this page — raise head_limit or set offset=") != null);
    // Every match line shown is complete (the cut is at match granularity).
    var it = std.mem.splitScalar(u8, out, '\n');
    var shown: usize = 0;
    while (it.next()) |line| {
        if (line.len > 0 and std.ascii.isDigit(line[0])) {
            try std.testing.expect(std.mem.endsWith(u8, line, "w"));
            shown += 1;
        }
    }
    try std.testing.expect(shown > 100 and shown < 400);
    // And the advertised offset is the number of matches shown.
    const marker = "set offset=";
    const at = std.mem.indexOf(u8, out, marker).?;
    const digits = out[at + marker.len .. std.mem.indexOfScalarPos(u8, out, at + marker.len, ']').?];
    try std.testing.expectEqual(shown, try std.fmt.parseInt(usize, digits, 10));
}
