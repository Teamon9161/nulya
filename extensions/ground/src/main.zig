//! `ground` — the facts a session starts from, rendered outside the kernel.
//!
//! **What it is.** One tool, `render`, which never appears on a model face
//! (`surface: "internal"`). It writes this workspace's starting facts — the
//! project layout, the project's own instruction files, the environment, the
//! git state — to a file and answers where that file is. A driver calls it just
//! before `session new` and passes the path to `--prompt`:
//!
//! ```
//! nulya ext run ground@<v> render      → {"prompt": ".nulya/scratch/ground/<n>/ground.md"}
//! nulya session new --prompt <that path>
//! ```
//!
//! **Why `--prompt` and not a contributed system prompt.** A contributed prompt
//! is a file frozen inside an extension version: the same bytes in every
//! session, on every machine. These facts are the opposite — today's date,
//! this checkout's branch, this directory's layout — and their lifetime is
//! exactly one session. That is the line `docs/goals/session-prompt.md` draws,
//! and `--prompt` is the side of it they fall on. It also puts them where they
//! belong for cost: frozen into the header, at the front of the cached prefix,
//! paid for once rather than rediscovered by the model's first few tool calls.
//!
//! **Why the package contributes nothing.** No `apply`, no system prompt, no
//! model-facing tool: installing `ground` changes no session by itself. It is a
//! renderer, and the driver decides whether a session gets what it rendered —
//! the same shape as `extensions/agent`'s `render` and `extensions/compact`.
//!
//! **Facts here, discipline in `extensions/coding`.** Two packages because they
//! are two decisions: somebody may want to be told where they are without being
//! told how to work, or already have their own working discipline. Nothing in
//! this file is advice.

const std = @import("std");
const facts = @import("facts.zig");
const git = @import("git.zig");
const instructions = @import("instructions.zig");
const layout = @import("layout.zig");

/// A directory per invocation, holding a file with a fixed name, under
/// `.nulya/scratch/` — where this repository already stages what belongs to a
/// run rather than to the source tree, and deliberately not in a store root,
/// which holds installed code.
///
/// The name is fixed because the kernel takes a prompt block's `source` from
/// the file's stem, so `ground.md` is the word that labels the block for the
/// life of the session and shows up in `session list` — "ground" says which
/// package put it there, "context" would say nothing.
///
/// The DIRECTORY is unique because the file is read by somebody else, later:
/// this process writes it and answers a path, and `session new --prompt` opens
/// it afterwards. One shared name means two sessions starting at once in the
/// same workspace race — the second render overwrites the first, and the first
/// session freezes facts that were measured for the second. A workspace with
/// two front ends on it is a thing nulya supports, so this is not hypothetical.
const out_root = ".nulya/scratch/ground";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // One arena for the whole call: this process renders one document, writes
    // one file and prints one line.
    const alloc = init.arena.allocator();

    // The wire is `plain` (DESIGN §7.3): stdin is this call's arguments as one
    // JSON object. This tool takes none — everything it reports comes from the
    // working directory it was spawned in — but the stream is still drained, so
    // a caller that sent `{}` is not left writing into a closed pipe.
    var in_buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    _ = reader.interface.allocRemaining(alloc, .limited(1 << 20)) catch {};

    const document = render(alloc, io) catch |err| return fail(io, alloc, err);
    const written_at = write(alloc, io, document) catch |err| return fail(io, alloc, err);

    // One field, because one is all a caller uses: the path. A byte count rode
    // along at first and nothing ever read it — an interface nobody consumes is
    // a promise to keep it working for no one.
    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("prompt");
    try jw.write(written_at);
    try jw.endObject();
    try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
}

/// Sections in the order tcode's startup context puts them: what the project
/// is, what it asks of you, then where you are standing. A section with nothing
/// to report writes no heading — an empty "# Project instructions" would read
/// as "this project has no conventions", which is a claim, not an absence.
fn render(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    const repo = git.locate(alloc, io);

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;

    if (try layout.render(alloc, io, w, repo)) try w.writeAll("\n");
    if (try instructions.render(alloc, io, w, repo)) try w.writeAll("\n");
    try facts.renderEnvironment(alloc, io, w);
    try w.writeAll("\n");
    try facts.renderGit(alloc, io, w, repo);

    return out.toOwnedSlice();
}

/// Write the document into a directory this invocation owns, and answer where.
///
/// Exclusive creation is what makes it ours: whoever wins the name gets it, and
/// a loser simply tries the next one. The counter starts from the clock so two
/// processes are unlikely to collide at all, and correctness does not rest on
/// that — it rests on `O_EXCL`.
fn write(alloc: std.mem.Allocator, io: std.Io, document: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_root);

    var n: u64 = @bitCast(std.Io.Timestamp.now(io, .real).toMilliseconds());
    var tries: usize = 0;
    while (tries < 1000) : ({
        tries += 1;
        n +%= 1;
    }) {
        const dir = try std.fmt.allocPrint(alloc, "{s}/{x}", .{ out_root, n });
        cwd.createDir(io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        const path = try std.fmt.allocPrint(alloc, "{s}/ground.md", .{dir});
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, document);
        return path;
    }
    return error.NoFreeGroundDirectory;
}

/// On the plain wire stderr is the failure message and the exit code is what
/// makes it a failure (DESIGN §7.3). A driver that cannot ground a session
/// should still be able to start one, so the message says which half broke.
fn fail(io: std.Io, alloc: std.mem.Allocator, err: anyerror) noreturn {
    const message = std.fmt.allocPrint(
        alloc,
        "ground could not render this workspace's context: {s}\n",
        .{@errorName(err)},
    ) catch "ground could not render this workspace's context\n";
    std.Io.File.stderr().writeStreamingAll(io, message) catch {};
    std.process.exit(1);
}

test {
    _ = facts;
    _ = git;
    _ = instructions;
    _ = layout;
}
