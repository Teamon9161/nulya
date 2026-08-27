//! The kernel surface of the end-to-end suite (`zig build e2e-core`): the
//! durable ledger, the `nulya session *` driver face, the gate, images in a
//! user turn, background tasks, and the self-description entry.
//!
//! The durable ledger (DESIGN §3.4): a session created with `createDurable`
//! persists to a JSONL file, a second process `openDurable` resumes it and
//! projects a block-identical PromptIR, a separate CLI process's
//! `capability_note` deposit is drained on the next step, and a crash-left
//! assistant-with-calls tail is repaired on resume.
//!
//! The `nulya session *` CLI (PLAN §3.2): a shell-script driver runs a goal
//! loop to completion, and `--max-steps` is enforced by the kernel even when the
//! loop-mode model would run forever. Plus the slow loop's substrate (M5): a
//! verdict recorded while another process holds the session lease (DESIGN §3.3),
//! per-step usage on the assistant event, `session new --with` composing a
//! built-but-inactive version into one session, and `session list --json`.
//!
//! The self-description entry (guide): `nulya help` printing one screen that
//! every bare verb family is a strict substring of, `ext api manifest` /
//! `examples` stating today's authority and a worked path with no document
//! citations anywhere the model can read, a fresh session's kernel system block
//! naming NULYA_EXE / `nulya help` / `nulya src`, and the repo's own
//! `extensions/guide` composing in as one skill and no system prompt.
//!
//!   e2e/support.zig      shared fixtures — CLI runners, scaffolds, fake models
//!   e2e/session.zig      the durable ledger and the `nulya session *` surface
//!   e2e/vision.zig       images in a user turn: the catalog gate, the line, events
//!   e2e/background.zig   background tasks: the supervisor, `nulya task …`,
//!                        `shell {background:true}` and the report it deposits
//!   e2e/gate_pin.zig     the gate request's frozen columns, and pin ⇒ membership
//!   e2e/cli.zig          the self-description entry: `nulya help`, `ext api`
//!                        topics, the kernel prompt's bootstrap sentence, guide
//!   e2e/journal.zig      `nulya journal append|read`: the append-only JSONL
//!                        discipline exposed as a CLI verb
//!
//! The other groups are `e2e-ext` (tests/e2e_ext.zig), `e2e-agent`
//! (tests/e2e_agent.zig) and `e2e-std` (tests/e2e_std.zig). `zig build e2e`
//! depends on all four, so it is still the whole suite — and the four run in
//! parallel, which is the whole point of there being four.

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/session.zig");
    _ = @import("e2e/vision.zig");
    _ = @import("e2e/background.zig");
    _ = @import("e2e/gate_pin.zig");
    _ = @import("e2e/cli.zig");
    _ = @import("e2e/journal.zig");
}
