//! The agent definitions this package ships.
//!
//! Three personas — reconnaissance, planning, and general delegated work — so
//! that delegation works before anybody has written a file. Distribution is the
//! binary: they are `@embedFile`d into this extension's own executable, which
//! `nulya ext seed` writes into a store root and `ext build` freezes, exactly
//! like the rest of the package (DESIGN §7.8). There is no install step and no
//! directory to create.
//!
//! **They are the lowest layer, not a reserved one.** A definition in
//! `.nulya/agents/` or `~/.nulya/agents/` with the same name simply wins, and
//! the builtin is still listed, marked `shadowed` — the store roots' own rule
//! (§7.2, "first holder wins", nothing silently disappears). tcode reserves its
//! builtin names instead; that is a defensible choice there and the wrong one
//! here, where every other layered thing in the repository shadows rather than
//! refuses.
//!
//! **Ported from tcode** (`crates/tcode-tools/src/agent/builtin/*.md`), with the
//! concepts nulya does not have taken out rather than translated: `ask_user`
//! (there is no primitive for a sub-agent to reach a person, PLAN) and tcode's
//! frontmatter for things that do not exist here (`gatesOutput`, `tools: []`,
//! `questionPolicy`). `orchestrator` delegates and nothing else, so it carries
//! the `agents` whitelist that lets a sub-agent delegate at all — every other
//! persona here is a leaf.

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
