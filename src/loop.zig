//! The agent loop — one model step (DESIGN §4).
//!
//! Shape of a single step, and the two invariants it hard-codes:
//!
//!   1. The model may emit MANY tool calls in one assistant turn. The loop runs
//!      them as a batch and returns ALL results in ONE `tool_results` turn.
//!      Never one round-trip per tool (DESIGN §0.2).
//!   2. The ledger is only ever appended to (DESIGN §1).
//!
//! The model itself is a provider instance: transport/client/auth/cache policy
//! live behind `provider.Model`, while the loop only sees normalized turns.

const std = @import("std");
const ledger = @import("ledger.zig");
const registry = @import("registry.zig");
const tool = @import("tool.zig");
const emit = @import("emit.zig");
const prompt = @import("prompt.zig");
const provider = @import("provider.zig");
const environment = @import("environment.zig");

pub const ModelTurn = provider.ModelTurn;
pub const Model = provider.Model;

const interrupted_tool_output =
    "previous tool execution was interrupted before Nulya recorded results; " ++
    "the real-world state is unknown, so inspect the workspace before retrying or assuming effects";

pub const StepContext = struct {
    tool_context: tool.ToolContext,
    /// Directory under which `emit` spills overflowing output.
    scratch_dir: []const u8,
    /// Output discipline constants (base-tools.md §3).
    budget: tool.OutputBudget = .{},
    /// Aggregate budget for every tool result in one model step.
    step_budget: tool.StepOutputBudget = .{},
};

/// Run exactly one step against `l` from an already-projected `prompt_ir`.
/// Appends the assistant turn, and — if it carried tool calls — the single
/// batched `tool_results` turn. The prompt is projected by the caller
/// (`AgentSession`), which is what folds in the session's system blocks; the
/// loop only sees the finished IR.
pub fn runStepWithPrompt(
    alloc: std.mem.Allocator,
    l: *ledger.Ledger,
    model: Model,
    prompt_ir: *const prompt.PromptIR,
    tool_snapshot: registry.ToolSetSnapshot,
    step_ctx: StepContext,
    model_options: provider.Options,
) !provider.Usage {
    // seq base is the ledger position: deterministic across replays (DESIGN §1).
    const base_seq = l.len();

    const tool_defs = try tool_snapshot.definitions(alloc);
    defer alloc.free(tool_defs);

    const turn = try model.step(alloc, .{
        .prompt_ir = prompt_ir,
        .tools = tool_defs,
        .generation = prompt.currentGeneration(l.view()),
        .options = model_options,
    });
    defer turn.deinit(alloc);
    try l.append(.{ .assistant = .{ .text = turn.text, .calls = turn.calls } });
    if (turn.calls.len == 0) return turn.usage; // model addressed the user; step complete.

    const results = try alloc.alloc(ledger.ToolResultEntry, turn.calls.len);
    var initialized_results: usize = 0;
    defer {
        for (results[0..initialized_results]) |r| {
            alloc.free(r.output);
            if (r.spill_path) |p| alloc.free(p);
        }
        alloc.free(results);
    }

    var step_output = emit.StepOutputLimiter.init(step_ctx.tool_context.environment.io, step_ctx.scratch_dir, base_seq, step_ctx.step_budget);
    const max_concurrent_tools = maxConcurrentTools(batchExecutionPolicy(tool_snapshot, turn.calls));
    std.debug.assert(max_concurrent_tools == 1);
    for (turn.calls, 0..) |call, i| {
        results[i] = try execOne(alloc, tool_snapshot, call, step_ctx, base_seq, i);
        initialized_results += 1;
        try step_output.apply(alloc, call.tool, i, &results[i].output, &results[i].spill_path);
    }
    // ONE user turn carrying the whole batch.
    try l.append(.{ .tool_results = results });
    return turn.usage;
}

pub fn completeInterruptedToolBatch(alloc: std.mem.Allocator, l: *ledger.Ledger) !void {
    const events = l.view();
    if (events.len == 0) return;

    const last = events[events.len - 1];
    if (last != .assistant) return;
    const assistant = last.assistant;
    if (assistant.calls.len == 0) return;

    const results = try alloc.alloc(ledger.ToolResultEntry, assistant.calls.len);
    defer alloc.free(results);
    for (assistant.calls, 0..) |call, i| {
        results[i] = .{
            .call_id = call.id,
            .ok = false,
            .output = interrupted_tool_output,
        };
    }
    try l.append(.{ .tool_results = results });
}

fn batchExecutionPolicy(tool_snapshot: registry.ToolSetSnapshot, calls: []const ledger.ToolCall) tool.BatchPolicy {
    if (calls.len == 0) return .sequential;
    for (calls) |call| {
        const t = tool_snapshot.lookup(call.tool) orelse return .sequential;
        if (t.batch_policy != .parallel_read_only) return .sequential;
    }
    return .parallel_read_only;
}

