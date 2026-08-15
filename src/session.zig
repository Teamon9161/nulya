//! Minimal agent session orchestration.
//!
//! `loop.zig` owns one provider turn and batched tool execution. `AgentSession`
//! owns the conversation-level preparation around those turns: ledger lifetime,
//! session-scoped capability composition, active extension capability notes,
//! interrupted tool-batch repair, and cumulative usage accounting.

const std = @import("std");
const ledger = @import("ledger.zig");
const loop = @import("loop.zig");
const registry = @import("registry.zig");
const provider = @import("provider.zig");
const notes = @import("extension/notes.zig");
const environment = @import("environment.zig");
const prompt = @import("prompt.zig");
const composition = @import("composition.zig");
const tool = @import("tool.zig");

pub const AgentSession = struct {
    alloc: std.mem.Allocator,
    l: ledger.Ledger,
    composition: composition.SessionComposition,
    model: provider.Model,
    step_ctx: loop.StepContext,
    model_options: provider.Options,
    extension_root: []const u8,
    total_usage: provider.Usage = .{},

    pub const Options = struct {
        model: provider.Model,
        step_ctx: loop.StepContext,
        model_options: provider.Options = .{},
        extension_root: []const u8 = ".nulya/extensions",
        /// Native tool selection and budget, resolved from config at the
        /// session-setup boundary so this module stays config-agnostic.
        registry: composition.Options = .{},
    };

    pub fn init(alloc: std.mem.Allocator, opts: Options) !AgentSession {
        const tool_ctx = opts.step_ctx.tool_context;
        const comp = try composition.SessionComposition.init(alloc, tool_ctx.environment.io, tool_ctx.cwd, opts.extension_root, opts.registry);
        errdefer comp.deinit(alloc);

        return .{
            .alloc = alloc,
            .l = ledger.Ledger.init(alloc),
            .composition = comp,
            .model = opts.model,
            .step_ctx = opts.step_ctx,
            .model_options = opts.model_options,
            .extension_root = opts.extension_root,
        };
    }

    pub fn deinit(self: *AgentSession) void {
        self.l.deinit();
        self.composition.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn appendUser(self: *AgentSession, text: []const u8) !void {
        try self.l.append(.{ .user_text = text });
    }

    /// Run one step. Cancellation is reported as `StepOutcome.status == .canceled`
    /// (never an error): the host that owns the running step's `Future` decides
    /// what to do next. Usage is accumulated for canceled and completed steps
    /// alike, since the ledger is left in a legal state either way. A canceled
    /// step does not poison the session — the next `step()` runs normally.
    pub fn step(self: *AgentSession) !loop.StepOutcome {
        // Reconciliation runs cancellable filesystem I/O (extension integrity,
        // manifest reads). A cancel there is host execution control, not a fault:
        // no provider/tool execution for this step has started, usage is 0, and
        // cancellation adds no partial model turn. (prepareStep may still have
        // appended a repair batch or capability note first — that is legal
        // history, not a partial turn.) Report it as a canceled outcome, honoring
        // step()'s contract that cancellation is never an error.
        self.prepareStep() catch |err| switch (err) {
            error.Canceled => return .{ .status = .canceled },
            else => return err,
        };
        const prompt_ir = try prompt.projectWithSystem(self.alloc, self.composition.system_prompts.blocks, self.l.view());
        defer prompt_ir.deinit(self.alloc);
        const outcome = try loop.runStepWithPrompt(self.alloc, &self.l, self.model, &prompt_ir, self.composition.tools, self.step_ctx, self.model_options);
        accumulate(&self.total_usage, outcome.usage);
        return outcome;
    }

    pub fn usage(self: *const AgentSession) provider.Usage {
        return self.total_usage;
    }

    pub fn lastAssistantDone(self: *const AgentSession) bool {
        if (self.l.len() == 0) return false;
        return switch (self.l.view()[self.l.len() - 1]) {
            .assistant => |as| as.calls.len == 0,
            else => false,
        };
    }

    fn prepareStep(self: *AgentSession) !void {
        // Repair before extension note sync so a note append cannot hide an
        // illegal assistant-with-tool-calls tail from the prior process.
        const tool_ctx = self.step_ctx.tool_context;
        try loop.completeInterruptedToolBatch(self.alloc, &self.l);
        try notes.syncFromActiveExtensions(self.alloc, tool_ctx.environment.io, tool_ctx.cwd, &self.l, self.extension_root);
    }
};

fn accumulate(total: *provider.Usage, step: provider.Usage) void {
    total.input_tokens += step.input_tokens;
    total.output_tokens += step.output_tokens;
    total.cache_read_tokens += step.cache_read_tokens;
    total.cache_write_tokens += step.cache_write_tokens;
}

test "session repairs interrupted tool batch before provider request" {
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
            try std.testing.expect(std.mem.indexOf(u8, request.prompt_ir.stable_blocks[3].bytes, "state is unknown") != null);
            self.saw_unknown_result = true;
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "recovered" });
            try sink.emit(.{ .usage = .{ .input_tokens = 3, .output_tokens = 2 } });
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

    var lenv = try environment.LocalEnvironment.init(alloc, threaded.io(), .{});
    defer lenv.deinit();

    var model_impl = RecoveringModel{};
    var sess = try AgentSession.init(alloc, .{
        .model = .{ .ptr = &model_impl, .vtable = &RecoveringModel.vtable },
        .step_ctx = .{
            .tool_context = .{
                .environment = lenv.environment(),
                .fs = lenv.workspaceFs(),
                .cwd = ".",
            },
            .scratch_dir = "/tmp",
        },
    });
    defer sess.deinit();

    try sess.appendUser("go");
    try sess.l.append(.{ .assistant = .{
        .text = "running",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"touch marker\"}" }},
    } });

    _ = try sess.step();

    try std.testing.expect(model_impl.saw_unknown_result);
    try std.testing.expectEqual(@as(usize, 4), sess.l.len());
    try std.testing.expectEqual(@as(u64, 3), sess.usage().input_tokens);
    try std.testing.expectEqual(@as(u64, 2), sess.usage().output_tokens);
}

