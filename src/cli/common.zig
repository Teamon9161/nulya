//! Plumbing every `nulya` verb file shares (DESIGN §14): stdout/stderr writing,
//! argv scanning, the workspace cwd, and the ordered store-root search each
//! `ext` / `skill` / `session` command opens. Nothing here decides anything
//! about a verb — a helper lands in this file exactly when two verb files need
//! it, so `cli.zig` itself can stay a dispatcher over the files beside it.

const std = @import("std");
const builtin = @import("builtin");
const store = @import("../extension/store.zig");
const roots_mod = @import("../extension/roots.zig");
const config = @import("../config.zig");
const composition = @import("../composition.zig");
const launch = @import("../launch.zig");

/// The ordered store roots this invocation searches (DESIGN §7.2), opened once.
/// Every `ext` / `skill` command goes through this instead of assuming the
/// workspace store is the only one: an extension may live in the user's
/// `~/.nulya/extensions` or in a trusted `extensions.paths` entry, and the first
/// root holding an ACTIVE version of an id wins.
pub const RootSearch = struct {
    specs: []const []const u8,
    roots: roots_mod.Roots,

    pub fn open(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) !RootSearch {
        const specs = try rootSpecs(alloc, io);
        errdefer launch.freeExtensionRoots(alloc, specs);
        const roots = try roots_mod.Roots.open(alloc, io, cwd, specs);
        return .{ .specs = specs, .roots = roots };
    }

    pub fn deinit(self: *RootSearch, alloc: std.mem.Allocator) void {
        self.roots.deinit();
        launch.freeExtensionRoots(alloc, self.specs);
    }
};

/// Resolve the ordered root specs from the environment + config chain. Caller
/// owns the result (`launch.freeExtensionRoots`).
pub fn rootSpecs(alloc: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();
    return launch.extensionRoots(alloc, &host, &cfg);
}

/// Where a write-side command puts things: the user store under `--user`, else
/// the workspace store. Null means `--user` on a machine with no home. Caller
/// owns the result.
pub fn writeRootSpec(alloc: std.mem.Allocator, user: bool) !?[]u8 {
    if (!user) return try alloc.dupe(u8, store.workspace_root_rel);
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    return launch.userExtensionsRoot(alloc, &host);
}

/// Split `args` into `(has --user, everything else)` — the one flag every
/// write-side `ext` verb shares. Caller owns the returned positionals.
pub fn takeUserFlag(alloc: std.mem.Allocator, args: []const []const u8) !struct { user: bool, rest: [][]const u8 } {
    var rest: std.ArrayList([]const u8) = .empty;
    errdefer rest.deinit(alloc);
    var user = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--user")) user = true else try rest.append(alloc, a);
    }
    return .{ .user = user, .rest = try rest.toOwnedSlice(alloc) };
}

/// The root spec an `activate` / `rollback` / `deactivate` acts on. `--user`
/// names the user store outright. Otherwise the root whose copy of `id` is IN
/// EFFECT (`Roots.firstActive`, DESIGN §7.2): the operation lands on what a
/// session would use — an activate there takes effect, an activate anywhere
/// else would succeed and change nothing. Only when no root has an active copy
/// does a `version` pick the first root that holds it built. Null means there
/// is nowhere to act (and, for `--user`, no home directory). Caller owns it.
pub fn targetRootSpec(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    id: []const u8,
    version: ?[]const u8,
    user: bool,
) !?[]u8 {
    if (user) return writeRootSpec(alloc, true);
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const index = if (try search.roots.firstActive(alloc, id)) |active| blk: {
        alloc.free(active.version);
        break :blk active.root;
    } else search.roots.firstWithVersion(alloc, id, version orelse return null) orelse return null;
    return try alloc.dupe(u8, search.roots.entries[index].spec);
}

/// The id of the session this process is running INSIDE, or null when it is not.
/// `session step` puts the live session's file path in `NULYA_SESSION` for its
/// shell children (DESIGN §5.3), so anything the model runs can name the session
/// it is in without being told. Caller owns the result.
pub fn envSessionId(alloc: std.mem.Allocator) !?[]u8 {
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    const path = host.get("NULYA_SESSION") orelse return null;
    const stem = std.fs.path.stem(path);
    if (stem.len == 0) return null;
    return try alloc.dupe(u8, stem);
}

/// Find `--flag <value>` in args; returns the value or null.
pub fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

/// `<id>[@<version>]` — the one spelling of "an extension, maybe at an exact
/// version" shared by `session new --with` and `ext run`. Version ids contain
/// no `@`, extension ids neither, so the last `@` splits unambiguously.
pub fn withRef(spec: []const u8) composition.WithRef {
    const at = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return .{ .id = spec };
    return .{ .id = spec[0..at], .version = spec[at + 1 ..] };
}

pub fn cwdRealPath(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ![]u8 {
    const len = try std.Io.Dir.cwd().realPath(io, buf);
    return buf[0..len];
}

pub fn sliceHasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

pub fn dataDir(alloc: std.mem.Allocator, host: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = host.get("LOCALAPPDATA") orelse ".";
        return std.fs.path.join(alloc, &.{ base, "nulya" });
    }
    if (host.get("XDG_DATA_HOME")) |x| return std.fs.path.join(alloc, &.{ x, "nulya" });
    const home = host.get("HOME") orelse ".";
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "nulya" });
}

pub fn writeInto(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ sub_dir, name });
    defer alloc.free(path);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn usage(io: std.Io) !u8 {
    try printRaw(io,
        \\nulya — minimal self-evolving agent harness
        \\
        \\  nulya ext init <id> <tool>        scaffold a new extension
        \\  nulya ext build <path>            compile into an immutable version
        \\  nulya ext activate <id> <ver>     point `current` at a version
        \\  nulya ext rollback <id> <ver>     repoint `current` at an older version
        \\  nulya ext run <id>[@<ver>] [tool] <json>  invoke the active (or that exact) version
        \\  nulya ext list                    list extensions and active versions
        \\  nulya ext inspect <id>            print an extension's manifest
        \\  nulya ext api [protocol|permissions|examples]
        \\  nulya session new|append|step|events|cancel   drive a durable session
        \\  nulya config show [--json]        effective provider profiles + model catalog
        \\  nulya src [path] [--tests]        print this binary's own source
        \\  nulya skill list                 list active extension skills
        \\  nulya skill load <pinned-ref>    print a frozen SKILL.md
        \\  nulya toolchain zig <args...>     run the managed zig (scratch)
        \\
    );
    return 0;
}

pub fn printOut(alloc: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try printRaw(io, s);
}

pub fn printRaw(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

pub fn printErr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}
