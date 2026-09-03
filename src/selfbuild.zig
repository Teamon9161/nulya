//! Writing this binary's own checkout back out, so it can build a copy of
//! itself for a machine it is not running on.
//!
//! `source.zig` holds `src/**` and `bundled.zig` holds `extensions/**`; this
//! adds what is left — the build script, the manifest, the default config and
//! the vendored dependency — and puts the three together as a directory `zig
//! build` accepts. Nothing here compiles: choosing a compiler and a place to
//! keep the result are the shell layer's decisions.
//!
//! **`build_id` is the point.** Two nulyas built from the same bytes write the
//! same tree and carry the same id, so a cross-built agent can be cached under
//! it, recognized over a wire, and replaced when the source it came from moved
//! — without anyone having to remember to.

const std = @import("std");
const embed = @import("build_embed");
const source = @import("source.zig");
const bundled = @import("bundled.zig");

/// The build inputs neither of the other two embeds carries, keyed by their
/// path relative to the checkout root.
pub const files: []const embed.Entry = &embed.files;

/// Write a complete checkout into `dir` — every file the three embeds hold, at
/// the path it had in the repository.
///
/// What lands is enough to CONFIGURE and run the default step; `tests/`, `tui/`
/// and `docs/` are not aboard, so `zig build test` there would fail on a missing
/// root source. That is the trade this makes deliberately: a remote agent needs
/// the binary, not the suite that proves it.
pub fn materialize(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    for (files) |f| try writeAt(alloc, io, dir, "", f.path, f.bytes);
    for (source.files) |f| try writeAt(alloc, io, dir, "src/", f.path, f.bytes);
    for (bundled.files) |f| try writeAt(alloc, io, dir, "extensions/", f.path, f.bytes);
}

fn writeAt(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    rel: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, rel });
    defer alloc.free(path);
    if (std.fs.path.dirnamePosix(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// This binary's checkout, named — a hex digest build.zig took over the very
/// bytes the three embeds carry, paths included.
///
/// A copy cross-built from `materialize`'s output hashes the identical tree, so
/// it reports the SAME id: that is what lets a far agent be recognized as this
/// build's own rather than merely "some nulya".
pub const build_id: []const u8 = @import("config_options").build_id;

test "the written tree holds everything build.zig reads to configure a build" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try materialize(alloc, io, tmp.dir);

    // Every path build.zig itself names or walks. A build that cannot see one
    // of these does not fail late with a link error — it fails at configure
    // time, on the machine of whoever was waiting for a remote session.
    for ([_][]const u8{
        "build.zig",
        "build.zig.zon",
        "default.toml",
        "src/main.zig",
        "src/root.zig",
        "vendor/zig-toml/src/root.zig",
        "extensions/std/extension.json",
    }) |needed| {
        tmp.dir.access(io, needed, .{}) catch |err| {
            std.debug.print("materialized tree is missing {s}: {s}\n", .{ needed, @errorName(err) });
            return err;
        };
    }
}

test "this build carries a name for its own tree" {
    try std.testing.expect(build_id.len != 0);
    for (build_id) |c| try std.testing.expect(std.ascii.isHex(c));
}
