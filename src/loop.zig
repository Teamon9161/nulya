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

// A tool that was mid-flight when the step was canceled: its executor ran (or
// started to), so real side effects may already exist and be only partially
// applied. Distinct from `tool_not_executed_output` on purpose (DESIGN §4).
const tool_canceled_executing_output =
    "tool execution was canceled; side effects may be partial or unknown";

// A tool whose executor had ALREADY returned success when the step was canceled
// mid-result-recording (a step-budget spill write). The tool may have fully
// completed, so this is distinct from `tool_canceled_executing_output`: the
// model must not conclude the side effects never happened.
const tool_result_recording_canceled_output =
    "tool execution completed, but result recording was canceled; " ++
    "side effects may have occurred and the result is unavailable";

// A tool the loop never dispatched because an earlier call in the same batch was
// canceled. Nulya guarantees this executor never ran, so nothing changed.
const tool_not_executed_output =
    "not executed because the step was canceled";

/// Whether a step ran to completion or was canceled mid-flight. Cancellation is
/// host *execution control*, not a model stop reason (`provider.StopReason`) and
/// not a ledger event — the ledger stays a factual history either way.
pub const StepStatus = enum { completed, canceled };

/// The result of one step. `usage` is always the reliably-known token cost so the
/// session accumulates it whether the step completed or was canceled. Real faults
/// (network, protocol, OOM) still surface as errors, never as an outcome.
pub const StepOutcome = struct {
    usage: provider.Usage = .{},
    status: StepStatus = .completed,
};

/// PURE OBSERVATION of one running step (tui.md §2.2). The kernel reports facts
/// as they happen — provider stream events, tool dispatch, the step boundary —
/// so a front end can show a step in flight instead of only its result.
///
/// An observer is deliberately powerless: every callback returns `void` and
/// takes only read-only views, so it cannot append to the ledger, cannot touch
/// model-visible state, and cannot fail a step. A step run WITH an observer
/// behaves exactly like the same step run without one; whatever an observer's
/// own I/O does (a closed stdout pipe) stays the observer's problem.
pub const StepObserver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Every provider stream event, teed on its way to the turn collector.
        modelEvent: *const fn (ptr: *anyopaque, event: provider.StreamEvent) void,
        /// Just before a call is handed to its executor.
        toolBegin: *const fn (ptr: *anyopaque, call: ledger.ToolCall) void,
        /// Just after the executor returned; `ok` is the executor's own verdict.
        /// Calls the loop never dispatched (a canceled batch's tail) get neither
        /// callback, matching the fact that nothing about them ran.
        toolEnd: *const fn (ptr: *anyopaque, call: ledger.ToolCall, ok: bool) void,
        /// One step boundary: the ledger as it now stands (read-only, so the
        /// observer can flush whatever it has not yet reported) and how the step
        /// ended. Fired for canceled steps too, including one canceled at its
        /// boundary before the model ran.
        stepEnd: *const fn (ptr: *anyopaque, events: []const ledger.Event, status: StepStatus) void,
    };

    pub fn modelEvent(self: StepObserver, event: provider.StreamEvent) void {
        self.vtable.modelEvent(self.ptr, event);
    }

    pub fn toolBegin(self: StepObserver, call: ledger.ToolCall) void {
        self.vtable.toolBegin(self.ptr, call);
    }

    pub fn toolEnd(self: StepObserver, call: ledger.ToolCall, ok: bool) void {
        self.vtable.toolEnd(self.ptr, call, ok);
    }

    pub fn stepEnd(self: StepObserver, events: []const ledger.Event, status: StepStatus) void {
        self.vtable.stepEnd(self.ptr, events, status);
    }
};

