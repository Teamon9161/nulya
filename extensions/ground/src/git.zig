//! Everything this package asks git, in one place.
//!
//! Two things come from git rather than from our own code, both deliberately:
//! **which files count** (gitignore is git's algorithm — precedence, negation,
//! nested `.gitignore`, `core.excludesFile`, `.git/info/exclude` — and a second
//! implementation of it would be a second set of answers), and **where the repo
//! root is relative to here**, which `rev-parse` gives without a realpath.
//!
//! Nothing here ever fails a render. Every question has three outcomes: an
//! answer, no git to ask, or no answer — and "no answer" is passed upward as
//! such, never flattened into an empty string, because for two of these
//! questions the empty string is itself a meaningful answer ("detached head",
//! "working tree clean"), and never into a conclusion about the directory,
//! because a question that timed out has told us nothing about it.

const std = @import("std");
const builtin = @import("builtin");

const max_output: usize = 4 << 20;

/// How long any one git command may take before this package stops waiting.
///
/// Not a performance knob — a bound on a hang. Two of the commands here walk
/// the working tree (`ls-files --others` and `status --porcelain`), and that
/// walk is not always finite: on Windows git descends a directory junction as
/// if it were an ordinary directory, so a junction cycle — nested `node_modules`
/// links are the known way to get one — is an endless descent. Without a bound
/// the symptom is the worst kind there is: a session that never starts, with
/// nothing on screen to say why, because this runs before the first message.
/// With one, it becomes the case every caller here already handles — git did
/// not answer, so that section says less.
///
/// Generous on purpose. A healthy render is tens of milliseconds; anything near
/// this is already pathological.
const deadline_ms: u32 = 4000;

/// One `git <args…>` in this process's working directory — the workspace, which
/// is where the host spawns an extension (DESIGN §7.6). Trimmed, since every
/// caller outside this file wants one value; `locate` needs the raw bytes and
/// goes through `whether` for them.
pub fn ask(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) ?[]const u8 {
    const raw = switch (whether(alloc, io, args)) {
        .ok => |text| text,
        else => return null,
    };
    // The END only. `git status --porcelain` puts each entry's two status
    // columns at the start of its line, so trimming the front eats the first
    // entry's — one line out of every listing silently a character narrower
    // than the rest. Nothing here has leading whitespace worth removing.
    return std.mem.trimEnd(u8, raw, " \t\r\n");
}

/// What came back, as a union so that "answered" and "did not" cannot both be
/// half-true at once.
pub const Answer = union(enum) {
    /// git ran, exited zero, and this is what it printed — possibly nothing,
    /// which for two of these questions is the interesting answer.
    ok: []const u8,
    /// git could not be run at all. The one distinction worth keeping, because
    /// "not a git repository" is a claim about the directory and a machine
    /// without git is in no position to make it — `renderGit` reports this in
    /// its own sentence.
    missing,
    /// git ran and did not answer: non-zero exit, the deadline, output past the
    /// cap, a failed wait. Deliberately one case rather than a reason code —
    /// every caller says the same thing for all of them, and a reason nobody
    /// branches on is a field nobody reads.
    failed,
};

fn whether(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) Answer {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(alloc, "git") catch return .failed;
    argv.appendSlice(alloc, args) catch return .failed;
    return bounded(alloc, io, argv.items, deadline_ms);
}

/// Where this working directory sits in its repository.
///
/// A union rather than a record with an `inside` flag: there is no such thing
/// as half of an answer here, and a shape that cannot express one is better
/// than a comment promising nobody will construct one.
pub const Repo = union(enum) {
    /// git could not be run on this machine at all.
    no_git,
    /// git did not report a working tree here. Not the same as "this is not a
    /// repository", and deliberately not narrowed to it: a non-zero `rev-parse`
    /// is usually that, but it is also how a timeout, an unsafe-repository
    /// refusal and an unreadable answer arrive. The common case reads fine as
    /// "no descent, say less"; the rare ones would read as a false claim.
    unknown,
    inside: Inside,

    pub const Inside = struct {
        /// `rev-parse --show-cdup`: the path from here UP to the root, with a
        /// trailing separator (`"../../"`). Empty when this directory is the
        /// root.
        cdup: []const u8,
        /// `rev-parse --show-prefix`: the path from the root DOWN to here, with
        /// a trailing separator (`"crates/foo/"`). Empty at the root. Together
        /// with `cdup` it names every directory between, without resolving a
        /// single absolute path.
        prefix: []const u8,
    };

    pub fn within(self: Repo) ?Inside {
        return switch (self) {
            .inside => |i| i,
            else => null,
        };
    }
};

/// Asked as ONE command, and that is what makes the union honest: two calls
/// could return one answer and one failure, and there would be a state to
/// invent a meaning for. `rev-parse` prints one line per flag — two empty lines
/// at the repository root — so the untrimmed output says which is which and a
/// short answer is simply not an answer.
pub fn locate(alloc: std.mem.Allocator, io: std.Io) Repo {
    const raw = switch (whether(alloc, io, &.{ "rev-parse", "--show-cdup", "--show-prefix" })) {
        .ok => |text| text,
        .missing => return .no_git,
        .failed => return .unknown,
    };

    var lines = std.mem.splitScalar(u8, raw, '\n');
    const cdup = lines.next() orelse return .unknown;
    const prefix = lines.next() orelse return .unknown;
    return .{ .inside = .{
        .cdup = std.mem.trim(u8, cdup, " \t\r"),
        .prefix = std.mem.trim(u8, prefix, " \t\r"),
    } };
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
    }) catch |err| return if (err == error.FileNotFound) .missing else .failed;

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
            return .failed;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        // The bound doing its job, and the reason it exists. Treated as one more
        // way git did not answer, so every caller already handles it.
        else => {
            child.kill(io);
            return .failed;
        },
    }

    const term = child.wait(io) catch return .failed;
    const text = drain.toOwnedSlice(0) catch return .failed;
    drain.deinit();
    draining = false;

    switch (term) {
        .exited => |code| if (code != 0) return .failed,
        else => return .failed,
    }
    return .{ .ok = text };
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

    // `failed`, not `missing` — the program was there, it just never finished,
    // and the difference is what keeps a hung git from being reported as a
    // machine without git.
    try std.testing.expect(answer == .failed);
    // Generous: what would fail here is waiting for the child, not being a
    // second or two slow under load.
    try std.testing.expect(spent < 30_000);
}

test "a program that is not installed is told apart from one that says no" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;

    try std.testing.expect(bounded(alloc, io, &.{"nulya-no-such-program-anywhere"}, 1000) == .missing);
    if (builtin.os.tag == .windows) return;
    // Present, ran, exited non-zero: no answer, and nothing to say about the
    // machine — the distinction `# Git` reports in two different sentences.
    try std.testing.expect(bounded(alloc, io, &.{"false"}, 1000) == .failed);
}

test "an empty answer is an answer: a clean tree is not a failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The distinction the whole file turns on, and the one `orelse ""` at a
    // call site would destroy: `git status --porcelain` says "clean" by
    // printing nothing, and that is not the same as not answering.
    const said = bounded(arena.allocator(), std.testing.io, &.{"true"}, 1000);
    try std.testing.expect(said == .ok);
    try std.testing.expectEqualStrings("", said.ok);
}
