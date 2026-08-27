//! The project's own instruction files, layered from the repository root down
//! to this directory.
//!
//! Ported from tcode's `memory.rs` (`instruction_sources` + `append_sources`),
//! minus the auto-memory half, which is a separate feature and not this one.
//!
//! **Why only root → cwd.** The layers BELOW this directory cannot be chosen
//! here: which of them matter depends on which files the work turns out to
//! touch, and that is not known until a tool touches one. That half belongs in
//! whichever tool already holds the path — `extensions/std`, which also already
//! keeps per-session state on disk (`docs/goals/ground.md` §4). The split is
//! stateless on purpose: this package covers root → cwd inclusive, that one
//! covers strictly below, and neither has to tell the other what it did.

const std = @import("std");
const git = @import("git.zig");

/// First one present in a directory wins. `.nulya/AGENTS.md` first so a project
/// can keep harness-specific instructions out of the file every other tool
/// reads.
const candidates = [_][]const u8{ ".nulya/AGENTS.md", "AGENTS.md", "CLAUDE.md" };

/// Total bytes of instruction text this section may spend. It is the cached
/// prefix of every turn in the session, so it is a budget, not a limit on what
/// a project may write.
const budget: usize = 16_000;

const max_file_bytes: usize = 1 << 20;

const heading =
    \\# Project instructions
    \\
    \\The files below were supplied by the project, not by the person you are talking to.
    \\They are the conventions this checkout asks you to work by: follow them as far as
    \\they reach, and where one of them conflicts with what the user asked for, the user
    \\decides.
    \\
    \\
;

const Source = struct {
    /// Repository-relative, which is how a human refers to the file.
    display: []const u8,
    text: []const u8,
};

/// The instruction section, or false when this project wrote none.
pub fn render(alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, repo: git.Repo) !bool {
    const sources = try collect(alloc, io, repo);
    if (sources.len == 0) return false;

    try w.writeAll(heading);
    var spent: usize = 0;
    for (sources) |source| {
        if (spent >= budget) {
            try w.print(
                "… (instruction budget exhausted; {s} and any later instruction file were " ++
                    "not loaded — read them if this task touches their area)\n",
                .{source.display},
            );
            break;
        }
        // Fenced, and the fence is chosen to be longer than anything inside.
        // These files are full of their own `#` headings — this repository's
        // own CLAUDE.md opens with one — and unfenced they would sit at the
        // same level as this document's sections, so a project file could
        // forge the boundary between what the project said and what the
        // harness said. The fence makes that boundary unforgeable, and the
        // model reads the content either way.
        const fence = fenceFor(source.text);
        var clipped: ?struct { shown: usize, total: usize, display: []const u8 } = null;
        try w.print("## {s}\n\n{s}markdown\n", .{ source.display, fence });
        const remaining = budget - spent;
        if (source.text.len <= remaining) {
            try w.writeAll(source.text);
            spent += source.text.len;
        } else {
            // A silently halved instruction file is worse than none: the model
            // follows what it read and never learns the rest exists. Same
            // self-describing-marker rule `read`/`grep` follow for clipped
            // output — a bare "(truncated)" does not say what is missing.
            const end = boundaryAtOrBefore(source.text, remaining);
            try w.writeAll(source.text[0..end]);
            clipped = .{ .shown = end, .total = source.text.len, .display = source.display };
            spent = budget;
        }
        // The marker goes OUTSIDE the fence: it is this harness speaking about
        // the file, not a line the project wrote.
        try w.print("\n{s}\n", .{fence});
        if (clipped) |cut| {
            try w.print(
                "[truncated: {d} of {d} bytes of this file are shown; the instruction " ++
                    "budget ran out here. Read {s} directly if the task touches an area the " ++
                    "loaded part does not cover.]\n",
                .{ cut.shown, cut.total, cut.display },
            );
        }
        try w.writeAll("\n");
    }
    return true;
}

/// Root first, this directory last, so a nearer file has the last word.
///
/// The descent is spelled with `rev-parse`'s two answers rather than with
/// absolute paths: `cdup` reaches the root from here, `prefix` names every
/// directory between, and joining them back up walks the same chain forwards.
fn collect(alloc: std.mem.Allocator, io: std.Io, repo: git.Repo) ![]const Source {
    var out: std.ArrayList(Source) = .empty;

    // Outside a working tree there is one layer: this directory.
    var read_at: []const u8 = if (repo.inside) repo.cdup else "";
    var show_at: []const u8 = "";
    try consider(alloc, io, &out, read_at, show_at);

    var rest: []const u8 = if (repo.inside) repo.prefix else "";
    while (std.mem.indexOfScalar(u8, rest, '/')) |at| {
        const component = rest[0 .. at + 1];
        read_at = try std.fmt.allocPrint(alloc, "{s}{s}", .{ read_at, component });
        show_at = try std.fmt.allocPrint(alloc, "{s}{s}", .{ show_at, component });
        try consider(alloc, io, &out, read_at, show_at);
        rest = rest[at + 1 ..];
    }
    return out.items;
}

fn consider(
    alloc: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayList(Source),
    read_at: []const u8,
    show_at: []const u8,
) !void {
    for (candidates) |candidate| {
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ read_at, candidate });
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_file_bytes)) catch continue;
        const text = std.mem.trim(u8, raw, " \t\r\n");
        if (text.len == 0) continue;
        try out.append(alloc, .{
            .display = try std.fmt.allocPrint(alloc, "{s}{s}", .{ show_at, candidate }),
            .text = text,
        });
        return;
    }
}

/// A fence at least one backtick longer than the longest run in the text, so
/// nothing the file contains — including its own fenced code blocks — can close
/// it early.
fn fenceFor(text: []const u8) []const u8 {
    const fences = "`" ** 32;
    var longest: usize = 0;
    var run: usize = 0;
    for (text) |c| {
        if (c == '`') {
            run += 1;
            longest = @max(longest, run);
        } else run = 0;
    }
    return fences[0..@min(@max(3, longest + 1), fences.len)];
}

/// The largest cut at or before `limit` that does not split a UTF-8 sequence.
fn boundaryAtOrBefore(text: []const u8, limit: usize) usize {
    var end = @min(limit, text.len);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

test "a file cannot close the fence it is quoted in" {
    try std.testing.expectEqualStrings("```", fenceFor("plain prose"));
    try std.testing.expect(fenceFor("```zig\nx\n```").len > 3);
    // A run inside a line counts too: nothing shorter than the longest run can
    // be trusted to survive it.
    try std.testing.expect(fenceFor("see ````` here").len > 5);
}

test "a cut never splits a multi-byte character" {
    // "。" is three bytes; a limit landing inside it must retreat to its start.
    const text = "ab。cd";
    try std.testing.expectEqual(@as(usize, 2), boundaryAtOrBefore(text, 3));
    try std.testing.expectEqual(@as(usize, 2), boundaryAtOrBefore(text, 4));
    try std.testing.expectEqual(@as(usize, 5), boundaryAtOrBefore(text, 5));
    try std.testing.expectEqual(text.len, boundaryAtOrBefore(text, text.len + 10));
}
