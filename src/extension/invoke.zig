//! Extension tool invocation (DESIGN §7.3).
//!
//! The narrow seam between a NAMED frozen extension version and the one wire:
//! the arguments on stdin, `NULYA_TOOL` / `NULYA_ARG_<k>` in the environment,
//! stdout verbatim, the exit code as ok/failed. It knows nothing about the
//! extension store: the caller decides WHICH version serves the call (session
//! composition froze it; `ext run` resolved it) and the executing machine
//! decides which file that version means (`extension/exec.zig`). `invokeTool`
//! never asks what `current` means, and never holds a path.
//!
//! The contract itself, and the two pure rules inside it, live in
//! `protocol.zig` — what this file adds is spawning, capture, and the text a
//! failed call is read as.
//!
//! Failure classification — the three kinds never merge:
//!
//!   extension application failure (non-zero exit) → normalized failed invocation
//!   host execution/resource failure                → error
//!   cancellation                                   → error.Canceled unchanged
//!
//! Ownership: the returned `ToolInvocation.output` is owned by the allocator
//! passed to `invokeTool` and freed with `ToolInvocation.deinit`. Every
//! intermediate allocation (per-call environment, captured stdout/stderr,
//! diagnostic) is released on all paths.

const std = @import("std");
const builtin = @import("builtin");
const environment = @import("../environment.zig");
const exec = @import("exec.zig");
const protocol = @import("protocol.zig");
const tool = @import("../tool.zig");

pub const Options = struct {
    /// The cap a caller that has nothing better to say uses. A tool whose
    /// manifest declares its own passes that instead (DESIGN §7.3).
    pub const default_timeout_ms: u32 = tool.Timeouts.extension_ms;

    /// Wall-clock cap for the oneshot call, forwarded to `Environment.runExtension`
    /// (`tool.Timeouts`, base-tools.md §3).
    timeout_ms: u32 = default_timeout_ms,
    /// Runner-level capture cap for the child's stdout/stderr.
    max_output_bytes: usize = 1 << 20,
    /// Workspace-relative file where the child may write UI-only presentation
    /// JSON. It is not stdout and never reaches the model.
    presentation_file: ?[]const u8 = null,
};

/// One normalized invocation: the tool's stdout on success, a human-readable
/// diagnostic (with exit code and stderr when available) on a normal failure.
/// Host faults and cancellation surface as errors, never here.
pub const ToolInvocation = struct {
    ok: bool,
    output: []const u8,

    /// Free the `output` owned by the allocator passed to `invokeTool`.
    pub fn deinit(self: ToolInvocation, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
    }
};

/// Run one tool of the named frozen version once. Errors from
/// `Environment.runExtension` propagate unchanged: `error.Canceled` in
/// particular is host execution control and is never folded into a failed
/// invocation.
///
/// The result is the child's stdout verbatim, which §7.3 already defines — no
/// second rule about how text reaches the model. A non-zero exit is an ordinary
/// failed invocation carrying `exit <n>`, the child's stderr, and whatever it
/// managed to print.
///
/// The arguments' SHAPE is checked here, before anything is spawned or sent
/// anywhere: nothing runs — and no frame crosses a channel — with something a
/// tool's declared `input` schema could not describe.
pub fn invokeTool(
    alloc: std.mem.Allocator,
    env: environment.Environment,
    id: []const u8,
    version: []const u8,
    tool_name: []const u8,
    cwd: []const u8,
    args_json: []const u8,
    options: Options,
) !ToolInvocation {
    const arguments = protocol.normalizedArguments(args_json);
    try protocol.requireArgumentsObject(alloc, arguments);

    const outcome = env.runExtension(alloc, .{
        .id = id,
        .version = version,
        .tool = tool_name,
        .cwd = cwd,
        .request_json = arguments,
        .max_output_bytes = options.max_output_bytes,
        .timeout_ms = options.timeout_ms,
        .presentation_file = options.presentation_file,
    }) catch |err| {
        // "This machine cannot run that version" is a FAILED CALL, not a host
        // fault: the caller is the one who can act on it, and killing the whole
        // step over it would take a conversation down for something one tool
        // could have reported. The far side of a channel answers the same class
        // of failure with a refusal that arrives here as the same shape, so the
        // model reads one story whichever machine it happened on.
        if (!exec.isUnrunnableHere(err)) return err;
        var diag: std.Io.Writer.Allocating = .init(alloc);
        errdefer diag.deinit();
        try diag.writer.print(
            "extension {s}@{s} cannot run on this machine ({s}, {s}); see `nulya ext inspect {s}@{s}`",
            .{ id, version, @errorName(err), @tagName(builtin.os.tag), id, version },
        );
        return .{ .ok = false, .output = try diag.toOwnedSlice() };
    };
    defer outcome.deinit(alloc);

    if (outcome.timed_out) {
        // A wall-clock timeout is a normal failed invocation, not an error and
        // not a cancellation: the host decided the call was too slow.
        var diag: std.Io.Writer.Allocating = .init(alloc);
        errdefer diag.deinit();
        try diag.writer.print("extension timed out after {d}ms", .{options.timeout_ms});
        try appendStderr(&diag, outcome.stderr);
        return .{ .ok = false, .output = try diag.toOwnedSlice() };
    }

    if (outcome.exit_code == 0) return .{ .ok = true, .output = try alloc.dupe(u8, outcome.stdout) };

    var diag: std.Io.Writer.Allocating = .init(alloc);
    errdefer diag.deinit();
    try diag.writer.print("exit {d}", .{outcome.exit_code});
    try appendStderr(&diag, outcome.stderr);
    // Whatever it printed before failing is often the whole explanation, so it
    // is kept — after the exit code, which is the fact that decides `ok`.
    if (outcome.stdout.len != 0) try diag.writer.print("\nstdout:\n{s}", .{outcome.stdout});
    return .{ .ok = false, .output = try diag.toOwnedSlice() };
}

