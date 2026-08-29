//! Extension tools as ordinary kernel tools (DESIGN §7.3, §5).
//!
//! `Binding` pairs a tool's model-facing `tool.ToolDefinition` with the FROZEN
//! VERSION that serves its calls, then adapts it into the kernel's single
//! `tool.Tool` through the existing `ToolExecutor` seam — no second tool
//! abstraction.
//!
//! Two invariants hold:
//!   - The binding never touches the extension store, `current`, manifests, or
//!     discovery; which version serves this tool was decided and frozen by the
//!     caller, and which FILE that version means is answered later, by the
//!     machine about to spawn it (`extension/exec.zig`).
//!   - `ToolExecutor.ptr` borrows the binding, so the binding (and its borrowed
//!     definition strings) must outlive every derived `Tool` and must not move.

const std = @import("std");
const tool = @import("../tool.zig");
const invoke = @import("invoke.zig");

/// A frozen extension tool binding.
pub const Binding = struct {
    /// Model-facing identity and schema. `definition.id` is the stable logical
    /// id (never version-qualified); `definition.name` is the tool name the
    /// manifest declared, which is what reaches the child as `NULYA_TOOL`.
    definition: tool.ToolDefinition,
    /// The package this tool belongs to.
    ext_id: []const u8,
    /// The frozen version that SERVES a call to it. For a session whose tools
    /// run on another machine that is the header's `exec_version` — the sibling
    /// build for that machine's target (DESIGN §3.4) — and otherwise the
    /// member's own frozen version. Either way the choice was made once, at
    /// freeze time, and is merely carried here.
    version: []const u8,
    /// The wall-clock cap this tool's frozen manifest declared for one call, or
    /// null to take the host default (`invoke.Options.timeout_ms`). Frozen with
    /// the version like everything else the manifest says.
    timeout_ms: ?u32 = null,

    /// Build a binding that owns copies of every string it exposes, so it can
    /// outlive the transient manifest and version data it was resolved from. The
    /// session composition holds these on the heap: once its `Binding[]` is
    /// frozen (`toOwnedSlice`), each binding's address is stable and every
    /// derived `Tool` may borrow it (see `asTool`).
    pub fn initOwned(
        alloc: std.mem.Allocator,
        definition: tool.ToolDefinition,
        ext_id: []const u8,
        version: []const u8,
        timeout_ms: ?u32,
    ) !Binding {
        const id = try alloc.dupe(u8, definition.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, definition.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, definition.description);
        errdefer alloc.free(description);
        const input_schema = try alloc.dupe(u8, definition.input_schema);
        errdefer alloc.free(input_schema);
        const owned_ext_id = try alloc.dupe(u8, ext_id);
        errdefer alloc.free(owned_ext_id);
        const owned_version = try alloc.dupe(u8, version);

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
            .ext_id = owned_ext_id,
            .version = owned_version,
            .timeout_ms = timeout_ms,
        };
    }

    /// Release the strings an `initOwned` binding holds. Never call on a binding
    /// built from static string literals (the tests below).
    pub fn deinit(self: Binding, alloc: std.mem.Allocator) void {
        alloc.free(self.definition.id);
        alloc.free(self.definition.name);
        alloc.free(self.definition.description);
        alloc.free(self.definition.input_schema);
        alloc.free(self.ext_id);
        alloc.free(self.version);
    }

    /// Adapt into a kernel `Tool`. `executor.ptr` is this binding's address.
    pub fn asTool(self: *Binding) tool.Tool {
        return .{
            .definition = self.definition,
            .executor = .{ .ptr = self, .callFn = call },
        };
    }
};

/// `ToolExecutor` callback: a thin passthrough — `invokeTool` owns the spawn,
/// the capture and the failure taxonomy.
fn call(ptr: ?*anyopaque, alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    const self: *Binding = @ptrCast(@alignCast(ptr));

    const invocation = try invoke.invokeTool(
        alloc,
        req.ctx.environment,
        self.ext_id,
        self.version,
        self.definition.name,
        req.ctx.cwd,
        req.args_json,
        .{
            .timeout_ms = self.timeout_ms orelse invoke.Options.default_timeout_ms,
            .presentation_file = req.ctx.presentation_file,
        },
    );

    // Ownership transfer: both slices are allocator-owned; returning moves
    // `invocation.output` (no `deinit`, no copy).
    return .{ .ok = invocation.ok, .output = invocation.output };
}

const testing = std.testing;
const environment = @import("../environment.zig");

/// What a successful call prints: stdout is the result, so a driver-facing tool
/// puts JSON here and a model-facing one puts text. Either way the executor
/// hands the bytes on unchanged.
const success_output = "{\"results\":[]}";

