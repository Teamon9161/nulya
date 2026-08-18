//! Managed Zig toolchain (DESIGN §10).
//!
//! The host-platform Zig release archive is `@embedFile`'d into the nulya
//! binary and extracted on first use. Nulya is already platform-specific, so a
//! single embedded host archive suffices — and one host Zig cross-compiles to
//! every target, so this also buys cross-platform extension builds for free.
//!
//! The AI never calls `zig build` directly: it calls `nulya ext build`, and
//! nulya alone fixes zig version / optimize / target / cache, so builds are
//! reproducible (DESIGN §10, §14).
//!
//! Embedding is gated behind the `-Dembed-toolchain` build option so day-to-day
//! `zig build test` stays light. When the option is off, `@embedFile` resolves
//! to an empty stub and there is nothing to extract — but the directory the
//! extraction would land in is still the pinned compiler's home, so a build
//! without the archive USES what is already there: a release build extracted
//! it earlier, or somebody unpacked (or junctioned) a 0.16.0 install into it.
//! Only when the archive is absent AND the directory is empty does
//! `ensureExtracted` return `error.ToolchainNotEmbedded`; the shipped binary and
//! the e2e build set the option on.

const std = @import("std");
const builtin = @import("builtin");

/// The single Zig version nulya builds every extension with (DESIGN §10).
pub const pinned_version = "0.16.0";

/// Host target triple used in the reproducible-build version hash (DESIGN §7.4).
pub const host_target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

pub const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

/// Where the pinned compiler lives under nulya's data directory — the one path
/// that both the extraction and a person unpacking the release archive by hand
/// have to agree on, so it is spelled once and printed in every "needs zig"
/// sentence.
pub const managed_rel = "toolchains" ++ std.fs.path.sep_str ++ "zig" ++ std.fs.path.sep_str ++ pinned_version;

/// The embedded archive. Empty when built without `-Dembed-toolchain`.
const embedded_archive = @embedFile("zig_archive");

/// Windows ships a `.zip`; other hosts a `.tar.xz`.
const archive_is_zip = builtin.os.tag == .windows;

pub const EnsureError = error{
    ToolchainNotEmbedded,
    ZigExeNotFound,
} || std.mem.Allocator.Error;

pub fn isEmbedded() bool {
    return embedded_archive.len != 0;
}

/// The pinned Zig under `data_dir/managed_rel`, as an ABSOLUTE path to its
/// `zig` executable (usable as `argv[0]` regardless of the child's cwd) —
/// extracted from the embedded archive when this binary carries one and the
/// directory does not hold it yet. Idempotent: a completed extraction is marked
/// with a `.ok` file and skipped on subsequent calls.
///
/// A binary WITHOUT the archive still answers from that directory when a whole
/// toolchain is already in it (either layout `zigExeAbsPath` accepts). The
/// directory is nulya's own and the version is pinned, so who put the bytes
/// there — an earlier release build, or a person following the "needs zig"
/// sentence — does not change what they are; refusing them would send a dev
/// build to an unpinned PATH zig while the pinned one sits right there.
///
/// NOTE: the extraction path is validated only via the manual embedded build
/// (`-Dembed-toolchain`), since unit tests run with embedding off.
pub fn ensureExtracted(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir) ![]u8 {
    const rel = managed_rel;
    const ok_marker = rel ++ std.fs.path.sep_str ++ ".ok";

    if (data_dir.access(io, ok_marker, .{})) |_| {
        return try zigExeAbsPath(alloc, io, data_dir, rel);
    } else |_| {}

    if (!isEmbedded()) {
        // Nothing to extract; whatever is in the directory is all there is.
        return zigExeAbsPath(alloc, io, data_dir, rel) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ToolchainNotEmbedded,
        };
    }

    // Fresh (or partial) extraction. Clear any partial dir, then extract into
    // place and only then write the marker so an interrupted run re-extracts.
    data_dir.deleteTree(io, rel) catch {};
    try data_dir.createDirPath(io, rel);
    var dest = try data_dir.openDir(io, rel, .{ .iterate = true });
    defer dest.close(io);

    if (archive_is_zip) {
        try extractZip(alloc, io, data_dir, rel, dest);
    } else {
        try extractTarXz(alloc, io, dest);
    }

    try data_dir.writeFile(io, .{ .sub_path = ok_marker, .data = "" });
    return try zigExeAbsPath(alloc, io, data_dir, rel);
}

