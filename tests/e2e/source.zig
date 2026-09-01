//! `nulya src` and `nulya ext api`: the binary prints the exact
//! `src/**` it was built from, so what an agent reads can never drift from what
//! runs.

const std = @import("std");
const support = @import("support.zig");

const runCli = support.runCli;

test "cli src: --raw matches the on-disk source; default strips tests; ext api reads real source" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // The binary embeds the exact `src/**` it was built from, so `--raw` prints
    // that file byte-for-byte — regardless of the child's cwd (here a fresh tmp).
    // The test process cwd is the build root, so the on-disk source is readable.
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, "src" ++ std.fs.path.sep_str ++ "prompt.zig", alloc, .unlimited);
    defer alloc.free(on_disk);

    const raw = try runCli(alloc, io, ws, &.{ exe_abs, "src", "prompt.zig", "--raw" });
    defer alloc.free(raw.stdout);
    try std.testing.expectEqual(@as(u8, 0), raw.code);
    try std.testing.expectEqualStrings(on_disk, raw.stdout);

    // The default view strips top-level test blocks: shorter, and no test header
    // survives at column 0 (the raw view has them).
    const def = try runCli(alloc, io, ws, &.{ exe_abs, "src", "prompt.zig" });
    defer alloc.free(def.stdout);
    try std.testing.expectEqual(@as(u8, 0), def.code);
    try std.testing.expect(def.stdout.len < raw.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, raw.stdout, "\ntest ") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.stdout, "\ntest ") == null);

    // No path lists the embedded tree.
    const list = try runCli(alloc, io, ws, &.{ exe_abs, "src" });
    defer alloc.free(list.stdout);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "prompt.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "extension/protocol.zig") != null);

    // `ext api` is now a curated `nulya src`: it prints the real protocol source.
    const api = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "api" });
    defer alloc.free(api.stdout);
    try std.testing.expectEqual(@as(u8, 0), api.code);
    try std.testing.expect(std.mem.indexOf(u8, api.stdout, "Extension wire protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, api.stdout, "NULYA_ARG_") != null);

    // An unknown path fails cleanly.
    const miss = try runCli(alloc, io, ws, &.{ exe_abs, "src", "nope.zig" });
    defer alloc.free(miss.stdout);
    try std.testing.expectEqual(@as(u8, 1), miss.code);
}
