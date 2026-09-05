//! `zig build e2e-ext`: "Nulya ships one tool. The second is created by Nulya
//! itself." Scaffolds a real extension, builds it with the host's zig,
//! activates the immutable version, then invokes it through the same
//! Environment seam a live agent would use.
//!
//! Also covers: script extensions (init -> build, no toolchain -> activate ->
//! run, through their interpreter; version excludes compiler identity and is
//! rebuild-stable; a per-OS `runtime.entry` picks the host's own variant, or
//! fails by name); store roots (workspace/user with first-root-wins
//! shadowing, and `extensions/evolution` going through the same path with no
//! special casing); and the model-driven handoff loop end to end —
//! `compact`'s `brief_file` fork, the bundled `handoff` tool's refusals, a
//! session pinning `ext:handoff/handoff`, and the real `drivers/goal` script
//! running the whole loop.
//!
//! Compiling an extension is a real `zig build-exe` — about seven seconds
//! that no zig cache shortens. `support.zig` keeps a compile-once cache of
//! built versions and copies frozen version directories into each test's
//! store; delete `.zig-cache` to reset it.
//!
//!   e2e/support.zig      shared fixtures — CLI runners, scaffolds, fake models
//!   e2e/extension.zig    the extension lifecycle, store roots, bundled packages
//!   e2e/script_wire.zig  the wire and per-platform entry / interpreter
//!   e2e/manufacture.zig  the flagship self-manufacture + pin proof
//!   e2e/source.zig       `nulya src` / `ext api`
//!   e2e/ext_cli.zig      activation's shape default, `ext run` timeout, `ext inspect`
//!   e2e/mcp.zig          `extensions/mcp`: one MCP server, generated into one package
//!
//! The other groups are `e2e-core`, `e2e-agent`, `e2e-std` and `e2e-remote`;
//! `zig build e2e` is all five.

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/extension.zig");
    _ = @import("e2e/script_wire.zig");
    _ = @import("e2e/manufacture.zig");
    _ = @import("e2e/source.zig");
    _ = @import("e2e/ext_cli.zig");
    _ = @import("e2e/mcp.zig");
}
