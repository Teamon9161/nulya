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
//! And the self-description entry (guide): `nulya help` printing one screen
//! that every bare verb family is a strict substring of, `ext api permissions`
//! / `examples` stating today's authority and a worked path with no document
//! citations anywhere the model can read, a fresh session's kernel system block
//! naming NULYA_EXE / `nulya help` / `nulya src`, and the repo's own
//! `extensions/guide` composing in as one skill and no system prompt.
//!
//! And the bundled `std` extension (docs/goals/std.md): five file/search tools
//! in one compiled package — built, activated, reached by `ext run`; `read`'s
//! self-pagination and freshness stubs, `write` / `append` refusing to touch a
//! file the session has not read (state on disk under the session's scratch
//! dir, none outside a session), `grep`'s smart-case / per-file cap / paging /
//! gitignore, `glob`'s mtime order — and a string JSON-RPC `result` reaching the
//! caller verbatim (DESIGN §7.3).
//!
//! Compiling an extension is a real `zig build-exe`, so `support.zig` keeps a
//! compile-once cache of built versions under `.zig-cache/` and copies frozen
//! version directories into each test's store; the tests where the BUILD is the
//! subject still compile for real. Delete `.zig-cache` to reset it.
//!
//! The tests live in `tests/e2e/`, grouped by what they prove:
//!
//!   e2e/support.zig      shared fixtures — CLI runners, scaffolds, fake models
//!   e2e/extension.zig    the extension lifecycle, store roots, bundled packages
//!   e2e/session.zig      the durable ledger and the `nulya session *` surface
//!   e2e/vision.zig       images in a user turn: the catalog gate, the line, events
//!   e2e/manufacture.zig  the flagship self-manufacture + pin proof
//!   e2e/source.zig       `nulya src` / `ext api`
//!   e2e/cli.zig          the self-description entry: `nulya help`, `ext api`
//!                        topics, the kernel prompt's bootstrap sentence, guide
//!   e2e/std.zig          the bundled `std` extension: fixtures + smoke;
//!   e2e/std_fs.zig       … its read / write / append + freshness;
//!   e2e/std_search.zig   … its grep / glob

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/extension.zig");
    _ = @import("e2e/session.zig");
    _ = @import("e2e/vision.zig");
    _ = @import("e2e/manufacture.zig");
    _ = @import("e2e/source.zig");
    _ = @import("e2e/cli.zig");
    _ = @import("e2e/std.zig");
    _ = @import("e2e/std_fs.zig");
    _ = @import("e2e/std_search.zig");
}
