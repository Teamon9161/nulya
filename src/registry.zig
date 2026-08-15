//! The tool registry.
//!
//! In the immutable kernel there are exactly two builtin tools: shell and edit
//! (DESIGN §6). Everything else the AI grows as an extension and invokes through
//! `shell -> nulya ext run` (DESIGN §5, §7). A session receives a frozen
//! `ToolSetSnapshot` through `SessionComposition`; execution never queries a live
//! registry mid-step.

const std = @import("std");
const tool = @import("tool.zig");
const shell = @import("tools/shell.zig");
const edit = @import("tools/edit.zig");

const builtins = [_]tool.Tool{
    shell.def,
    edit.def,
};

pub const ToolSetSnapshot = struct {
    /// Frozen model-facing tool set for the session composition. Names must be
    /// unique inside the snapshot; builtin names `shell` and `edit` are
    /// permanently reserved.
    tools: []const tool.Tool,

    pub fn deinit(self: ToolSetSnapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.tools);
    }

    pub fn lookup(self: ToolSetSnapshot, name: []const u8) ?tool.Tool {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.definition.name, name)) return t;
        }
        return null;
    }

    /// Borrow-free model-facing definitions for provider serialization. The
    /// returned slice owns only the array; each definition points at the frozen
    /// snapshot's static/manifest-backed strings.
    pub fn definitions(self: ToolSetSnapshot, alloc: std.mem.Allocator) ![]tool.ToolDefinition {
        const defs = try alloc.alloc(tool.ToolDefinition, self.tools.len);
        for (self.tools, 0..) |t, i| defs[i] = t.definition;
        return defs;
    }
};

pub fn snapshot(alloc: std.mem.Allocator) !ToolSetSnapshot {
    return .{ .tools = try alloc.dupe(tool.Tool, &builtins) };
}

test "snapshot freezes builtin table for lookup" {
    const snap = try snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);
    try std.testing.expect(snap.lookup("shell") != null);
    try std.testing.expect(snap.lookup("edit") != null);
    try std.testing.expect(snap.lookup("nope") == null);
}

test "snapshot exposes unique model-facing names" {
    const snap = try snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);

    for (snap.tools, 0..) |a, i| {
        try std.testing.expect(a.definition.name.len != 0);
        for (snap.tools[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.definition.name, b.definition.name));
        }
    }
}

test "snapshot exports provider-facing tool definitions without handlers" {
    const snap = try snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);

    const defs = try snap.definitions(std.testing.allocator);
    defer std.testing.allocator.free(defs);

    try std.testing.expectEqual(snap.tools.len, defs.len);
    try std.testing.expectEqualStrings(snap.tools[0].definition.name, defs[0].name);
}


test "builtin tools declare conservative sequential scheduling" {
    const snap = try snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);

    try std.testing.expectEqual(tool.BatchPolicy.sequential, snap.lookup("shell").?.batch_policy);
    try std.testing.expectEqual(tool.BatchPolicy.sequential, snap.lookup("edit").?.batch_policy);
}
