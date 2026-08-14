//! Builtin tool: shell (base-tools.md §4).
//!
//! `{ command, cwd?, timeout_ms? }`. Runs `sh -c <command>`, captures
//! stdout+stderr, appends the exit code, and passes everything through `emit`
//! so overflow is spilled — the model never picks an output mode.
//!
//! Skeleton scope: synchronous run only. Background tasks / streaming / timeout
//! enforcement are later work (base-tools.md §4).

const std = @import("std");
const tool = @import("../tool.zig");
const emit = @import("../emit.zig");

/// Raise Child.run's own cap well above the emit budget so that `emit` — not
/// the process runner — is what decides truncation.
const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;

pub const def: tool.Tool = .{
    .name = "shell",
    .description = "Run a shell command (`sh -c`). Args: {command, cwd?}.",
    .run = run,
};

fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.ToolResult {
    const command = try tool.requireString(req.args, "command");
    const cwd = tool.optionalString(req.args, "cwd") orelse req.ctx.cwd;

    const result = std.process.run(alloc, req.ctx.io, .{
        .argv = &.{ "sh", "-c", command },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(MAX_CAPTURE_BYTES),
        .stderr_limit = .limited(MAX_CAPTURE_BYTES),
    }) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "failed to spawn shell: {s}", .{@errorName(err)});
        return .{ .ok = false, .output = msg };
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };

    // Assemble stdout, then a `--- stderr ---` section, then the exit line.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, result.stdout);
    if (result.stderr.len > 0) {
        if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
        try raw.appendSlice(alloc, "--- stderr ---\n");
        try raw.appendSlice(alloc, result.stderr);
    }
    if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
    try raw.print(alloc, "[exit {d}]", .{exit_code});

    const out = try emit.emit(alloc, req.ctx.io, raw.items, "shell", req.ctx.seq, req.ctx.scratch_dir, req.ctx.budget);
    return .{ .ok = exit_code == 0, .output = out.text, .spill_path = out.spill_path };
}