pub const StepContext = struct {
    tool_context: tool.ToolContext,
    /// Directory under which `emit` spills overflowing output.
    scratch_dir: []const u8,
    /// Output discipline constants (base-tools.md §3).
    budget: tool.OutputBudget = .{},
    /// Aggregate budget for every tool result in one model step.
    step_budget: tool.StepOutputBudget = .{},
    /// Optional pure-observation hook (tui.md §2.2). Absent by default: a step
    /// with no observer runs byte-for-byte the same code path it always has.
    observer: ?StepObserver = null,
};

/// Tees the provider stream: the observer sees each event first (so a front end
/// renders deltas as they arrive), then the collector accumulates the turn as
/// usual. Only the collector's outcome can fail the step.
const TeeSink = struct {
    collector: *provider.TurnCollector,
    observer: StepObserver,

    fn emitTeed(ptr: *anyopaque, event: provider.StreamEvent) anyerror!void {
        const self: *TeeSink = @ptrCast(@alignCast(ptr));
        self.observer.modelEvent(event);
        return self.collector.onEvent(event);
    }

    fn sink(self: *TeeSink) provider.EventSink {
        return .{ .ptr = self, .emitFn = emitTeed };
    }
};

/// One assistant turn from the provider. Without an observer this IS
/// `Model.step`; with one, the same collection happens behind a tee. Both paths
/// discard a partial collector on error, so a canceled stream leaves nothing.
fn collectTurn(
    alloc: std.mem.Allocator,
    model: Model,
    request: provider.Request,
    observer: ?StepObserver,
) !provider.ModelTurn {
    const obs = observer orelse return model.step(alloc, request);
    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var tee: TeeSink = .{ .collector = &collector, .observer = obs };
    try model.stream(alloc, request, tee.sink());
    return collector.finish();
}

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
) !StepOutcome {
    // seq base is the ledger position: deterministic across replays (DESIGN §1).
    const base_seq = l.len();

    const tool_defs = try tool_snapshot.definitions(alloc);
    defer alloc.free(tool_defs);

    const turn = collectTurn(alloc, model, .{
        .prompt_ir = prompt_ir,
        .tools = tool_defs,
        // generation == ledger file (DESIGN §11): one file is one cache scope, so
        // within a session the generation is constant.
        .generation = 0,
        .options = model_options,
    }, step_ctx.observer) catch |err| switch (err) {
        // Provider-phase cancellation: a complete assistant turn never formed.
        // `model.step` already discarded and freed the partial collector, so the
        // ledger prefix is untouched — no partial assistant / tool_call appended.
        // Usage is what is reliably known: the streaming usage chunk arrives at
        // the very end of the stream, so a mid-stream cancel means 0 (DESIGN §13).
        error.Canceled => return .{ .usage = .{}, .status = .canceled },
        else => return err,
    };
    defer turn.deinit(alloc);
    try l.append(.{ .assistant = .{
        .reasoning = turn.reasoning,
        .text = turn.text,
        .calls = turn.calls,
        // Recorded only when the provider reported a cost. All-zero means "this
        // provider does not price turns" (the scripted stand-in), which is not
        // the same fact as "this step cost zero" — so it is left off the line
        // entirely, and old ledgers stay byte-identical.
        .usage = if (turn.usage.isZero()) null else turn.usage,
    } });
    if (turn.calls.len == 0) return .{ .usage = turn.usage }; // model addressed the user; step complete.

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

    // Execute the batch serially. On cancellation the batch is NOT abandoned: the
    // ledger invariant is "one assistant tool-call batch ↔ exactly one matching
    // tool_results batch" (DESIGN §4). The task's cancellation is consumed here at
    // the step boundary — per std.Io, the *next* cancelation point after the first
    // is what re-signals, so building and appending this batch (pure memory ops)
    // runs uninterrupted. See §8/§6 of the task brief.
    var i: usize = 0;
    var canceled = false;
    while (i < turn.calls.len) : (i += 1) {
        const call = turn.calls[i];
        if (step_ctx.observer) |obs| obs.toolBegin(call);
        const res = execOne(alloc, tool_snapshot, call, step_ctx, base_seq, i) catch |err| switch (err) {
            error.Canceled => {
                if (step_ctx.observer) |obs| obs.toolEnd(call, false);
                results[i] = canceledResult(call.id, try alloc.dupe(u8, tool_canceled_executing_output));
                initialized_results += 1;
                canceled = true;
                break;
            },
            else => return err,
        };
        if (step_ctx.observer) |obs| obs.toolEnd(call, res.ok);
        results[i] = res;
        initialized_results += 1;
        // The step-budget limiter can spill to disk, a cancelable I/O point. A
        // cancel here would otherwise escape as an error and strand the
        // assistant-with-tool-calls tail without its matching batch (DESIGN §4).
        // The executor already finished, so `results[i]` is a real result: allocate
        // the marker first (so an OOM leaves that valid result intact for cleanup),
        // then replace it and complete the batch like the executing-cancel path —
        // with the recording-canceled marker, since the tool itself succeeded.
        step_output.apply(alloc, call.tool, i, &results[i].output, &results[i].spill_path) catch |err| switch (err) {
            error.Canceled => {
                const marker = try alloc.dupe(u8, tool_result_recording_canceled_output);
                alloc.free(results[i].output);
                if (results[i].spill_path) |p| alloc.free(p);
                results[i] = canceledResult(call.id, marker);
                canceled = true;
                break;
            },
            else => return err,
        };
    }

    if (canceled) {
        // Every call after the canceled one was never handed to any executor, so
        // Nulya knows for certain nothing about them changed.
        i += 1; // step past the canceled-while-executing entry filled above.
        while (i < turn.calls.len) : (i += 1) {
            results[i] = canceledResult(turn.calls[i].id, try alloc.dupe(u8, tool_not_executed_output));
            initialized_results += 1;
        }
        try l.append(.{ .tool_results = results });
        return .{ .usage = turn.usage, .status = .canceled };
    }

    // ONE user turn carrying the whole batch.
    try l.append(.{ .tool_results = results });
    return .{ .usage = turn.usage };
}

