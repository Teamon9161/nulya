//! Builtin tool: shell (base-tools.md §4).
//!
//! `{ command, cwd? }`. Hands the command to the execution Environment (which
//! picks the dialect and provides a sanitized child env — DESIGN §8/§9),
//! captures stdout+stderr, appends the exit code, and returns raw text. The
//! agent loop applies `emit` uniformly after every executor returns.
//!
//! Skeleton scope: synchronous run only. Background tasks / streaming / timeout
//! enforcement are later work (base-tools.md §4).

const std = @import("std");
const tool = @import("../tool.zig");

/// Raise the runner's capture cap well above the emit budget so that `emit` —
/// not the process runner — is what decides truncation.
const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;

pub const def: tool.Tool = .{
    .definition = .{
        .id = "builtin.shell",
        .name = "shell",
        .description = "Run a command in the configured shell.",
        .input_schema =
        \\{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"}},"required":["command"]}
        ,
    },
    .batch_policy = .sequential,
    .executor = tool.functionExecutor(run),
};

fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const command = try tool.requireString(req.args, "command");
    const cwd = tool.optionalString(req.args, "cwd") orelse req.ctx.cwd;

    const outcome = req.ctx.environment.runShell(alloc, .{
        .command = command,
        .cwd = cwd,
        .max_output_bytes = MAX_CAPTURE_BYTES,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "failed to spawn shell: {s}", .{@errorName(err)});
        return .{ .ok = false, .output = msg };
    };
    defer outcome.deinit(alloc);

    // Assemble stdout, then a `--- stderr ---` section, then the exit line.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, outcome.stdout);
    if (outcome.stderr.len > 0) {
        if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
        try raw.appendSlice(alloc, "--- stderr ---\n");
        try raw.appendSlice(alloc, outcome.stderr);
    }
    if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
    try raw.print(alloc, "[exit {d}]", .{outcome.exit_code});

    const out = try raw.toOwnedSlice(alloc);
    return .{ .ok = outcome.exit_code == 0, .output = out };
}
