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

/// Hard ceiling on the ASSEMBLED document, independent of any one section's
/// own budget (`instructions.zig`'s 16 KB per file, `git.zig`'s 4 MiB raw
/// capture). A section budget only bounds what that section quotes, not what
/// git itself hands back around the quote: `facts.zig`'s commit subject is
/// clipped with git's own `%<(240,trunc)`, which cuts at DISPLAY COLUMNS, and
/// a subject built from zero-width combining marks can make columns-to-bytes
/// unbounded — measured against a real `git log` (2.50.1), 240 columns of
/// combining marks alone printed 2.2 MB, not the ~960 bytes a byte-per-column
/// estimate predicts. This is Ground's own render budget, not a copy of the
/// kernel's `prompt.max_system_prompt_bytes` (2 MiB) — comfortably under it
/// rather than equal to it, so this backstop trips before that one ever has
/// a reason to.
const max_document_bytes: usize = 1 << 20;

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

    var host = try init.minimal.environ.createMap(alloc);
    const document = render(alloc, io, &host) catch |err| return fail(io, alloc, err);
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
fn render(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    const repo = git.locate(alloc, io);

    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;

    if (try layout.render(alloc, io, w, repo)) try w.writeAll("\n");
    if (try instructions.render(alloc, io, w, repo)) try w.writeAll("\n");
    try facts.renderEnvironment(alloc, io, w, env);
    try w.writeAll("\n");
    try facts.renderGit(alloc, io, w, repo);

    // Final backstops, not a substitute for the sources that skip a bad name or
    // a bad file instead of quoting it (`layout.zig`'s `skip`,
    // `instructions.zig`'s candidate check): every section funnels into this one
    // document, and this is the one place that can say the whole thing is fit
    // to freeze. `session new --prompt` refuses anything that is not valid
    // UTF-8 (BUGS #22 — `std.json.Stringify` writes it as an array of numbers,
    // not a string, and the header stops being the shape §3 promises) or over
    // its 2 MiB size limit, so failing — or clipping — HERE means `render`
    // reports the outcome instead of reporting success and letting it land on
    // the next command instead.
    const document = try clipToBudget(alloc, try out.toOwnedSlice());
    if (!std.unicode.utf8ValidateSlice(document)) return error.InvalidUtf8;
    return document;
}

/// Cut an assembled document down to `max_document_bytes`, UTF-8-safe, with a
/// marker saying so. Pulled out of `render` so the invariant can be tested
/// against a document git never had to be coaxed into producing.
fn clipToBudget(alloc: std.mem.Allocator, document: []const u8) ![]const u8 {
    if (document.len <= max_document_bytes) return document;
    const end = instructions.boundaryAtOrBefore(document, max_document_bytes);
    return std.fmt.allocPrint(
        alloc,
        "{s}\n\n[ground: this document was {d} bytes; the render budget is {d}, so it was cut here.]\n",
        .{ document[0..end], document.len, max_document_bytes },
    );
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

test "a document within budget passes through untouched" {
    const alloc = std.testing.allocator;
    const small = "hello world\n";
    const out = try clipToBudget(alloc, small);
    try std.testing.expectEqualStrings(small, out);
}

test "an oversized document is clipped to the budget, not merely UTF-8 validated" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Ported from a real measurement against git 2.50.1: a commit subject
    // built from ~1.1M zero-width combining marks made `%<(240,trunc)` print
    // 2.2 MB, not the ~960-byte worst case a bytes-per-column estimate
    // predicts (`docs/goals/review-fork-remote.md`). This document-level
    // budget is what stands between that and `render` reporting success on
    // something `session new --prompt` (2 MiB) then refuses.
    const huge = try alloc.alloc(u8, 3 << 20);
    @memset(huge, 'x');
    const clipped = try clipToBudget(alloc, huge);
    try std.testing.expect(clipped.len < huge.len);
    try std.testing.expect(clipped.len <= max_document_bytes + 200);
    try std.testing.expect(std.mem.indexOf(u8, clipped, "cut here") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped));
}

test "the clip never splits a multi-byte character even when the cut lands inside one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A multi-byte character straddling the exact budget boundary — the case
    // `boundaryAtOrBefore` retreats for.
    var huge: std.ArrayList(u8) = .empty;
    while (huge.items.len < max_document_bytes + 100) try huge.appendSlice(alloc, "中文字符ab");
    const clipped = try clipToBudget(alloc, huge.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(clipped));
}
