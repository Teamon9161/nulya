//! The extension drafts this binary ships, backing `nulya ext seed`. build.zig
//! `@embedFile`s the repo's own `extensions/**` tree, so a distributed binary can
//! seed a store root on a machine that never saw this checkout. Nothing here
//! builds or trusts anything: a seeded draft is an ordinary draft.

const std = @import("std");
const embed = @import("ext_embed");
const manifest = @import("extension/manifest.zig");

/// Every embedded draft file, sorted by path. Paths are relative to the repo's
/// `extensions/` directory and slash-normalized, so the first component is the
/// draft id.
pub const files: []const embed.Entry = &embed.files;

/// The draft id a path belongs to: its first component.
pub fn idOf(path: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return path;
    return path[0..slash];
}

/// Every bundled draft id, sorted, unique. Only the outer slice is allocated;
/// the ids are views into the embedded paths.
pub fn ids(alloc: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    // `files` is sorted by path, so one id's files are adjacent and comparing
    // against the last appended id is a full dedupe.
    for (files) |f| {
        const id = idOf(f.path);
        if (out.items.len != 0 and std.mem.eql(u8, out.items[out.items.len - 1], id)) continue;
        try out.append(alloc, id);
    }
    return out.toOwnedSlice(alloc);
}

pub fn has(id: []const u8) bool {
    for (files) |f| {
        if (std.mem.eql(u8, idOf(f.path), id)) return true;
    }
    return false;
}

test "every bundled manifest validates, and agent ships its authoring manual as a reference skill" {
    const alloc = std.testing.allocator;
    var checked: usize = 0;
    for (files) |f| {
        if (!std.mem.endsWith(u8, f.path, "/extension.json")) continue;
        checked += 1;
        var m = manifest.parse(alloc, f.bytes) catch |err| {
            std.debug.print("bundled {s} does not parse: {t}\n", .{ f.path, err });
            return err;
        };
        defer m.deinit();
        m.validate() catch |err| {
            std.debug.print("bundled {s} does not validate: {t}\n", .{ f.path, err });
            return err;
        };

        // `agent`'s tool must be on the model's face, so the package is a
        // member of every session that delegates. Its authoring manual rides
        // that membership and must NOT ride it onto the catalogue: one line of
        // every session's attention for a page opened once in a hundred.
        if (!std.mem.eql(u8, m.id, "agent")) continue;
        var manual = false;
        for (m.skills) |spec| {
            if (!std.mem.endsWith(u8, spec.path, "writing-an-agent")) continue;
            manual = true;
            try std.testing.expectEqual(manifest.SkillSurface.reference, spec.surfaceOf());
        }
        try std.testing.expect(manual);
    }
    try std.testing.expect(checked >= 8);
}

test "bundled drafts include every one the repo ships, each with a manifest at its root" {
    const alloc = std.testing.allocator;
    const list = try ids(alloc);
    defer alloc.free(list);
    for ([_][]const u8{ "agent", "ask", "compact", "evolution", "guide", "handoff", "plan", "std" }) |want| {
        try std.testing.expect(has(want));
        var manifest_path_buf: [64]u8 = undefined;
        const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/extension.json", .{want});
        var found = false;
        for (files) |f| {
            if (std.mem.eql(u8, f.path, manifest_path)) found = true;
        }
        try std.testing.expect(found);
    }
    for (list, 0..) |id, i| {
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, list[i - 1], id));
    }
    try std.testing.expect(!has("does-not-exist"));
}
