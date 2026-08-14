//! Extension subsystem facade for external test modules.

pub const build_ext = @import("extension/build_ext.zig");
pub const manifest = @import("extension/manifest.zig");
pub const notes = @import("extension/notes.zig");
pub const protocol = @import("extension/protocol.zig");
pub const store = @import("extension/store.zig");
pub const templates = @import("extension/templates.zig");
