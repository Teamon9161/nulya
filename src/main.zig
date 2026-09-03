//! Nulya — a minimal, self-evolving AI agent harness.
//!
//! The entry point is a switch and nothing else: every invocation goes to
//! `cli.dispatch`. This file also aggregates every module's tests.

const std = @import("std");
const cli = @import("cli.zig");
const environment = @import("environment.zig");
const ssh_askpass = @import("environment/remote/ssh_askpass.zig");

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    // std 0.16 hands the OS environ only to `main`; register it once so every
    // layer that reads host env sees the real environment.
    environment.registerHostEnviron(init.minimal.environ);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const argv = try init.arena.allocator().alloc([]const u8, args.len -| 1);
    for (args[1..], 0..) |a, i| argv[i] = a;

    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    // OpenSSH invokes SSH_ASKPASS with exactly one argv word: its prompt. A
    // private marker env var selects the helper before the ordinary CLI sees
    // that argv; requiring the one-word shape too keeps a broad SendEnv rule
    // from making a remote `nulya remote serve` mistake a forwarded marker for
    // a helper invocation.
    if (argv.len == 1) if (host.get(ssh_askpass.marker_env)) |marker|
        return ssh_askpass.runHelper(io, marker);

    return cli.dispatch(alloc, io, argv);
}

// Pull unit tests from every module into `zig build test`.
test {
    std.testing.refAllDecls(@This());
    _ = @import("diag.zig");
    _ = @import("emit.zig");
    _ = @import("ledger.zig");
    _ = @import("lease.zig");
    _ = @import("tool.zig");
    _ = @import("journals/journal.zig");
    _ = @import("journals/tool_stats.zig");
    _ = @import("journals/outcome.zig");
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
    _ = @import("providers/scripted.zig");
    _ = @import("environment.zig");
    _ = @import("environment/tree.zig");
    _ = @import("environment/remote/mod.zig");
    _ = @import("environment/remote/protocol.zig");
    _ = @import("environment/remote/ssh_askpass.zig");
    _ = @import("environment/remote/install.zig");
    _ = @import("config.zig");
    _ = @import("extension/protocol.zig");
    _ = @import("extension/invoke.zig");
    _ = @import("extension/tools.zig");
    _ = @import("extension/manifest.zig");
    _ = @import("extension/skills.zig");
    _ = @import("extension/store.zig");
    _ = @import("extension/site.zig");
    _ = @import("extension/build/build_ext.zig");
    _ = @import("session.zig");
    _ = @import("launch.zig");
    _ = @import("cli.zig");
    _ = @import("cli/common.zig");
    _ = @import("cli/session.zig");
    _ = @import("cli/session_list.zig");
    _ = @import("cli/task.zig");
    _ = @import("cli/task_remote.zig");
    _ = @import("cli/remote.zig");
    _ = @import("cli/step_stream.zig");
    _ = @import("cli/ext.zig");
    _ = @import("cli/ext_seed.zig");
    _ = @import("cli/config.zig");
    _ = @import("cli/skill.zig");
    _ = @import("cli/src.zig");
    _ = @import("cli/remote_agent.zig");
    _ = @import("cli/toolchain.zig");
    _ = @import("selfbuild.zig");
    _ = @import("source.zig");
    _ = @import("bundled.zig");
    _ = @import("extension/build/toolchain.zig");
}
