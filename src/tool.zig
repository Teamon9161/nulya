//! The tool boundary — the single most load-bearing type in the kernel.
//!
//! A tool is a pure-ish function `f(args, ctx_header)`:
//!
//!   - `args`      : model-distilled *semantic* input (JSON). The model curates
//!                   this out of the conversation; the tool never sees the ledger.
//!   - `ctx_header`: *constant-size* context. It must NOT grow with the
//!                   conversation — that is what keeps the cache prefix stable
//!                   (DESIGN §1) and keeps tools least-privilege (DESIGN §7.6).
//!   - factual data (files, command output) is reached through the environment
//!     and `cwd`, not passed in. "Needs the whole conversation" -> it is a
//!     subagent, not a tool.
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

/// Wall-clock caps for the child processes the kernel spawns (base-tools.md §3).
/// ONE table, so no call site carries its own literal: `shell` defaults to
/// `shell_default_ms` and clamps a model-supplied `timeout_ms` into
/// `[1, shell_max_ms]`; an extension's oneshot `tool/call` gets `extension_ms`
/// unless its manifest declares its own, which may reach `extension_max_ms`
/// (DESIGN §7.3). Not config: a timeout is a property of the tool contract the
/// model is taught, not of an operator's deployment.
pub const Timeouts = struct {
    pub const shell_default_ms: u32 = 120_000;
    pub const shell_max_ms: u32 = 600_000;
    pub const extension_ms: u32 = 30_000;
    /// Ceiling for a manifest-declared `contributes.tools[].timeout_ms`, the
    /// same ten minutes `shell` may be asked for: a tool that knows it is slow
    /// (one that steps a real model, say) says so, but no manifest may hand the
    /// host an unbounded wait.
    pub const extension_max_ms: u32 = 600_000;
};

/// Constant-size context handed to every tool call.
///
/// INVARIANT: every field here is fixed-shape and executor-facing. Loop/session
/// presentation data such as spill directories, event sequence numbers, and
/// output budgets stays outside this type.
pub const ToolContext = struct {
    /// The process execution environment (DESIGN §8).
    environment: Environment,
    /// Working directory for filesystem-relative operations.
    cwd: []const u8,
};

/// A single tool invocation request. This is the entire input surface.
pub const ToolRequest = struct {
    /// Raw JSON arguments; executors that need typed values parse locally.
    args_json: []const u8,
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
    /// This tool's own claim that it only reads, frozen from its manifest
    /// (`contributes.tools[].readonly`, DESIGN §7.2.1). The kernel enforces
    /// nothing with it; it travels here so that whoever answers the gate
    /// (DESIGN §4) reads the frozen fact instead of re-deriving it from a
    /// manifest — which is a derivation that can fail silently, and did.
    ///
    /// `null` is not `false`: the package said nothing (and the builtin `shell`
    /// is the kernel itself, which makes no claim either). Not part of the
    /// provider wire — a definition's readonly-ness is a fact about the tool,
    /// not part of what the model is told about it — so `kernel_hash` (which
    /// hashes the builtin definitions) is unaffected by the default.
    readonly: ?bool = null,
};

/// A registered tool: its model-facing definition and its execution handler.
///
/// Several calls may arrive in one assistant turn; the loop runs them serially
/// (DESIGN §4), which preserves model-call order and makes every side effect
/// visible to the calls after it. Batching is about ONE round trip, not about
/// concurrency, so a tool never has to be concurrency-safe.
pub const Tool = struct {
    definition: ToolDefinition,
    executor: ToolExecutor,
};

/// Helper: parse raw tool arguments as JSON.
pub fn parseArgs(alloc: std.mem.Allocator, args_json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch error.InvalidArgsJson;
}

/// Helper: fetch a required string field from parsed args, with a teaching error.
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
