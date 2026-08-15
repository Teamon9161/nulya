//! Minimal agent session orchestration.
//!
//! `loop.zig` owns one provider turn and batched tool execution. `AgentSession`
//! owns the conversation-level preparation around those turns: ledger lifetime,
//! session-scoped capability composition, the step-boundary drain of the
//! cross-process inbox and cancel marker, interrupted tool-batch repair, and
//! cumulative usage accounting.

const std = @import("std");
const ledger = @import("ledger.zig");
const loop = @import("loop.zig");
const registry = @import("registry.zig");
const provider = @import("provider.zig");
const environment = @import("environment.zig");
const prompt = @import("prompt.zig");
const composition = @import("composition.zig");
const tool = @import("tool.zig");
const tool_stats = @import("tool_stats.zig");

/// The most kernel steps one `run` may take, whatever the caller asks for
/// (DESIGN §4, §14). A driver can lower the budget per call, never raise it.
pub const max_steps_ceiling: usize = 50;

/// Where a durable session's file and its cross-process siblings (`<id>.inbox/`,
/// `<id>.cancel`) live. The `workspace` handle is borrowed — the caller keeps it
/// open for the session's lifetime; `session_path` is owned and relative to
/// `workspace`.
pub const DurableRef = struct {
    workspace: std.Io.Dir,
    session_path: []const u8,
};

/// Ask a durable session to stop at its next step boundary, from any process:
/// drops the `<stem>.cancel` marker next to the session file. The owning
/// session consumes it in `prepareStep` and reports that step as `.canceled`
/// without calling the model (DESIGN §4). Requesting twice is one request.
pub fn requestCancel(alloc: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir, session_path: []const u8) !void {
    const marker = try ledger.siblingPath(alloc, session_path, ".cancel");
    defer alloc.free(marker);
    try workspace.writeFile(io, .{ .sub_path = marker, .data = "" });
}

