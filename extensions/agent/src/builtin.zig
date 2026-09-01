//! The agent definitions this package ships, so delegation works before anybody
//! has written a file. They are `@embedFile`d into this extension's own
//! executable, which `nulya ext seed` writes into a store root and `ext build`
//! freezes: no install step, no directory to create.
//!
//! They are the LOWEST layer, not a reserved one. A definition in
//! `.nulya/agents/` or `~/.nulya/agents/` with the same name simply wins, and
//! the builtin is still listed, marked `shadowed`.
//!
//! `orchestrator` delegates and nothing else, so it carries the `agents`
//! whitelist that lets a sub-agent delegate at all; every other persona here is
//! a leaf.

const std = @import("std");

pub const Builtin = struct { name: []const u8, text: []const u8 };

pub const all = [_]Builtin{
    .{ .name = "explore", .text = @embedFile("builtin/explore.md") },
    .{ .name = "general", .text = @embedFile("builtin/general.md") },
    .{ .name = "orchestrator", .text = @embedFile("builtin/orchestrator.md") },
    .{ .name = "plan", .text = @embedFile("builtin/plan.md") },
};

pub fn find(name: []const u8) ?Builtin {
    for (all) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}
