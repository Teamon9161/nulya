//! Extension tools as ordinary kernel tools (DESIGN §7.3, §5).
//!
//! `Binding` pairs a tool's model-facing `tool.ToolDefinition` with its exact
//! frozen executable path, then adapts it into the kernel's single `tool.Tool`
//! through the existing `ToolExecutor` seam — no second tool abstraction.
//!
//! Two invariants hold:
//!   - The binding never touches the extension store, `current`, manifests, or
//!     discovery; `entry_path` is already resolved and frozen by the caller.
//!   - `ToolExecutor.ptr` borrows the binding, so the binding (and its borrowed
//!     definition strings) must outlive every derived `Tool` and must not move.

const std = @import("std");
const tool = @import("../tool.zig");
const invoke = @import("invoke.zig");

/// A frozen extension tool binding. The binding and its borrowed definition
/// strings must outlive derived Tools.
pub const Binding = struct {
    /// Model-facing identity and schema. `definition.id` is the stable logical
    /// id (never version-qualified); `definition.name` is what the model calls.
    definition: tool.ToolDefinition,
    /// Exact frozen executable path, passed verbatim to `Environment.runExtension`.
    entry_path: []const u8,

    /// Adapt into a kernel `Tool`. The returned `Tool` borrows this binding:
    /// `executor.ptr` is the binding's address.
    pub fn asTool(self: *Binding) tool.Tool {
        return .{
            .definition = self.definition,
            .executor = .{ .ptr = self, .callFn = call },
        };
    }
};

/// `ToolExecutor` callback. Does not interpret the invocation — `invokeTool`
/// owns encode/run/decode, diagnostics, and the failure taxonomy — it only
/// binds the executor to it and transfers the output slice.
fn call(ptr: ?*anyopaque, alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const self: *Binding = @ptrCast(@alignCast(ptr));

    const invocation = try invoke.invokeTool(
        alloc,
        req.ctx.environment,
        self.entry_path,
        req.ctx.cwd,
        self.definition.name,
        req.args_json,
        .{},
    );

    // Ownership transfer: `invocation.output` is allocator-owned, as is
    // `RawToolResult.output`; returning the slice moves it (no `deinit`, no copy).
    return .{ .ok = invocation.ok, .output = invocation.output };
}

const testing = std.testing;
const environment = @import("../environment.zig");

const success_response = "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"result\":{\"results\":[]}}";
const error_response = "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"error\":{\"code\":-32000,\"message\":\"down\"}}";

/// Scripted environment backend: returns a canned `ExtensionOutcome` (or a
/// canned error) and records what the helper sent, so the executor's
/// orchestration is exercised without spawning a real process.
const FakeEnv = struct {
    io: std.Io,
    response: []const u8 = "",
    timed_out: bool = false,
    err: ?anyerror = null,
    saw_entry_path: []const u8 = "",
    saw_request_json: []const u8 = "",

    fn runExtension(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ExtensionRequest) anyerror!environment.ExtensionOutcome {
        const self: *FakeEnv = @ptrCast(@alignCast(ptr));
        if (self.err) |e| return e;
        // Allocate everything before publishing to `self`: a mid-way failure
        // frees the locals via errdefer and leaves the saw fields empty, so
        // `deinit` never double-frees.
        const saw_entry_path = try alloc.dupe(u8, req.entry_path);
        errdefer alloc.free(saw_entry_path);
        const saw_request_json = try alloc.dupe(u8, req.request_json);
        errdefer alloc.free(saw_request_json);
        const stdout = try alloc.dupe(u8, self.response);
        errdefer alloc.free(stdout);
        const stderr = try alloc.dupe(u8, "");
        self.saw_entry_path = saw_entry_path;
        self.saw_request_json = saw_request_json;
        return .{ .stdout = stdout, .stderr = stderr, .exit_code = 0, .timed_out = self.timed_out };
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
        if (self.saw_entry_path.len > 0) alloc.free(self.saw_entry_path);
        if (self.saw_request_json.len > 0) alloc.free(self.saw_request_json);
    }
};

