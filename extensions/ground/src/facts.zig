//! Where this session is running, and what state the checkout is in.
//!
//! Ported from tcode's `grounding.rs` (`render_environment` / `render_git` /
//! `civil_from_days`). Everything here is a fact about the machine, never an
//! opinion about how to work — that is `extensions/coding`, a separate package
//! precisely so a project can take one without the other.

const std = @import("std");
const builtin = @import("builtin");
const git = @import("git.zig");

/// How many `git status --porcelain` lines to show before summarising.
const status_preview: usize = 15;

pub fn renderEnvironment(alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer) !void {
    try w.writeAll("# Environment\n\n");

    if (std.process.currentPathAlloc(io, alloc)) |cwd| {
        try w.print("working directory: {s}\n", .{cwd});
    } else |_| {}

    try w.print("platform: {s}", .{@tagName(builtin.os.tag)});
    if (try osRelease(alloc, io)) |name| try w.print(" ({s})", .{name});
    try w.writeAll("\n");

    // Not "which shells exist" but which command line the `shell` tool actually
    // runs (DESIGN §8): a model that knows it is under `bash -lc` knows why its
    // profile is sourced, and one told "bash is available" would only be
    // guessing.
    try w.print("shell: {s}\n", .{if (builtin.os.tag == .windows)
        "powershell -NoProfile -NonInteractive -Command"
    else
        "bash -lc"});

    try w.print("date: {s}\n", .{try today(alloc, io)});
}

pub fn renderGit(alloc: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, repo: git.Repo) !void {
    try w.writeAll("# Git\n\n");
    switch (repo) {
        // Not "not a repository": this machine has no git to ask, and saying
        // the checkout is unversioned would be a claim we cannot support.
        .no_git => {
            try w.writeAll("git is not installed here, so nothing is known about version control.\n");
            return;
        },
        // Says what was observed rather than what it usually means. This is
        // almost always "not a repository", but it is also where a timed-out or
        // refusing `rev-parse` lands, and those have told us nothing about the
        // directory — the same reason a hung `status` is not reported as clean.
        .unknown => {
            try w.writeAll("git did not report a working tree here — either this is not a repository, or git could not answer.\n");
            return;
        },
        .inside => {},
    }

    // Each of these keeps "git did not answer" separate from what an empty
    // answer MEANS, because for two of them the empty answer is the
    // interesting one. `git branch --show-current` prints nothing on a
    // detached head; `git status --porcelain` prints nothing when the tree is
    // clean. An `orelse ""` here would report a timed-out git as a detached
    // head and a hung one as a clean tree — the exact false statements the
    // deadline was added to avoid.
    if (git.ask(alloc, io, &.{ "branch", "--show-current" })) |branch| {
        try w.print("branch: {s}\n", .{if (branch.len == 0) "(detached HEAD)" else branch});
    }
    if (git.ask(alloc, io, &.{ "log", "-1", "--format=%h %s" })) |head| {
        if (head.len != 0) try w.print("last commit: {s}\n", .{head});
    }

    const status = git.ask(alloc, io, &.{ "status", "--porcelain" }) orelse {
        try w.writeAll("working tree: unknown (git did not answer)\n");
        return;
    };
    if (status.len == 0) {
        try w.writeAll("working tree: clean\n");
        return;
    }

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len != 0) count += 1;
    }
    try w.print("working tree: {d} changed file(s)\n", .{count});

    var shown: usize = 0;
    lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        const entry = std.mem.trimEnd(u8, line, " \t\r");
        if (entry.len == 0) continue;
        if (shown == status_preview) break;
        try w.print("  {s}\n", .{entry});
        shown += 1;
    }
    if (count > shown) try w.print("  … (+{d} more)\n", .{count - shown});
}

/// The distribution name, on the one platform that publishes it as a file.
/// Elsewhere the OS tag is the whole of what we can say without spawning
/// something, and a wrong version string is worse than no version string.
fn osRelease(alloc: std.mem.Allocator, io: std.Io) !?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", alloc, .limited(64 << 10)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const value = stripPrefix(line, "PRETTY_NAME=") orelse continue;
        return std.mem.trim(u8, value, "\"' \t\r");
    }
    return null;
}

fn stripPrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

/// UTC, and it says so: tcode ports Howard Hinnant's days-to-civil algorithm,
/// but `std.time.epoch` already answers this, and the kernel's own journals
/// timestamp themselves the same way (`journals/journal.zig`).
fn today(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = if (ms < 0) 0 else @intCast(@divFloor(ms, 1000)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2} (UTC)", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}
