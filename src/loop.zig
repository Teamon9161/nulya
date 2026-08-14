//! The agent loop — one model step (DESIGN §4).
//!
//! Shape of a single step, and the two invariants it hard-codes:
//!
//!   1. The model may emit MANY tool calls in one assistant turn. The loop runs
//!      them as a batch and returns ALL results in ONE `tool_results` turn.
//!      Never one round-trip per tool (DESIGN §0.2).
//!   2. The ledger is only ever appended to (DESIGN §1).
//!
//! The model itself is behind a function pointer. The skeleton ships a scripted
//! stub; the real provider (request builder + cache breakpoints, DESIGN §13)
//! drops in here without the loop changing.

const std = @import("std");
const ledger = @import("ledger.zig");
const registry = @import("registry.zig");
const tool = @import("tool.zig");

/// What the model returns for one step.
pub const ModelTurn = struct {
    text: []const u8,
    calls: []const ledger.ToolCall,
};

/// A model is a function from the current ledger view to one assistant turn.
pub const Model = struct {
    step: *const fn (alloc: std.mem.Allocator, view: []const ledger.Event) anyerror!ModelTurn,
};

/// Run exactly one step against `l`. Appends the assistant turn, and — if it
/// carried tool calls — the single batched `tool_results` turn.
pub fn runStep(
    alloc: std.mem.Allocator,
    l: *ledger.Ledger,
    model: Model,
    ctx_base: tool.CtxHeader,
) !void {
    // seq base is the ledger position: deterministic across replays (DESIGN §1).
    const base_seq = l.len();

    const turn = try model.step(alloc, l.view());
    try l.append(.{ .assistant = .{ .text = turn.text, .calls = turn.calls } });
    if (turn.calls.len == 0) return; // model addressed the user; step complete.

    const results = try alloc.alloc(ledger.ToolResultEntry, turn.calls.len);
    for (turn.calls, 0..) |call, i| {
        var ctx = ctx_base;
        ctx.seq = base_seq * 64 + i; // unique per call -> unique spill filename
        results[i] = try execOne(alloc, call, ctx);
    }
    // ONE user turn carrying the whole batch.
    try l.append(.{ .tool_results = results });
}

fn execOne(
    alloc: std.mem.Allocator,
    call: ledger.ToolCall,
    ctx: tool.CtxHeader,
) !ledger.ToolResultEntry {
    const t = registry.lookup(call.tool) orelse {
        const msg = try std.fmt.allocPrint(alloc, "unknown tool '{s}'; builtins are shell, edit", .{call.tool});
        return .{ .call_id = call.id, .ok = false, .output = msg };
    };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, call.args_json, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "invalid JSON args for '{s}': {s}", .{ call.tool, @errorName(err) });
        return .{ .call_id = call.id, .ok = false, .output = msg };
    };
    defer parsed.deinit();

    const res = t.run(alloc, .{ .args = parsed.value, .ctx = ctx }) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "{s} failed: {s}", .{ call.tool, @errorName(err) });
        return .{ .call_id = call.id, .ok = false, .output = msg };
    };
    return .{
        .call_id = call.id,
        .ok = res.ok,
        .output = res.output,
        .spill_path = res.spill_path,
    };
}

test "one step runs a batch of two shell calls and appends one result turn" {
    const alloc = std.testing.allocator;

    const Scripted = struct {
        fn step(a: std.mem.Allocator, view: []const ledger.Event) anyerror!ModelTurn {
            _ = view;
            const calls = try a.alloc(ledger.ToolCall, 2);
            calls[0] = .{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo one\"}" };
            calls[1] = .{ .id = "c2", .tool = "shell", .args_json = "{\"command\":\"echo two\"}" };
            return .{ .text = "running", .calls = calls };
        }
    };

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });

    try runStep(alloc, &l, .{ .step = Scripted.step }, .{
        .io = threaded.io(),
        .cwd = ".",
        .scratch_dir = "/tmp",
        .seq = 0,
    });

    // user_text, assistant, tool_results — exactly one batched result turn.
    try std.testing.expectEqual(@as(usize, 3), l.len());
    const last = l.view()[2];
    try std.testing.expectEqual(@as(usize, 2), last.tool_results.len);
    try std.testing.expect(last.tool_results[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, last.tool_results[0].output, "one") != null);

    // free the scripted allocations
    for (l.view()) |e| switch (e) {
        .assistant => |as| alloc.free(as.calls),
        .tool_results => |rs| {
            for (rs) |r| {
                alloc.free(r.output);
                if (r.spill_path) |p| alloc.free(p);
            }
            alloc.free(rs);
        },
        else => {},
    };
}
