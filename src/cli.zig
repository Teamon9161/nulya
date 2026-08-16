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
const cli_src = @import("cli/src.zig");
const cli_config = @import("cli/config.zig");

/// The bare-`nulya` demo composes a session through the same code path
/// `session new` does, so the two cannot drift (DESIGN §14).
pub const createSession = cli_session.createSession;

/// The top-level help — also what a bare `nulya ext` / `nulya skill` prints, so
/// it lives beside the rest of the shared plumbing rather than here.
pub const usage = common.usage;

/// Dispatch `args` (everything after the program name). Returns a process exit
/// code. Errors are printed and turned into a non-zero code by `main`.
pub fn dispatch(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return usage(io);
    if (std.mem.eql(u8, args[0], "ext")) return ext.dispatchExt(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "skill")) return skill.dispatchSkill(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "toolchain")) return cli_toolchain.dispatchToolchain(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "session")) return cli_session.dispatchSession(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "src")) return cli_src.dispatchSrc(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "config")) return cli_config.dispatchConfig(alloc, io, args[1..]);
    try common.printErr(io, "unknown command; try `nulya ext`, `nulya skill`, `nulya session`, `nulya config`, `nulya src`, or `nulya toolchain`\n");
    return 1;
}