/// The executor never touches `req.ctx.fs`; a stub keeps the `ToolContext`
/// well-formed without reaching the real filesystem.
const DummyFs = struct {
    fn readFileAlloc(ptr: *anyopaque, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) anyerror![]u8 {
        _ = ptr;
        _ = alloc;
        _ = path;
        _ = max_bytes;
        return error.NotSupported;
    }

    fn atomicWriteFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        _ = ptr;
        _ = path;
        _ = data;
        return error.NotSupported;
    }

    fn handle(self: *DummyFs) environment.WorkspaceFs {
        return .{ .ptr = self, .vtable = &.{ .readFileAlloc = readFileAlloc, .atomicWriteFile = atomicWriteFile } };
    }
};

fn testBinding() Binding {
    return .{
        .definition = .{
            .id = "ext:web.search/web_search",
            .name = "web_search",
            .description = "Search web",
            .input_schema = "{\"type\":\"object\"}",
        },
        .entry_path = "/frozen/v1/bin/web-search",
    };
}

test "asTool exposes the frozen definition, sequential policy, and binding pointer" {
    var binding = testBinding();
    const t = binding.asTool();

    // The id is the stable logical identity; the name is what the model calls.
    try testing.expectEqualStrings("ext:web.search/web_search", t.definition.id);
    try testing.expectEqualStrings("web_search", t.definition.name);
    try testing.expectEqualStrings("Search web", t.definition.description);
    try testing.expectEqualStrings("{\"type\":\"object\"}", t.definition.input_schema);
    // Extension tools stay on the safe default: sequential execution.
    try testing.expectEqual(tool.BatchPolicy.sequential, t.batch_policy);

    // The executor's identity IS the binding: the callback recovers the
    // binding from this pointer, so it must be the binding's own address.
    const binding_ptr: ?*anyopaque = @ptrCast(&binding);
    try testing.expectEqual(binding_ptr, t.executor.ptr);
}

test "executor forwards the exact frozen entry path" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_response };
    defer fake.deinit(alloc);
    var fs = DummyFs{};

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .fs = fs.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    // The frozen executable path reaches the environment verbatim — the
    // executor neither resolves `current` nor joins/derives the path.
    try testing.expectEqualStrings("/frozen/v1/bin/web-search", fake.saw_entry_path);
}

test "executor forwards the model's raw arguments as a tool/call request" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_response };
    defer fake.deinit(alloc);
    var fs = DummyFs{};

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .fs = fs.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    // The binding's tool name is the JSON-RPC name; the model's raw arguments
    // ride along untouched inside `arguments`.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, fake.saw_request_json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("tool/call", obj.get("method").?.string);
    const params = obj.get("params").?.object;
    try testing.expectEqualStrings("web_search", params.get("name").?.string);
    try testing.expectEqualStrings("zig", params.get("arguments").?.object.get("query").?.string);
}

test "success maps to a raw success result" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_response };
    defer fake.deinit(alloc);
    var fs = DummyFs{};

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .fs = fs.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    try testing.expect(result.ok);
    try testing.expectEqualStrings("{\"results\":[]}", result.output);
}

test "application failure maps to a raw failed result without reformatting" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = error_response };
    defer fake.deinit(alloc);
    var fs = DummyFs{};

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .fs = fs.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    try testing.expect(!result.ok);
    // invokeTool's diagnostic already carries the extension's message; the
    // executor must not re-wrap it.
    try testing.expect(std.mem.indexOf(u8, result.output, "down") != null);
}

test "timeout remains a normal failed tool result" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .timed_out = true };
    defer fake.deinit(alloc);
    var fs = DummyFs{};

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .fs = fs.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    try testing.expect(!result.ok);
    try testing.expect(std.mem.indexOf(u8, result.output, "timed out") != null);
}

test "cancellation propagates unchanged" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .err = error.Canceled };
    defer fake.deinit(alloc);
    var fs = DummyFs{};

    // Host execution control surfaces as the same error out of the executor —
    // never a failed tool result.
    try testing.expectError(error.Canceled, binding.asTool().executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = fake.handle(), .fs = fs.handle(), .cwd = "ws" },
    }));
}

test "host faults propagate as errors, not failed results" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .err = error.OutOfMemory };
    defer fake.deinit(alloc);
    var fs = DummyFs{};

    // A host resource fault is an error out of the executor, never folded into
    // a `.ok = false` result.
    try testing.expectError(error.OutOfMemory, binding.asTool().executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = fake.handle(), .fs = fs.handle(), .cwd = "ws" },
    }));
}