/// If a cancel marker exists for the session, delete it and return true.
fn consumeCancel(alloc: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir, session_path: []const u8) !bool {
    const marker = try ledger.siblingPath(alloc, session_path, ".cancel");
    defer alloc.free(marker);
    workspace.deleteFile(io, marker) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub const AgentSession = struct {
    alloc: std.mem.Allocator,
    l: ledger.Ledger,
    composition: composition.SessionComposition,
    model: provider.Model,
    step_ctx: loop.StepContext,
    model_options: provider.Options,
    extension_root: []const u8,
    /// Set for durable sessions: the session file's location, used to drain the
    /// cross-process capability-note inbox each step (DESIGN §3, §5.3).
    durable: ?DurableRef = null,
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

    /// Create a new durable session (DESIGN §3): resolve the composition fresh
    /// from `opts.registry`, freeze it into the header, and open the session file
    /// for appends. Fails if the file already exists.
    pub const CreateDurableOptions = struct {
        workspace: std.Io.Dir,
        session_path: []const u8,
        session_id: []const u8,
        /// The provider profile NAME (display / effort lookup).
        model_profile: []const u8 = "",
        /// The RESOLVED model identity to freeze into the header (DESIGN §3). The
        /// caller resolves this from config at the creation boundary; the kernel
        /// only stores it. Empty provider = a scripted/legacy session.
        model_identity: ledger.ModelDescriptor = .{},
        created: []const u8 = "",
        parent: ?ledger.ParentRef = null,
    };

    /// Reopen an existing durable session: replay the ledger and rebuild the
    /// frozen composition from the header, never from the live `current`.
    pub const OpenDurableOptions = struct {
        workspace: std.Io.Dir,
        session_path: []const u8,
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

    pub fn createDurable(alloc: std.mem.Allocator, opts: Options, d: CreateDurableOptions) !AgentSession {
        const tool_ctx = opts.step_ctx.tool_context;
        const io = tool_ctx.environment.io;
        var comp = try composition.SessionComposition.init(alloc, io, tool_ctx.cwd, opts.extension_root, opts.registry);
        errdefer comp.deinit(alloc);

        // Freeze the resolved composition into the header: the active pinned
        // versions and which of their tools are native this session. Any process
        // reopening the file rebuilds the identical composition.
        const active = try alloc.alloc(ledger.PinnedExtensionRef, comp.pinned_extensions.len);
        defer alloc.free(active);
        for (comp.pinned_extensions, 0..) |p, i| active[i] = .{ .id = p.id, .version = p.version };
        const native = try alloc.alloc([]const u8, comp.extension_tool_bindings.len);
        defer alloc.free(native);
        for (comp.extension_tool_bindings, 0..) |b, i| native[i] = b.definition.id;

        var l = try ledger.createDurable(alloc, io, d.workspace, d.session_path, .{
            .session = d.session_id,
            .parent = d.parent,
            .model = d.model_profile,
            .model_identity = d.model_identity,
            .created = d.created,
            .composition = .{ .active = active, .native_tools = native },
        });
        errdefer l.deinit();

        const owned_path = try alloc.dupe(u8, d.session_path);
        errdefer alloc.free(owned_path);

        return .{
            .alloc = alloc,
            .l = l,
            .composition = comp,
            .model = opts.model,
            .step_ctx = opts.step_ctx,
            .model_options = opts.model_options,
            .extension_root = opts.extension_root,
            .durable = .{ .workspace = d.workspace, .session_path = owned_path },
        };
    }

    pub fn openDurable(alloc: std.mem.Allocator, opts: Options, d: OpenDurableOptions) !AgentSession {
        const tool_ctx = opts.step_ctx.tool_context;
        const io = tool_ctx.environment.io;
        var l = try ledger.openDurable(alloc, io, d.workspace, d.session_path);
        errdefer l.deinit();
        const hdr = l.header().?;
        var comp = try composition.SessionComposition.initFrozen(alloc, io, tool_ctx.cwd, opts.extension_root, hdr.composition);
        errdefer comp.deinit(alloc);

        const owned_path = try alloc.dupe(u8, d.session_path);
        errdefer alloc.free(owned_path);

        return .{
            .alloc = alloc,
            .l = l,
            .composition = comp,
            .model = opts.model,
            .step_ctx = opts.step_ctx,
            .model_options = opts.model_options,
            .extension_root = opts.extension_root,
            .durable = .{ .workspace = d.workspace, .session_path = owned_path },
        };
    }

    pub fn deinit(self: *AgentSession) void {
        self.l.deinit();
        self.composition.deinit(self.alloc);
        if (self.durable) |d| self.alloc.free(d.session_path);
        self.* = undefined;
    }

    pub fn appendUser(self: *AgentSession, text: []const u8) !void {
        try self.l.append(.{ .user_text = text });
    }

    /// Run one step. Cancellation is reported as `StepOutcome.status == .canceled`
    /// (never an error), whether it came from the host canceling the running
    /// step's `Future` or from a `requestCancel` marker consumed at this step's
    /// boundary; the host decides what to do next. Usage is accumulated for
    /// canceled and completed steps alike, since the ledger is left in a legal
    /// state either way. A canceled step does not poison the session — the next
    /// `step()` runs normally.
    pub fn step(self: *AgentSession) !loop.StepOutcome {
        // Preparation runs cancellable filesystem I/O (inbox, extension
        // integrity, manifest reads) and consumes any cancel marker. A cancel
        // there is host execution control, not a fault: no provider/tool
        // execution for this step has started, usage is 0, and cancellation adds
        // no partial model turn. (prepareStep may still have appended a repair
        // batch or a drained event first — that is legal history, not a partial
        // turn.) Report it as a canceled outcome, honoring step()'s contract that
        // cancellation is never an error.
        self.prepareStep() catch |err| switch (err) {
            error.Canceled => return .{ .status = .canceled },
            else => return err,
        };
        const prompt_ir = try prompt.projectWithSystem(self.alloc, self.composition.system_prompts.blocks, self.l.view());
        defer prompt_ir.deinit(self.alloc);
        // Ledger position before this step's turns: everything appended from
        // here on is this step's assistant turn plus, when it carried tool
        // calls, the single batched tool_results turn.
        const before = self.l.len();
        const outcome = try loop.runStepWithPrompt(self.alloc, &self.l, self.model, &prompt_ir, self.composition.tools, self.step_ctx, self.model_options);
        accumulate(&self.total_usage, outcome.usage);
        if (outcome.status == .completed) {
            // Tool usage stats are auxiliary durable metadata, not conversation
            // truth: a recording failure never rewinds the ledger or turns a
            // completed invocation into a failure. Host faults (OOM, real I/O
            // errors) propagate; a cancel landing after the step's real work
            // already finished is host execution control, so the completed
            // outcome is reported as-is and this step's events go unrecorded.
            self.recordCompletedToolStats(before) catch |err| switch (err) {
                error.Canceled => {},
                else => return err,
            };
        }
        return outcome;
    }

    /// Run steps until the assistant ends its turn or the budget is reached —
    /// whichever comes first. The budget is `min(max_steps, max_steps_ceiling)`
    /// and is enforced here in the kernel, not by a caller's loop, so a driver
    /// that wants "just keep going" still cannot run a session past it (DESIGN
    /// §4, PLAN §3.6). A canceled step (host cancel or a consumed cancel marker)
    /// stops the run. Returns the number of steps taken.
    pub fn run(self: *AgentSession, max_steps: usize) !usize {
        const budget = @min(max_steps, max_steps_ceiling);
        var taken: usize = 0;
        while (taken < budget) {
            const outcome = try self.step();
            taken += 1;
            if (outcome.status == .canceled) break;
            if (self.lastAssistantDone()) break;
        }
        return taken;
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

    /// The step boundary (DESIGN §4): repair an interrupted tail, honor a
    /// pending cancel request, drain the cross-process inbox. Repair comes
    /// first so a drained event can never land between an
    /// assistant-with-tool-calls and its matching tool_results batch (the batch
    /// invariant). A pure in-memory session has no siblings to consult.
    fn prepareStep(self: *AgentSession) !void {
        try loop.completeInterruptedToolBatch(self.alloc, &self.l);
        if (self.durable) |d| {
            const io = self.step_ctx.tool_context.environment.io;
            // The marker is the cross-process form of the same cancellation the
            // host expresses in-process by canceling the step's Future: it is
            // consumed here, at the boundary, and this step reports `.canceled`.
            if (try consumeCancel(self.alloc, io, d.workspace, d.session_path)) return error.Canceled;
            try ledger.drainInbox(self.alloc, io, &self.l, d.workspace, d.session_path);
        }
    }

    /// Append one usage event per completed tool call in this step's ledger
    /// suffix `[before..]`. Stats are an observation after execution, so the
    /// loop stays generic and no executor knows the journal exists. A completed
    /// step's suffix has a fixed shape the loop guarantees — no calls: exactly
    /// `[assistant]`; with calls: exactly `[assistant, tool_results]` with one
    /// result per call — so this reads the shape directly instead of searching
    /// for possibly-present events, and asserts instead of tolerating a broken
    /// invariant. A call is recorded only when its model-facing name resolves
    /// to a real exposed `ToolDefinition.id`: a hallucinated name has no
    /// durable identity, so it is skipped rather than saved under a fake id.
    fn recordCompletedToolStats(self: *AgentSession, before: usize) !void {
        const suffix = self.l.view()[before..];
        if (suffix.len == 1) return; // the model addressed the user; nothing to record
        std.debug.assert(suffix.len == 2);
        const assistant = switch (suffix[0]) {
            .assistant => |a| a,
            else => unreachable, // runStepWithPrompt always appends the assistant first
        };
        const results = switch (suffix[1]) {
            .tool_results => |r| r,
            else => unreachable, // a completed step with calls always appends its batch
        };
        // One tool_results entry per assistant call; the loop fills them in call
        // order. The multi-prong for panics if the lengths ever disagree.
        std.debug.assert(assistant.calls.len == results.len);

        const ctx = self.step_ctx.tool_context;
        for (assistant.calls, results) |call, result| {
            const t = self.composition.tools.lookup(call.tool) orelse continue;
            try tool_stats.append(self.alloc, ctx.environment.io, ctx.cwd, t.definition.id, result.ok);
        }
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);
    // A durable session whose inbox directory exists: prepareStep drains the
    // inbox each step, and that `openDir` is a real filesystem cancelation point.
    try tmp.dir.createDirPath(io, ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s.inbox");

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    var model_impl = CountingModel{};
    var sess = try AgentSession.createDurable(alloc, .{
        .model = .{ .ptr = &model_impl, .vtable = &CountingModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_root = "nulya-absent-extensions-root",
    }, .{
        .workspace = tmp.dir,
        .session_path = ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s.jsonl",
        .session_id = "s",
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

fn sessionTmpCwd(alloc: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    return alloc.dupe(u8, buf[0..len]);
}

/// A model that always addresses the user and ends the turn (no tool calls).
const EndTurnModel = struct {
    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "end-turn";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "end-turn";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = ptr;
        _ = a;
        _ = request;
        try sink.emit(.started);
        try sink.emit(.{ .text_delta = "done" });
        try sink.emit(.{ .done = .end_turn });
    }
    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

test "a durable session persists across create, close, and reopen" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);
    try tmp.dir.createDirPath(io, ".nulya" ++ std.fs.path.sep_str ++ "sessions");
    const session_path = ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s.jsonl";

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model_impl = EndTurnModel{};
    const opts: AgentSession.Options = .{
        .model = .{ .ptr = &model_impl, .vtable = &EndTurnModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_root = ".nulya/extensions",
    };

    // Process A: create, take one turn, then close.
    {
        var a = try AgentSession.createDurable(alloc, opts, .{
            .workspace = tmp.dir,
            .session_path = session_path,
            .session_id = "s",
            .model_profile = "scripted",
        });
        defer a.deinit();
        try a.appendUser("hello");
        _ = try a.step();
        try std.testing.expect(a.lastAssistantDone());
        try std.testing.expectEqual(@as(usize, 2), a.l.len()); // user + assistant
    }

    // Process B: reopen from the file and see the same history, then continue.
    // Close it before process C opens — the writer lease is exclusive.
    {
        var b = try AgentSession.openDurable(alloc, opts, .{ .workspace = tmp.dir, .session_path = session_path });
        defer b.deinit();
        try std.testing.expectEqual(@as(usize, 2), b.l.len());
        try std.testing.expect(b.l.view()[0] == .user_text);
        try std.testing.expectEqualStrings("hello", b.l.view()[0].user_text);
        try std.testing.expectEqualStrings("s", b.l.header().?.session);

        try b.appendUser("again");
        _ = try b.step();
        try std.testing.expectEqual(@as(usize, 4), b.l.len());
    }

    // A third process sees all four events replayed from disk.
    var c = try AgentSession.openDurable(alloc, opts, .{ .workspace = tmp.dir, .session_path = session_path });
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 4), c.l.len());
}

test "a cancel marker is consumed at the step boundary: no model call, then the session resumes" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);
    try tmp.dir.createDirPath(io, ".nulya" ++ std.fs.path.sep_str ++ "sessions");
    const session_path = ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s.jsonl";

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
            try sink.emit(.{ .text_delta = "done" });
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
    var sess = try AgentSession.createDurable(alloc, .{
        .model = .{ .ptr = &model_impl, .vtable = &CountingModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_root = "nulya-absent-extensions-root",
    }, .{ .workspace = tmp.dir, .session_path = session_path, .session_id = "s" });
    defer sess.deinit();
    try sess.appendUser("go");

    // Another process asks for a cancel; `run` would take up to 5 steps but
    // stops at the very first boundary without calling the model.
    try requestCancel(alloc, io, tmp.dir, session_path);
    const taken = try sess.run(5);
    try std.testing.expectEqual(@as(usize, 1), taken);
    try std.testing.expectEqual(@as(usize, 0), model_impl.calls);
    try std.testing.expectEqual(@as(usize, 1), sess.l.len()); // only the user text

    // The marker was consumed: the next run proceeds normally.
    _ = try sess.run(5);
    try std.testing.expectEqual(@as(usize, 1), model_impl.calls);
    try std.testing.expect(sess.lastAssistantDone());
}

test "run clamps any requested budget to the kernel ceiling" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp); // completed steps journal usage under cwd
    defer alloc.free(cwd);

    // A tool that always succeeds and a model that always calls it: the turn
    // never ends on its own.
    const NoopTool = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            _ = req;
            return .{ .ok = true, .output = try a.dupe(u8, "ok") };
        }
    };
    const tools_arr = [_]tool.Tool{
        .{ .definition = .{ .id = "t.noop", .name = "noop", .description = "n", .input_schema = "{}" }, .executor = .{ .ptr = null, .callFn = NoopTool.call } },
    };
    const ForeverModel = struct {
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "forever";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "forever";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = ptr;
            _ = a;
            _ = request;
            try sink.emit(.started);
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "noop" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{}" } });
            try sink.emit(.{ .done = .tool_use });
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
    var model_impl = ForeverModel{};
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
        .model = .{ .ptr = &model_impl, .vtable = &ForeverModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_root = "nulya-absent-extensions-root",
    };
    defer sess.l.deinit();
    try sess.appendUser("go");

    try std.testing.expectEqual(max_steps_ceiling, try sess.run(max_steps_ceiling + 10));
    // user + (assistant, tool_results) per step
    try std.testing.expectEqual(1 + 2 * max_steps_ceiling, sess.l.len());
}

test "completed step records stable ids, never model names or hallucinated names" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    const OkTool = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            _ = req;
            return .{ .ok = true, .output = try a.dupe(u8, "searched") };
        }
    };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "ext:web.search/web_search", .name = "web_search", .description = "search", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = OkTool.call },
        },
    };

    // One real call (web_search) and one name the model invented (ghost): the
    // real call resolves to its stable id, the hallucinated one is skipped.
    const MixedModel = struct {
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "mixed";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "mixed-test";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = ptr;
            _ = a;
            _ = request;
            try sink.emit(.started);
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "web_search" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{}" } });
            try sink.emit(.{ .tool_use_start = .{ .index = 1, .id = "c2", .name = "ghost" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 1, .fragment = "{}" } });
            try sink.emit(.{ .done = .tool_use });
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
    var model_impl = MixedModel{};
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
        .model = .{ .ptr = &model_impl, .vtable = &MixedModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_root = "nulya-absent-extensions-root",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    const outcome = try sess.step();
    try std.testing.expectEqual(loop.StepStatus.completed, outcome.status);

    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", events[0].tool_id);
    try std.testing.expect(events[0].ok);
}

test "a canceled step records no tool usage stats" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    var ready: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
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
    var block_tool = BlockTool{ .ready = &ready, .release = &release };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "ext:web.search/web_search", .name = "web_search", .description = "search", .input_schema = "{}" },
            .executor = .{ .ptr = &block_tool, .callFn = BlockTool.call },
        },
    };

    const OneCallModel = struct {
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "onecall";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "onecall";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = ptr;
            _ = a;
            _ = request;
            try sink.emit(.started);
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "web_search" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{}" } });
            try sink.emit(.{ .done = .tool_use });
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
    var model_impl = OneCallModel{};
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
        .model = .{ .ptr = &model_impl, .vtable = &OneCallModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_root = "nulya-absent-extensions-root",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    var fut = io.async(stepCall, .{ &sess });
    try ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) });
    const outcome = try fut.cancel(io);
    try std.testing.expectEqual(loop.StepStatus.canceled, outcome.status);

    // A canceled batch is not recorded as a failure (or anything): the journal
    // stays absent.
    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}
