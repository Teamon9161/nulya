//! Test-support facade for the out-of-tree e2e module (`tests/e2e.zig`).
//!
//! Zig 0.16 forbids a single file living in two module graphs, so the e2e test
//! binary is its own module and can only reach core code through what this facade
//! re-exports. This file is NOT part of the shipped `nulya` binary — nothing in
//! the root module graph imports it (it exists purely so the e2e tests can drive
//! the real session / composition / promotion / extension code paths).
//!
//! Keep it a thin re-export surface: add a line when a test genuinely needs a
//! core module, never any logic.

pub const build_ext = @import("extension/build_ext.zig");
pub const composition = @import("composition.zig");
pub const config = @import("config.zig");
pub const environment = @import("environment.zig");
pub const integrity = @import("extension/integrity.zig");
pub const launch = @import("launch.zig");
pub const ledger = @import("ledger.zig");
pub const manifest = @import("extension/manifest.zig");
pub const outcome = @import("outcome.zig");
pub const prompt = @import("prompt.zig");
pub const promotion = @import("promotion.zig");
pub const protocol = @import("extension/protocol.zig");
pub const provider = @import("provider.zig");
pub const session = @import("session.zig");
pub const store = @import("extension/store.zig");
pub const templates = @import("extension/templates.zig");
pub const tool = @import("tool.zig");
pub const tool_stats = @import("tool_stats.zig");
