//! Managed Zig toolchain.
//!
//! The host-platform Zig release archive is `@embedFile`'d into the nulya
//! binary and extracted on first use — one host Zig cross-compiles to every
//! target. The AI never calls `zig build` directly; nulya alone fixes zig
//! version / optimize / target / cache.
//!
//! Embedding is gated behind `-Dembed-toolchain`, so with the option off there
//! is nothing to extract — the directory is still the pinned compiler's home,
//! and a build uses whatever is already there. Only archive absent AND
//! directory empty gives `error.ToolchainNotEmbedded`.

const std = @import("std");
const builtin = @import("builtin");

/// The single Zig version nulya builds every extension with.
pub const pinned_version = "0.16.0";

pub const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

/// The one path the extraction and a person unpacking the archive by hand must
/// agree on.
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

/// An absolute path to the pinned `zig` (usable as `argv[0]` whatever the
/// child's cwd), extracted from the embedded archive when this binary carries
/// one. Idempotent: a completed extraction is marked with a `.ok` file.
///
/// A binary without the archive still answers from that directory when a whole
/// toolchain is already in it (either layout `zigExeAbsPath` accepts).
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

    // Clear any partial dir, extract, and only THEN write the marker, so an
    // interrupted run re-extracts.
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
    // `strip_components = 1` drops the leading `zig-<target>-<ver>/` so the
    // executable lands directly at `<dest>/zig`.
    try std.tar.extract(io, dest, &xz.reader, .{ .strip_components = 1 });
}

fn extractZip(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir, rel: []const u8, dest: std.Io.Dir) !void {
    // std.zip needs a seekable reader, so spill the embedded bytes to a temp
    // file first. zip has no strip_components, so the leading
    // `zig-<target>-<ver>/` is resolved later by `zigExeAbsPath`.
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

/// Absolute path of the extracted `zig`, in either the flattened (tar strip) or
/// nested (`zig-*/`) layout.
fn zigExeAbsPath(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir, rel: []const u8) ![]u8 {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = data_dir.realPath(io, &real_buf) catch return error.ZigExeNotFound;
    const base = real_buf[0..base_len];

    // Flattened: <data>/<rel>/zig[.exe]
    {
        const flat = try std.fs.path.join(alloc, &.{ rel, exe_name });
        defer alloc.free(flat);
        if (data_dir.access(io, flat, .{})) |_| {
            return std.fs.path.join(alloc, &.{ base, flat });
        } else |_| {}
    }

    // Nested: <data>/<rel>/zig-<target>-<ver>/zig[.exe]
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

test "the pinned version is a non-empty compile-time constant" {
    try std.testing.expect(pinned_version.len != 0);
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
