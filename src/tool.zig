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

/// Truncation / spill limits. Kernel defaults live here (base-tools.md §3) and
/// are the primary knob for per-result token cost.
pub const OutputBudget = emit.OutputBudget;

/// Constant-size context handed to every tool call.
///
/// INVARIANT: every field here is fixed-shape. Nothing that scales with the
/// number of turns may be added — no message history, no ledger handle.
pub const CtxHeader = struct {
    /// The execution environment's I/O handle (DESIGN §8). In Zig 0.16 all fs
    /// and process operations are performed through an `Io`; passing it here is
    /// exactly how a tool reaches its environment — local today, sandbox/remote
    /// later, without changing tool code. Fixed-shape, so it belongs here.
    io: std.Io,
    /// Working directory for filesystem-relative operations.
    cwd: []const u8,
    /// Directory under which `emit` spills overflowing output.
    scratch_dir: []const u8,
    /// Monotonic step sequence. Feeds deterministic spill filenames so a
    /// replayed ledger reproduces byte-for-byte (base-tools.md §2.4).
    seq: u64,
    /// Output discipline constants (base-tools.md §3).
    budget: OutputBudget = .{},
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

/// A registered tool: a name, a schema description, and its run function.
///
/// We use an explicit function pointer rather than a vtable/interface because
/// the whole point is that a tool is *just a function of its request*.
pub const Tool = struct {
    name: []const u8,
    /// One-line description surfaced to the model (and, later, its JSON schema).
    description: []const u8,
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
