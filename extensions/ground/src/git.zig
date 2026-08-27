//! Everything this package asks git, in one place.
//!
//! Two things come from git rather than from our own code, both deliberately:
//! **which files count** (gitignore is git's algorithm — precedence, negation,
//! nested `.gitignore`, `core.excludesFile`, `.git/info/exclude` — and a second
//! implementation of it would be a second set of answers), and **where the repo
//! root is relative to here**, which `rev-parse` gives without a realpath.

const std = @import("std");
const builtin = @import("builtin");

const max_output: usize = 4 << 20;

/// How long any one git command may take before this package stops waiting.
///
/// Not a performance knob — a bound on a hang. Two of the commands here walk
/// the working tree (`ls-files --others` and `status --porcelain`), and that
/// walk is not always finite: on Windows git descends a directory junction as
/// if it were an ordinary directory, so a junction cycle — nested `node_modules`
/// links are the known way to get one — is an endless descent. Without a
/// bound the symptom is the worst kind there is: a session that never starts,
/// with nothing on screen to say why, because this runs before the first
/// message. With one, it becomes the case this file already handles everywhere
/// else — git did not answer, so that section says less.
///
/// Generous on purpose. A healthy render is tens of milliseconds; anything near
/// this is already pathological.
const deadline_ms: u32 = 4000;

/// One `git <args…>` in this process's working directory — the workspace, which
/// is where the host spawns an extension (DESIGN §7.6).
///
/// Null covers every way this can fail to answer, and none of them is an error
/// here: a session still has to start, and a section that could not get its
/// answer simply says less. Nothing in this package retries, and nothing fails
/// because git did.
pub fn ask(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) ?[]const u8 {
    return askWhy(alloc, io, args).answer;
}

pub const Answer = struct {
    answer: ?[]const u8 = null,
    /// The one distinction worth keeping: git could not be run at all, as
    /// opposed to git running and saying no. "Not a git repository" is a claim
    /// about the directory, and a machine without git is in no position to make
    /// it — the sections below report the two differently.
    missing: bool = false,
};

pub fn askWhy(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) Answer {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(alloc, "git") catch return .{};
    argv.appendSlice(alloc, args) catch return .{};
    return bounded(alloc, io, argv.items, deadline_ms);
}

/// Spawn, drain with a deadline, read the exit code — the whole of how this
/// package talks to another program.
///
/// `std.process.run` would be shorter and has no deadline, which is the one
/// thing this needs. The output is drained WHILE the child runs rather than
/// after it: `ls-files` on a large repository is megabytes, and waiting first
/// would deadlock on a full pipe long before the deadline had anything to say.
///
/// Killing the direct child is enough here, so none of `environment/tree.zig`'s
/// process-group and job-object machinery is repeated: git spawns no helper
/// when its stdout is a pipe (that is exactly when it does not start a pager),
/// so there is no grandchild left holding the write end.
fn bounded(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8, ms: u32) Answer {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        // Dropped rather than captured: this package never reports what git
        // said on stderr, and a pipe nobody drains is a process that blocks
        // once it fills.
        .stderr = .ignore,
        .stdout = .pipe,
    }) catch |err| return .{ .missing = err == error.FileNotFound };

    var streams: std.Io.File.MultiReader.Buffer(1) = undefined;
    var drain: std.Io.File.MultiReader = undefined;
    drain.init(alloc, io, streams.toStreams(), &.{child.stdout.?});
    var draining = true;
    defer if (draining) drain.deinit();

    const out = drain.reader(0);
    const timeout: std.Io.Timeout = .{ .deadline = std.Io.Clock.Timestamp.fromNow(
        io,
        .{ .clock = .awake, .raw = .fromMilliseconds(ms) },
    ) };

    while (drain.fill(64, timeout)) |_| {
        if (out.buffered().len > max_output) {
            child.kill(io);
            return .{};
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        // The bound doing its job, and the reason it exists. Treated as one more
        // way git did not answer, so every caller already handles it.
        else => {
            child.kill(io);
            return .{};
        },
    }

    const term = child.wait(io) catch return .{};
    const text = drain.toOwnedSlice(0) catch return .{};
    drain.deinit();
    draining = false;

    switch (term) {
        .exited => |code| if (code != 0) return .{},
        else => return .{},
    }
    return .{ .answer = std.mem.trim(u8, text, " \t\r\n") };
}

test "a command that would never finish is given up on, not waited for" {
    // POSIX-only because it needs a program that hangs on purpose; what is being
    // pinned is the deadline, and the deadline is not platform-specific.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    const started = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const answer = bounded(arena.allocator(), io, &.{ "sleep", "60" }, 150);
    const spent = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started;

    // No answer, not `missing` — the program was there, it just never finished.
    try std.testing.expect(answer.answer == null);
    try std.testing.expect(!answer.missing);
    // Generous: what would fail here is waiting for the child, not being a
    // second or two slow under load.
    try std.testing.expect(spent < 30_000);
}

test "a program that is not installed is told apart from one that says no" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;

    try std.testing.expect(bounded(alloc, io, &.{"nulya-no-such-program-anywhere"}, 1000).missing);
    if (builtin.os.tag == .windows) return;
    // Present, ran, exited non-zero: no answer, and nothing to say about the
    // machine — the distinction `# Git` reports in two different sentences.
    const refused = bounded(alloc, io, &.{ "false" }, 1000);
    try std.testing.expect(refused.answer == null and !refused.missing);
}

/// Where this working directory sits in its repository.
pub const Repo = struct {
    inside: bool = false,
    /// git could not be run on this machine. Distinct from `inside == false`,
    /// which is git's own answer about this directory.
    no_git: bool = false,
    /// `rev-parse --show-cdup`: the path from here UP to the root, with a
    /// trailing separator (`"../../"`). Empty when this directory is the root.
    cdup: []const u8 = "",
    /// `rev-parse --show-prefix`: the path from the root DOWN to here, with a
    /// trailing separator (`"crates/foo/"`). Empty when this directory is the
    /// root. Together with `cdup` it names every intermediate directory without
    /// resolving a single absolute path.
    prefix: []const u8 = "",
};

pub fn locate(alloc: std.mem.Allocator, io: std.Io) Repo {
    // Asked as two commands rather than one: at the repository root both answers
    // are the empty string, and one invocation would return them as a single
    // blank line with no way to tell "root" from "git said nothing".
    const cdup = askWhy(alloc, io, &.{ "rev-parse", "--show-cdup" });
    const found = cdup.answer orelse return .{ .no_git = cdup.missing };
    // The first answer already settled that this IS a working tree, so a second
    // one that does not come back cannot unsettle it: the descent simply stops
    // at this directory rather than the whole thing turning into "not a
    // repository", which by then would be a claim we know to be false.
    const prefix = ask(alloc, io, &.{ "rev-parse", "--show-prefix" }) orelse "";
    return .{ .inside = true, .cdup = found, .prefix = prefix };
}
