//! Extension tool invocation (DESIGN §7.3).
//!
//! The narrow seam between an already-resolved extension executable and the two
//! wires a runtime may declare (`manifest.Wire`): JSON-RPC `tool/call`, or the
//! `plain` wire (arguments on stdin, `NULYA_ARG_<k>` in the environment, stdout
//! verbatim). It knows nothing about the extension store: the caller resolves
//! the active version, validates integrity, reads the frozen manifest, verifies
//! the tool is declared, and passes an exact executable path. `invokeTool` never
//! asks what `current` means.
//!
//! Both wires reach the SAME `Environment.runExtension` — same timeout, same
//! tree kill, same sanitized environment, same `NULYA_EXE` / `NULYA_SESSION` —
//! and produce the same `ToolInvocation`. The wire decides what is written to
//! stdin and how stdout is read, and nothing else.
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
const ext_manifest = @import("manifest.zig");
const protocol = @import("protocol.zig");
const tool = @import("../tool.zig");

/// Fixed JSON-RPC request id. The runtime is oneshot — one request per process —
/// so the id has no multiplexing or tracing role: the extension only echoes it
/// back and the helper verifies it.
const request_id = "call";

pub const Options = struct {
    /// The cap a caller that has nothing better to say uses. A tool whose
    /// manifest declares its own passes that instead (DESIGN §7.3).
    pub const default_timeout_ms: u32 = tool.Timeouts.extension_ms;

    /// Wall-clock cap for the oneshot call, forwarded to `Environment.runExtension`
    /// (`tool.Timeouts`, base-tools.md §3).
    timeout_ms: u32 = default_timeout_ms,
    /// Runner-level capture cap for the child's stdout/stderr.
    max_output_bytes: usize = 1 << 20,
    /// For a script extension, the interpreter to run the entry with.
    interpreter: ?[]const u8 = null,
    /// How to talk to this runtime, from its frozen manifest
    /// (`manifest.Runtime.wireOf`). The default is what every manifest written
    /// before the field said.
    wire: ext_manifest.Wire = .jsonrpc,
};

/// One normalized `tool/call` invocation: compact result JSON on success, a
/// human-readable diagnostic (with exit code and stderr when available) on a
/// normal failure. Host faults and cancellation surface as errors, never here.
pub const ToolInvocation = struct {
    ok: bool,
    output: []const u8,

    /// Free the `output` owned by the allocator passed to `invokeTool`.
    pub fn deinit(self: ToolInvocation, alloc: std.mem.Allocator) void {
        alloc.free(self.output);
    }
};

/// Run the already-resolved executable once over the wire its manifest
/// declared. Errors from `Environment.runExtension` propagate unchanged:
/// `error.Canceled` in particular is host execution control and is never folded
/// into a failed invocation.
pub fn invokeTool(
    alloc: std.mem.Allocator,
    env: environment.Environment,
    entry_path: []const u8,
    cwd: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    options: Options,
) !ToolInvocation {
    return switch (options.wire) {
        .jsonrpc => invokeJsonRpc(alloc, env, entry_path, cwd, tool_name, args_json, options),
        .plain => invokePlain(alloc, env, entry_path, cwd, tool_name, args_json, options),
    };
}

/// The JSON-RPC wire: encode a `tool/call` request, run once, decode the
/// response. Not one byte of it changed when `plain` arrived.
fn invokeJsonRpc(
    alloc: std.mem.Allocator,
    env: environment.Environment,
    entry_path: []const u8,
    cwd: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    options: Options,
) !ToolInvocation {
    const req: protocol.ToolCallRequest = .{
        .id = request_id,
        .name = tool_name,
        .arguments_json = args_json,
    };
    const request_json = try req.encode(alloc);
    defer alloc.free(request_json);

    const outcome = try env.runExtension(alloc, .{
        .entry_path = entry_path,
        .interpreter = options.interpreter,
        .cwd = cwd,
        .request_json = request_json,
        .max_output_bytes = options.max_output_bytes,
        .timeout_ms = options.timeout_ms,
    });
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

    const decoded = protocol.decodeResponse(alloc, request_id, outcome.stdout) catch |err| switch (err) {
        // Protocol violations are extension faults → a failed invocation; a
        // broken extension never crashes the host.
        error.InvalidResponse, error.UnsupportedVersion => {
            var diag: std.Io.Writer.Allocating = .init(alloc);
            errdefer diag.deinit();
            try diag.writer.print("extension returned an invalid response (exit {d})", .{outcome.exit_code});
            try appendStderr(&diag, outcome.stderr);
            return .{ .ok = false, .output = try diag.toOwnedSlice() };
        },
        // Host resource faults propagate. Cancellation cannot reach this
        // branch — decodeResponse performs no I/O.
        else => return err,
    };

    switch (decoded) {
        // Ownership transfer: `json` becomes `ToolInvocation.output` — no dupe.
        .result => |json| return .{ .ok = true, .output = json },
        .extension_error => |err| {
            defer decoded.deinit(alloc);

            var diag: std.Io.Writer.Allocating = .init(alloc);
            errdefer diag.deinit();
            try diag.writer.print("extension error [{d}]: {s}", .{ err.code, err.message });
            return .{ .ok = false, .output = try diag.toOwnedSlice() };
        },
    }
}

