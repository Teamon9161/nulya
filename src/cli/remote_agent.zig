//! Building a nulya for a machine this one is not, so a remote session can
//! reach a far side whose os or cpu differs from the host's.
//!
//! The shell layer's half of `remote.AgentBuilder`: the kernel names the far
//! machine, and everything here — which compiler, where the checkout is written,
//! where the result is kept between runs — is a path decision, which is why it
//! lives beside the other two (`resolveZig`, `dataDir`) rather than in
//! `environment/remote/`.
//!
//! **The result is a cache, not an identity.** It is keyed by the target and by
//! `selfbuild.build_id`, so editing `src/` invalidates it; the compiler is
//! deliberately NOT in that key, because asking a compiler its name costs a
//! process spawn on the path that finds a hit and does not spawn anything at all.

const std = @import("std");
const common = @import("common.zig");
const cli_toolchain = @import("toolchain.zig");
const environment = @import("../environment.zig");
const launch = @import("../launch.zig");
const selfbuild = @import("../selfbuild.zig");
const target_mod = @import("../extension/target.zig");
const Diag = @import("../diag.zig").Diag;

/// What every CLI path hands a session's reach: stderr for the story, and this
/// module for a binary the far machine can actually run.
pub const reach: launch.Reach = .{
    .diag = common.stderr_diag,
    .build_agent = build,
    .build_id = selfbuild.build_id,
};

/// Where cross-built agents live, under this machine's data directory.
const agents_rel = "agents";

/// Zig's own cache, shared by every target and every digest: a compile it has
/// done once is reused even when the checkout around it was written fresh.
const zig_cache_rel = agents_rel ++ std.fs.path.sep_str ++ "zig-cache";

/// `remote.AgentBuilder`: an absolute path to a nulya that runs on `for_target`,
/// compiling one if this machine has not already. Caller owns the path.
pub fn build(alloc: std.mem.Allocator, io: std.Io, for_target: target_mod.Target, diag: Diag) anyerror![]u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const data_path = try common.dataDir(alloc, &host);
    defer alloc.free(data_path);

    const dest = try std.fmt.allocPrint(alloc, "{s}{c}{s}{c}{s}-{s}", .{
        data_path,       std.fs.path.sep,    agents_rel,
        std.fs.path.sep, for_target.words(), selfbuild.build_id,
    });
    defer alloc.free(dest);

    const exe = try std.fmt.allocPrint(alloc, "{s}{c}bin{c}nulya{s}", .{
        dest, std.fs.path.sep, std.fs.path.sep, for_target.exeSuffix(),
    });
    errdefer alloc.free(exe);

    if (std.Io.Dir.accessAbsolute(io, exe, .{})) |_| {
        diag.reportFmt(io, "reusing the nulya already built for {s}\n", .{for_target.words()});
        return exe;
    } else |_| {}

    const zig = cli_toolchain.resolveZig(alloc, io) catch |err| {
        const hint = try cli_toolchain.noZigHint(alloc);
        defer alloc.free(hint);
        diag.reportFmt(io, "cannot build a nulya for {s} without a compiler: {s}\n", .{ for_target.words(), hint });
        return err;
    };
    defer zig.deinit(alloc);

    diag.reportFmt(io, "building a nulya for {s} — about a minute, and only the first time\n", .{for_target.words()});
    const started = std.Io.Timestamp.now(io, .awake);
    try compile(alloc, io, data_path, dest, for_target, zig.path, diag);
    const elapsed_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds() - started.toMilliseconds();
    diag.reportFmt(io, "built in {d}s\n", .{@divTrunc(elapsed_ms, 1000)});
    return exe;
}

/// Write the checkout somewhere private, build it, and move the finished
/// `bin/` into place under one atomic rename.
///
/// The rename is what keeps two sessions cross-building at once from watching
/// each other's half-written directory; the loser of that race finds the winner's
/// result already there, which is the same answer it was computing.
fn compile(
    alloc: std.mem.Allocator,
    io: std.Io,
    data_path: []const u8,
    dest: []const u8,
    for_target: target_mod.Target,
    zig_exe: []const u8,
    diag: Diag,
) !void {
    const cwd = std.Io.Dir.cwd();
    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const staging = try std.fmt.allocPrint(alloc, "{s}{c}{s}{c}.building-{x}", .{
        data_path, std.fs.path.sep, agents_rel, std.fs.path.sep, &suffix,
    });
    defer alloc.free(staging);
    defer cwd.deleteTree(io, staging) catch {};

    const checkout = try std.fmt.allocPrint(alloc, "{s}{c}src", .{ staging, std.fs.path.sep });
    defer alloc.free(checkout);
    try cwd.createDirPath(io, checkout);
    var checkout_dir = try std.Io.Dir.openDirAbsolute(io, checkout, .{});
    defer checkout_dir.close(io);
    try selfbuild.materialize(alloc, io, checkout_dir);

    const cache = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ data_path, std.fs.path.sep, zig_cache_rel });
    defer alloc.free(cache);
    const triple = try std.fmt.allocPrint(alloc, "-Dtarget={s}", .{for_target.zigTriple()});
    defer alloc.free(triple);

    // `-Dstrip` because these bytes cross a network and then sit on somebody
    // else's disk; the debug info is 13 of the 18 MB and nothing over there
    // reads it (`nulya src` prints from the embedded checkout, not from DWARF).
    const result = std.process.run(alloc, io, .{
        .argv = &.{
            zig_exe,                  "build",
            "-Doptimize=ReleaseSafe", "-Dstrip=true",
            triple,                   "--cache-dir",
            cache,                    "--prefix",
            staging,
        },
        .cwd = .{ .dir = checkout_dir },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        diag.reportFmt(io, "could not run {s}: {s}\n", .{ zig_exe, @errorName(err) });
        return err;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    if (exit_code != 0) {
        diag.report(io, "the compiler refused this build:\n");
        diag.report(io, tail(result.stderr));
        return error.AgentBuildFailed;
    }

    // Only `bin/` is worth keeping; the checkout is 3 MB that `materialize`
    // reproduces for free, and zig's own cache already lives outside `staging`.
    cwd.deleteTree(io, checkout) catch {};
    std.Io.Dir.renameAbsolute(staging, dest, io) catch |err| {
        // Someone else finished the identical build first: their bytes are this
        // function's answer, and only a genuinely absent result is a failure.
        if (std.Io.Dir.accessAbsolute(io, dest, .{})) |_| return else |_| {}
        return err;
    };
}

/// The last stretch of a compiler's complaint. Zig prints the summary last, and
/// a whole megabyte of instantiation traces helps nobody read it.
fn tail(stderr: []const u8) []const u8 {
    const most = 1600;
    if (stderr.len <= most) return stderr;
    const cut = stderr[stderr.len - most ..];
    const nl = std.mem.indexOfScalar(u8, cut, '\n') orelse return cut;
    return cut[nl + 1 ..];
}

test "the tail of a complaint keeps the end and starts on a line boundary" {
    try std.testing.expectEqualStrings("short\n", tail("short\n"));

    const long = "x" ** 2000 ++ "\nlast line\n";
    const cut = tail(long);
    try std.testing.expect(cut.len < long.len);
    try std.testing.expectEqualStrings("last line\n", cut);
}
