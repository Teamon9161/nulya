//! `ground` — the facts a session starts from, rendered outside the kernel.
//!
//! **What it is.** One tool, `render`, which never appears on a model face
//! (`surface: "internal"`). It writes this workspace's starting facts — the
//! project layout, the project's own instruction files, the environment, the
//! git state — to a file and answers where that file is. A driver calls it just
//! before `session new` and passes the path to `--prompt`:
//!
//! ```
//! nulya ext run ground@<v> render
//! nulya session new --prompt .nulya/scratch/ground/context.md
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

/// Under `.nulya/scratch/`, where this repository already stages things that
/// belong to a run rather than to the source tree — and deliberately not in a
/// store root, which holds installed code (`extensions/agent` renders personas
/// to `.nulya/scratch/agents/` for the same reason).
const out_dir = ".nulya/scratch/ground";
/// Named after the package, not after what it holds: the kernel takes a prompt
/// block's `source` from the file's stem, so this is the word that labels the
/// block for the life of the session and shows up in `session list`. "ground"
/// says which package put it there; "context" would say nothing.
const out_path = out_dir ++ "/ground.md";

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
    write(io, document) catch |err| return fail(io, alloc, err);

    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("prompt");
    try jw.write(out_path);
    try jw.objectField("bytes");
    try jw.write(document.len);
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

fn write(io: std.Io, document: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_dir);
    // Whole-file replacement, not an append: this is a snapshot of right now,
    // and the previous session's snapshot has no claim on it. `session new`
    // reads the bytes and freezes them, so a later overwrite cannot reach back
    // into a session that already started.
    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, document);
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
