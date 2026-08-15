//! Extension tool invocation (DESIGN §7.3).
//!
//! The narrow seam between an already-resolved extension executable and the
//! JSON-RPC `tool/call` protocol. It knows nothing about the extension store:
//! the caller resolves the active version, validates integrity, reads the
//! frozen manifest, verifies the tool is declared, and passes an exact
//! executable path. `invokeTool` never asks what `current` means.
//!
//! Failure classification — the three kinds never merge:
//!
//!   extension protocol/application failure → normalized failed invocation
//!   host execution/resource failure          → error
//!   cancellation                             → error.Canceled unchanged
//!
//! Ownership: the returned `ToolInvocation.output` is owned by the allocator
//! passed to `invokeTool` and freed with `ToolInvocation.deinit`. Every
//! intermediate allocation (request JSON, captured stdout/stderr, decoded
//! response, diagnostic) is released on all paths.

const std = @import("std");
const environment = @import("../environment.zig");
const protocol = @import("protocol.zig");

pub const Options = struct {
    /// Wall-clock cap for the oneshot call, forwarded to `Environment.runExtension`.
    timeout_ms: u32 = 30_000,
    /// Runner-level capture cap for the child's stdout/stderr.
    max_output_bytes: usize = 1 << 20,
    /// JSON-RPC request id echoed back by the extension. The CLI uses "cli";
    /// future callers (the native ExtensionExecutor) may supply their own.
    request_id: []const u8 = "call",
};

/// One normalized `tool/call` invocation.
///
/// `.ok == true`: `output` is the compact JSON of the decoded `result`.
/// `.ok == false`: `output` is a human-readable diagnostic for a normal failed
/// invocation (timeout, JSON-RPC application error, or malformed response),
/// preserving the exit code and stderr when available. Host faults — OOM, I/O,
/// cancellation — are never folded here; they surface as errors from
/// `invokeTool`.
pub const ToolInvocation = struct {
    ok: bool,
    output: []const u8,

    /// Free the `output` owned by the allocator passed to `invokeTool`.
    pub fn deinit(self: ToolInvocation, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
    }
};

/// Encode a `tool/call` request, run the already-resolved executable once, and
/// decode its response. Errors from `Environment.runExtension` propagate
/// unchanged: `error.Canceled` in particular is host execution control and is
/// never folded into a failed invocation.
pub fn invokeTool(
    alloc: std.mem.Allocator,
    env: environment.Environment,
    entry_path: []const u8,
    cwd: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    options: Options,
) !ToolInvocation {
    const req: protocol.ToolCallRequest = .{
        .id = options.request_id,
        .name = tool_name,
        .arguments_json = args_json,
    };
    const request_json = try req.encode(alloc);
    defer alloc.free(request_json);

    const outcome = try env.runExtension(alloc, .{
        .entry_path = entry_path,
        .cwd = cwd,
        .request_json = request_json,
        .max_output_bytes = options.max_output_bytes,
        .timeout_ms = options.timeout_ms,
    });
    defer outcome.deinit(alloc);

    if (outcome.timed_out) {
        // A wall-clock timeout is a normal failed invocation, not an error and
        // not a cancellation: the host decided the call was too slow. Keep any
        // stderr the runtime produced before being killed.
        var diag: std.Io.Writer.Allocating = .init(alloc);
        errdefer diag.deinit();
        try diag.writer.print("extension timed out after {d}ms", .{options.timeout_ms});
        try appendStderr(&diag, outcome.stderr);
        return .{ .ok = false, .output = try diag.toOwnedSlice() };
    }

    const decoded = protocol.decodeResponse(alloc, options.request_id, outcome.stdout) catch |err| switch (err) {
        // The extension wrote a protocol violation (garbage, wrong JSON-RPC
        // version, wrong id, or missing result/error): an extension fault → a
        // normal failed invocation; a broken extension never crashes the host.
        error.InvalidResponse, error.UnsupportedVersion => {
            var diag: std.Io.Writer.Allocating = .init(alloc);
            errdefer diag.deinit();
            try diag.writer.print("extension returned an invalid response (exit {d})", .{outcome.exit_code});
            try appendStderr(&diag, outcome.stderr);
            return .{ .ok = false, .output = try diag.toOwnedSlice() };
        },
        // Host resource faults (`WriteFailed`, `OutOfMemory`) are host execution
        // faults: propagate, never fold into a failed invocation. Cancellation
        // cannot reach this branch — decodeResponse performs no I/O.
        else => return err,
    };
    defer decoded.deinit(alloc);

    if (decoded.ok) {
        return .{ .ok = true, .output = try alloc.dupe(u8, decoded.value_json) };
    }
    var diag: std.Io.Writer.Allocating = .init(alloc);
    errdefer diag.deinit();
    try diag.writer.print("extension error [{d}]: {s}", .{ decoded.err.?.code, decoded.err.?.message });
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
    saw_entry_path: []const u8 = "",
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
        self.saw_entry_path = try alloc.dupe(u8, req.entry_path);
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

    fn handle(self: *FakeEnv) environment.Environment {
        return .{
            .io = self.io,
            .ptr = self,
            .vtable = &.{
                .dialect = dialect,
                .runShell = runShell,
                .runExtension = runExtension,
            },
        };
    }

    fn deinit(self: *FakeEnv, alloc: std.mem.Allocator) void {
        self.dropSaw(alloc);
    }

    fn dropSaw(self: *FakeEnv, alloc: std.mem.Allocator) void {
        if (!self.saw_live) return;
        if (self.saw_request_json.len > 0) alloc.free(self.saw_request_json);
        if (self.saw_entry_path.len > 0) alloc.free(self.saw_entry_path);
        self.saw_live = false;
    }
};