/// Append the runtime's stderr to a diagnostic as its own block, so a failed
/// invocation still shows the repair signal an AI-authored extension produced.
fn appendStderr(diag: *std.Io.Writer.Allocating, stderr: []const u8) !void {
    if (stderr.len == 0) return;
    try diag.writer.print("\nstderr:\n{s}", .{stderr});
}

const testing = std.testing;

/// Scripted environment backend: returns a canned `ExtensionOutcome` (or a
/// canned error) and records what the helper sent, so tests exercise
/// `invokeTool`'s orchestration without spawning a real process.
const FakeEnv = struct {
    io: std.Io,
    response: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: u8 = 0,
    timed_out: bool = false,
    err: ?anyerror = null,
    saw_request_json: []const u8 = "",
    /// `<id>@<version>/<tool>` — the whole of what this seam now hands the
    /// executing side, as one string so an assertion reads like the identity it
    /// is checking.
    saw_ref: []const u8 = "",
    saw_live: bool = false,

    fn runExtension(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ExtensionRequest) anyerror!environment.ExtensionOutcome {
        const self: *FakeEnv = @ptrCast(@alignCast(ptr));
        if (self.err) |e| return e;
        // Reuse-safe: the allocation-failure sweep below drives this fake many
        // times, so drop any previous recording before overwriting it.
        self.dropSaw(alloc);

        self.saw_request_json = try alloc.dupe(u8, req.request_json);
        self.saw_live = true;
        errdefer self.dropSaw(alloc);
        self.saw_ref = try std.fmt.allocPrint(alloc, "{s}@{s}/{s}", .{ req.id, req.version, req.tool });
        const stdout = try alloc.dupe(u8, self.response);
        errdefer alloc.free(stdout);
        const stderr = try alloc.dupe(u8, self.stderr);
        return .{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = self.exit_code,
            .timed_out = self.timed_out,
        };
    }

    fn dialect(ptr: *anyopaque) environment.Dialect {
        _ = ptr;
        return .bash;
    }

    fn runShell(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ShellRequest) anyerror!environment.ShellOutcome {
        _ = ptr;
        _ = alloc;
        _ = req;
        return error.NotSupported;
    }

    fn startShellTask(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.TaskRequest) anyerror!environment.TaskStart {
        _ = ptr;
        _ = alloc;
        _ = req;
        return error.NoDurableSession;
    }

    fn putWorkspaceFile(ptr: *anyopaque, rel_path: []const u8, bytes: []const u8) anyerror!void {
        _ = ptr;
        _ = rel_path;
        _ = bytes;
        return error.NotSupported;
    }

    fn handle(self: *FakeEnv) environment.Environment {
        return .{
            .io = self.io,
            .ptr = self,
            .vtable = &.{
                .dialect = dialect,
                .runShell = runShell,
                .runExtension = runExtension,
                .startShellTask = startShellTask,
                .putWorkspaceFile = putWorkspaceFile,
            },
        };
    }

    fn deinit(self: *FakeEnv, alloc: std.mem.Allocator) void {
        self.dropSaw(alloc);
    }

    fn dropSaw(self: *FakeEnv, alloc: std.mem.Allocator) void {
        if (!self.saw_live) return;
        if (self.saw_request_json.len > 0) alloc.free(self.saw_request_json);
        if (self.saw_ref.len > 0) alloc.free(self.saw_ref);
        self.saw_request_json = "";
        self.saw_ref = "";
        self.saw_live = false;
    }
};

/// The identity every test below invokes: one package, one frozen version.
const ref_id = "greeter";
const ref_version = "v-000000000000000000000001";

