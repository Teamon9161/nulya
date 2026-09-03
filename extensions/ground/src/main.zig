//! `ground` — the facts a session starts from, rendered outside the kernel.
//!
//! One tool, `render`, `surface: "internal"` (never on a model face). It
//! writes this workspace's starting facts — project layout, the project's own
//! instruction files, the environment, git state — to a file and answers
//! where that file is. A driver calls it just before `session new` and passes
//! the path to `--prompt`, which freezes it into the session header:
//!
//! ```
//! nulya ext run ground@<v> render      → {"prompt": ".nulya/scratch/ground/<n>/ground.md"}
//! nulya session new --prompt <that path>
//! ```
//!
//! These facts (today's date, this branch, this directory) have a lifetime of
//! exactly one session, unlike a contributed system prompt — the same bytes
//! frozen into every session an extension version serves. The package itself
//! contributes nothing: installing it changes no session by itself.

const std = @import("std");
const facts = @import("facts.zig");
const git = @import("git.zig");
const instructions = @import("instructions.zig");
const layout = @import("layout.zig");

/// A directory per invocation, holding a file with a fixed name, under
/// `.nulya/scratch/` (not a store root, which holds installed code).
///
/// The file name is fixed because the kernel takes a prompt block's `source`
/// from the file's stem, so `ground.md` labels the block in `session list` —
/// "ground" says which package put it there.
///
/// The directory is unique per call because the file is read later by a
/// separate process (`session new --prompt`): a shared name would let two
/// sessions starting at once in the same workspace race, with the second
/// render overwriting the first and the first session freezing facts that
/// were measured for the second.
const out_root = ".nulya/scratch/ground";

/// Hard ceiling on the ASSEMBLED document, independent of any one section's
/// own budget (`instructions.zig`'s 16 KB per file, `git.zig`'s 4 MiB raw
/// capture). A section budget only bounds what that section quotes, not what
/// git itself hands back around the quote: `facts.zig`'s commit subject is
/// clipped with git's own `%<(240,trunc)`, which cuts at DISPLAY COLUMNS, not
/// bytes — a subject built from zero-width combining marks defeats any
/// byte-per-column estimate. Measured against real `git log` (2.50.1), 240
/// columns of combining marks alone printed 2.2 MB. Kept comfortably under
/// the kernel's own `prompt.max_system_prompt_bytes` (2 MiB) so this backstop
/// trips before that one has a reason to.
const max_document_bytes: usize = 1 << 20;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    // Stdin carries this call's arguments as a JSON object (the plain wire).
    // This tool takes none — everything it reports comes from the working
    // directory it was spawned in — but the stream is still drained, so a
    // caller that sent `{}` is not left writing into a closed pipe.
    var in_buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    _ = reader.interface.allocRemaining(alloc, .limited(1 << 20)) catch {};

    var host = try init.minimal.environ.createMap(alloc);
    const document = render(alloc, io, &host) catch |err| return fail(io, alloc, err);
    const written_at = write(alloc, io, document) catch |err| return fail(io, alloc, err);

    var out: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("prompt");
    try jw.write(written_at);
    try jw.endObject();
    try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
}

/// Section order: what the project is, what it asks of you, then where you
/// are standing. A section with nothing to report writes no heading — an
/// empty "# Project instructions" would read as "this project has no
/// conventions", which is a claim, not an absence.
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
    // `instructions.zig`'s candidate check). `session new --prompt` refuses
    // anything that is not valid UTF-8 (`std.json.Stringify` would otherwise
    // write it as an array of numbers instead of a string, breaking the
    // session header's format) or over its 2 MiB size limit, so failing — or
    // clipping — HERE means `render` reports the outcome itself instead of
    // reporting success and letting the failure land on the next command.
    const document = try clipToBudget(alloc, try out.toOwnedSlice());
    if (!std.unicode.utf8ValidateSlice(document)) return error.InvalidUtf8;
    return document;
}

/// Cut an assembled document down to `max_document_bytes`, UTF-8-safe, with a
/// marker saying so.
///
/// The marker is measured BEFORE the prefix is cut, and the cut uses what is
/// left over — not measured after appending it to a `max_document_bytes`-sized
/// prefix. The latter would make the true ceiling on what `render` returns be
/// `max_document_bytes` plus however many bytes the marker happens to be,
/// rather than a real ceiling.
fn clipToBudget(alloc: std.mem.Allocator, document: []const u8) ![]const u8 {
    if (document.len <= max_document_bytes) return document;
    var marker_buf: [256]u8 = undefined;
    const marker = std.fmt.bufPrint(
        &marker_buf,
        "\n\n[ground: this document was {d} bytes; the render budget is {d}, so it was cut here.]\n",
        .{ document.len, max_document_bytes },
    ) catch unreachable; // two usize values in decimal, comfortably under 256 bytes
    const end = instructions.boundaryAtOrBefore(document, max_document_bytes -| marker.len);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ document[0..end], marker });
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

/// On the plain wire, stderr is the failure message and the exit code is what
/// makes it a failure. A driver that cannot ground a session should still be
/// able to start one, so the message says which half broke.
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

    // A real measurement against git 2.50.1: a commit subject built from
    // ~1.1M zero-width combining marks made `%<(240,trunc)` print 2.2 MB, not
    // the ~960-byte worst case a bytes-per-column estimate predicts. This
    // document-level budget is what stands between that and `render`
    // reporting success on something `session new --prompt` (2 MiB) refuses.
    const huge = try alloc.alloc(u8, 3 << 20);
    @memset(huge, 'x');
    const clipped = try clipToBudget(alloc, huge);
    try std.testing.expect(clipped.len < huge.len);
    // A HARD ceiling: the marker is measured before the cut, not appended
    // after it, so what `clipToBudget` returns is never larger than what it
    // names — not "the budget plus however many bytes a marker happens to be".
    try std.testing.expect(clipped.len <= max_document_bytes);
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