/// Build a synthetic tool result for a canceled call. `call_id` is borrowed from
/// the assistant turn (owned there until it is cloned into the ledger), matching
/// how `execOne` leaves `call_id` unowned; `output` is caller-allocated and freed
/// by the batch's cleanup path.
fn canceledResult(call_id: []const u8, output: []const u8) ledger.ToolResultEntry {
    return .{ .call_id = call_id, .ok = false, .output = output };
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
) !StepOutcome {
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

        const res = t.executor.call(alloc, .{ .args_json = call.args_json, .ctx = step_ctx.tool_context }) catch |err| switch (err) {
            // Cancellation is not a tool failure — it is host execution control.
            // Propagate it to the step boundary, which records the whole batch as
            // canceled (DESIGN §4). Ordinary executor errors still teach as text.
            error.Canceled => return error.Canceled,
            else => break :blk try std.fmt.allocPrint(alloc, "{s} failed: {s}", .{ call.tool, @errorName(err) }),
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

// ── Cancellation test fixtures ──────────────────────────────────────────────
//
// These exercise real std.Io cancellation: the step runs on a worker task via
// `io.async`, the test thread waits for the step to reach a cancelation point
// (signaled through a `std.Io.Event`), then calls `Future.cancel`. No custom
// cancellation flag exists anywhere — the Threaded backend interrupts the blocked
// task and its next `Io` cancelation point returns `error.Canceled`. Gate waits
// are always `try`ed, never swallowed: a timeout means the worker never reached
// the cancelation point, and canceling from an unknown state would defeat the
// determinism these tests exist to establish.

fn testDeadline(io: std.Io, ms: u32) std.Io.Timeout {
    return .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(ms) }) };
}

