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

/// Run exactly one step against `l`. Appends the assistant turn, and — if it
/// carried tool calls — the single batched `tool_results` turn.
pub fn runStep(
    alloc: std.mem.Allocator,
    l: *ledger.Ledger,
    model: Model,
    tool_snapshot: registry.ToolSetSnapshot,
    ctx_base: tool.CtxHeader,
) !provider.Usage {
    return runStepWithOptions(alloc, l, model, tool_snapshot, ctx_base, .{});
}

pub fn runStepWithOptions(
    alloc: std.mem.Allocator,
    l: *ledger.Ledger,
    model: Model,
    tool_snapshot: registry.ToolSetSnapshot,
    ctx_base: tool.CtxHeader,
    model_options: provider.Options,
) !provider.Usage {
    // If the previous process died after recording tool calls but before
    // recording the batched results, make the ledger legal and conservative
    // before the next provider request. Mutating tools must not be replayed
    // automatically: the workspace may already have changed.
    try completeInterruptedToolBatch(alloc, l);

    // seq base is the ledger position: deterministic across replays (DESIGN §1).
    const base_seq = l.len();

    const prompt_ir = try prompt.project(alloc, l.view());
    defer prompt_ir.deinit(alloc);

    const tool_defs = try tool_snapshot.definitions(alloc);
    defer alloc.free(tool_defs);

    const turn = try model.step(alloc, .{
        .prompt_ir = &prompt_ir,
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

    var step_output = emit.StepOutputLimiter.init(ctx_base.environment.io, ctx_base.scratch_dir, base_seq, ctx_base.step_budget);
    const max_concurrent_tools = maxConcurrentTools(batchExecutionPolicy(tool_snapshot, turn.calls));
    std.debug.assert(max_concurrent_tools == 1);
    for (turn.calls, 0..) |call, i| {
        var ctx = ctx_base;
        ctx.event_seq = base_seq;
        ctx.call_index = i;
        results[i] = try execOne(alloc, tool_snapshot, call, ctx);
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

fn execOne(
    alloc: std.mem.Allocator,
    tool_snapshot: registry.ToolSetSnapshot,
    call: ledger.ToolCall,
    ctx: tool.CtxHeader,
) !ledger.ToolResultEntry {
    const t = tool_snapshot.lookup(call.tool) orelse {
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
        fn run(a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.ToolResult {
            const command = try tool.requireString(req.args, "command");
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
        .run = FakeShell.run,
    }};
    const tools: registry.ToolSetSnapshot = .{ .tools = &fake_tools };

    var lenv = try environment.LocalEnvironment.init(alloc, threaded.io(), .{});
    defer lenv.deinit();

    var scripted = Scripted{};
    _ = try runStep(alloc, &l, .{ .ptr = &scripted, .vtable = &Scripted.vtable }, tools, .{
        .environment = lenv.environment(),
        .cwd = ".",
        .scratch_dir = "/tmp",
        .event_seq = 0,
        .call_index = 0,
    });

    // user_text, assistant, tool_results — exactly one batched result turn.
    try std.testing.expectEqual(@as(usize, 3), l.len());
    const last = l.view()[2];
    try std.testing.expectEqual(@as(usize, 2), last.tool_results.len);
    try std.testing.expect(last.tool_results[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, last.tool_results[0].output, "one") != null);

    // Ledger owns cloned assistant/tool-result payloads and frees them in deinit.
}


test "interrupted tool batch is completed as unknown before next model request" {
    const alloc = std.testing.allocator;

    const RecoveringModel = struct {
        saw_unknown_result: bool = false,

        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "recovering";
        }

        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "recovering-test";
        }

        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }

        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqual(@as(usize, 4), request.prompt_ir.stable_blocks.len);
            try std.testing.expectEqual(prompt.BlockKind.tool_result, request.prompt_ir.stable_blocks[3].kind);
            try std.testing.expect(std.mem.indexOf(u8, request.prompt_ir.stable_blocks[3].bytes, "state is unknown") != null);
            self.saw_unknown_result = true;
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "recovered" });
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
    try l.append(.{ .assistant = .{
        .text = "running",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"touch marker\"}" }},
    } });

    var lenv = try environment.LocalEnvironment.init(alloc, threaded.io(), .{});
    defer lenv.deinit();

    var model_impl = RecoveringModel{};
    _ = try runStep(alloc, &l, .{ .ptr = &model_impl, .vtable = &RecoveringModel.vtable }, .{ .tools = &.{} }, .{
        .environment = lenv.environment(),
        .cwd = ".",
        .scratch_dir = "/tmp",
        .event_seq = 0,
        .call_index = 0,
    });

    try std.testing.expect(model_impl.saw_unknown_result);
    try std.testing.expectEqual(@as(usize, 4), l.len());
    const repaired = l.view()[2].tool_results;
    try std.testing.expectEqual(@as(usize, 1), repaired.len);
    try std.testing.expect(!repaired[0].ok);
    try std.testing.expectEqualStrings("c1", repaired[0].call_id);
    try std.testing.expect(std.mem.indexOf(u8, repaired[0].output, "state is unknown") != null);
}


test "a capability note reaches the provider as a tool_note block" {
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
                if (block.kind == .tool_note and std.mem.indexOf(u8, block.bytes, "ext run") != null) {
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
    try l.append(.{ .tool_available_note = "New capability available: tool `greet` from extension `demo`.\nInvoke it through the shell tool: nulya ext run demo '<json-args>'" });

    var lenv = try environment.LocalEnvironment.init(alloc, threaded.io(), .{});
    defer lenv.deinit();

    var model_impl = NoteModel{};
    _ = try runStep(alloc, &l, .{ .ptr = &model_impl, .vtable = &NoteModel.vtable }, .{ .tools = &.{} }, .{
        .environment = lenv.environment(),
        .cwd = ".",
        .scratch_dir = "/tmp",
        .event_seq = 0,
        .call_index = 0,
    });

    try std.testing.expect(model_impl.saw_note);
    try std.testing.expectEqual(@as(usize, 3), l.len()); // user, note, assistant
}

test "batch execution policy is parallel only when every call opts in" {
    const Dummy = struct {
        fn run(alloc: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.ToolResult {
            _ = req;
            return .{ .ok = true, .output = try alloc.dupe(u8, "ok") };
        }
    };

    const fake_tools = [_]tool.Tool{
        .{
            .definition = .{ .id = "test.read_a", .name = "read_a", .description = "read", .input_schema = "{}" },
            .batch_policy = .parallel_read_only,
            .run = Dummy.run,
        },
        .{
            .definition = .{ .id = "test.read_b", .name = "read_b", .description = "read", .input_schema = "{}" },
            .batch_policy = .parallel_read_only,
            .run = Dummy.run,
        },
        .{
            .definition = .{ .id = "test.shell", .name = "shell", .description = "shell", .input_schema = "{}" },
            .batch_policy = .sequential,
            .run = Dummy.run,
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
