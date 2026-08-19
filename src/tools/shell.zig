//! Builtin tool: shell (base-tools.md §4).
//!
//! `{ command, cwd?, timeout_ms?, background? }`. Hands the command to the
//! execution Environment (which picks the dialect and provides a sanitized child
//! env — DESIGN §8/§9), captures stdout+stderr, appends the exit code, and
//! returns raw text. The agent loop applies `emit` uniformly after every
//! executor returns.
//!
//! `background: true` is the other half (DESIGN §6.1): the command is started
//! DETACHED and this returns at once with a receipt. It is a flag on this tool
//! rather than a separate CLI verb on purpose — a gate and an approval policy
//! read `shell`'s own `command`, and a `nulya task run -- rm -rf x` wrapper would
//! blind both of them.

const std = @import("std");
const builtin = @import("builtin");
const tool = @import("../tool.zig");
const environment = @import("../environment.zig");

/// Raise the runner's capture cap well above the emit budget so that `emit` —
/// not the process runner — is what decides truncation.
const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;

pub const def: tool.Tool = .{
    .definition = .{
        .id = "builtin.shell",
        .name = "shell",
        .description = "Run a command in the configured shell. With background:true it starts detached and returns at once; you are told when it finishes.",
        .input_schema =
        \\{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"timeout_ms":{"type":"integer"},"background":{"type":"boolean"}},"required":["command"]}
        ,
    },
    .executor = tool.functionExecutor(run),
};

/// What a background call is told when there is no session to report back to.
/// Teaching, not just refusing: the tool says how to get one and what to do
/// right now (base-tools.md §1).
const no_session_text = "background needs a durable session (nulya session new); run it in the foreground here";

fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const parsed = try tool.parseArgs(alloc, req.args_json);
    defer parsed.deinit();
    const args = parsed.value;

    const command = try tool.requireString(args, "command");
    const cwd = tool.optionalString(args, "cwd") orelse req.ctx.cwd;

    const background = backgroundFlag(args) catch return .{
        .ok = false,
        .output = try alloc.dupe(u8, "background must be true or false; omit it to run the command in the foreground"),
    };
    if (background) return startBackground(alloc, req, args, command, cwd);

    const timeout_ms = timeoutMs(args) catch return .{
        .ok = false,
        .output = try std.fmt.allocPrint(
            alloc,
            "timeout_ms must be a positive integer of milliseconds (clamped to {d} max); omit it for the {d} ms default",
            .{ tool.Timeouts.shell_max_ms, tool.Timeouts.shell_default_ms },
        ),
    };

    const outcome = req.ctx.environment.runShell(alloc, .{
        .command = command,
        .cwd = cwd,
        .max_output_bytes = MAX_CAPTURE_BYTES,
        .timeout_ms = timeout_ms,
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
    // A timeout says so between the captured output and the exit line: what is
    // above is real but partial, and the exit code is the host's, not the
    // command's (base-tools.md §3).
    if (outcome.timed_out) {
        if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
        try raw.print(alloc, "[timed out after {d} ms; process killed, output above is partial]", .{timeout_ms});
    }
    if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
    try raw.print(alloc, "[exit {d}]", .{outcome.exit_code});

    const out = try raw.toOwnedSlice(alloc);
    return .{ .ok = outcome.exit_code == 0 and !outcome.timed_out, .output = out };
}

/// Start the command detached and answer immediately. The receipt is the whole
/// of what the model gets now — a name, where the output is accumulating, and
/// the three commands that ask about it — because the RESULT arrives later, as
/// its own turn (DESIGN §3.1, §6.1).
fn startBackground(
    alloc: std.mem.Allocator,
    req: tool.ToolRequest,
    args: std.json.Value,
    command: []const u8,
    cwd: []const u8,
) anyerror!tool.RawToolResult {
    const timeout_ms = backgroundTimeoutMs(args) catch return .{
        .ok = false,
        .output = try alloc.dupe(u8, "timeout_ms must be a positive integer of milliseconds; omit it and the task runs until it finishes or you kill it"),
    };

    const start = req.ctx.environment.startShellTask(alloc, .{
        .command = command,
        .cwd = cwd,
        .timeout_ms = timeout_ms,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // Nowhere to report a result TO. Not a failure of the command — it was
        // never started — so the model is told what is missing, and what works.
        error.NoDurableSession => return .{ .ok = false, .output = try alloc.dupe(u8, no_session_text) },
        else => return .{
            .ok = false,
            .output = try std.fmt.allocPrint(alloc, "could not start a background task: {s}", .{@errorName(err)}),
        },
    };
    defer start.deinit(alloc);

    return .{ .ok = true, .output = try std.fmt.allocPrint(
        alloc,
        "[background task {s} started] {s}\nlog: {s}\n" ++
            "You will be told when it finishes (exit code and the tail of its output). Until then: " ++
            "nulya task status {s} · nulya task wait {s} --timeout-ms 60000 · nulya task kill {s}; " ++
            "read its output so far with tail.",
        .{ start.task_id, command, start.log_path, start.task_id, start.task_id, start.task_id },
    ) };
}

/// `background` is a bool or it is nothing: a string `"yes"` is refused rather
/// than guessed at, the same discipline `timeout_ms` follows. Getting this wrong
/// silently would mean the model believes a command is running in the background
/// while the step waits for it (or the reverse).
fn backgroundFlag(args: std.json.Value) !bool {
    if (args != .object) return false;
    const v = args.object.get("background") orelse return false;
    if (v != .bool) return error.InvalidBackground;
    return v.bool;
}

/// A background task's budget: passed through as given, with NO default and NO
/// ceiling (DESIGN §6.1). Outliving the step is the whole point of the flag, so
/// the foreground's 120s / 600s would defeat it; what ends a task instead is
/// `nulya task kill`. Only the "not a positive integer" refusal is shared.
fn backgroundTimeoutMs(args: std.json.Value) !?u32 {
    if (args != .object) return null;
    const v = args.object.get("timeout_ms") orelse return null;
    if (v != .integer or v.integer <= 0 or v.integer > std.math.maxInt(u32)) return error.InvalidTimeout;
    return @intCast(v.integer);
}

/// The command's wall-clock budget: the model's `timeout_ms` clamped into
/// `[1, shell_max_ms]`, or the default when it said nothing (`tool.Timeouts`,
/// base-tools.md §3). A non-integer or non-positive value is refused rather than
/// rounded, so the model is told once instead of silently getting another number.
fn timeoutMs(args: std.json.Value) !u32 {
    if (args != .object) return tool.Timeouts.shell_default_ms;
    const v = args.object.get("timeout_ms") orelse return tool.Timeouts.shell_default_ms;
    if (v != .integer or v.integer <= 0) return error.InvalidTimeout;
    return @intCast(@min(v.integer, @as(i64, tool.Timeouts.shell_max_ms)));
}

test "a command that outruns its timeout_ms is killed and reported, not waited on" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_real: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = root_real[0..try tmp.dir.realPath(io, &root_real)];

    // The DEFAULT dialect on purpose — on this project's development machine
    // that is Git Bash, whose `bin\bash.exe` re-execs the real shell as a
    // grandchild that holds the pipe write-ends. Killing only the direct child
    // would leave the drain blocked for the command's full 5s, so the elapsed
    // assertion below is the proof the whole process TREE dies (see `Tree` in
    // environment.zig). Same on POSIX, where `bash -lc "a; b"` forks for `b`.
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // Print first, then sleep far past the budget: the output above the kill must
    // come back with the result (base-tools.md §3), not be thrown away.
    //
    // The budget has to clear the INTERPRETER's own startup, not just the
    // command's: nothing is written until the shell is up, and the kill does not
    // wait for that. Measured on this project's development machine, `bash -lc
    // "echo …; sleep 5"` through the Git Bash launcher takes 268-425 ms (n=15,
    // mean 309) to put its first byte in the pipe — so the 300 ms this test used
    // to allow sat inside that spread, and roughly one run in eight killed the
    // child before `echo` had run at all. That was the test asserting an ordering
    // the OS never promised it, not output being lost after the write: with the
    // budget clear of startup the marker is there every time. Keep it well above
    // interpreter startup and well below the command's own sleep — both bounds
    // are what the assertions below read.
    const args_json = switch (lenv.dialect_val) {
        .bash => "{\"command\":\"echo before-the-wait; sleep 5\",\"timeout_ms\":1500}",
        .powershell => "{\"command\":\"Write-Output before-the-wait; Start-Sleep -Seconds 5\",\"timeout_ms\":1500}",
    };

    const started = std.Io.Timestamp.now(io, .awake);
    const res = try run(alloc, .{
        .args_json = args_json,
        .ctx = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
    });
    defer alloc.free(res.output);
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    // The budget is what ended it, not the command: startup plus 1500ms lands
    // around 1.8s, well under the 5s sleep. It was ~5000ms before the tree kill,
    // which is exactly the regression this pins.
    try std.testing.expect(elapsed_ms >= 0 and elapsed_ms < 4000);
    try std.testing.expect(!res.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "timed out after 1500 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "output above is partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "before-the-wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "[exit 1]") != null);
}

test "timeout_ms is clamped to the max, and a non-integer teaches instead of guessing" {
    const alloc = std.testing.allocator;

    // Missing: the kernel default (base-tools.md §3).
    const parsed_default = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"x\"}", .{});
    defer parsed_default.deinit();
    try std.testing.expectEqual(tool.Timeouts.shell_default_ms, try timeoutMs(parsed_default.value));

    // Above the ceiling: clamped, not refused — the model asked for "as long as
    // possible" and gets exactly that.
    const parsed_big = try std.json.parseFromSlice(std.json.Value, alloc, "{\"timeout_ms\":9999999}", .{});
    defer parsed_big.deinit();
    try std.testing.expectEqual(tool.Timeouts.shell_max_ms, try timeoutMs(parsed_big.value));

    const parsed_ok = try std.json.parseFromSlice(std.json.Value, alloc, "{\"timeout_ms\":1500}", .{});
    defer parsed_ok.deinit();
    try std.testing.expectEqual(@as(u32, 1500), try timeoutMs(parsed_ok.value));

    // A string or a zero is refused: silently substituting another number would
    // leave the model believing a bound it never got.
    for ([_][]const u8{ "{\"timeout_ms\":\"300\"}", "{\"timeout_ms\":0}", "{\"timeout_ms\":-5}", "{\"timeout_ms\":1.5}" }) |body| {
        const bad = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer bad.deinit();
        try std.testing.expectError(error.InvalidTimeout, timeoutMs(bad.value));
    }
}

test "background:true outside a durable session teaches instead of starting anything" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_real: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = root_real[0..try tmp.dir.realPath(io, &root_real)];

    // An environment with no session — a `session new`, the demo, a library
    // caller. There is nowhere to deposit a `task_finished`, so nothing starts.
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    const ctx: tool.ToolContext = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd };

    const res = try run(alloc, .{
        .args_json = "{\"command\":\"echo never\",\"background\":true}",
        .ctx = ctx,
    });
    defer alloc.free(res.output);
    try std.testing.expect(!res.ok);
    try std.testing.expectEqualStrings(no_session_text, res.output);
    // And it really did not start: no tasks tree was created anywhere.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".nulya", .{}));

    // A `background` that is not a bool is refused, not guessed at — believing
    // a command is detached when it is not (or the reverse) is the failure this
    // prevents.
    const bad = try run(alloc, .{
        .args_json = "{\"command\":\"echo never\",\"background\":\"yes\"}",
        .ctx = ctx,
    });
    defer alloc.free(bad.output);
    try std.testing.expect(!bad.ok);
    try std.testing.expect(std.mem.indexOf(u8, bad.output, "background must be true or false") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".nulya", .{}));
}

test "a background timeout is passed through unclamped; a foreground one is still clamped" {
    const alloc = std.testing.allocator;

    // No default and no ceiling: outliving the step is the point (DESIGN §6.1).
    const none = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"x\"}", .{});
    defer none.deinit();
    try std.testing.expectEqual(@as(?u32, null), try backgroundTimeoutMs(none.value));

    const huge = try std.json.parseFromSlice(std.json.Value, alloc, "{\"timeout_ms\":3600000}", .{});
    defer huge.deinit();
    try std.testing.expectEqual(@as(?u32, 3_600_000), (try backgroundTimeoutMs(huge.value)).?);
    // The same number in the foreground is still clamped to the kernel ceiling.
    try std.testing.expectEqual(tool.Timeouts.shell_max_ms, try timeoutMs(huge.value));

    for ([_][]const u8{ "{\"timeout_ms\":0}", "{\"timeout_ms\":-1}", "{\"timeout_ms\":\"600\"}" }) |body| {
        const bad = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer bad.deinit();
        try std.testing.expectError(error.InvalidTimeout, backgroundTimeoutMs(bad.value));
    }
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
