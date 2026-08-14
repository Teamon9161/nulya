//! Nulya — a minimal, self-evolving AI agent harness.
//!
//! This entry point is a *walking skeleton*: it stands up the immutable ledger,
//! the two builtin tools, the `emit` output primitive, and the batched agent
//! loop, then runs ONE scripted step so the whole geometry compiles and prints.
//! The scripted model stands in for the real provider (DESIGN §13).

const std = @import("std");
const ledger = @import("ledger.zig");
const loop = @import("loop.zig");
const registry = @import("registry.zig");
const tool = @import("tool.zig");

/// Scripted stand-in model: on seeing a pending user turn, it issues two shell
/// calls in a single assistant turn — demonstrating batched execution.
fn scriptedModel(alloc: std.mem.Allocator, view: []const ledger.Event) anyerror!loop.ModelTurn {
    _ = view;
    const calls = try alloc.alloc(ledger.ToolCall, 2);
    calls[0] = .{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo hello from nulya\"}" };
    calls[1] = .{ .id = "c2", .tool = "shell", .args_json = "{\"command\":\"uname -s\"}" };
    return .{ .text = "Let me probe the environment.", .calls = calls };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = "What system am I on?" });

    const tools = try registry.snapshot(alloc);
    defer tools.deinit(alloc);

    try loop.runStep(alloc, &l, .{ .step = scriptedModel }, tools, .{
        .io = io,
        .cwd = ".",
        .scratch_dir = ".nulya/scratch",
        .event_seq = 0,
        .call_index = 0,
    });

    printLedger(&l);

    // Ledger owns cloned assistant/tool-result payloads and frees them in deinit.
}

fn printLedger(l: *const ledger.Ledger) void {
    const p = std.debug.print;
    p("=== ledger ({d} events) ===\n", .{l.len()});
    for (l.view(), 0..) |e, i| {
        switch (e) {
            .user_text => |t| p("[{d}] user: {s}\n", .{ i, t }),
            .assistant => |as| {
                p("[{d}] assistant: {s}\n", .{ i, as.text });
                for (as.calls) |c| p("      call {s} -> {s} {s}\n", .{ c.id, c.tool, c.args_json });
            },
            .tool_results => |rs| {
                p("[{d}] tool_results ({d}):\n", .{ i, rs.len });
                for (rs) |r| p("      {s} ok={} | {s}\n", .{ r.call_id, r.ok, std.mem.trimEnd(u8, r.output, "\n") });
            },
        }
    }
}

// Pull unit tests from every module into `zig build test`.
test {
    std.testing.refAllDecls(@This());
    _ = @import("emit.zig");
    _ = @import("ledger.zig");
    _ = @import("tool.zig");
    _ = @import("registry.zig");
    _ = @import("loop.zig");
    _ = @import("prompt.zig");
}
