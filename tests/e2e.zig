//! End-to-end proof of the milestone (DESIGN §16): "Nulya v0.1 ships two tools.
//! The third is created by Nulya itself."
//!
//! This scaffolds a real extension, builds it with the HOST's zig (injected via
//! NULYA_TEST_ZIG by build.zig so the ~90MB embed is not needed), activates the
//! immutable version, then invokes it through the same Environment seam a live
//! agent would use — and checks the wire response round-trips. Run with
//! `zig build e2e`.
//!
//! It also covers the durable ledger (DESIGN §3.4): a session created with
//! `createDurable` persists to a JSONL file, a second process `openDurable`
//! resumes it and projects a block-identical PromptIR, a separate CLI process's
//! `capability_note` deposit is drained on the next step, and a crash-left
//! assistant-with-calls tail is repaired on resume.
//!
//! And the `nulya session *` CLI (PLAN §3.2): a shell-script driver runs a goal
//! loop to completion, and `--max-steps` is enforced by the kernel even when the
//! loop-mode model would run forever.
//!
//! And script extensions (DESIGN §7.1): a script extension goes init(--script) →
//! build (no toolchain) → activate → run → pinned native and executes through
//! its interpreter; its version excludes compiler identity and is rebuild-stable.
//!
//! And the slow loop's substrate (M5): a verdict recorded while another process
//! holds the session lease (DESIGN §3.3); per-step usage on the assistant event,
//! not projected (§3.1); extensions discovered across workspace and user store
//! roots with first-root-wins shadowing, and a frozen version resolved from
//! whichever root holds it (§7.2); `ext build` landing under the store root by
//! manifest id; `session new --with` composing a built-but-inactive version into
//! one session; `session list --json`; and the repo's own `extensions/evolution`
//! going through exactly that path with no special casing.
//!
//! And the model-driven handoff (M2c, DESIGN §11): `compact`'s `brief_file`
//! branch forking at the parent's tail while leaving the parent file
//! byte-identical; the bundled `handoff` tool refusing an incomplete brief and a
//! call from outside a session without writing anything, and recording a complete
//! one; a session that pins `ext:handoff/handoff` reaching the frozen version
//! natively; and the real `drivers/goal` script running the whole loop — the
//! model hands off, the driver forks through compact, the goal completes in the
//! child, control lines on stdout and the step's `--stream` protocol on stderr.
//!
//! The tests live in `tests/e2e/`, grouped by what they prove:
//!
//!   e2e/support.zig      shared fixtures — CLI runners, scaffolds, fake models
//!   e2e/extension.zig    the extension lifecycle, store roots, bundled packages
//!   e2e/session.zig      the durable ledger and the `nulya session *` surface
//!   e2e/manufacture.zig  the flagship self-manufacture + pin proof
//!   e2e/source.zig       `nulya src` / `ext api`
//!   e2e/cli.zig          the self-description entry: `nulya help`, `ext api`
//!                        topics, the kernel prompt's bootstrap sentence, guide

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/extension.zig");
    _ = @import("e2e/session.zig");
    _ = @import("e2e/manufacture.zig");
    _ = @import("e2e/source.zig");
    _ = @import("e2e/cli.zig");
}
