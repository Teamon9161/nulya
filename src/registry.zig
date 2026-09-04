//! The tool registry. Exactly ONE builtin tool: shell. Everything else the AI
//! grows as an extension, reaching the model face through the session's
//! composition or, otherwise, `nulya ext run`. A session receives a frozen
//! `ToolSetSnapshot`; execution never queries a live registry mid-step.

const std = @import("std");
const tool = @import("tool.zig");
const environment = @import("environment.zig");
const shell = @import("tools/shell.zig");

/// The builtin table for one shell dialect. `shell` is the only entry, and the
/// dialect reaches it because its description names the interpreter it runs.
fn builtinsFor(dialect: environment.Dialect) [1]tool.Tool {
    return .{shell.defFor(dialect)};
}

/// Permanent model-facing tool slots, reserved before any extension tool.
pub const builtin_count: usize = 1;

/// A snapshot rejects two ways of colliding: logical-identity clashes, not
/// resource faults, so they stay their own error set.
pub const SnapshotError = error{
    DuplicateToolId,
    DuplicateToolName,
};

pub const ToolSetSnapshot = struct {
    /// Frozen model-facing tool set for the session composition. Names must be
    /// unique inside the snapshot; `shell` is permanently reserved.
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

    /// Model-facing definitions for provider serialization. The returned slice
    /// owns only the array; the definitions point into the frozen snapshot.
    pub fn definitions(self: ToolSetSnapshot, alloc: std.mem.Allocator) ![]tool.ToolDefinition {
        const defs = try alloc.alloc(tool.ToolDefinition, self.tools.len);
        for (self.tools, 0..) |t, i| defs[i] = t.definition;
        return defs;
    }
};

pub fn snapshot(alloc: std.mem.Allocator, dialect: environment.Dialect) !ToolSetSnapshot {
    return snapshotWith(alloc, dialect, &.{});
}

/// Freeze the builtin table plus `extras` into one model-facing tool set. The
/// registry stays ignorant of what `extras` are and only enforces two identity
/// invariants: unique stable id, unique model-facing name. The builtin keeps its
/// leading slot; extras follow sorted by stable id, so the frozen set is
/// deterministic regardless of caller order.
pub fn snapshotWith(alloc: std.mem.Allocator, dialect: environment.Dialect, extras: []const tool.Tool) !ToolSetSnapshot {
    const builtins = builtinsFor(dialect);
    const tools = try alloc.alloc(tool.Tool, builtins.len + extras.len);
    errdefer alloc.free(tools);

    @memcpy(tools[0..builtins.len], &builtins);
    @memcpy(tools[builtins.len..], extras);
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
    const snap = try snapshot(std.testing.allocator, .bash);
    defer snap.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snap.tools.len);
    try std.testing.expect(snap.lookup("shell") != null);
    // `edit` is not a builtin: it is a tool of the bundled `std` extension.
    try std.testing.expect(snap.lookup("edit") == null);
    try std.testing.expect(snap.lookup("nope") == null);
}

test "snapshot exposes unique model-facing names" {
    const snap = try snapshot(std.testing.allocator, .bash);
    defer snap.deinit(std.testing.allocator);

    for (snap.tools, 0..) |a, i| {
        try std.testing.expect(a.definition.name.len != 0);
        for (snap.tools[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.definition.name, b.definition.name));
        }
    }
}

test "snapshot exports provider-facing tool definitions without handlers" {
    const snap = try snapshot(std.testing.allocator, .bash);
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
    const snap = try snapshotWith(std.testing.allocator, .bash, &extras);
    defer snap.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), snap.tools.len);
    try std.testing.expectEqualStrings("shell", snap.tools[0].definition.name);
    // Extras follow, ordered by stable id, not by caller order.
    try std.testing.expectEqualStrings("ext:a.pkg/alpha", snap.tools[1].definition.id);
    try std.testing.expectEqualStrings("ext:z.pkg/zeta", snap.tools[2].definition.id);
}

test "snapshotWith rejects a duplicate stable id" {
    const extras = [_]tool.Tool{
        stubTool("ext:dup/one", "one"),
        stubTool("ext:dup/one", "two"),
    };
    try std.testing.expectError(error.DuplicateToolId, snapshotWith(std.testing.allocator, .bash, &extras));
}

test "snapshotWith rejects a model-facing name that collides across extensions" {
    const extras = [_]tool.Tool{
        stubTool("ext:a.pkg/search", "search"),
        stubTool("ext:b.pkg/search", "search"),
    };
    try std.testing.expectError(error.DuplicateToolName, snapshotWith(std.testing.allocator, .bash, &extras));
}

test "snapshotWith rejects an extra that shadows a builtin name" {
    const extras = [_]tool.Tool{stubTool("ext:evil/shell", "shell")};
    try std.testing.expectError(error.DuplicateToolName, snapshotWith(std.testing.allocator, .bash, &extras));
}
