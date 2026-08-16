//! Nulya — a minimal, self-evolving AI agent harness.
//!
//! The entry point is a switch and nothing else: `nulya <cmd> …` goes to the
//! CLI (DESIGN §14), bare `nulya` runs the fixed-prompt demo — which is itself
//! a client of that same CLI, so there is only one way a session is created and
//! stepped. This file also aggregates every module's tests for `zig build test`.

const std = @import("std");
const cli = @import("cli.zig");

const demo_prompt = "What system am I on?";

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    // `nulya <cmd> ...` -> CLI (DESIGN §14); bare `nulya` -> the agent-loop demo.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        const argv = try init.arena.allocator().alloc([]const u8, args.len - 1);
        for (args[1..], 0..) |a, i| argv[i] = a;
        return cli.dispatch(alloc, io, argv);
    }

    return runDemo(alloc, io);
}

/// Bare `nulya` runs a fixed-prompt demo over the same durable session path a
/// driver uses (DESIGN §3.4, §14). It is a CLIENT of the CLI's own verbs —
/// `session new`, then `session append`, then `session step` — rather than a
/// second assembly of config, environment and session creation; the
/// demo can therefore never drift from what `nulya session *` actually does.
/// The offline scripted provider stands in when no credential is set (`session
/// new` says so on stderr).
fn runDemo(alloc: std.mem.Allocator, io: std.Io) !u8 {
    const id = (try cli.createSession(alloc, io, &.{})) orelse return 1;
    defer alloc.free(id);
    std.debug.print("session: {s}\n", .{id});

    const appended = try cli.dispatch(alloc, io, &.{ "session", "append", id, demo_prompt });
    if (appended != 0) return appended;
    // stdout is what the step appended, one JSONL event per line.
    return cli.dispatch(alloc, io, &.{ "session", "step", id, "--max-steps", "4" });
}

// Pull unit tests from every module into `zig build test`.
test {
    std.testing.refAllDecls(@This());
    _ = @import("emit.zig");
    _ = @import("ledger.zig");
    _ = @import("tool.zig");
    _ = @import("journal.zig");
    _ = @import("tool_stats.zig");
    _ = @import("outcome.zig");
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
    _ = @import("config.zig");
    _ = @import("extension/protocol.zig");
    _ = @import("extension/invoke.zig");
    _ = @import("extension/tools.zig");
    _ = @import("extension/manifest.zig");
    _ = @import("extension/skills.zig");
    _ = @import("extension/store.zig");
    _ = @import("extension/build_ext.zig");
    _ = @import("session.zig");
    _ = @import("launch.zig");
    _ = @import("cli.zig");
    _ = @import("source.zig");
    _ = @import("toolchain.zig");
}