fn stepCall(sess: *AgentSession) anyerror!loop.StepOutcome {
    return sess.step();
}

test "a canceled step accumulates its usage and the session runs the next step" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A tool that blocks on `release` (a cancelation point) after announcing `ready`.
    const BlockTool = struct {
        ready: *std.Io.Event,
        release: *std.Io.Event,
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            const io_local = req.ctx.environment.io;
            self.ready.set(io_local);
            try self.release.wait(io_local);
            return .{ .ok = true, .output = try a.dupe(u8, "unreachable") };
        }
    };

    // Step 0 issues one blocking tool call (usage 9); step 1 addresses the user
    // and ends the turn (usage 3). The counter picks the script per step.
    const StepModel = struct {
        step_no: usize = 0,
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "stepmodel";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "stepmodel";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            _ = request;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const n = self.step_no;
            self.step_no += 1;
            try sink.emit(.started);
            if (n == 0) {
                try sink.emit(.{ .usage = .{ .input_tokens = 9, .output_tokens = 2 } });
                try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "block" } });
                try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{}" } });
                try sink.emit(.{ .done = .tool_use });
            } else {
                try sink.emit(.{ .usage = .{ .input_tokens = 3, .output_tokens = 1 } });
                try sink.emit(.{ .text_delta = "all done" });
                try sink.emit(.{ .done = .end_turn });
            }
        }
        const vtable: provider.Model.VTable = .{
            .name = name,
            .modelName = modelName,
            .capabilities = capabilities,
            .stream = stream,
        };
    };

    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    var block_tool = BlockTool{ .ready = &ready, .release = &release };

    const tools_arr = [_]tool.Tool{
        .{ .definition = .{ .id = "t.block", .name = "block", .description = "b", .input_schema = "{}" }, .executor = .{ .ptr = &block_tool, .callFn = BlockTool.call } },
    };

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    var model_impl = StepModel{};

    // Built by hand with a static composition so the blocking tool is in scope;
    // its slices are static, so only the ledger needs freeing (never `sess.deinit`,
    // which would try to free the static composition).
    var sess: AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .pinned_extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &StepModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = "." },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_root = "nulya-absent-extensions-root",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");

    // Step 0: cancel it mid-tool.
    var fut = io.async(stepCall, .{&sess});
    ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) }) catch {};
    const first = try fut.cancel(io);
    try std.testing.expectEqual(loop.StepStatus.canceled, first.status);

    // The canceled step's usage was accumulated.
    try std.testing.expectEqual(@as(u64, 9), sess.usage().input_tokens);

    // Step 1: runs normally, addresses the user.
    const second = try sess.step();
    try std.testing.expectEqual(loop.StepStatus.completed, second.status);
    try std.testing.expect(sess.lastAssistantDone());

    // Usage accumulates across the canceled and completed steps.
    try std.testing.expectEqual(@as(u64, 12), sess.usage().input_tokens);

    // Ledger: user, assistant(step0), canceled tool_results, assistant(step1).
    try std.testing.expectEqual(@as(usize, 4), sess.l.len());
    try std.testing.expect(sess.l.view()[2] == .tool_results);
    try std.testing.expect(!sess.l.view()[2].tool_results[0].ok);
}

