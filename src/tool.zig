//! The tool boundary — the single most load-bearing type in the kernel.
//!
//! A tool is a pure-ish function `f(args, ctx_header)`:
//!
//!   - `args`      : model-distilled *semantic* input (JSON). The model curates
//!                   this out of the conversation; the tool never sees the ledger.
//!   - `ctx_header`: *constant-size* context. It must NOT grow with the
//!                   conversation — that is what keeps the cache prefix stable
//!                   (DESIGN §1) and keeps tools least-privilege (DESIGN §7.6).
//!   - factual data (files, command output) is reached through `fs`/`cwd`, not
//!     passed in. "Needs the whole conversation" -> it is a subagent, not a tool.
//!
//! Everything a tool is allowed to touch enters through `ToolRequest`. If a
//! field would grow unbounded with the dialogue, it does not belong in
//! `ToolContext`.

const std = @import("std");
const emit = @import("emit.zig");
const environment = @import("environment.zig");

pub const Environment = environment.Environment;

/// Truncation / spill limits. Kernel defaults live here (base-tools.md §3) and
/// are the primary knob for per-result token cost.
pub const OutputBudget = emit.OutputBudget;

pub const StepOutputBudget = emit.StepOutputBudget;

/// Constant-size context handed to every tool call.
///
/// INVARIANT: every field here is fixed-shape and executor-facing. Loop/session
/// presentation data such as spill directories, event sequence numbers, and
/// output budgets stays outside this type.
pub const ToolContext = struct {
    /// The execution environment (DESIGN §8). Tools run subprocesses through the
    /// environment; filesystem operations still use `environment.io` until the
    /// planned WorkspaceFs vtable lands.
    environment: Environment,
    /// Working directory for filesystem-relative operations.
    cwd: []const u8,
};

/// A single tool invocation request. This is the entire input surface.
pub const ToolRequest = struct {
    /// Raw JSON arguments; each tool parses its own typed shape.
    args: std.json.Value,
    ctx: ToolContext,
};

/// A single tool invocation result before model-facing output discipline.
pub const RawToolResult = struct {
    ok: bool,
    /// Raw text produced by the executor, owned by the caller's allocator. The
    /// kernel applies `emit` after the executor returns, so builtin / extension /
    /// MCP executors never need to know scratch paths, spill budgets, or
    /// presentation rules.
    output: []const u8,
};

pub const ToolExecutor = struct {
    ptr: ?*anyopaque,
    callFn: *const fn (ptr: ?*anyopaque, alloc: std.mem.Allocator, req: ToolRequest) anyerror!RawToolResult,

    pub fn call(self: ToolExecutor, alloc: std.mem.Allocator, req: ToolRequest) !RawToolResult {
        return self.callFn(self.ptr, alloc, req);
    }
};

pub fn functionExecutor(comptime runFn: *const fn (alloc: std.mem.Allocator, req: ToolRequest) anyerror!RawToolResult) ToolExecutor {
    const Adapter = struct {
        fn call(ptr: ?*anyopaque, alloc: std.mem.Allocator, req: ToolRequest) anyerror!RawToolResult {
            _ = ptr;
            return runFn(alloc, req);
        }
    };
    return .{ .ptr = null, .callFn = Adapter.call };
}

/// Model-facing tool definition. This is the shape provider serialization and
/// extension manifests share.
pub const ToolDefinition = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

/// How the agent loop may schedule several calls emitted in one assistant turn.
/// The default is the safest boundary: preserve model-call order and make every
/// side effect visible to later calls. Read-only tools may opt into parallel
/// execution later without changing provider serialization.
pub const BatchPolicy = enum {
    sequential,
    parallel_read_only,
};

/// A registered tool: its model-facing definition, scheduling contract, and
/// execution handler.
pub const Tool = struct {
    definition: ToolDefinition,
    batch_policy: BatchPolicy = .sequential,
    executor: ToolExecutor,
};

/// Helper: fetch a required string field from `args`, with a teaching error.
pub fn requireString(args: std.json.Value, field: []const u8) ![]const u8 {
    if (args != .object) return error.ArgsNotObject;
    const v = args.object.get(field) orelse return error.MissingField;
    if (v != .string) return error.FieldNotString;
    return v.string;
}

/// Helper: fetch an optional string field.
pub fn optionalString(args: std.json.Value, field: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(field) orelse return null;
    if (v != .string) return null;
    return v.string;
}

test "requireString reports missing field distinctly from wrong type" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"a\":\"x\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("x", try requireString(parsed.value, "a"));
    try std.testing.expectError(error.MissingField, requireString(parsed.value, "b"));
}


test "tools default to sequential batch policy" {
    const Fake = struct {
        fn run(alloc: std.mem.Allocator, req: ToolRequest) anyerror!RawToolResult {
            _ = req;
            return .{ .ok = true, .output = try alloc.dupe(u8, "ok") };
        }
    };

    const fake: Tool = .{
        .definition = .{
            .id = "test.fake",
            .name = "fake",
            .description = "fake",
            .input_schema = "{}",
        },
        .executor = functionExecutor(Fake.run),
    };
    try std.testing.expectEqual(BatchPolicy.sequential, fake.batch_policy);
}
