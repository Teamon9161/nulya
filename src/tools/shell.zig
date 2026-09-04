//! Builtin tool: shell.
//!
//! `{ command, cwd?, timeout_ms?, background? }`. Hands the command to the
//! execution Environment (which picks the dialect and provides a sanitized child
//! env), captures stdout+stderr, appends the exit code, and returns raw text;
//! the loop applies `emit` afterwards.
//!
//! `background: true` starts the command DETACHED and returns at once with a
//! receipt. A flag on this tool rather than a separate CLI verb because a gate
//! and an approval policy read `shell`'s own `command`, and a wrapper verb would
//! blind both.

const std = @import("std");
const builtin = @import("builtin");
const tool = @import("../tool.zig");
const environment = @import("../environment.zig");

/// Well above the emit budget, so `emit` decides truncation, not the runner.
const MAX_CAPTURE_BYTES: usize = 8 * 1024 * 1024;

const background_sentence = "With background:true it starts detached and returns at once; you are told when it finishes.";

/// The argv each dialect runs, named and nothing more — how the named shell
/// behaves is not this tool's to explain, and every word here is re-sent on
/// every request. The one non-derivable fact is WHICH shell: on Windows bash
/// wins whenever one is installed, and a wrong guess there is not refused but
/// silently rewritten (bash expands `$_` in a PowerShell pipeline).
const not_powershell = if (builtin.os.tag == .windows) " — a POSIX shell, not PowerShell." else ".";

fn descriptionFor(dialect: environment.Dialect) []const u8 {
    return switch (dialect) {
        .bash => "Run a command as `bash -lc <command>`" ++ not_powershell ++ " " ++ background_sentence,
        .powershell => "Run a command as `powershell -NoProfile -NonInteractive -Command <command>`. " ++ background_sentence,
    };
}

/// The builtin as this session's shell dialect makes it. A function rather than
/// a constant because the description names the interpreter, which is resolved
/// per environment; the description is part of `composition.kernelHash`, so a
/// session resumed under a different shell says so instead of drifting quietly.
pub fn defFor(dialect: environment.Dialect) tool.Tool {
    return .{
        .definition = .{
            .id = "builtin.shell",
            .name = "shell",
            .description = descriptionFor(dialect),
            .input_schema =
            \\{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"timeout_ms":{"type":"integer"},"background":{"type":"boolean"}},"required":["command"]}
            ,
        },
        .executor = tool.functionExecutor(run),
    };
}

/// What a background call is told when there is no session to report back to:
/// how to get one, and what to do right now.
const no_session_text = "background needs a durable session (nulya session new); run it in the foreground here";
const remote_lost_text = "the connection to the machine this session's commands run on ended while this command was in flight; whether it ran, is still running, or never started there is unknown - do not assume either, and do not simply run it again";
const remote_refused_text = "the machine this session's commands run on would not start a background task; check that it is answering (nulya remote check) and run it in the foreground here meanwhile";

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
        // A canceled step must surface AS cancellation, not a shell failure
        // string — the loop consumes it at the step boundary.
        error.Canceled => return error.Canceled,
        // The channel to the machine this session runs on ended mid-command.
        // What happened over there is unknown, so no exit code is invented and
        // nothing is retried — a command that already ran must not run twice.
        error.RemoteChannelLost, error.RemoteChannelStalled => return .{
            .ok = false,
            .output = try alloc.dupe(u8, remote_lost_text),
        },
        else => {
            const msg = try std.fmt.allocPrint(alloc, "failed to spawn shell: {s}", .{@errorName(err)});
            return .{ .ok = false, .output = msg };
        },
    };
    defer outcome.deinit(alloc);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, outcome.stdout);
    if (outcome.stderr.len > 0) {
        if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
        try raw.appendSlice(alloc, "--- stderr ---\n");
        try raw.appendSlice(alloc, outcome.stderr);
    }
    // A timeout says so between the captured output and the exit line: what is
    // above is real but partial, and the exit code is the host's.
    if (outcome.timed_out) {
        if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
        try raw.print(alloc, "[timed out after {d} ms; process killed, output above is partial]", .{timeout_ms});
    }
    if (raw.items.len > 0 and raw.items[raw.items.len - 1] != '\n') try raw.append(alloc, '\n');
    try raw.print(alloc, "[exit {d}]", .{outcome.exit_code});

    const out = try raw.toOwnedSlice(alloc);
    return .{ .ok = outcome.exit_code == 0 and !outcome.timed_out, .output = out };
}

/// Start the command detached and answer immediately with a receipt; the RESULT
/// arrives later as its own turn.
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
        // Nowhere to report a result TO, so the command was never started.
        error.NoDurableSession => return .{ .ok = false, .output = try alloc.dupe(u8, no_session_text) },
        // A start either yields a receipt or an error, so the far side's own
        // sentence cannot come back: say which half failed and where to look.
        error.RemoteTaskRefused => return .{ .ok = false, .output = try alloc.dupe(u8, remote_refused_text) },
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

/// `background` is a bool or nothing: a string `"yes"` is refused rather than
/// guessed at, which would leave the model believing a command runs in the
/// background while the step waits for it, or the reverse.
fn backgroundFlag(args: std.json.Value) !bool {
    if (args != .object) return false;
    const v = args.object.get("background") orelse return false;
    if (v != .bool) return error.InvalidBackground;
    return v.bool;
}