/// Test-only coordination: consume the first cancelation at a deterministic gate
/// (`release.wait`), re-arm it via `io.recancel()`, then run a real step so the
/// pending cancelation lands inside `prepareStep`'s first filesystem syscall.
/// `recancel` exists for exactly this kind of test choreography — production
/// control flow consumes or propagates `error.Canceled` at each boundary instead.
fn stepAfterRecancel(
    sess: *AgentSession,
    io: std.Io,
    ready: *std.Io.Event,
    release: *std.Io.Event,
) anyerror!loop.StepOutcome {
    ready.set(io);

    release.wait(io) catch |err| switch (err) {
        error.Canceled => io.recancel(),
    };

    return sess.step();
}

test "a cancel during prepareStep reconciliation reports canceled with zero usage and a usable session" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const CountingModel = struct {
        calls: usize = 0,

        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "counting";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "counting";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            _ = request;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            try sink.emit(.started);
            try sink.emit(.{ .usage = .{ .input_tokens = 3, .output_tokens = 1 } });
            try sink.emit(.{ .text_delta = "all good" });
            try sink.emit(.{ .done = .end_turn });
        }
        const vtable: provider.Model.VTable = .{
            .name = name,
            .modelName = modelName,
            .capabilities = capabilities,
            .stream = stream,
        };
    };

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    var model_impl = CountingModel{};
    var sess = try AgentSession.init(alloc, .{
        .model = .{ .ptr = &model_impl, .vtable = &CountingModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = "." },
            .scratch_dir = "/tmp",
        },
        // Nonexistent root: prepareStep's reconciliation still performs real
        // filesystem I/O (opening the workspace and root) before it can decide
        // the root is missing, and that open is the cancelation point.
        .extension_root = "nulya-absent-extensions-root",
    });
    defer sess.deinit();

    try sess.appendUser("go");

    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    var fut = io.async(stepAfterRecancel, .{ &sess, io, &ready, &release });
    // Determinism contract: cancel only after the worker is known to sit at the
    // gate. A timeout here means the worker never arrived — fail, don't proceed.
    try ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) });
    const first = try fut.cancel(io);

    // The cancel was consumed at the gate, re-armed, and re-signaled by
    // prepareStep's first filesystem op — reported as a canceled outcome,
    // never as an error.
    try std.testing.expectEqual(loop.StepStatus.canceled, first.status);
    try std.testing.expectEqual(@as(u64, 0), first.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), sess.usage().input_tokens);
    try std.testing.expectEqual(@as(usize, 0), model_impl.calls); // provider never called
    // No partial assistant or note: only the user text survives.
    try std.testing.expectEqual(@as(usize, 1), sess.l.len());
    try std.testing.expect(sess.l.view()[0] == .user_text);

    // The canceled step does not poison the session: the next step runs normally.
    const second = try sess.step();
    try std.testing.expectEqual(loop.StepStatus.completed, second.status);
    try std.testing.expectEqual(@as(usize, 1), model_impl.calls);
    try std.testing.expect(sess.lastAssistantDone());
    try std.testing.expectEqual(@as(u64, 3), sess.usage().input_tokens);
}