test "the arguments object goes to stdin and stdout comes back verbatim" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .response = "hello from greeter, name=world\n" };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), ref_id, ref_version, "greet", "ws", "{\"name\":\"world\"}", .{});
    defer invocation.deinit(alloc);

    try testing.expect(invocation.ok);
    // No envelope, no decode: the bytes the script printed, unchanged.
    try testing.expectEqualStrings("hello from greeter, name=world\n", invocation.output);
    try testing.expectEqualStrings("{\"name\":\"world\"}", fake.saw_request_json);
    // What the executing side is handed is an IDENTITY, not a path: which file
    // that version means is its answer to give (`extension/exec.zig`), and the
    // arguments it derives `NULYA_TOOL` / `NULYA_ARG_<k>` from are the very
    // bytes on stdin (`protocol.callEnv`, tested there).
    try testing.expectEqualStrings(ref_id ++ "@" ++ ref_version ++ "/greet", fake.saw_ref);
}

test "no arguments still sends an object" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .response = "" };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), ref_id, ref_version, "t", "ws", "", .{});
    defer invocation.deinit(alloc);
    try testing.expect(invocation.ok);
    try testing.expectEqualStrings("{}", fake.saw_request_json);
}

test "a non-zero exit is a failed call carrying the code, stderr and stdout" {
    const alloc = testing.allocator;
    var fake = FakeEnv{
        .io = testing.io,
        .response = "partial work\n",
        .stderr = "run.sh: no such file\n",
        .exit_code = 3,
    };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), ref_id, ref_version, "t", "ws", "{}", .{});
    defer invocation.deinit(alloc);

    try testing.expect(!invocation.ok);
    // The exact shape e2e and the front end read: the code first, then each
    // captured stream as its own block.
    try testing.expectEqualStrings(
        "exit 3\nstderr:\nrun.sh: no such file\n\nstdout:\npartial work\n",
        invocation.output,
    );
}

test "arguments that are not a JSON object are refused before anything is spawned" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .response = "" };
    defer fake.deinit(alloc);

    try testing.expectError(error.InvalidArgumentsJson, invokeTool(alloc, fake.handle(), ref_id, ref_version, "t", "ws", "{bad", .{}));
    try testing.expectError(error.ArgumentsNotObject, invokeTool(alloc, fake.handle(), ref_id, ref_version, "t", "ws", "[]", .{}));
    // Nothing was spawned, and nothing crossed a channel: the shape is checked
    // before the child exists.
    try testing.expect(!fake.saw_live);
}

test "a timeout is a failed call, and cancellation still propagates" {
    const alloc = testing.allocator;

    var slow = FakeEnv{ .io = testing.io, .timed_out = true, .stderr = "stuck on network\n" };
    defer slow.deinit(alloc);
    const invocation = try invokeTool(alloc, slow.handle(), ref_id, ref_version, "t", "ws", "{}", .{});
    defer invocation.deinit(alloc);
    try testing.expect(!invocation.ok);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "timed out after") != null);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "stuck on network") != null);

    var canceled = FakeEnv{ .io = testing.io, .err = error.Canceled };
    defer canceled.deinit(alloc);
    try testing.expectError(error.Canceled, invokeTool(alloc, canceled.handle(), ref_id, ref_version, "t", "ws", "{}", .{}));
}

test "no allocation failure is swallowed into a failed invocation" {
    // Sweep every allocation in the success path with a failing allocator: the
    // per-call environment, and the environment's captured stdout/stderr. Each
    // induced OOM must surface as an error — a host resource fault is never
    // folded into a `.ok = false` invocation.
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var fake = FakeEnv{ .io = testing.io, .response = "text" };
            defer fake.deinit(alloc);
            const invocation = invokeTool(alloc, fake.handle(), ref_id, ref_version, "t", "ws", "{\"a\":\"b\",\"c\":1}", .{}) catch |err| switch (err) {
                // The allocating writer reports a denied allocation as
                // WriteFailed ("effectively out-of-memory" for an allocating
                // sink), while the sweep only accepts OutOfMemory. Normalize the
                // alias — both are host resource faults, and any real swallow
                // still trips the check below.
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer invocation.deinit(alloc);
            try testing.expect(invocation.ok);
        }
    }.run, .{});
}

test "the failed-call path leaks nothing under allocation failure either" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var fake = FakeEnv{ .io = testing.io, .response = "partial", .stderr = "why", .exit_code = 2 };
            defer fake.deinit(alloc);
            const invocation = invokeTool(alloc, fake.handle(), ref_id, ref_version, "t", "ws", "{}", .{}) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer invocation.deinit(alloc);
            try testing.expect(!invocation.ok);
            try testing.expect(std.mem.indexOf(u8, invocation.output, "exit 2") != null);
        }
    }.run, .{});
}
