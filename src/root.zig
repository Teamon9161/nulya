//! The kernel as a library: the root module of the public `nulya` package
//! (`b.addModule("nulya", …)` in build.zig), the conventional `src/root.zig`
//! a Zig dependency exposes. An application that wants the kernel in-process
//! adds this repo to its `build.zig.zon` and `@import("nulya")`s what it needs.
//!
//! Two consumers share this one surface on purpose. The e2e test binary is an
//! out-of-tree module (Zig 0.16 forbids a single file living in two module
//! graphs), so it reaches core code only through what is re-exported here —
//! which means the e2e suite exercises exactly the surface a dependent gets.
//! This file is NOT part of the shipped `nulya` binary; nothing in the binary's
//! own module graph imports it.
//!
//! No stability promise yet: pre-release, the API moves when the kernel does.
//! The stable integration surfaces remain the CLI (`nulya session *` for
//! drivers, DESIGN §14) and the plain wire for extensions (DESIGN §7.3); this
//! module is for embedding, not the only door in.
//!
//! Keep it a thin re-export surface: add a line when a consumer (a test, an
//! embedder) genuinely needs a core module, never any logic.

pub const build_ext = @import("extension/build/build_ext.zig");
pub const composition = @import("composition.zig");
pub const config = @import("config.zig");
pub const environment = @import("environment.zig");
pub const integrity = @import("extension/integrity.zig");
pub const launch = @import("launch.zig");
pub const ledger = @import("ledger.zig");
pub const manifest = @import("extension/manifest.zig");
pub const outcome = @import("journals/outcome.zig");
pub const prompt = @import("prompt.zig");
pub const provider = @import("provider.zig");
pub const remote = @import("environment/remote/mod.zig");
pub const remote_protocol = @import("environment/remote/protocol.zig");
pub const session = @import("session.zig");
pub const store = @import("extension/store.zig");
pub const templates = @import("extension/build/templates.zig");
pub const tool = @import("tool.zig");
pub const tool_stats = @import("journals/tool_stats.zig");
pub const trust = @import("journals/trust.zig");