/// Scripted environment backend: returns a canned `ExtensionOutcome` (or a
/// canned error) and records what the helper sent, so the executor's
/// orchestration is exercised without spawning a real process.
const FakeEnv = struct {
    io: std.Io,
    response: []const u8 = "",
    stderr_text: []const u8 = "",
    exit_code: u8 = 0,
    timed_out: bool = false,
    err: ?anyerror = null,
    saw_ref: []const u8 = "",
    saw_request_json: []const u8 = "",
    saw_timeout_ms: ?u32 = null,

    fn runExtension(ptr: *anyopaque, alloc: std.mem.Allocator, req: environment.ExtensionRequest) anyerror!environment.ExtensionOutcome {
        const self: *FakeEnv = @ptrCast(@alignCast(ptr));
        if (self.err) |e| return e;
        self.saw_timeout_ms = req.timeout_ms;
        // Allocate everything before publishing to `self`: a mid-way failure
        // frees the locals via errdefer and leaves the saw fields empty, so
        // `deinit` never double-frees.
        const saw_ref = try std.fmt.allocPrint(alloc, "{s}@{s}/{s}", .{ req.id, req.version, req.tool });
        errdefer alloc.free(saw_ref);
        const saw_request_json = try alloc.dupe(u8, req.request_json);
        errdefer alloc.free(saw_request_json);
        const stdout = try alloc.dupe(u8, self.response);
        errdefer alloc.free(stdout);
        const stderr = try alloc.dupe(u8, self.stderr_text);
        self.saw_ref = saw_ref;
        self.saw_request_json = saw_request_json;
        return .{ .stdout = stdout, .stderr = stderr, .exit_code = self.exit_code, .timed_out = self.timed_out };
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
        if (self.saw_ref.len > 0) alloc.free(self.saw_ref);
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
        .ext_id = "web.search",
        .version = "v-000000000000000000000001",
    };
}

test "initOwned copies every exposed string and survives the source being freed" {
    const alloc = testing.allocator;

    // Sources on the heap, freed before use, to prove the binding took copies.
    const id = try alloc.dupe(u8, "ext:web.search/web_search");
    const name = try alloc.dupe(u8, "web_search");
    const description = try alloc.dupe(u8, "Search web");
    const input_schema = try alloc.dupe(u8, "{\"type\":\"object\"}");
    const ext_id = try alloc.dupe(u8, "web.search");
    const version = try alloc.dupe(u8, "v-000000000000000000000001");

    const binding = try Binding.initOwned(alloc, .{
        .id = id,
        .name = name,
        .description = description,
        .input_schema = input_schema,
    }, ext_id, version, null);
    defer binding.deinit(alloc);

    // Drop the sources; the binding must not alias them.
    alloc.free(id);
    alloc.free(name);
    alloc.free(description);
    alloc.free(input_schema);
    alloc.free(ext_id);
    alloc.free(version);

    try testing.expectEqualStrings("ext:web.search/web_search", binding.definition.id);
    try testing.expectEqualStrings("web_search", binding.definition.name);
    try testing.expectEqualStrings("Search web", binding.definition.description);
    try testing.expectEqualStrings("{\"type\":\"object\"}", binding.definition.input_schema);
    try testing.expectEqualStrings("web.search", binding.ext_id);
    try testing.expectEqualStrings("v-000000000000000000000001", binding.version);
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
    }, "std", "v-000000000000000000000002", null);
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
            }, "web.search", "v-000000000000000000000001", null);
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

test "executor forwards the exact frozen identity" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_output };
    defer fake.deinit(alloc);

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    // The frozen (package, version, tool) reaches the environment verbatim —
    // no resolution here, and no path: the machine that spawns it decides which
    // file that version means.
    try testing.expectEqualStrings("web.search@v-000000000000000000000001/web_search", fake.saw_ref);
}

test "a binding's declared timeout reaches the environment; without one the host default does" {
    const alloc = testing.allocator;

    var default_binding = testBinding();
    var default_env = FakeEnv{ .io = testing.io, .response = success_output };
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
    var slow_env = FakeEnv{ .io = testing.io, .response = success_output };
    defer slow_env.deinit(alloc);
    const slow_result = try slow_binding.asTool().executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = slow_env.handle(), .cwd = "ws" },
    });
    defer alloc.free(slow_result.output);
    try testing.expectEqual(@as(?u32, 600_000), slow_env.saw_timeout_ms);
}

test "executor forwards the model's raw arguments to stdin" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_output };
    defer fake.deinit(alloc);

    const result = try binding.asTool().executor.call(alloc, .{
        .args_json = "{\"query\":\"zig\"}",
        .ctx = .{ .environment = fake.handle(), .cwd = "ws" },
    });
    defer alloc.free(result.output);

    // What the child is sent is the model's own arguments object — no envelope
    // around it, and no re-emission of the JSON it wrote.
    try testing.expectEqualStrings("{\"query\":\"zig\"}", fake.saw_request_json);
}

test "success maps to a raw success result carrying stdout verbatim" {
    const alloc = testing.allocator;
    var binding = testBinding();
    var fake = FakeEnv{ .io = testing.io, .response = success_output };
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
    // A tool that failed: its message on stderr, a non-zero exit.
    var fake = FakeEnv{ .io = testing.io, .stderr_text = "down", .exit_code = 1 };
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
