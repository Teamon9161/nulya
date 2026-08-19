//! The tool registry.
//!
//! In the immutable kernel there is exactly ONE builtin tool: shell (DESIGN §6).
//! Everything else the AI grows as an extension: selected tools are exposed
//! natively this session through `SessionComposition` pins, and every other
//! extension capability is invoked through `nulya ext run` (DESIGN §5, §7).
//! A session receives a frozen `ToolSetSnapshot` through `SessionComposition`;
//! execution never queries a live registry mid-step.

const std = @import("std");
const tool = @import("tool.zig");
const shell = @import("tools/shell.zig");

const builtins = [_]tool.Tool{
    shell.def,
};

/// Permanent model-facing tool slots (shell). The tool budget always reserves
/// these before any extension tool is promoted (DESIGN §6).
pub const builtin_count: usize = builtins.len;

/// A snapshot rejects two ways of colliding. Both are logical-identity clashes,
/// not resource faults, so they stay their own error set.
pub const SnapshotError = error{
    /// Two tools share a stable `ToolDefinition.id`.
    DuplicateToolId,
    /// Two tools share a model-facing `ToolDefinition.name`.
    DuplicateToolName,
};

pub const ToolSetSnapshot = struct {
    /// Frozen model-facing tool set for the session composition. Names must be
    /// unique inside the snapshot; the builtin name `shell` is permanently
    /// reserved.
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
    return snapshotWith(alloc, &.{});
}

/// Freeze the builtin table plus `extras` into one model-facing tool set.
///
/// The registry stays ignorant of what `extras` are — extension tools, MCP
/// tools, anything adapted to `tool.Tool` — and only enforces the two identity
/// invariants every snapshot must hold: unique stable id and unique model-facing
/// name. The builtin keeps its leading slot; extras follow, sorted by stable id
/// so the frozen set is deterministic regardless of caller order.
pub fn snapshotWith(alloc: std.mem.Allocator, extras: []const tool.Tool) !ToolSetSnapshot {
    const tools = try alloc.alloc(tool.Tool, builtins.len + extras.len);
    errdefer alloc.free(tools);

    @memcpy(tools[0..builtins.len], &builtins);
    @memcpy(tools[builtins.len..], extras);
    // Only the extras are sorted; builtins keep their reserved leading order.
    std.mem.sort(tool.Tool, tools[builtins.len..], {}, lessThanById);

    for (tools, 0..) |a, i| {
        for (tools[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.definition.id, b.definition.id)) return error.DuplicateToolId;
            if (std.mem.eql(u8, a.definition.name, b.definition.name)) return error.DuplicateToolName;
        }
    }

    return .{ .tools = tools };
}

fn lessThanById(_: void, a: tool.Tool, b: tool.Tool) bool {
    return std.mem.lessThan(u8, a.definition.id, b.definition.id);
}

test "snapshot freezes builtin table for lookup" {
    const snap = try snapshot(std.testing.allocator);
    defer snap.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snap.tools.len);
    try std.testing.expect(snap.lookup("shell") != null);
    // `edit` is not a builtin: it is a tool of the bundled `std` extension and
    // arrives, if at all, as a pinned extra (DESIGN §6, §7.8).
    try std.testing.expect(snap.lookup("edit") == null);
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

fn stubTool(id: []const u8, name: []const u8) tool.Tool {
    return .{
        .definition = .{ .id = id, .name = name, .description = "", .input_schema = "{}" },
        .executor = .{ .ptr = null, .callFn = undefined },
    };
}

test "snapshotWith keeps builtins first and sorts extras by stable id" {
    const extras = [_]tool.Tool{
        stubTool("ext:z.pkg/zeta", "zeta"),
        stubTool("ext:a.pkg/alpha", "alpha"),
    };
    const snap = try snapshotWith(std.testing.allocator, &extras);
    defer snap.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), snap.tools.len);
    // The builtin keeps its reserved leading slot regardless of extras.
    try std.testing.expectEqualStrings("shell", snap.tools[0].definition.name);
    // Extras follow, ordered by stable id (a before z), not by caller order.
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", snap.tools[1].definition.id);
    try std.testing.expectEqualStrings("ext:z.pkg/zeta", snap.tools[2].definition.id);
}

test "snapshotWith rejects a duplicate stable id" {
    const extras = [_]tool.Tool{
        stubTool("ext:dup/one", "one"),
        stubTool("ext:dup/one", "two"),
    };
    try std.testing.expectError(error.DuplicateToolId, snapshotWith(std.testing.allocator, &extras));
}

test "snapshotWith rejects a model-facing name that collides across extensions" {
    const extras = [_]tool.Tool{
        stubTool("ext:a.pkg/search", "search"),
        stubTool("ext:b.pkg/search", "search"),
    };
    try std.testing.expectError(error.DuplicateToolName, snapshotWith(std.testing.allocator, &extras));
}

test "snapshotWith rejects an extra that shadows a builtin name" {
    const extras = [_]tool.Tool{stubTool("ext:evil/shell", "shell")};
    try std.testing.expectError(error.DuplicateToolName, snapshotWith(std.testing.allocator, &extras));
}
