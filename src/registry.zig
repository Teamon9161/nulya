//! The tool registry.
//!
//! In the immutable kernel there are exactly two builtin tools: shell and edit
//! (DESIGN §6). Everything else the AI grows as an extension and invokes through
//! `shell -> nulya ext run` (DESIGN §5, §7). A model step receives a frozen
//! `ToolSetSnapshot`; execution never queries the live registry mid-step.

const std = @import("std");
const tool = @import("tool.zig");
const shell = @import("tools/shell.zig");
const edit = @import("tools/edit.zig");

pub const builtins = [_]tool.Tool{
    shell.def,
    edit.def,
};

pub const ToolSetSnapshot = struct {
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
};

pub fn snapshot(alloc: std.mem.Allocator) !ToolSetSnapshot {
    return .{ .tools = try alloc.dupe(tool.Tool, &builtins) };
}

pub fn lookup(name: []const u8) ?tool.Tool {
    for (builtins) |t| {
        if (std.mem.eql(u8, t.definition.name, name)) return t;
    }
    return null;
}

test "both builtins resolve, unknown does not" {
    try std.testing.expect(lookup("shell") != null);
    try std.testing.expect(lookup("edit") != null);
    try std.testing.expect(lookup("nope") == null);
}

test "snapshot freezes builtin table for lookup" {
    const snap = try snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);
    try std.testing.expect(snap.lookup("shell") != null);
    try std.testing.expect(snap.lookup("edit") != null);
    try std.testing.expect(snap.lookup("nope") == null);
}
