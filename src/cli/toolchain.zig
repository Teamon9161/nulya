//! `nulya toolchain zig`, plus the one place a Zig compiler is resolved
//! (DESIGN §10). `ext build` needs the same answer, so the resolution — and the
//! single line that admits when the compiler came from an unpinned PATH — lives
//! here rather than being spelled twice.

const std = @import("std");
const builtin = @import("builtin");
const toolchain = @import("../extension/build/toolchain.zig");
const common = @import("common.zig");
const environment = @import("../environment.zig");
const dataDir = common.dataDir;
const printOut = common.printOut;
const printErr = common.printErr;

pub fn dispatchToolchain(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1 or !std.mem.eql(u8, args[0], "zig")) {
        try printErr(io, "usage: nulya toolchain zig <args...>\n");
        return 1;
    }
    const zig_exe = resolveZig(alloc, io) catch |err| switch (err) {
        error.NoZigToolchain => {
            try printOut(alloc, io, "no zig toolchain; set NULYA_ZIG, put zig on PATH, or build nulya with -Dembed-toolchain\n", .{});
            return 1;
        },
        else => {
            try printOut(alloc, io, "no zig toolchain: {s}\n", .{@errorName(err)});
            return 1;
        },
    };
    defer zig_exe.deinit(alloc);
    // This verb IS the compiler, so which one it is belongs on screen.
    try noteUnpinnedZig(alloc, io, zig_exe);

    var argv = try alloc.alloc([]const u8, args.len);
    defer alloc.free(argv);
    argv[0] = zig_exe.path;
    for (args[1..], 1..) |a, i| argv[i] = a;

    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

/// A resolved compiler and where it came from — the second half matters,
/// because only one of the three sources is unpinned.
pub const ZigExe = struct {
    path: []u8,
    source: enum { env, embedded, path },

    pub fn deinit(self: ZigExe, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
};

/// Resolve a zig executable, in this order: `NULYA_ZIG` (the explicit dev
/// override), the embedded managed toolchain (DESIGN §10), then a `zig` on
/// PATH. Caller owns the returned path; `error.NoZigToolchain` means none of
/// the three answered.
///
/// The PATH fallback is for development builds, which carry no toolchain: the
/// alternative is that `nulya ext build` cannot compile anything on a machine
/// that plainly has a compiler. It is honest rather than pinned — a compiled
/// version's id hashes the compiler identity (DESIGN §7.4), so building with a
/// different zig yields a *different version*, never a silently different
/// binary under the same id. That is why taking it is allowed, and why callers
/// that actually compile say so once (`noteUnpinnedZig`).
pub fn resolveZig(alloc: std.mem.Allocator, io: std.Io) !ZigExe {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();

    if (host.get("NULYA_ZIG")) |p| {
        if (p.len != 0) return .{ .path = try alloc.dupe(u8, p), .source = .env };
    }

    const embedded: ?[]u8 = blk: {
        const data_path = try dataDir(alloc, &host);
        defer alloc.free(data_path);
        std.Io.Dir.cwd().createDirPath(io, data_path) catch {};
        var data = std.Io.Dir.openDirAbsolute(io, data_path, .{ .iterate = true }) catch break :blk null;
        defer data.close(io);
        break :blk toolchain.ensureExtracted(alloc, io, data) catch |err| switch (err) {
            error.Canceled => return err,
            else => null, // not embedded (the usual case), or unextractable
        };
    };
    if (embedded) |z| return .{ .path = z, .source = .embedded };

    const on_path = (try zigOnPath(alloc, io, &host)) orelse return error.NoZigToolchain;
    return .{ .path = on_path, .source = .path };
}

/// One stderr line naming the compiler that is about to define a version id —
/// only for the unpinned source, and only from a caller that really compiles
/// (a data or script package never touches zig, so saying it there would be
/// noise about a decision that was not made).
pub fn noteUnpinnedZig(alloc: std.mem.Allocator, io: std.Io, zig: ZigExe) !void {
    if (zig.source != .path) return;
    const note = try std.fmt.allocPrint(
        alloc,
        "note: using zig from PATH ({s}); set NULYA_ZIG or use an embedded build for a pinned toolchain\n",
        .{zig.path},
    );
    defer alloc.free(note);
    try printErr(io, note);
}

/// The first executable `zig` on PATH, as an absolute path, or null. Caller owns
/// the result.
fn zigOnPath(alloc: std.mem.Allocator, io: std.Io, host: *const std.process.Environ.Map) !?[]u8 {
    const path_value = host.get("PATH") orelse return null;
    const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

    var dirs = std.mem.splitScalar(u8, path_value, separator);
    while (dirs.next()) |raw_dir| {
        const dir = std.mem.trim(u8, raw_dir, " \t\"");
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        const candidate = try std.fs.path.join(alloc, &.{ dir, exe_name });
        errdefer alloc.free(candidate);
        // `execute` is what matters: a `zig` directory or a non-executable file
        // on PATH is not a compiler.
        if (std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true })) |_| return candidate else |err| switch (err) {
            error.Canceled => return err,
            else => alloc.free(candidate),
        }
    }
    return null;
}