fn maxConcurrentTools(policy: tool.BatchPolicy) usize {
    // v0.1 has no worker executor: every batch runs serially, so the cap is 1
    // for EVERY policy. The policy is still recorded per call so read-only tools
    // can raise this once a bounded-parallel dispatcher and arena-per-worker
    // allocation land — without touching provider serialization. Keeping the cap
    // here (rather than a tunable const) means there is no knob that looks like
    // it enables parallelism while execution is still serial.
    return switch (policy) {
        .sequential, .parallel_read_only => 1,
    };
}

/// Test-only convenience: project with no system prompt, then run one step.
/// Real sessions project through `AgentSession` (which carries system blocks),
/// so this shortcut is deliberately not part of the public loop API.
fn runStepForTest(
    alloc: std.mem.Allocator,
    l: *ledger.Ledger,
    model: Model,
    tool_snapshot: registry.ToolSetSnapshot,
    step_ctx: StepContext,
) !provider.Usage {
    const prompt_ir = try prompt.project(alloc, l.view());
    defer prompt_ir.deinit(alloc);
    return runStepWithPrompt(alloc, l, model, &prompt_ir, tool_snapshot, step_ctx, .{});
}

fn execOne(
    alloc: std.mem.Allocator,
    tool_snapshot: registry.ToolSetSnapshot,
    call: ledger.ToolCall,
    step_ctx: StepContext,
    event_seq: u64,
    call_index: usize,
) !ledger.ToolResultEntry {
    var ok = false;
    const raw_output = blk: {
        const t = tool_snapshot.lookup(call.tool) orelse {
            break :blk try std.fmt.allocPrint(alloc, "unknown tool '{s}'; builtins are shell, edit", .{call.tool});
        };

        const res = t.executor.call(alloc, .{ .args_json = call.args_json, .ctx = step_ctx.tool_context }) catch |err| {
            break :blk try std.fmt.allocPrint(alloc, "{s} failed: {s}", .{ call.tool, @errorName(err) });
        };
        ok = res.ok;
        break :blk res.output;
    };
    defer alloc.free(raw_output);

    const emitted = try emit.emit(alloc, step_ctx.tool_context.environment.io, raw_output, call.tool, event_seq, call_index, step_ctx.scratch_dir, step_ctx.budget);
    return .{
        .call_id = call.id,
        .ok = ok,
        .output = emitted.text,
        .spill_path = emitted.spill_path,
    };
}

test "one step runs a batch of two shell calls and appends one result turn" {
    const alloc = std.testing.allocator;

    const Scripted = struct {
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "scripted";
        }

        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "scripted-test";
        }

        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{ .parallel_tool_calls = true };
        }

        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = ptr;
            _ = a;
            try std.testing.expectEqual(@as(usize, 1), request.prompt_ir.stable_blocks.len);
            try std.testing.expectEqual(@as(usize, 1), request.tools.len);
            try std.testing.expectEqualStrings("shell", request.tools[0].name);
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "running" });
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo one\"}" } });
            try sink.emit(.{ .tool_use_start = .{ .index = 1, .id = "c2", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 1, .fragment = "{\"command\":\"echo two\"}" } });
            try sink.emit(.{ .done = .tool_use });
        }

        const vtable: provider.Model.VTable = .{
            .name = name,
            .modelName = modelName,
            .capabilities = capabilities,
            .stream = stream,
        };
    };

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });

    const FakeShell = struct {
        fn run(a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            const parsed = try tool.parseArgs(a, req.args_json);
            defer parsed.deinit();
            const command = try tool.requireString(parsed.value, "command");
            const output = if (std.mem.indexOf(u8, command, "one") != null) "one\n[exit 0]" else "two\n[exit 0]";
            return .{ .ok = true, .output = try a.dupe(u8, output) };
        }
    };

    const fake_tools = [_]tool.Tool{.{
        .definition = .{
            .id = "test.shell",
            .name = "shell",
            .description = "test shell",
            .input_schema = "{}",
        },
        .executor = tool.functionExecutor(FakeShell.run),
    }};
    const tools: registry.ToolSetSnapshot = .{ .tools = &fake_tools };

    var lenv = try environment.LocalEnvironment.init(alloc, threaded.io(), .{});
    defer lenv.deinit();

    var scripted = Scripted{};
    _ = try runStepForTest(alloc, &l, .{ .ptr = &scripted, .vtable = &Scripted.vtable }, tools, .{
        .tool_context = .{
            .environment = lenv.environment(),
            .fs = lenv.workspaceFs(),
            .cwd = ".",
        },
        .scratch_dir = "/tmp",
    });

    // user_text, assistant, tool_results — exactly one batched result turn.
    try std.testing.expectEqual(@as(usize, 3), l.len());
    const last = l.view()[2];
    try std.testing.expectEqual(@as(usize, 2), last.tool_results.len);
    try std.testing.expect(last.tool_results[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, last.tool_results[0].output, "one") != null);

    // Ledger owns cloned assistant/tool-result payloads and frees them in deinit.
}


