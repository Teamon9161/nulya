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
const environment = @import("../environment.zig");

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
    .executor = tool.functionExecutor(run),
};

fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const parsed = try tool.parseArgs(alloc, req.args_json);
    defer parsed.deinit();
    const args = parsed.value;

    const command = try tool.requireString(args, "command");
    const cwd = tool.optionalString(args, "cwd") orelse req.ctx.cwd;

    const outcome = req.ctx.environment.runShell(alloc, .{
        .command = command,
        .cwd = cwd,
        .max_output_bytes = MAX_CAPTURE_BYTES,
    }) catch |err| switch (err) {
        // A canceled step must surface AS cancellation, not as a shell failure
        // string — the loop consumes it at the step boundary. std.process.run has
        // already killed the child and closed its pipes on this path.
        error.Canceled => return error.Canceled,
        else => {
            const msg = try std.fmt.allocPrint(alloc, "failed to spawn shell: {s}", .{@errorName(err)});
            return .{ .ok = false, .output = msg };
        },
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

test "shell tool reports cancellation as an error, not a failure result" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_real: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_real);
    const cwd = root_real[0..root_len];

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const args_json = switch (lenv.dialect_val) {
        .bash => "{\"command\":\"touch started; sleep 5\"}",
        .powershell => "{\"command\":\"New-Item started -ItemType File -Force > $null; Start-Sleep -Seconds 5\"}",
    };

    const req: tool.ToolRequest = .{
        .args_json = args_json,
        .ctx = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
    };

    var fut = io.async(run, .{ alloc, req });

    // Bounded only so a broken spawn fails instead of hanging; a busy machine is
    // allowed to take its time getting the child up (see `environment.zig`).
    var waited: usize = 0;
    while (waited < 1500) : (waited += 1) {
        if (blk: {
            tmp.dir.access(io, "started", .{}) catch break :blk false;
            break :blk true;
        }) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    }

    // The special-case in `run` must let error.Canceled through rather than
    // producing `{ ok=false, output="failed to spawn shell: Canceled" }`.
    try std.testing.expectError(error.Canceled, fut.cancel(io));
}
