//! The tool registry.
//!
//! In the immutable kernel there are exactly two builtin tools: shell and edit
//! (DESIGN §6). Everything else the AI grows as an extension and invokes through
//! `shell -> nulya ext run` (DESIGN §5, §7) — it never mutates this table
//! mid-conversation, which is what keeps `tools[]` frozen for cache stability.

const std = @import("std");
const tool = @import("tool.zig");
const shell = @import("tools/shell.zig");
const edit = @import("tools/edit.zig");

pub const builtins = [_]tool.Tool{
    shell.def,
    edit.def,
};

pub fn lookup(name: []const u8) ?tool.Tool {
    for (builtins) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

test "both builtins resolve, unknown does not" {
    try std.testing.expect(lookup("shell") != null);
    try std.testing.expect(lookup("edit") != null);
    try std.testing.expect(lookup("nope") == null);
}