/// A tool that announces it started (`ready`) then blocks on `release` — a
/// cancelation point that never resolves except by cancellation.
const BlockingTool = struct {
    ready: *std.Io.Event,
    release: *std.Io.Event,

    fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        const io = req.ctx.environment.io;
        self.ready.set(io);
        try self.release.wait(io); // returns error.Canceled once the step is canceled
        return .{ .ok = true, .output = try a.dupe(u8, "unreachable-after-cancel") };
    }

    fn executor(self: *@This()) tool.ToolExecutor {
        return .{ .ptr = self, .callFn = call };
    }
};

/// A tool that records whether it was ever dispatched.
const RecordingTool = struct {
    ran: bool = false,

    fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
        _ = req;
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        self.ran = true;
        return .{ .ok = true, .output = try a.dupe(u8, "recorded") };
    }

    fn executor(self: *@This()) tool.ToolExecutor {
        return .{ .ptr = self, .callFn = call };
    }
};

/// A tool whose executor consumes the first cancelation at a deterministic gate,
/// re-arms it via `io.recancel()`, then returns SUCCESS. Test-only coordination:
/// `recancel` must never appear in production control flow, which consumes or
/// propagates `error.Canceled` at each ownership boundary instead.
const RecancelAndReturnTool = struct {
    ready: *std.Io.Event,
    release: *std.Io.Event,

    fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        const io = req.ctx.environment.io;
        self.ready.set(io);
        self.release.wait(io) catch |err| switch (err) {
            error.Canceled => io.recancel(),
        };
        return .{ .ok = true, .output = try a.dupe(u8, "small-but-over-step-budget") };
    }

    fn executor(self: *@This()) tool.ToolExecutor {
        return .{ .ptr = self, .callFn = call };
    }
};

fn stubSuccess(a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
    _ = req;
    return .{ .ok = true, .output = try a.dupe(u8, "first-real-output") };
}

/// Model that emits a fixed list of `{id, name}` tool calls (plus one usage
/// chunk), then stops with `tool_use`. Nothing here blocks — the blocking, and
/// hence the cancellation, happens in the tools.
const ScriptedCallModel = struct {
    calls: []const [2][]const u8,
    usage: provider.Usage = .{},

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted-calls";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted-calls";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = a;
        _ = request;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try sink.emit(.started);
        try sink.emit(.{ .usage = self.usage });
        for (self.calls, 0..) |c, i| {
            try sink.emit(.{ .tool_use_start = .{ .index = i, .id = c[0], .name = c[1] } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = i, .fragment = "{}" } });
        }
        try sink.emit(.{ .done = .tool_use });
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };

    fn handle(self: *@This()) provider.Model {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "canceling provider streaming appends no partial assistant and leaves the ledger prefix intact" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A model that streams a partial assistant turn, signals `ready`, then blocks
    // on `release` (a cancelation point) before it can finish. Cancellation must
    // discard the partial turn entirely.
    const BlockingModel = struct {
        io: std.Io,
        ready: *std.Io.Event,
        release: *std.Io.Event,
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "blocking";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "blocking";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            _ = request;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "partial thought that must be discarded" });
            self.ready.set(self.io);
            try self.release.wait(self.io); // cancelation point; never released
            try sink.emit(.{ .done = .end_turn });
        }
        const vtable: provider.Model.VTable = .{
            .name = name,
            .modelName = modelName,
            .capabilities = capabilities,
            .stream = stream,
        };
    };

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const prompt_ir = try prompt.project(alloc, l.view());
    defer prompt_ir.deinit(alloc);

    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    var model_impl = BlockingModel{ .io = io, .ready = &ready, .release = &release };

    const step_ctx: StepContext = .{
        .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = "." },
        .scratch_dir = "/tmp",
    };
    const tools: registry.ToolSetSnapshot = .{ .tools = &.{} };

    var fut = io.async(runStepWithPrompt, .{
        alloc,                                                            &l,
        provider.Model{ .ptr = &model_impl, .vtable = &BlockingModel.vtable }, &prompt_ir,
        tools,                                                            step_ctx,
        provider.Options{},
    });
    try ready.waitTimeout(io, testDeadline(io, 5000));
    const outcome = try fut.cancel(io);

    try std.testing.expectEqual(StepStatus.canceled, outcome.status);
    try std.testing.expectEqual(@as(u64, 0), outcome.usage.input_tokens);
    // Only the original user turn survives — no partial assistant was appended.
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expect(l.view()[0] == .user_text);
}