/// The `plain` wire (DESIGN §7.3, contract at the top of `protocol.zig`): the
/// arguments JSON on stdin, `NULYA_TOOL` / `NULYA_ARG_<k>` in the environment,
/// stdout VERBATIM as the tool's text, exit code as ok/failed.
///
/// The result is a string result, which §7.3 already defines — no second rule
/// about how text reaches the model. A non-zero exit is an ordinary failed
/// invocation, the same shape a JSON-RPC error folds into, carrying `exit <n>`,
/// the child's stderr, and whatever it managed to print.
fn invokePlain(
    alloc: std.mem.Allocator,
    env: environment.Environment,
    entry_path: []const u8,
    cwd: []const u8,
    tool_name: []const u8,
    args_json: []const u8,
    options: Options,
) !ToolInvocation {
    const arguments = normalizedArguments(args_json);

    var vars: EnvVars = .empty;
    defer vars.deinit(alloc);
    try vars.add(alloc, "NULYA_TOOL", tool_name);
    try vars.addArguments(alloc, arguments);

    const outcome = try env.runExtension(alloc, .{
        .entry_path = entry_path,
        .interpreter = options.interpreter,
        .cwd = cwd,
        .request_json = arguments,
        .max_output_bytes = options.max_output_bytes,
        .timeout_ms = options.timeout_ms,
        .env_extra = vars.list.items,
    });
    defer outcome.deinit(alloc);

    if (outcome.timed_out) {
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

/// The exact bytes both wires agree on: the model's arguments object, trimmed,
/// with "nothing" spelled `{}`. `ToolCallRequest.encode` applies the same rule
/// to what it nests under `params.arguments`, so a script sees on stdin what a
/// JSON-RPC extension sees inside the envelope.
fn normalizedArguments(args_json: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    return if (trimmed.len == 0) "{}" else trimmed;
}

/// The per-call environment for the `plain` wire, owning every string it hands
/// to `runExtension`.
const EnvVars = struct {
    list: std.ArrayList(environment.EnvVar) = .empty,

    const empty: EnvVars = .{};

    fn deinit(self: *EnvVars, alloc: std.mem.Allocator) void {
        for (self.list.items) |v| {
            alloc.free(v.name);
            alloc.free(v.value);
        }
        self.list.deinit(alloc);
    }

    fn add(self: *EnvVars, alloc: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_value = try alloc.dupe(u8, value);
        errdefer alloc.free(owned_value);
        try self.list.append(alloc, .{ .name = owned_name, .value = owned_value });
    }

    /// `NULYA_ARG_<k>` for each TOP-LEVEL scalar argument. Arrays, objects and
    /// null do not appear: an environment variable is a string, and inventing a
    /// serialization for a structure would be a second argument format for a
    /// script to parse — stdin already carries the whole object, exactly.
    ///
    /// Keys outside `[A-Za-z0-9_]+` are skipped rather than mangled, for the
    /// same reason: a name a shell cannot read is not made readable by rewriting
    /// it, and the value is still on stdin.
    ///
    /// The parse is also where "the arguments are a JSON object" is enforced —
    /// the SAME two errors `ToolCallRequest.encode` raises for the other wire,
    /// so one rule about arguments holds for both, and nothing is spawned with
    /// something a tool's declared `input` schema could not describe.
    fn addArguments(self: *EnvVars, alloc: std.mem.Allocator, arguments: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch |err| switch (err) {
            // A host OOM is a resource fault and must not be misreported as
            // malformed arguments (`encode`'s split, for its reason).
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgumentsJson,
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.ArgumentsNotObject,
        };

        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!isEnvSafeKey(key)) continue;
            var buf: [64]u8 = undefined;
            const value: []const u8 = switch (entry.value_ptr.*) {
                .string => |s| s,
                .bool => |b| if (b) "true" else "false",
                .integer => |n| std.fmt.bufPrint(&buf, "{d}", .{n}) catch continue,
                .float => |f| std.fmt.bufPrint(&buf, "{d}", .{f}) catch continue,
                .number_string => |s| s,
                else => continue,
            };
            // A NUL byte ENDS an environment string on both platforms, so a
            // value carrying one would arrive silently truncated. Skipped
            // instead — stdin still has it whole.
            if (std.mem.indexOfScalar(u8, value, 0) != null) continue;
            const name = try std.fmt.allocPrint(alloc, "NULYA_ARG_{s}", .{key});
            defer alloc.free(name);
            try self.add(alloc, name, value);
        }
    }
};

