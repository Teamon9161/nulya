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
//! `CtxHeader`.

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
/// INVARIANT: every field here is fixed-shape. Nothing that scales with the
/// number of turns may be added — no message history, no ledger handle.
pub const CtxHeader = struct {
    /// The execution environment (DESIGN §8). A tool reaches its filesystem via
    /// `environment.io` and runs subprocesses via `environment.runShell` — local
    /// today, sandbox/remote later, without changing tool code. It also carries
    /// the dialect and the sanitized child env (DESIGN §9). Fixed-shape, so it
    /// belongs here.
    environment: Environment,
    /// Working directory for filesystem-relative operations.
    cwd: []const u8,
    /// Directory under which `emit` spills overflowing output.
    scratch_dir: []const u8,
    /// Ledger event sequence for the assistant turn that requested this call.
    /// Feeds deterministic spill filenames so a replayed ledger reproduces
    /// byte-for-byte (base-tools.md §2.4).
    event_seq: u64,
    /// Index of this call within the assistant turn. Unlike packing into one
    /// integer, this has no hidden per-turn call-count limit.
    call_index: usize,
    /// Output discipline constants (base-tools.md §3).
    budget: OutputBudget = .{},
    /// Aggregate budget for every tool result in one model step.
    step_budget: StepOutputBudget = .{},
};

/// A single tool invocation request. This is the entire input surface.
pub const ToolRequest = struct {
    /// Raw JSON arguments; each tool parses its own typed shape.
    args: std.json.Value,
    ctx: CtxHeader,
};

/// A single tool invocation result, already passed through `emit`.
pub const ToolResult = struct {
    ok: bool,
    /// Text returned to the model (post-`emit`: line-clipped, budget-bounded).
    output: []const u8,
    /// If output overflowed, the full raw text was written here.
    spill_path: ?[]const u8 = null,
};

/// Model-facing tool definition. This is the shape provider serialization and
/// extension manifests share.
pub const ToolDefinition = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

/// A registered tool: its model-facing definition plus its execution handler.
///
/// Builtins use function pointers. Extensions can later use a different handler
/// representation without changing provider serialization.
pub const Tool = struct {
    definition: ToolDefinition,
    run: *const fn (alloc: std.mem.Allocator, req: ToolRequest) anyerror!ToolResult,
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
