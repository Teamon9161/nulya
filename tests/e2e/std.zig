//! The bundled `std` extension (docs/goals/std.md): shared fixtures and the
//! smoke test. The per-tool proofs live beside it — `std_fs.zig` (read / write /
//! append + freshness) and `std_search.zig` (grep / glob) — so the two halves
//! can be written in parallel without touching one file.

const std = @import("std");
const support = @import("support.zig");

pub const EnvPair = support.EnvPair;
pub const runCli = support.runCli;
pub const runCliEnvs = support.runCliEnvs;
pub const extractVersion = support.extractVersion;

/// Build the repo's `extensions/std` into a fresh workspace's store and return
/// `std@<version>` (caller frees). Compiles once per `zig build e2e` through
/// `support.stageBundled`; the real `ext build` then answers "already built".
pub fn buildStd(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe_abs: []const u8) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;

    alloc.free(try support.stageBundled(alloc, io, ws, "std"));

    const src = try std.fs.path.join(alloc, &.{ repo, "extensions", "std" });
    defer alloc.free(src);
    const built = try support.runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", src }, "NULYA_ZIG", zig_exe);
    defer alloc.free(built.stdout);
    if (built.code != 0) {
        std.debug.print("std extension failed to build:\n{s}\n", .{built.stdout});
        return error.ExtensionBuildFailed;
    }
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    return std.fmt.allocPrint(alloc, "std@{s}", .{version});
}

/// The absolute path of the `nulya` under test (caller frees), or SkipZigTest.
pub fn nulyaExe(alloc: std.mem.Allocator) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    return std.fs.path.resolve(alloc, &.{exe_rel});
}

/// `ext run <ref> <tool> '<json>'` in `ws`, optionally inside a session (the
/// same `NULYA_SESSION` the kernel would set — that is what turns freshness on).
pub fn runStd(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    ref: []const u8,
    tool: []const u8,
    args_json: []const u8,
    session: ?[]const u8,
) !support.CliRun {
    const argv = [_][]const u8{ exe_abs, "ext", "run", ref, tool, args_json };
    if (session) |s| {
        const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{s});
        defer alloc.free(spath);
        return runCliEnvs(alloc, io, ws, &argv, &.{.{ .key = "NULYA_SESSION", .value = spath }});
    }
    return runCli(alloc, io, ws, &argv);
}

test "bundled std: ext build compiles one binary with five tools; ext run reaches a tool by name and rejects an unknown one; version is stable across rebuilds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const exe_abs = try nulyaExe(alloc);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildStd(alloc, io, ws, exe_abs);
    defer alloc.free(ref);
    try std.testing.expect(std.mem.startsWith(u8, ref, "std@v-"));

    // Activate it, and the store lists it as a tools package (the marker reads
    // the frozen manifest of the ACTIVE version).
    {
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "std", ref["std@".len..] });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "list" });
        defer alloc.free(listed.stdout);
        try std.testing.expectEqual(@as(u8, 0), listed.code);
        try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "std\t") != null);
        try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "[tools]") != null);
    }

    // A call reaches the named tool: the answer is that tool's own refusal (a
    // path that does not exist), which on this wire is the message on
    // stderr and a non-zero exit, and which the CLI reports as `exit 1` plus
    // that message — not "unknown tool", not a crash. What the refusal SAYS is
    // std_fs.zig's business.
    {
        const run = try runStd(alloc, io, ws, exe_abs, ref, "read", "{\"path\":\"no-such-file.txt\"}", null);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        try std.testing.expect(std.mem.startsWith(u8, run.stdout, "exit 1\nstderr:\n"));
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "no tool named") == null);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "invalid response") == null);
    }

    // The manifest, not the binary, is the truth about what exists: a name the
    // manifest does not declare is refused by the CLI before anything runs.
    {
        const run = try runStd(alloc, io, ws, exe_abs, ref, "nope", "{}", null);
        defer alloc.free(run.stdout);
        try std.testing.expect(run.code != 0);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "does not declare tool 'nope'") != null);
    }

    // Rebuilding the same source is the same version.
    {
        const again = try buildStd(alloc, io, ws, exe_abs);
        defer alloc.free(again);
        try std.testing.expectEqualStrings(ref, again);
    }
}