fn isEnvSafeKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
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
    /// The per-call environment flattened to `NAME=VALUE\n` lines and OWNED:
    /// the caller's pairs are freed the moment its call returns, so a borrow
    /// would be read after free by every assertion below.
    saw_env: []const u8 = "",

    fn runExtension(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ExtensionRequest) anyerror!environment.ExtensionOutcome {
        const self: *FakeEnv = @ptrCast(@alignCast(ptr));
        if (self.err) |e| return e;
        // Reuse-safe: the allocation-failure sweep below drives this fake many
        // times, so drop any previous recording before overwriting it.
        self.dropSaw(alloc);

        self.saw_request_json = try alloc.dupe(u8, req.request_json);
        self.saw_live = true;
        errdefer self.dropSaw(alloc);
        self.saw_env = try flattenEnv(alloc, req.env_extra);
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

    fn startShellTask(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.TaskRequest) anyerror!environment.TaskStart {
        _ = ptr;
        _ = alloc;
        _ = req;
        return error.NoDurableSession;
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
        if (self.saw_env.len > 0) alloc.free(self.saw_env);
        self.saw_request_json = "";
        self.saw_entry_path = "";
        self.saw_env = "";
        self.saw_live = false;
    }
};

fn flattenEnv(alloc: std.mem.Allocator, vars: []const environment.EnvVar) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (vars) |v| try out.writer.print("{s}={s}\n", .{ v.name, v.value });
    return out.toOwnedSlice();
}

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

// --- the `plain` wire (DESIGN §7.3) ---------------------------------------

test "plain sends the arguments object on stdin and returns stdout verbatim" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .response = "hello from greeter, name=world\n" };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), "ext/src/run.sh", "ws", "greet", "{\"name\":\"world\"}", .{ .wire = .plain });
    defer invocation.deinit(alloc);

    try testing.expect(invocation.ok);
    // No envelope, no decode: the bytes the script printed, unchanged.
    try testing.expectEqualStrings("hello from greeter, name=world\n", invocation.output);
    // stdin is the model's arguments object itself — the same bytes JSON-RPC
    // nests under `params.arguments`.
    try testing.expectEqualStrings("{\"name\":\"world\"}", fake.saw_request_json);
}

test "plain names the tool and every top-level scalar argument in the environment" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .response = "ok" };
    defer fake.deinit(alloc);

    const args = "{\"name\":\"world\",\"count\":3,\"deep\":true,\"list\":[1,2],\"obj\":{\"a\":1},\"nothing\":null,\"bad-key\":\"x\"}";
    const invocation = try invokeTool(alloc, fake.handle(), "bin", "ws", "greet", args, .{ .wire = .plain });
    defer invocation.deinit(alloc);

    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "NULYA_TOOL=greet\n") != null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "NULYA_ARG_name=world\n") != null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "NULYA_ARG_count=3\n") != null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "NULYA_ARG_deep=true\n") != null);
    // Structures get no invented serialization, and a key a shell cannot read
    // is not rewritten into one. Both are still on stdin, whole.
    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "NULYA_ARG_list") == null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "NULYA_ARG_obj") == null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "NULYA_ARG_nothing") == null);
    try testing.expect(std.mem.indexOf(u8, fake.saw_env, "bad-key") == null);
    try testing.expectEqualStrings(args, fake.saw_request_json);
}