/// A background task's budget: passed through as given, with NO default and NO
/// ceiling — outliving the step is the point. `nulya task kill` ends a task.
fn backgroundTimeoutMs(args: std.json.Value) !?u32 {
    if (args != .object) return null;
    const v = args.object.get("timeout_ms") orelse return null;
    if (v != .integer or v.integer <= 0 or v.integer > std.math.maxInt(u32)) return error.InvalidTimeout;
    return @intCast(v.integer);
}

/// The command's wall-clock budget: the model's `timeout_ms` clamped into
/// `[1, shell_max_ms]`, or the default when it said nothing. A non-integer or
/// non-positive value is refused rather than rounded.
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

    // The DEFAULT dialect on purpose: an interpreter may re-exec the real shell
    // as a grandchild holding the pipe write-ends (Git Bash does; so does
    // `bash -lc "a; b"`). The elapsed assertion below is proof the whole process
    // TREE dies, not just the direct child.
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // Print first, then sleep far past the budget: the output above the kill
    // must come back with the result. The budget must clear the INTERPRETER's
    // own startup (a few hundred ms) and stay well under the 5s sleep.
    const args_json = switch (lenv.dialect_val) {
        .bash => "{\"command\":\"echo before-the-wait; sleep 5\",\"timeout_ms\":1500}",
        .powershell => "{\"command\":\"Write-Output before-the-wait; Start-Sleep -Seconds 5\",\"timeout_ms\":1500}",
    };

    const started = std.Io.Timestamp.now(io, .awake);
    const res = try run(alloc, .{
        .args_json = args_json,
        .ctx = .{ .environment = lenv.environment(), .cwd = cwd },
    });
    defer alloc.free(res.output);
    const elapsed_ms = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();

    // The budget is what ended it, not the command: without the tree kill this
    // would wait out the full 5s sleep.
    try std.testing.expect(elapsed_ms >= 0 and elapsed_ms < 4000);
    try std.testing.expect(!res.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "timed out after 1500 ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "output above is partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "before-the-wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "[exit 1]") != null);
}

test "timeout_ms is clamped to the max, and a non-integer teaches instead of guessing" {
    const alloc = std.testing.allocator;

    const parsed_default = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"x\"}", .{});
    defer parsed_default.deinit();
    try std.testing.expectEqual(tool.Timeouts.shell_default_ms, try timeoutMs(parsed_default.value));

    const parsed_big = try std.json.parseFromSlice(std.json.Value, alloc, "{\"timeout_ms\":9999999}", .{});
    defer parsed_big.deinit();
    try std.testing.expectEqual(tool.Timeouts.shell_max_ms, try timeoutMs(parsed_big.value));

    const parsed_ok = try std.json.parseFromSlice(std.json.Value, alloc, "{\"timeout_ms\":1500}", .{});
    defer parsed_ok.deinit();
    try std.testing.expectEqual(@as(u32, 1500), try timeoutMs(parsed_ok.value));

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

    // No session means nowhere to deposit a report note, so nothing starts.
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    const ctx: tool.ToolContext = .{ .environment = lenv.environment(), .cwd = cwd };

    const res = try run(alloc, .{
        .args_json = "{\"command\":\"echo never\",\"background\":true}",
        .ctx = ctx,
    });
    defer alloc.free(res.output);
    try std.testing.expect(!res.ok);
    try std.testing.expectEqualStrings(no_session_text, res.output);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".nulya", .{}));

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

    const none = try std.json.parseFromSlice(std.json.Value, alloc, "{\"command\":\"x\"}", .{});
    defer none.deinit();
    try std.testing.expectEqual(@as(?u32, null), try backgroundTimeoutMs(none.value));

    const huge = try std.json.parseFromSlice(std.json.Value, alloc, "{\"timeout_ms\":3600000}", .{});
    defer huge.deinit();
    try std.testing.expectEqual(@as(?u32, 3_600_000), (try backgroundTimeoutMs(huge.value)).?);
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
        .ctx = .{ .environment = lenv.environment(), .cwd = cwd },
    };

    var fut = io.async(run, .{ alloc, req });

    // Bounded only so a broken spawn fails instead of hanging; a busy machine
    // may take its time getting the child up.
    var waited: usize = 0;
    while (waited < 1500) : (waited += 1) {
        if (blk: {
            tmp.dir.access(io, "started", .{}) catch break :blk false;
            break :blk true;
        }) break;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    }

    // `run` must let error.Canceled through, not make it a failed shell result.
    try std.testing.expectError(error.Canceled, fut.cancel(io));
}

test "each dialect's description names the argv that dialect actually runs" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The description is the model's ONLY statement of which interpreter it is
    // writing for, so it has to be checked against `shellArgv` rather than
    // maintained beside it: a flag added there and forgotten here sends the
    // model syntax the real shell mangles instead of refusing.
    for ([_]environment.Dialect{ .bash, .powershell }) |dialect| {
        var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .dialect = dialect });
        defer lenv.deinit();

        var buf: [5][]const u8 = undefined;
        const cmdline = try lenv.shellArgv(alloc, "echo hi", &buf);
        defer cmdline.deinit(alloc);

        const described = descriptionFor(dialect);
        // Every argv word but the command itself — the interpreter and each of
        // its flags — has to appear in what the model is told.
        for (cmdline.argv[0 .. cmdline.argv.len - 1], 0..) |word, i| {
            // argv[0] may be an absolute path on a host where the interpreter
            // is not on PATH; the model is told the NAME either way.
            const named = if (i == 0) std.fs.path.stem(word) else word;
            try std.testing.expect(std.mem.indexOf(u8, described, named) != null);
        }
    }
}
