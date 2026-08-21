//! Nulya — a minimal, self-evolving AI agent harness.
//!
//! The entry point is a switch and nothing else: every invocation — including
//! the bare one, which prints the usage screen — goes to `cli.dispatch`
//! (DESIGN §14). The fixed-prompt demo is a verb like any other (`nulya demo`),
//! so there is no behaviour reachable only by running the binary with no
//! arguments. This file also aggregates every module's tests for `zig build
//! test`.

const std = @import("std");
const cli = @import("cli.zig");
const environment = @import("environment.zig");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    // std 0.16 hands the OS environ only to `main`; register it once so the
    // layers that read host env (config chain, NULYA_* vars, child-env
    // sanitization) see the real environment (environment.hostEnvironMap).
    environment.registerHostEnviron(init.minimal.environ);

    // `nulya <cmd> ...` -> CLI (DESIGN §14); bare `nulya` -> the usage screen,
    // which `dispatch` prints for an empty argv.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const argv = try init.arena.allocator().alloc([]const u8, args.len -| 1);
    for (args[1..], 0..) |a, i| argv[i] = a;
    return cli.dispatch(alloc, io, argv);
}

// Pull unit tests from every module into `zig build test`.
test {
    std.testing.refAllDecls(@This());
    _ = @import("emit.zig");
    _ = @import("ledger.zig");
    _ = @import("tool.zig");
    _ = @import("journals/journal.zig");
    _ = @import("journals/tool_stats.zig");
    _ = @import("journals/outcome.zig");
    _ = @import("journals/trust.zig");
    _ = @import("registry.zig");
    _ = @import("skill.zig");
    _ = @import("composition.zig");
    _ = @import("loop.zig");
    _ = @import("prompt.zig");
    _ = @import("provider.zig");
    _ = @import("providers/wire.zig");
    _ = @import("providers/openai.zig");
    _ = @import("providers/anthropic.zig");
    _ = @import("providers/codex.zig");
    _ = @import("environment.zig");
    _ = @import("environment/tree.zig");
    _ = @import("config.zig");
    _ = @import("extension/protocol.zig");
    _ = @import("extension/invoke.zig");
    _ = @import("extension/tools.zig");
    _ = @import("extension/manifest.zig");
    _ = @import("extension/skills.zig");
    _ = @import("extension/store.zig");
    _ = @import("extension/roots.zig");
    _ = @import("extension/build/build_ext.zig");
    _ = @import("session.zig");
    _ = @import("launch.zig");
    _ = @import("cli.zig");
    _ = @import("cli/common.zig");
    _ = @import("cli/session.zig");
    _ = @import("cli/session_list.zig");
    _ = @import("cli/task.zig");
    _ = @import("cli/step_stream.zig");
    _ = @import("cli/ext.zig");
    _ = @import("cli/ext_seed.zig");
    _ = @import("cli/config.zig");
    _ = @import("cli/skill.zig");
    _ = @import("cli/src.zig");
    _ = @import("cli/toolchain.zig");
    _ = @import("source.zig");
    _ = @import("bundled.zig");
    _ = @import("extension/build/toolchain.zig");
}
