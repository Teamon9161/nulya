//! CLI surface (DESIGN §14). None of these are model-facing tools: the model
//! reaches them through `shell`, keeping its tool face tiny. `nulya ext api`
//! prints THIS binary's real protocol so the model never guesses a signature.
//!
//! This file is the dispatcher and nothing else: one file per verb family under
//! `cli/`, plus `cli/common.zig` for the plumbing two or more of them share.

const std = @import("std");
const common = @import("cli/common.zig");
const ext = @import("cli/ext.zig");
const skill = @import("cli/skill.zig");
const cli_toolchain = @import("cli/toolchain.zig");
const cli_session = @import("cli/session.zig");
const cli_task = @import("cli/task.zig");
const cli_remote = @import("cli/remote.zig");
const cli_journal = @import("cli/journal.zig");
const cli_src = @import("cli/src.zig");
const cli_config = @import("cli/config.zig");

/// `nulya demo` composes a session through the same code path `session new`
/// does, so the two cannot drift (DESIGN §14).
pub const createSession = cli_session.createSession;

const demo_prompt = "What system am I on?";

/// The top-level help — also what a bare `nulya ext` / `nulya skill` prints, so
/// it lives beside the rest of the shared plumbing rather than here.
pub const usage = common.usage;

/// Dispatch `args` (everything after the program name). Returns a process exit
/// code. Errors are printed and turned into a non-zero code by `main`.
pub fn dispatch(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return usage(io);
    // `help` is a verb like any other so that a model which reached this binary
    // through `shell` can ask it what it can do without guessing a flag; the two
    // flag spellings are here because everything else on a terminal accepts them.
    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) return usage(io);
    if (std.mem.eql(u8, args[0], "ext")) return ext.dispatchExt(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "skill")) return skill.dispatchSkill(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "toolchain")) return cli_toolchain.dispatchToolchain(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "session")) return cli_session.dispatchSession(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "task")) return cli_task.dispatchTask(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "remote")) return cli_remote.dispatchRemote(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "journal")) return cli_journal.dispatchJournal(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "src")) return cli_src.dispatchSrc(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "config")) return cli_config.dispatchConfig(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "demo")) return runDemo(alloc, io);
    try common.printErrFmt(alloc, io, "unknown command '{s}'; run `nulya help`\n", .{args[0]});
    return 1;
}

/// `nulya demo` runs a fixed-prompt session over the same durable path a driver
/// uses (DESIGN §3.4, §14). It is a CLIENT of the verbs beside it — `session
/// new`, then `session append`, then `session step` — rather than a second
/// assembly of config, environment and session creation, so it can never drift
/// from what `nulya session *` actually does. The offline scripted provider
/// stands in when no credential is set (`session new` says so on stderr).
///
/// A verb rather than what a bare `nulya` does: running the binary with no
/// arguments should say what it can do, not start writing session files.
fn runDemo(alloc: std.mem.Allocator, io: std.Io) !u8 {
    const id = (try cli_session.createSession(alloc, io, &.{}, .stand_in)) orelse return 1;
    defer alloc.free(id);
    std.debug.print("session: {s}\n", .{id});

    const appended = try cli_session.dispatchSession(alloc, io, &.{ "append", id, demo_prompt });
    if (appended != 0) return appended;
    // stdout is what the step appended, one JSONL event per line.
    return cli_session.dispatchSession(alloc, io, &.{ "step", id, "--max-steps", "4" });
}
