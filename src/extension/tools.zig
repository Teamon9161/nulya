//! Extension tools as ordinary kernel tools (DESIGN §7.3, §5).
//!
//! `ExtensionToolBinding` adapts one already-resolved, frozen extension tool
//! to the kernel's single `tool.Tool` abstraction. The kernel already has
//! `ToolExecutor { ptr, callFn }`; an extension tool is just one more executor
//! implementation, exactly like a builtin — there is no second tool
//! abstraction, and no `ExtensionExecutor` wrapper type.
//!
//! The shape is deliberately narrow:
//!
//!   binding ──asTool()──▶ tool.Tool (definition + sequential executor)
//!                              │ executor.call
//!                              ▼
//!                       invoke.invokeTool()
//!                              │
//!                              ▼
//!                       Environment.runExtension
//!
//! Architecture invariants:
//!
//!   - Nothing in this file touches the extension store, `current`, manifests,
//!     integrity, or discovery. The binding already carries the exact frozen
//!     `entry_path` and `tool_name`; the executor uses them verbatim.
//!     Resolving an active version is the caller's job (the CLI today, a
//!     future SessionComposition).
//!   - `ToolExecutor.ptr` points at the `ExtensionToolBinding` itself, so the
//!     binding must not move while any `Tool` built from it is in use. The
//!     backing strings are borrowed: whoever constructs the binding owns them
//!     and must keep them alive for the lifetime of every derived `Tool`.
//!   - `invoke.invokeTool` owns encode/run/decode/timeout/diagnostics and the
//!     failure classification. The executor is a thin passthrough: it maps
//!     `ToolInvocation` to `RawToolResult` and propagates host faults
//!     (`OutOfMemory`, `WriteFailed`, I/O) and `error.Canceled` as errors,
//!     never folding them into a failed result.

const std = @import("std");
const tool = @import("../tool.zig");
const invoke = @import("invoke.zig");

/// One frozen, already-resolved extension tool, expressed as an ordinary
/// `tool.Tool` via `asTool`.
///
/// All slices are borrowed: this type never copies or frees them. The owner of
/// the backing storage (a future SessionComposition) must keep it alive while
/// any `Tool` derived from this binding is in use, and the binding itself must
/// not move — `ToolExecutor.ptr` points at its address.
pub const ExtensionToolBinding = struct {
    /// Pinned extension identity, e.g. `web.search` (informational; the stable
    /// logical identity is `tool_id`).
    extension_id: []const u8,
    /// Pinned implementation version, e.g. `v-123`. The version selects the
    /// executable; it is deliberately NOT part of the tool identity.
    version: []const u8,
    /// Stable logical capability identity, e.g. `ext:web.search/web_search`.
    /// Never version-qualified: v1 and v2 of an extension expose the same
    /// `tool_id`, so usage statistics accumulate to one logical tool.
    tool_id: []const u8,
    /// Model-facing invocation name from the manifest (e.g. `web_search`).
    /// Used as `ToolDefinition.name` and sent as the JSON-RPC `name`.
    tool_name: []const u8,
    description: []const u8,
    input_schema: []const u8,
    /// Exact frozen executable path. Never resolved, joined, or re-read here.
    entry_path: []const u8,

    /// Adapt this binding into a kernel `Tool`. The returned `Tool` borrows
    /// this binding: `executor.ptr` is the binding's address, so the binding
    /// must stay put for the lifetime of the `Tool`.
    pub fn asTool(self: *ExtensionToolBinding) tool.Tool {
        return .{
            .definition = .{
                .id = self.tool_id,
                .name = self.tool_name,
                .description = self.description,
                .input_schema = self.input_schema,
            },
            .batch_policy = .sequential,
            .executor = .{ .ptr = self, .callFn = call },
        };
    }
};

/// `ToolExecutor` callback: run the frozen executable once via
/// `invoke.invokeTool` and transfer the result into a `RawToolResult`.
///
/// Failure classification stays with `invokeTool`:
///   `ok=true`  → `RawToolResult.ok=true`
///   `ok=false` → `RawToolResult.ok=false` (timeout, JSON-RPC application
///                error, malformed response — the diagnostic is already
///                human-readable, never reformatted here)
///   host faults (`OutOfMemory`, `WriteFailed`, I/O) and `error.Canceled`
///   propagate as errors unchanged — never folded into a failed result.
fn call(ptr: ?*anyopaque, alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const self: *ExtensionToolBinding = @ptrCast(@alignCast(ptr));

    const invocation = try invoke.invokeTool(
        alloc,
        req.ctx.environment,
        self.entry_path,
        req.ctx.cwd,
        self.tool_name,
        req.args_json,
        .{},
    );

    // Ownership transfer: `invocation.output` is owned by `alloc`, and so is
    // `RawToolResult.output` (the caller's allocator). `ToolInvocation` holds
    // no other resources, so returning the struct moves the slice — no copy,
    // and no `deinit` here, which would free the output out from under the
    // returned result.
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
        self.saw_entry_path = try alloc.dupe(u8, req.entry_path);
        errdefer alloc.free(self.saw_entry_path);
        self.saw_request_json = try alloc.dupe(u8, req.request_json);
        errdefer alloc.free(self.saw_request_json);
        const stdout = try alloc.dupe(u8, self.response);
        errdefer alloc.free(stdout);
        const stderr = try alloc.dupe(u8, "");
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

fn testBinding() ExtensionToolBinding {
    return .{
        .extension_id = "web.search",
        .version = "v-123",
        .tool_id = "ext:web.search/web_search",
        .tool_name = "web_search",
        .description = "Search web",
        .input_schema = "{\"type\":\"object\"}",
        .entry_path = "/frozen/v1/bin/web-search",
    };
}

test "asTool exposes the frozen definition, sequential policy, and binding pointer" {
    var binding = testBinding();
    const t = binding.asTool();

    // The definition is the stable logical identity plus the model-facing
    // invocation name — the version appears nowhere in it.
    try testing.expectEqualStrings("ext:web.search/web_search", t.definition.id);
    try testing.expectEqualStrings("web_search", t.definition.name);
    try testing.expectEqualStrings("Search web", t.definition.description);
    try testing.expectEqualStrings("{\"type\":\"object\"}", t.definition.input_schema);
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

    // The binding's tool_name is the JSON-RPC name; the model's raw arguments
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
