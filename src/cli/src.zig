//! `nulya src` (PLAN §3.10): this binary printing its own embedded source, so
//! an agent reading the kernel reads the exact bytes it was built from.

const std = @import("std");
const source = @import("../source.zig");
const common = @import("common.zig");
const printOut = common.printOut;
const printRaw = common.printRaw;
const printErr = common.printErr;

// ── `nulya src` (PLAN §3.10) ─────────────────────────────────────────────────
//
// Print this binary's own embedded source. No path lists the tree; a path prints
// one file with its `test` blocks stripped (the agent usually wants structure, not
// test tokens), or verbatim with `--tests` / `--raw` (Zig-style reference).

pub fn dispatchSrc(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var include_tests = false;
    var path: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--tests") or std.mem.eql(u8, a, "--raw")) {
            include_tests = true;
        } else if (path == null) {
            path = a;
        } else {
            try printErr(io, "usage: nulya src [path] [--tests]\n");
            return 1;
        }
    }
    if (path == null) return srcList(alloc, io);
    return printSource(alloc, io, path.?, include_tests);
}

fn srcList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    for (source.files) |f| try printOut(alloc, io, "{s}\n", .{f.path});
    return 0;
}

pub fn printSource(alloc: std.mem.Allocator, io: std.Io, path: []const u8, include_tests: bool) !u8 {
    const bytes = source.find(path) orelse {
        try printOut(alloc, io, "no embedded source '{s}' (try `nulya src` for the list)\n", .{path});
        return 1;
    };
    if (include_tests) {
        try printRaw(io, bytes);
        return 0;
    }
    const stripped = try source.stripTests(alloc, bytes);
    defer alloc.free(stripped);
    try printRaw(io, stripped);
    return 0;
}
