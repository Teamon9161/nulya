//! The extension drafts this binary ships (DESIGN §7.8, `nulya ext seed`).
//!
//! build.zig `@embedFile`s the repo's own `extensions/**` tree — the same move
//! as `src_embed` (`nulya src`), pointed at the bundled drafts. A distributed
//! binary therefore carries the drafts themselves, and `ext seed` can write
//! them into a store root on a machine that never saw this checkout. Nothing
//! here builds or trusts anything: a seeded draft is an ordinary draft, and
//! `ext sync` / the store's own gates take it from there.

const std = @import("std");
const embed = @import("ext_embed");

/// Every embedded draft file, sorted by path. Paths are relative to the repo's
/// `extensions/` directory and slash-normalized (`std/src/main.zig`), so the
/// first component is the draft id.
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
    // `files` is sorted by path, so one id's files are adjacent: comparing
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
    // Sorted + unique is what the seed loop leans on.
    for (list, 0..) |id, i| {
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, list[i - 1], id));
    }
    try std.testing.expect(!has("does-not-exist"));
}
