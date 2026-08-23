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
const ext_manifest = @import("manifest.zig");
const invoke = @import("invoke.zig");

/// A frozen extension tool binding.
pub const Binding = struct {
    /// Model-facing identity and schema. `definition.id` is the stable logical
    /// id (never version-qualified); `definition.name` is the tool name the
    /// manifest declared, which is what the wire carries.
    definition: tool.ToolDefinition,
    /// Exact frozen executable path, passed verbatim to `Environment.runExtension`.
    entry_path: []const u8,
    /// For a script extension, the interpreter to run `entry_path` with; null for
    /// a compiled (or directly-executable) entry.
    interpreter: ?[]const u8 = null,
    /// The wall-clock cap this tool's frozen manifest declared for one call, or
    /// null to take the host default (`invoke.Options.timeout_ms`). Frozen with
    /// the version like everything else the manifest says.
    timeout_ms: ?u32 = null,
    /// How to talk to this runtime (`manifest.Runtime.wireOf`), frozen with the
    /// version for the same reason `interpreter` is: what runs and how it is
    /// spoken to are both decided once, at composition time.
    wire: ext_manifest.Wire = .jsonrpc,

    /// Build a binding that owns copies of every string it exposes, so it can
    /// outlive the transient manifest and version data it was resolved from. The
    /// session composition holds these on the heap: once its `Binding[]` is
    /// frozen (`toOwnedSlice`), each binding's address is stable and every
    /// derived `Tool` may borrow it (see `asTool`).
    pub fn initOwned(
        alloc: std.mem.Allocator,
        definition: tool.ToolDefinition,
        entry_path: []const u8,
        interpreter: ?[]const u8,
        timeout_ms: ?u32,
        wire: ext_manifest.Wire,
    ) !Binding {
        const id = try alloc.dupe(u8, definition.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, definition.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, definition.description);
        errdefer alloc.free(description);
        const input_schema = try alloc.dupe(u8, definition.input_schema);
        errdefer alloc.free(input_schema);
        const owned_entry = try alloc.dupe(u8, entry_path);
        errdefer alloc.free(owned_entry);
        const owned_interp: ?[]const u8 = if (interpreter) |i| try alloc.dupe(u8, i) else null;

        return .{
            .definition = .{
                .id = id,
                .name = name,
                .description = description,
                .input_schema = input_schema,
                // Copied, not re-read: an optional bool owns nothing, and this
                // is the frozen manifest's claim travelling to whoever answers
                // the gate (DESIGN §4/§7.2.1). `null` stays `null` — silence is
                // not "not read-only".
                .readonly = definition.readonly,
            },
            .entry_path = owned_entry,
            .interpreter = owned_interp,
            .timeout_ms = timeout_ms,
            .wire = wire,
        };
    }

    /// Release the strings an `initOwned` binding holds. Never call on a binding
    /// built from static string literals (the tests below).
    pub fn deinit(self: Binding, alloc: std.mem.Allocator) void {
        alloc.free(self.definition.id);
        alloc.free(self.definition.name);
        alloc.free(self.definition.description);
        alloc.free(self.definition.input_schema);
        alloc.free(self.entry_path);
        if (self.interpreter) |i| alloc.free(i);
    }

    /// Adapt into a kernel `Tool`. `executor.ptr` is this binding's address.
    pub fn asTool(self: *Binding) tool.Tool {
        return .{
            .definition = self.definition,
            .executor = .{ .ptr = self, .callFn = call },
        };
    }
};

/// `ToolExecutor` callback: a thin passthrough — `invokeTool` owns
/// encode/run/decode and the failure taxonomy.
fn call(ptr: ?*anyopaque, alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const self: *Binding = @ptrCast(@alignCast(ptr));

    const invocation = try invoke.invokeTool(
        alloc,
        req.ctx.environment,
        self.entry_path,
        req.ctx.cwd,
        self.definition.name,
        req.args_json,
        .{
            .interpreter = self.interpreter,
            .timeout_ms = self.timeout_ms orelse invoke.Options.default_timeout_ms,
            .wire = self.wire,
        },
    );

    // Ownership transfer: both slices are allocator-owned; returning moves
    // `invocation.output` (no `deinit`, no copy).
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
    saw_timeout_ms: ?u32 = null,

    fn runExtension(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ExtensionRequest) anyerror!environment.ExtensionOutcome {
        const self: *FakeEnv = @ptrCast(@alignCast(ptr));
        if (self.err) |e| return e;
        self.saw_timeout_ms = req.timeout_ms;
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
        if (self.saw_entry_path.len > 0) alloc.free(self.saw_entry_path);
        if (self.saw_request_json.len > 0) alloc.free(self.saw_request_json);
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

test "initOwned copies every exposed string and survives the source being freed" {
    const alloc = testing.allocator;

    // Sources on the heap, freed before use, to prove the binding took copies.
    const id = try alloc.dupe(u8, "ext:web.search/web_search");
    const name = try alloc.dupe(u8, "web_search");
    const description = try alloc.dupe(u8, "Search web");
    const input_schema = try alloc.dupe(u8, "{\"type\":\"object\"}");
    const entry_path = try alloc.dupe(u8, "/frozen/v1/bin/web-search");

    const binding = try Binding.initOwned(alloc, .{
        .id = id,
        .name = name,
        .description = description,
        .input_schema = input_schema,
    }, entry_path, null, null, .jsonrpc);
    defer binding.deinit(alloc);

    // Drop the sources; the binding must not alias them.
    alloc.free(id);
    alloc.free(name);
    alloc.free(description);
    alloc.free(input_schema);
    alloc.free(entry_path);

    try testing.expectEqualStrings("ext:web.search/web_search", binding.definition.id);
    try testing.expectEqualStrings("web_search", binding.definition.name);
    try testing.expectEqualStrings("Search web", binding.definition.description);
    try testing.expectEqualStrings("{\"type\":\"object\"}", binding.definition.input_schema);
    try testing.expectEqualStrings("/frozen/v1/bin/web-search", binding.entry_path);
    // Nothing was claimed, so nothing is claimed here either (DESIGN §7.2.1).
    try testing.expect(binding.definition.readonly == null);
}

test "a manifest's readonly claim rides on the frozen definition" {
    const alloc = testing.allocator;
    var binding = try Binding.initOwned(alloc, .{
        .id = "ext:std/read",
        .name = "read",
        .description = "Read a file",
        .input_schema = "{\"type\":\"object\"}",
        .readonly = true,
    }, "/frozen/v1/bin/std", null, null, .jsonrpc);
    defer binding.deinit(alloc);

    // The claim is what the gate is shown (DESIGN §4): the alternative — asking
    // a manifest again at approval time — is a second derivation of a fact this
    // session already froze.
    try testing.expectEqual(@as(?bool, true), binding.asTool().definition.readonly);
}

test "initOwned leaks nothing when an interior allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const binding = try Binding.initOwned(alloc, .{
                .id = "ext:web.search/web_search",
                .name = "web_search",
                .description = "Search web",
                .input_schema = "{\"type\":\"object\"}",
            }, "/frozen/v1/bin/web-search", null, null, .jsonrpc);
            binding.deinit(alloc);
        }
    }.run, .{});
}

