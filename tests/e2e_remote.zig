//! The remote environment (`zig build e2e-remote`): the channel, the two host
//! verbs, and a session whose commands run on another machine.
//!
//! **The "other machine" here is this one, over a pipe.** `--env
//! remote:exec:<this binary>` starts a real `nulya remote serve` and talks to
//! it through the real protocol, so both ends of every assertion below are
//! production code. That is what `remote:exec:` is for, beyond the container
//! runtimes it also serves: the general launcher form is what makes the whole
//! backend testable with no network, no ssh key and no WSL.
//!
//! A second binary (`tests/fake_remote.zig`) covers the shapes a correct agent
//! never produces — the wrong version, a half-written frame, a peer that stops
//! talking mid-command, a lied-about payload length.
//!
//!   e2e/remote.zig   the whole group
//!
//! The other groups are `e2e-ext`, `e2e-core`, `e2e-agent` and `e2e-std`.
//! `zig build e2e` depends on all five.

comptime {
    _ = @import("e2e/remote.zig");
}