test "success decodes a result and returns its compact JSON" {
    const alloc = testing.allocator;
    var fake = FakeEnv{
        .io = testing.io,
        .response = "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"result\":{\"x\":1}}",
    };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), "ext/bin/tool.exe", "ws", "greet", "{\"x\":1}", .{});
    defer invocation.deinit(alloc);

    try testing.expect(invocation.ok);
    try testing.expectEqualStrings("{\"x\":1}", invocation.output);
    // The helper encoded the tool/call request with the given id, name, and
    // verbatim arguments before handing it to the environment.
    try testing.expect(std.mem.indexOf(u8, fake.saw_request_json, "\"id\":\"call\"") != null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_request_json, "\"method\":\"tool/call\"") != null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_request_json, "\"name\":\"greet\"") != null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_request_json, "\"arguments\":{\"x\":1}") != null);
    // The already-resolved executable path is passed through untouched.
    try testing.expectEqualStrings("ext/bin/tool.exe", fake.saw_entry_path);
}

test "a JSON-RPC application error becomes a failed invocation with a diagnostic" {
    const alloc = testing.allocator;
    var fake = FakeEnv{
        .io = testing.io,
        .response = "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"error\":{\"code\":-32000,\"message\":\"down\"}}",
    };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{});
    defer invocation.deinit(alloc);

    try testing.expect(!invocation.ok);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "-32000") != null);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "down") != null);
}

test "malformed output becomes a failed invocation preserving exit code and stderr" {
    const alloc = testing.allocator;
    var fake = FakeEnv{
        .io = testing.io,
        .response = "not json at all",
        .stderr = "panic: wrote garbage\n",
        .exit_code = 2,
    };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{});
    defer invocation.deinit(alloc);

    try testing.expect(!invocation.ok);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "invalid response") != null);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "exit 2") != null);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "panic: wrote garbage") != null);
}

test "every protocol violation becomes a failed invocation, never a host error" {
    const alloc = testing.allocator;
    const cases = [_][]const u8{
        "garbage",
        "{\"jsonrpc\":\"1.0\",\"id\":\"call\",\"result\":null}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"other\",\"result\":null}",
        "{\"jsonrpc\":\"2.0\",\"id\":\"call\"}",
    };
    for (cases) |payload| {
        var fake = FakeEnv{ .io = testing.io, .response = payload };
        defer fake.deinit(alloc);

        const invocation = try invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{});
        defer invocation.deinit(alloc);

        try testing.expect(!invocation.ok);
        try testing.expect(std.mem.indexOf(u8, invocation.output, "invalid response") != null);
    }
}

test "a timed-out run becomes a failed invocation mentioning the timeout" {
    const alloc = testing.allocator;
    var fake = FakeEnv{
        .io = testing.io,
        .timed_out = true,
        .stderr = "stuck on network\n",
    };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{});
    defer invocation.deinit(alloc);

    try testing.expect(!invocation.ok);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "timed out after") != null);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "stuck on network") != null);
}

test "cancellation from the environment propagates unchanged" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .err = error.Canceled };
    defer fake.deinit(alloc);

    try testing.expectError(error.Canceled, invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{}));
}

test "no allocation failure is swallowed into a failed invocation" {
    // Sweep every allocation in the success path with a failing allocator:
    // encode, the environment's captured stdout/stderr, decode, and the result
    // dupe. Each induced OOM must surface as an error — a host resource fault
    // is never folded into a `.ok = false` invocation, and protocol/application
    // faults never become host errors.
    try testing.checkAllAllocationFailures(testing.allocator, invokeToolAllocSweep, .{
        "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"result\":{\"x\":1}}",
        true,
    });
}

test "a JSON-RPC error response leaks nothing under allocation failure" {
    // The error branch of `decodeResponse` allocates two owned slices
    // (`message_owned` and the `"null"` value_json) before returning; the
    // sweep locks the errdefer that releases the first if the second fails.
    try testing.checkAllAllocationFailures(testing.allocator, invokeToolAllocSweep, .{
        "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"error\":{\"code\":-32000,\"message\":\"down\"}}",
        false,
    });
}

/// Wrapper for `checkAllAllocationFailures`: must return `!void`, with the
/// allocator as the first argument. A fresh fake per invocation, so every
/// allocation and free lands on the same allocator instance the sweep tracks.
fn invokeToolAllocSweep(alloc: std.mem.Allocator, response: []const u8, expect_ok: bool) !void {
    var fake = FakeEnv{ .io = testing.io, .response = response };
    defer fake.deinit(alloc);
    var invocation = invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{}) catch |err| switch (err) {
        // The allocating JSON writer reports a denied allocation as WriteFailed
        // ("effectively out-of-memory" for an allocating sink), while the
        // sweep only accepts OutOfMemory. Normalize the alias — both are host
        // resource faults; the point is that neither is folded into a failed
        // invocation, and any real swallow still trips the check below.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer invocation.deinit(alloc);
    if (expect_ok) {
        try testing.expect(invocation.ok);
    } else {
        try testing.expect(!invocation.ok);
        try testing.expect(std.mem.indexOf(u8, invocation.output, "-32000") != null);
    }
}