test "canceling the first executing tool records a complete canceled batch" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    var block_tool = BlockingTool{ .ready = &ready, .release = &release };
    var record_tool = RecordingTool{};

    const tools_arr = [_]tool.Tool{
        .{ .definition = .{ .id = "t.block", .name = "block", .description = "b", .input_schema = "{}" }, .executor = block_tool.executor() },
        .{ .definition = .{ .id = "t.record", .name = "record", .description = "r", .input_schema = "{}" }, .executor = record_tool.executor() },
    };
    const tools: registry.ToolSetSnapshot = .{ .tools = &tools_arr };

    var model_impl = ScriptedCallModel{
        .calls = &.{ .{ "c1", "block" }, .{ "c2", "record" } },
        .usage = .{ .input_tokens = 11, .output_tokens = 4 },
    };

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const prompt_ir = try prompt.project(alloc, l.view());
    defer prompt_ir.deinit(alloc);

    const step_ctx: StepContext = .{
        .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = "." },
        .scratch_dir = "/tmp",
    };

    var fut = io.async(runStepWithPrompt, .{
        alloc, &l, model_impl.handle(), &prompt_ir, tools, step_ctx, provider.Options{},
    });
    try ready.waitTimeout(io, testDeadline(io, 5000));
    const outcome = try fut.cancel(io);

    try std.testing.expectEqual(StepStatus.canceled, outcome.status);
    // The completed assistant turn's usage is preserved through the tool-phase cancel.
    try std.testing.expectEqual(@as(u64, 11), outcome.usage.input_tokens);

    // user, assistant, and exactly ONE batched tool_results turn.
    try std.testing.expectEqual(@as(usize, 3), l.len());
    const trs = l.view()[2].tool_results;
    try std.testing.expectEqual(@as(usize, 2), trs.len); // result count == call count

    try std.testing.expectEqualStrings("c1", trs[0].call_id);
    try std.testing.expect(!trs[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, trs[0].output, "side effects may be partial") != null);

    try std.testing.expectEqualStrings("c2", trs[1].call_id);
    try std.testing.expect(!trs[1].ok);
    try std.testing.expect(std.mem.indexOf(u8, trs[1].output, "not executed") != null);

    // The second call's executor was never dispatched.
    try std.testing.expect(!record_tool.ran);
}

test "a successful earlier tool is kept when a later tool is canceled" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    var block_tool = BlockingTool{ .ready = &ready, .release = &release };

    const tools_arr = [_]tool.Tool{
        .{ .definition = .{ .id = "t.probe", .name = "probe", .description = "p", .input_schema = "{}" }, .executor = tool.functionExecutor(stubSuccess) },
        .{ .definition = .{ .id = "t.block", .name = "block", .description = "b", .input_schema = "{}" }, .executor = block_tool.executor() },
    };
    const tools: registry.ToolSetSnapshot = .{ .tools = &tools_arr };

    var model_impl = ScriptedCallModel{ .calls = &.{ .{ "c1", "probe" }, .{ "c2", "block" } } };

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const prompt_ir = try prompt.project(alloc, l.view());
    defer prompt_ir.deinit(alloc);

    const step_ctx: StepContext = .{
        .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = "." },
        .scratch_dir = "/tmp",
    };

    var fut = io.async(runStepWithPrompt, .{
        alloc, &l, model_impl.handle(), &prompt_ir, tools, step_ctx, provider.Options{},
    });
    // `block` sets `ready` only after `probe` has already returned (serial batch),
    // so the cancel deterministically targets the second call.
    try ready.waitTimeout(io, testDeadline(io, 5000));
    const outcome = try fut.cancel(io);

    try std.testing.expectEqual(StepStatus.canceled, outcome.status);
    const trs = l.view()[2].tool_results;
    try std.testing.expectEqual(@as(usize, 2), trs.len);

    // First call's real result is retained verbatim.
    try std.testing.expectEqualStrings("c1", trs[0].call_id);
    try std.testing.expect(trs[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, trs[0].output, "first-real-output") != null);

    // Second call was executing when canceled: side effects may be partial.
    try std.testing.expectEqualStrings("c2", trs[1].call_id);
    try std.testing.expect(!trs[1].ok);
    try std.testing.expect(std.mem.indexOf(u8, trs[1].output, "side effects may be partial") != null);
}

