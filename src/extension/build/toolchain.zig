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
//! to an empty stub and `ensureExtracted` returns `error.ToolchainNotEmbedded`;
//! the shipped binary and the e2e build set the option on.

const std = @import("std");
const builtin = @import("builtin");

/// The single Zig version nulya builds every extension with (DESIGN §10).
pub const pinned_version = "0.16.0";

/// Host target triple used in the reproducible-build version hash (DESIGN §7.4).
pub const host_target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

pub const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

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

/// Ensure the pinned Zig is extracted under `data_dir` and return an ABSOLUTE
/// path to its `zig` executable (usable as `argv[0]` regardless of the child's
/// cwd). Idempotent: a completed extraction is marked with a `.ok` file and
/// skipped on subsequent calls.
///
/// NOTE: the extraction path is validated only via the manual embedded build
/// (`-Dembed-toolchain`), since unit tests run with embedding off.
pub fn ensureExtracted(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir) ![]u8 {
    if (!isEmbedded()) return error.ToolchainNotEmbedded;

    const rel = try std.fs.path.join(alloc, &.{ "toolchains", "zig", pinned_version });
    defer alloc.free(rel);
    const ok_marker = try std.fs.path.join(alloc, &.{ rel, ".ok" });
    defer alloc.free(ok_marker);

    if (data_dir.access(io, ok_marker, .{})) |_| {
        return try zigExeAbsPath(alloc, io, data_dir, rel);
    } else |_| {}

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

test "ensureExtracted reports a clear error when the toolchain is not embedded" {
    if (isEmbedded()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.ToolchainNotEmbedded,
        ensureExtracted(std.testing.allocator, std.testing.io, tmp.dir),
    );
}