test "plain with no arguments still sends an object, and jsonrpc adds no environment at all" {
    const alloc = testing.allocator;

    var plain = FakeEnv{ .io = testing.io, .response = "" };
    defer plain.deinit(alloc);
    const p = try invokeTool(alloc, plain.handle(), "bin", "ws", "t", "", .{ .wire = .plain });
    defer p.deinit(alloc);
    try testing.expect(p.ok);
    try testing.expectEqualStrings("{}", plain.saw_request_json);
    try testing.expectEqualStrings("NULYA_TOOL=t\n", plain.saw_env);

    // The other wire's child environment is exactly what it always was.
    var rpc = FakeEnv{ .io = testing.io, .response = "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"result\":{}}" };
    defer rpc.deinit(alloc);
    const r = try invokeTool(alloc, rpc.handle(), "bin", "ws", "t", "{}", .{});
    defer r.deinit(alloc);
    try testing.expectEqualStrings("", rpc.saw_env);
}

test "plain treats a non-zero exit as a failed call carrying the code, stderr and stdout" {
    const alloc = testing.allocator;
    var fake = FakeEnv{
        .io = testing.io,
        .response = "partial work\n",
        .stderr = "run.sh: no such file\n",
        .exit_code = 3,
    };
    defer fake.deinit(alloc);

    const invocation = try invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{ .wire = .plain });
    defer invocation.deinit(alloc);

    try testing.expect(!invocation.ok);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "exit 3") != null);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "no such file") != null);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "partial work") != null);
}

test "plain refuses arguments that are not a JSON object, with the other wire's two errors" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .response = "" };
    defer fake.deinit(alloc);

    try testing.expectError(error.InvalidArgumentsJson, invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{bad", .{ .wire = .plain }));
    try testing.expectError(error.ArgumentsNotObject, invokeTool(alloc, fake.handle(), "bin", "ws", "t", "[]", .{ .wire = .plain }));
    // Nothing was spawned: the shape is checked before the child exists.
    try testing.expect(!fake.saw_live);
}

test "plain: a timeout is a failed call, and cancellation still propagates" {
    const alloc = testing.allocator;

    var slow = FakeEnv{ .io = testing.io, .timed_out = true, .stderr = "stuck\n" };
    defer slow.deinit(alloc);
    const invocation = try invokeTool(alloc, slow.handle(), "bin", "ws", "t", "{}", .{ .wire = .plain });
    defer invocation.deinit(alloc);
    try testing.expect(!invocation.ok);
    try testing.expect(std.mem.indexOf(u8, invocation.output, "timed out after") != null);

    var canceled = FakeEnv{ .io = testing.io, .err = error.Canceled };
    defer canceled.deinit(alloc);
    try testing.expectError(error.Canceled, invokeTool(alloc, canceled.handle(), "bin", "ws", "t", "{}", .{ .wire = .plain }));
}

test "plain leaks nothing when an interior allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var fake = FakeEnv{ .io = testing.io, .response = "text" };
            defer fake.deinit(alloc);
            const invocation = invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{\"a\":\"b\",\"c\":1}", .{ .wire = .plain }) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            };
            defer invocation.deinit(alloc);
            try testing.expect(invocation.ok);
        }
    }.run, .{});
}

test "cancellation from the environment propagates unchanged" {
    const alloc = testing.allocator;
    var fake = FakeEnv{ .io = testing.io, .err = error.Canceled };
    defer fake.deinit(alloc);

    try testing.expectError(error.Canceled, invokeTool(alloc, fake.handle(), "bin", "ws", "t", "{}", .{}));
}

test "no allocation failure is swallowed into a failed invocation" {
    // Sweep every allocation in the success path with a failing allocator:
    // encode, the environment's captured stdout/stderr, and decode. Each
    // induced OOM must surface as an error — a host resource fault is never
    // folded into a `.ok = false` invocation, and protocol/application faults
    // never become host errors.
    try testing.checkAllAllocationFailures(testing.allocator, invokeToolAllocSweep, .{
        "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"result\":{\"x\":1}}",
        true,
    });
}

test "a JSON-RPC error response leaks nothing under allocation failure" {
    // The error branch of `decodeResponse` owns the message slice; the sweep
    // locks that every path releases it.
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