test "canceling a step-budget spill keeps the ledger complete and never runs later tools" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The first tool's executor consumes the cancel at a deterministic gate,
    // re-arms it, and returns SUCCESS. Its output passes `emit` untouched (the
    // per-tool budget is the 128 KiB default) but exceeds the tiny step budget,
    // so the next cancelation point is `writeStepSpill` inside
    // `StepOutputLimiter.apply` — the regression this locks: a cancel there must
    // not strand the assistant-with-tool-calls tail without its matching batch.
    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    var spill_tool = RecancelAndReturnTool{ .ready = &ready, .release = &release };
    var record_tool = RecordingTool{};

    const tools_arr = [_]tool.Tool{
        .{ .definition = .{ .id = "t.spill", .name = "spill", .description = "s", .input_schema = "{}" }, .executor = spill_tool.executor() },
        .{ .definition = .{ .id = "t.record", .name = "record", .description = "r", .input_schema = "{}" }, .executor = record_tool.executor() },
    };
    const tools: registry.ToolSetSnapshot = .{ .tools = &tools_arr };

    var model_impl = ScriptedCallModel{
        .calls = &.{ .{ "c1", "spill" }, .{ "c2", "record" } },
        .usage = .{ .input_tokens = 11, .output_tokens = 4 },
    };

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "go" });

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const prompt_ir = try prompt.project(alloc, l.view());
    defer prompt_ir.deinit(alloc);

    const step_ctx: StepContext = .{
        .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = "." },
        .scratch_dir = "/tmp",
        .step_budget = .{ .max_bytes = 4 }, // tiny: any result forces the spill path
    };

    var fut = io.async(runStepWithPrompt, .{
        alloc, &l, model_impl.handle(), &prompt_ir, tools, step_ctx, provider.Options{},
    });
    // Determinism contract: cancel only after the worker is known to sit at the
    // gate. A timeout here means the worker never arrived — fail, don't proceed.
    try ready.waitTimeout(io, testDeadline(io, 5000));
    const outcome = try fut.cancel(io);

    try std.testing.expectEqual(StepStatus.canceled, outcome.status);
    // The completed assistant turn's usage is preserved through the spill cancel.
    try std.testing.expectEqual(@as(u64, 11), outcome.usage.input_tokens);

    // user, assistant, and exactly ONE batched tool_results turn.
    try std.testing.expectEqual(@as(usize, 3), l.len());
    const trs = l.view()[2].tool_results;
    try std.testing.expectEqual(@as(usize, 2), trs.len); // result count == call count

    // c1's executor finished successfully; only its result recording was canceled.
    try std.testing.expectEqualStrings("c1", trs[0].call_id);
    try std.testing.expect(!trs[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, trs[0].output, "result recording was canceled") != null);

    // c2 was never handed to its executor.
    try std.testing.expectEqualStrings("c2", trs[1].call_id);
    try std.testing.expect(!trs[1].ok);
    try std.testing.expect(std.mem.indexOf(u8, trs[1].output, "not executed") != null);
    try std.testing.expect(!record_tool.ran);
}
