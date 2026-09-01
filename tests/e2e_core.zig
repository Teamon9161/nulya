//! The kernel surface of the end-to-end suite (`zig build e2e-core`): the
//! durable ledger, the `nulya session *` driver face, the gate, images in a
//! user turn, background tasks, and the self-description entry.
//!
//!   e2e/support.zig      shared fixtures — CLI runners, scaffolds, fake models
//!   e2e/session.zig      the durable ledger and the `nulya session *` surface
//!   e2e/vision.zig       images in a user turn: the catalog gate, the line, events
//!   e2e/background.zig   background tasks: the supervisor, `nulya task …`,
//!                        `shell {background:true}` and the report it deposits
//!   e2e/gate_pin.zig     the gate request's frozen columns, and pin ⇒ membership
//!   e2e/exec_env.zig     `session new --env`: where a session's shell commands
//!                        run, frozen in the header, never silently local
//!   e2e/cli.zig          the self-description entry: `nulya help`, `ext api`
//!                        topics, the kernel prompt's bootstrap sentence, guide
//!   e2e/journal.zig      `nulya journal append|read`: the append-only JSONL
//!                        discipline exposed as a CLI verb
//!
//! The other groups are `e2e-ext`, `e2e-agent` and `e2e-std`; `zig build e2e`
//! depends on all four and runs them in parallel.

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/session.zig");
    _ = @import("e2e/vision.zig");
    _ = @import("e2e/background.zig");
    _ = @import("e2e/gate_pin.zig");
    _ = @import("e2e/exec_env.zig");
    _ = @import("e2e/cli.zig");
    _ = @import("e2e/journal.zig");
}