fn extractTarXz(alloc: std.mem.Allocator, io: std.Io, dest: std.Io.Dir) !void {
    var input = std.Io.Reader.fixed(embedded_archive);
    const window = try alloc.alloc(u8, 1 << 20);
    defer alloc.free(window);
    var xz = try std.compress.xz.Decompress.init(&input, alloc, window);
    // `strip_components = 1` drops the leading `zig-<target>-<ver>/` directory so
    // the executable lands directly at `<dest>/zig`.
    try std.tar.extract(io, dest, &xz.reader, .{ .strip_components = 1 });
}

fn extractZip(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir, rel: []const u8, dest: std.Io.Dir) !void {
    // std.zip needs a seekable reader, so spill the embedded bytes to a temp file
    // first, then extract from it. zip has no strip_components, so the archive's
    // leading `zig-<target>-<ver>/` directory is resolved later by `zigExeAbsPath`.
    const tmp_rel = try std.fs.path.join(alloc, &.{ rel, ".archive.zip" });
    defer alloc.free(tmp_rel);
    try data_dir.writeFile(io, .{ .sub_path = tmp_rel, .data = embedded_archive });
    defer data_dir.deleteFile(io, tmp_rel) catch {};

    var file = try data_dir.openFile(io, tmp_rel, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    try std.zip.extract(dest, &fr, .{ .allow_backslashes = true });
}

/// Resolve the absolute path of the extracted `zig` executable, handling both
/// the flattened (tar strip) and nested (`zig-*/`) layouts.
fn zigExeAbsPath(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir, rel: []const u8) ![]u8 {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = data_dir.realPath(io, &real_buf) catch return error.ZigExeNotFound;
    const base = real_buf[0..base_len];

    // Flattened layout: <data>/<rel>/zig[.exe]
    {
        const flat = try std.fs.path.join(alloc, &.{ rel, exe_name });
        defer alloc.free(flat);
        if (data_dir.access(io, flat, .{})) |_| {
            return std.fs.path.join(alloc, &.{ base, flat });
        } else |_| {}
    }

    // Nested layout: <data>/<rel>/zig-<target>-<ver>/zig[.exe]
    var dir = data_dir.openDir(io, rel, .{ .iterate = true }) catch return error.ZigExeNotFound;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "zig")) continue;
        const nested = try std.fs.path.join(alloc, &.{ rel, entry.name, exe_name });
        defer alloc.free(nested);
        if (data_dir.access(io, nested, .{})) |_| {
            return std.fs.path.join(alloc, &.{ base, nested });
        } else |_| {}
    }
    return error.ZigExeNotFound;
}

test "host target and pinned version are non-empty compile-time constants" {
    try std.testing.expect(pinned_version.len != 0);
    try std.testing.expect(host_target.len != 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, host_target, '-') != null);
}

test "ensureExtracted reports a clear error when nothing is embedded and nothing is there" {
    if (isEmbedded()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.ToolchainNotEmbedded,
        ensureExtracted(std.testing.allocator, std.testing.io, tmp.dir),
    );
}

test "ensureExtracted uses a toolchain already in the managed directory when nothing is embedded" {
    if (isEmbedded()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Flat layout: <data>/toolchains/zig/<ver>/zig — a tar strip, or a person
    // copying an install's contents straight in.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, managed_rel);
        try tmp.dir.writeFile(io, .{ .sub_path = managed_rel ++ std.fs.path.sep_str ++ exe_name, .data = "" });
        const found = try ensureExtracted(alloc, io, tmp.dir);
        defer alloc.free(found);
        try std.testing.expect(std.fs.path.isAbsolute(found));
        try std.testing.expect(std.mem.endsWith(u8, found, managed_rel ++ std.fs.path.sep_str ++ exe_name));
    }
    // Nested layout: the release archive unpacked as-is, `zig-<target>-<ver>/`
    // and all.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const nested = managed_rel ++ std.fs.path.sep_str ++ "zig-x86_64-anyos-" ++ pinned_version;
        try tmp.dir.createDirPath(io, nested);
        try tmp.dir.writeFile(io, .{ .sub_path = nested ++ std.fs.path.sep_str ++ exe_name, .data = "" });
        const found = try ensureExtracted(alloc, io, tmp.dir);
        defer alloc.free(found);
        try std.testing.expect(std.mem.endsWith(u8, found, nested ++ std.fs.path.sep_str ++ exe_name));
    }
}