test "completeInterruptedToolBatch appends unknown results for an assistant tail" {
    const alloc = std.testing.allocator;

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });
    try l.append(.{ .assistant = .{
        .text = "running",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"touch marker\"}" }},
    } });

    try completeInterruptedToolBatch(alloc, &l);

    try std.testing.expectEqual(@as(usize, 3), l.len());
    const repaired = l.view()[2].tool_results;
    try std.testing.expectEqual(@as(usize, 1), repaired.len);
    try std.testing.expect(!repaired[0].ok);
    try std.testing.expectEqualStrings("c1", repaired[0].call_id);
    try std.testing.expect(std.mem.indexOf(u8, repaired[0].output, "state is unknown") != null);
}


test "a capability note reaches the provider as a capability_note block" {
    const alloc = std.testing.allocator;

    const NoteModel = struct {
        saw_note: bool = false,

        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "note";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "note-test";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            for (request.prompt_ir.stable_blocks) |block| {
                if (block.kind == .capability_note and std.mem.indexOf(u8, block.bytes, "ext run") != null) {
                    self.saw_note = true;
                }
            }
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "ok" });
            try sink.emit(.{ .done = .end_turn });
        }
        const vtable: provider.Model.VTable = .{
            .name = name,
            .modelName = modelName,
            .capabilities = capabilities,
            .stream = stream,
        };
    };

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });
    try l.append(.{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "New capabilities from extension `demo` version `v-aaaa` are now available:\n\n- greet — Say hello.\n\nInvoke through the shell tool:\nnulya ext run demo <tool> '<json-args>'" } });

    var lenv = try environment.LocalEnvironment.init(alloc, threaded.io(), .{});
    defer lenv.deinit();

    var model_impl = NoteModel{};
    _ = try runStepForTest(alloc, &l, .{ .ptr = &model_impl, .vtable = &NoteModel.vtable }, .{ .tools = &.{} }, .{
        .tool_context = .{
            .environment = lenv.environment(),
            .fs = lenv.workspaceFs(),
            .cwd = ".",
        },
        .scratch_dir = "/tmp",
    });

    try std.testing.expect(model_impl.saw_note);
    try std.testing.expectEqual(@as(usize, 3), l.len()); // user, note, assistant
}

test "batch execution policy is parallel only when every call opts in" {
    const Dummy = struct {
        fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = req;
            return .{ .ok = true, .output = try alloc.dupe(u8, "ok") };
        }
    };

    const fake_tools = [_]tool.Tool{
        .{
            .definition = .{ .id = "test.read_a", .name = "read_a", .description = "read", .input_schema = "{}" },
            .batch_policy = .parallel_read_only,
            .executor = tool.functionExecutor(Dummy.run),
        },
        .{
            .definition = .{ .id = "test.read_b", .name = "read_b", .description = "read", .input_schema = "{}" },
            .batch_policy = .parallel_read_only,
            .executor = tool.functionExecutor(Dummy.run),
        },
        .{
            .definition = .{ .id = "test.shell", .name = "shell", .description = "shell", .input_schema = "{}" },
            .batch_policy = .sequential,
            .executor = tool.functionExecutor(Dummy.run),
        },
    };
    const tools: registry.ToolSetSnapshot = .{ .tools = &fake_tools };

    const read_calls = [_]ledger.ToolCall{
        .{ .id = "c1", .tool = "read_a", .args_json = "{}" },
        .{ .id = "c2", .tool = "read_b", .args_json = "{}" },
    };
    try std.testing.expectEqual(tool.BatchPolicy.parallel_read_only, batchExecutionPolicy(tools, &read_calls));
    try std.testing.expectEqual(@as(usize, 1), maxConcurrentTools(batchExecutionPolicy(tools, &read_calls)));

    const mixed_calls = [_]ledger.ToolCall{
        .{ .id = "c1", .tool = "read_a", .args_json = "{}" },
        .{ .id = "c2", .tool = "shell", .args_json = "{}" },
    };
    try std.testing.expectEqual(tool.BatchPolicy.sequential, batchExecutionPolicy(tools, &mixed_calls));

    const unknown_calls = [_]ledger.ToolCall{.{ .id = "c1", .tool = "missing", .args_json = "{}" }};
    try std.testing.expectEqual(tool.BatchPolicy.sequential, batchExecutionPolicy(tools, &unknown_calls));
}
