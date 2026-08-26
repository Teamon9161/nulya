//! End-to-end proof of the milestone (DESIGN §16), and the group it lives in
//! (`zig build e2e-ext`): "Nulya ships one tool. The second is created by Nulya
//! itself."
//!
//! This scaffolds a real extension, builds it with the HOST's zig (injected via
//! NULYA_TEST_ZIG by build.zig so the ~90MB embed is not needed), activates the
//! immutable version, then invokes it through the same Environment seam a live
//! agent would use — and checks what it printed reaches the caller.
//!
//! And script extensions (DESIGN §7.1): a script extension goes init → build (no
//! toolchain) → activate → run → pinned native and executes through its
//! interpreter; its version excludes compiler identity and is rebuild-stable.
//! The one wire is covered (arguments on stdin, `NULYA_ARG_<k>` in the
//! environment, stdout verbatim, exit code as ok/failed), as is a per-OS
//! `runtime.entry`: the host picks its own variant, and a version naming none
//! for this host is a named hard failure.
//!
//! And the store roots (M5): extensions discovered across workspace and user
//! store roots with first-root-wins shadowing, and a frozen version resolved
//! from whichever root holds it (§7.2); `ext build` landing under the store root
//! by manifest id; and the repo's own `extensions/evolution` going through
//! exactly that path with no special casing.
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
//! Compiling an extension is a real `zig build-exe` — about seven seconds that
//! no zig cache shortens, because DESIGN §7.4 fixes the invocation. So
//! `support.zig` keeps a compile-once cache of built versions under
//! `.zig-cache/` and copies frozen version directories into each test's store;
//! the tests where the BUILD is the subject still compile for real, and they are
//! why this group costs what it does. Delete `.zig-cache` to reset the cache.
//!
//!   e2e/support.zig      shared fixtures — CLI runners, scaffolds, fake models
//!   e2e/extension.zig    the extension lifecycle, store roots, bundled packages
//!   e2e/script_wire.zig  the wire and per-platform entry / interpreter
//!   e2e/manufacture.zig  the flagship self-manufacture + pin proof
//!   e2e/source.zig       `nulya src` / `ext api`
//!   e2e/ext_cli.zig      activation's shape default, `ext run` timeout, `ext
//!                        inspect` (docs/goals/ext-review.md Lane C)
//!
//! The other groups are `e2e-core` (tests/e2e_core.zig), `e2e-agent`
//! (tests/e2e_agent.zig) and `e2e-std` (tests/e2e_std.zig); `zig build e2e` is
//! all four, run in parallel.

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/extension.zig");
    _ = @import("e2e/script_wire.zig");
    _ = @import("e2e/manufacture.zig");
    _ = @import("e2e/source.zig");
    _ = @import("e2e/ext_cli.zig");
}
