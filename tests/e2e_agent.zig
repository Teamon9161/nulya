//! The delegation group of the end-to-end suite (`zig build e2e-agent`), one
//! test binary of its own so it runs beside the other two rather than after them.
//!
//! Everything here is `tests/e2e/agent.zig`: the bundled `agent` package's
//! `d-*` identities and their record, the wake invariant, interrupts, the
//! delegation whitelist and the depth backstop, and each runner that can hold a
//! delegation — a nulya session, Codex, Claude, pi (all three answered offline by
//! the fakes `build.zig` builds for this) and somebody else's extension speaking
//! the `agent_runner` contract (docs/goals/agent-runner.md).
//!
//! These are the suite's slowest tests: every one drives at least one real
//! background task through a real `nulya session step`. Isolating them is what
//! lets the other two groups finish without waiting on them.

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/agent.zig");
}