test "asTool exposes the frozen definition and binding pointer" {
    var binding = testBinding();
    const t = binding.asTool();

    try testing.expectEqualStrings("ext:web.search/web_search", t.definition.id);
    try testing.expectEqualStrings("web_search", t.definition.name);
    try testing.expectEqualStrings("Search web", t.definition.description);
    try testing.expectEqualStrings("{\"type\":\"object\"}", t.definition.input_schema);

    // The callback recovers the binding from this pointer, so it must be the
    // binding's own address.
    const binding_ptr: ?*anyopaque = @ptrCast(&binding);
    try testing.expectEqual(binding_ptr, t.executor.ptr);
}

test "executor forwards the exact frozen entry path" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_response };
    defer fake.deinit(alloc);

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    // The frozen executable path reaches the environment verbatim — no
    // resolution, no joining.
    try testing.expectEqualStrings("/frozen/v1/bin/web-search", fake.saw_entry_path);
}

test "a binding's declared timeout reaches the environment; without one the host default does" {
    const alloc = testing.allocator;

    var default_binding = testBinding();
    var default_env = FakeEnv{ .io = testing.io, .response = success_response };
    defer default_env.deinit(alloc);
    const default_result = try default_binding.asTool().executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = default_env.handle(), .cwd = "ws" },
    });
    defer alloc.free(default_result.output);
    try testing.expectEqual(@as(?u32, invoke.Options.default_timeout_ms), default_env.saw_timeout_ms);

    // A tool that knows it is slow said so in its manifest (DESIGN §7.3); the
    // binding carries that verbatim to the child.
    var slow_binding = testBinding();
    slow_binding.timeout_ms = 600_000;
    var slow_env = FakeEnv{ .io = testing.io, .response = success_response };
    defer slow_env.deinit(alloc);
    const slow_result = try slow_binding.asTool().executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = slow_env.handle(), .cwd = "ws" },
    });
    defer alloc.free(slow_result.output);
    try testing.expectEqual(@as(?u32, 600_000), slow_env.saw_timeout_ms);
}

test "a binding's declared wire decides what the child is sent and how its stdout is read" {
    const alloc = testing.allocator;
    var binding = testBinding();
    binding.entry_path = "/frozen/v1/src/run.sh";
    binding.wire = .plain;
    // A plain runtime writes text, not an envelope; the executor hands it on.
    var fake = FakeEnv{ .io = testing.io, .response = "hello from greeter\n" };
    defer fake.deinit(alloc);

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    try testing.expect(result.ok);
    try testing.expectEqualStrings("hello from greeter\n", result.output);
    // stdin is the arguments themselves — no JSON-RPC envelope in sight.
    try testing.expectEqualStrings("{\"query\":\"zig\"}", fake.saw_request_json);
}

test "executor forwards the model's raw arguments as a tool/call request" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_response };
    defer fake.deinit(alloc);

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

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

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
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

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    try testing.expect(!result.ok);
    // The executor forwards invokeTool's diagnostic — no re-wrapping.
    try testing.expect(std.mem.indexOf(u8, result.output, "down") != null);
}

test "timeout remains a normal failed tool result" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .timed_out = true };
    defer fake.deinit(alloc);

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
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

    try testing.expectError(error.Canceled, binding.asTool().executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    }));
}

test "host faults propagate as errors, not failed results" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .err = error.OutOfMemory };
    defer fake.deinit(alloc);

    try testing.expectError(error.OutOfMemory, binding.asTool().executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    }));
}
