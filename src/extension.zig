//! Test-facing facade for external test modules: the extension subsystem plus
//! the environment and tool-stats modules the e2e tests need (the real
//! `nulya ext run` path is exercised by spawning the installed binary).

pub const build_ext = @import("extension/build_ext.zig");
pub const composition = @import("composition.zig");
pub const environment = @import("environment.zig");
pub const integrity = @import("extension/integrity.zig");
pub const manifest = @import("extension/manifest.zig");
pub const notes = @import("extension/notes.zig");
pub const promotion = @import("promotion.zig");
pub const protocol = @import("extension/protocol.zig");
pub const store = @import("extension/store.zig");
pub const templates = @import("extension/templates.zig");
pub const tool = @import("tool.zig");
pub const tool_stats = @import("tool_stats.zig");
