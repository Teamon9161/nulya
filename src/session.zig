//! Minimal agent session orchestration.
//!
//! `loop.zig` owns one provider turn and batched tool execution. `AgentSession`
//! owns the conversation-level preparation around those turns: ledger lifetime,
//! session-scoped capability composition, the step-boundary drain of the
//! cross-process inbox and cancel marker, interrupted tool-batch repair, and
//! cumulative usage accounting.

const std = @import("std");
const ledger = @import("ledger.zig");
const lease = @import("lease.zig");
const loop = @import("loop.zig");
const registry = @import("registry.zig");
const provider = @import("provider.zig");
const environment = @import("environment.zig");
const prompt = @import("prompt.zig");
const composition = @import("composition.zig");
const tool = @import("tool.zig");
const tool_stats = @import("journals/tool_stats.zig");

/// The most kernel steps one `run` may take, whatever the caller asks for. A
/// driver can lower the budget per call, never raise it. A RUNAWAY GUARD, NOT A
/// BUDGET: set high enough that honest work never reaches it.
pub const max_steps_ceiling: usize = 500;

/// Consecutive RETRIABLE `max_tokens` steps before `run` stops on its own. Only
/// a truncation that CARRIED TOOL CALLS is retriable: it ends in a marker batch,
/// so stepping again shows the model what happened. Two in a row mean the cap is
/// too small for what is being asked, which no retry fixes.
pub const max_truncated_streak: usize = 2;

/// Where a durable session's file and its cross-process siblings (`<id>.inbox/`,
/// `<id>.cancel`) live. The `workspace` handle is borrowed — the caller keeps it
/// open for the session's lifetime; `session_path` is owned and relative to
/// `workspace`.
pub const DurableRef = struct {
    workspace: std.Io.Dir,
    session_path: []const u8,
};

/// Ask a durable session to stop at its next step boundary, from any process:
/// drops the `<stem>.cancel` marker next to the session file. The owning session
/// consumes it in `prepareStep` and reports that step as `.canceled` without
/// calling the model. Requesting twice is one request.
pub fn requestCancel(alloc: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir, session_path: []const u8) !void {
    const marker = try lease.siblingPath(alloc, session_path, ".cancel");
    defer alloc.free(marker);
    try workspace.writeFile(io, .{ .sub_path = marker, .data = "" });
}

/// If a cancel marker exists for the session, delete it and return true.
fn consumeCancel(alloc: std.mem.Allocator, io: std.Io, workspace: std.Io.Dir, session_path: []const u8) !bool {
    const marker = try lease.siblingPath(alloc, session_path, ".cancel");
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
    extension_store: []const u8,
    /// Set for durable sessions: the session file's location, used to drain the
    /// cross-process inbox each step.
    durable: ?DurableRef = null,
    total_usage: provider.Usage = .{},

    pub const Options = struct {
        model: provider.Model,
        step_ctx: loop.StepContext,
        model_options: provider.Options = .{},
        /// This machine's one extension store, as an absolute path. Empty when
        /// there is none — a session composing no member never needs one.
        extension_store: []const u8 = "",
        /// What the composition is built from, resolved from config at the
        /// session-setup boundary so this module stays config-agnostic. A resume
        /// rebuilds from the header, so only `diag` is read on that path.
        registry: composition.Options = .{},
    };

    /// Create a new durable session: resolve the composition fresh from
    /// `opts.registry`, freeze it into the header, and open the session file for
    /// appends. Fails if the file already exists.
    pub const CreateDurableOptions = struct {
        workspace: std.Io.Dir,
        session_path: []const u8,
        session_id: []const u8,
        /// The provider profile NAME (display / effort lookup).
        model_profile: []const u8 = "",
        /// The RESOLVED model identity to freeze into the header; the kernel
        /// only stores it. Empty provider = a scripted/legacy session.
        model_identity: ledger.ModelDescriptor = .{},
        /// The exec target's spec, frozen into the header — a creation-boundary
        /// decision like the model identity; the kernel only stores it.
        environment: []const u8 = "",
        /// For a remote environment, the absolute workspace on that machine —
        /// the other half of "where does this session run". Empty otherwise.
        remote_workspace: []const u8 = "",
        created: []const u8 = "",
        /// The creating binary's version string; the stamp's other half (the
        /// kernel hash) the kernel computes itself.
        nulya_version: []const u8 = "",
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
        const comp = try composition.SessionComposition.init(alloc, tool_ctx.environment.io, tool_ctx.cwd, opts.extension_store, opts.registry);
        errdefer comp.deinit(alloc);

        return .{
            .alloc = alloc,
            .l = ledger.Ledger.init(alloc),
            .composition = comp,
            .model = opts.model,
            .step_ctx = opts.step_ctx,
            .model_options = opts.model_options,
            .extension_store = opts.extension_store,
        };
    }

    pub fn createDurable(alloc: std.mem.Allocator, opts: Options, d: CreateDurableOptions) !AgentSession {
        const tool_ctx = opts.step_ctx.tool_context;
        const io = tool_ctx.environment.io;
        var comp = try composition.SessionComposition.init(alloc, io, tool_ctx.cwd, opts.extension_store, opts.registry);
        errdefer comp.deinit(alloc);

        // Frozen into the header, so any process reopening rebuilds it.
        const active = try alloc.alloc(ledger.ExtensionRef, comp.extensions.len);
        defer alloc.free(active);
        for (comp.extensions, 0..) |e, i| active[i] = .{
            .id = e.id,
            .version = e.version,
            // Decided once and never re-derived: asking the far machine again
            // could answer differently than the session was composed with.
            .exec_version = e.exec_version orelse "",
        };
        const native = try alloc.alloc([]const u8, comp.extension_tool_bindings.len);
        defer alloc.free(native);
        for (comp.extension_tool_bindings, 0..) |b, i| native[i] = b.definition.id;

        // Provenance: the kernel prompt and builtin definitions are the part of
        // the model-visible state the header could not otherwise name.
        const kernel_hash = try composition.kernelHash(alloc);
        defer alloc.free(kernel_hash);

        var l = try ledger.createDurable(alloc, io, d.workspace, d.session_path, .{
            .session = d.session_id,
            .parent = d.parent,
            .model = d.model_profile,
            .model_identity = d.model_identity,
            .environment = d.environment,
            .remote_workspace = d.remote_workspace,
            .created = d.created,
            .nulya = .{ .version = d.nulya_version, .kernel_hash = kernel_hash },
            // Inline prompts go in by VALUE, so a resume rebuilds identical
            // system blocks from this file alone.
            .composition = .{ .active = active, .native_tools = native, .prompts = comp.prompts },
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
            .extension_store = opts.extension_store,
            .durable = .{ .workspace = d.workspace, .session_path = owned_path },
        };
    }

    pub fn openDurable(alloc: std.mem.Allocator, opts: Options, d: OpenDurableOptions) !AgentSession {
        const tool_ctx = opts.step_ctx.tool_context;
        const io = tool_ctx.environment.io;
        var l = try ledger.openDurable(alloc, io, d.workspace, d.session_path);
        errdefer l.deinit();
        const hdr = l.header().?;
        var comp = try composition.SessionComposition.initFrozen(alloc, io, tool_ctx.cwd, opts.extension_store, hdr.composition, opts.registry.diag);
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
            .extension_store = opts.extension_store,
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
        try self.l.append(.{ .user_text = .{ .text = text } });
    }

    /// Run one step. Cancellation is reported as `StepOutcome.status ==
    /// .canceled`, NEVER an error, whether the host canceled the step's `Future`
    /// or a `requestCancel` marker was consumed at this boundary. Usage
    /// accumulates either way; the ledger is left legal either way.
    ///
    /// Fails with `error.TruncatedTurnNeedsInput` when the ledger ends on a reply
    /// the provider cut off: stepping it would ask the provider to continue its
    /// own message as a prefill. Nothing is appended.
    pub fn step(self: *AgentSession) !loop.StepOutcome {
        const outcome = try self.stepInner();
        // The step boundary is the one place the ledger is guaranteed legal.
        if (self.step_ctx.observer) |obs| obs.stepEnd(self.l.view(), outcome);
        return outcome;
    }

    fn stepInner(self: *AgentSession) !loop.StepOutcome {
        // Preparation runs cancellable filesystem I/O and consumes any cancel
        // marker. A cancel there means nothing of this step has run: usage 0, no
        // partial model turn. (A repair batch or drained event prepareStep
        // already appended is legal history, not a partial turn.)
        self.prepareStep() catch |err| switch (err) {
            error.Canceled => return .{ .status = .canceled },
            else => return err,
        };
        // AFTER prepareStep: a drained inbox event is exactly the new input
        // that makes the ledger steppable again.
        if (self.lastAssistantTruncated()) return error.TruncatedTurnNeedsInput;
        const prompt_ir = try prompt.projectWithSystem(self.alloc, self.composition.system_prompts.blocks, self.l.view());
        defer prompt_ir.deinit(self.alloc);
        // Ledger position before this step's turns.
        const before = self.l.len();
        // Step-local, so a duration cannot outlive the step that measured it.
        var durations_ms: std.ArrayList(?u64) = .empty;
        defer durations_ms.deinit(self.alloc);
        const outcome = try loop.runStepWithPrompt(self.alloc, &self.l, self.model, &prompt_ir, self.composition.tools, self.step_ctx, self.model_options, &durations_ms);
        self.total_usage.add(outcome.usage);
        // Recorded only for a step whose tools actually ran: a reply cut by
        // `max_tokens` closes its batch with marker results no executor
        // produced, and journalling those would bill tools for the output cap.
        const tools_executed = outcome.status == .completed and outcome.stop_reason != .max_tokens;
        if (tools_executed) {
            // Auxiliary evidence, not conversation truth: a recording failure
            // never rewinds the ledger. Host faults propagate; a cancel landing
            // after the real work leaves this step unrecorded.
            self.recordCompletedToolStats(before, durations_ms.items) catch |err| switch (err) {
                error.Canceled => {},
                else => return err,
            };
        }
        return outcome;
    }

    /// Run steps until the assistant ends its turn or the budget is reached. The
    /// budget is `min(max_steps, max_steps_ceiling)`, enforced HERE rather than
    /// by a caller's loop. A canceled step stops the run, and so do
    /// `max_truncated_streak` truncated replies in a row.
    pub fn run(self: *AgentSession, max_steps: usize) !usize {
        const budget = @min(max_steps, max_steps_ceiling);
        var taken: usize = 0;
        var truncated: usize = 0;
        while (taken < budget) {
            const outcome = try self.step();
            taken += 1;
            if (outcome.status == .canceled) break;
            truncated = if (outcome.stop_reason == .max_tokens) truncated + 1 else 0;
            if (truncated >= max_truncated_streak) break;
            // A truncated reply with NO calls leaves the ledger ending on an
            // assistant turn, and stepping again would send it back as a prefill
            // — which providers reject when thinking is on. So the run stops,
            // looking "done" by shape, and `lastStopReason` says it was cut.
            if (self.lastAssistantDone()) break;
        }
        return taken;
    }

    pub fn usage(self: *const AgentSession) provider.Usage {
        return self.total_usage;
    }

    /// Why the model stopped in the most recent turn on record — the ledger's
    /// LAST assistant event, or `end_turn` when there is none. Read from the
    /// DURABLE fact, so a resuming process answers like the one that stepped.
    pub fn lastStopReason(self: *const AgentSession) provider.StopReason {
        const events = self.l.view();
        var i = events.len;
        while (i > 0) {
            i -= 1;
            switch (events[i]) {
                .assistant => |as| return as.stop_reason,
                else => {},
            }
        }
        return .end_turn;
    }

    /// Whether the ledger ends on a reply the provider cut at its output cap.
    /// That tail is NOT steppable: projected as-is it becomes a trailing
    /// assistant message, which the provider reads as a prefill and rejects when
    /// thinking is on. Appending anything clears it.
    pub fn lastAssistantTruncated(self: *const AgentSession) bool {
        if (self.l.len() == 0) return false;
        return switch (self.l.view()[self.l.len() - 1]) {
            .assistant => |as| as.stop_reason == .max_tokens,
            else => false,
        };
    }

    /// Whether the ledger's last event is an assistant turn with no tool calls.
    /// Pure ledger SHAPE: a reply cut by `max_tokens` before it wrote a call has
    /// exactly this shape, so pair it with `lastStopReason`.
    pub fn lastAssistantDone(self: *const AgentSession) bool {
        if (self.l.len() == 0) return false;
        return switch (self.l.view()[self.l.len() - 1]) {
            .assistant => |as| as.calls.len == 0,
            else => false,
        };
    }

    /// The step boundary: repair an interrupted tail, honor a pending cancel
    /// request, drain the cross-process inbox. REPAIR COMES FIRST, so a drained
    /// event can never land between an assistant-with-tool-calls and its batch.
    fn prepareStep(self: *AgentSession) !void {
        try loop.completeInterruptedToolBatch(self.alloc, &self.l);
        if (self.durable) |d| {
            const io = self.step_ctx.tool_context.environment.io;
            // The cross-process form of canceling the step's Future: consumed
            // here, at the boundary, and this step reports `.canceled`.
            if (try consumeCancel(self.alloc, io, d.workspace, d.session_path)) return error.Canceled;
            try ledger.drainInbox(self.alloc, io, &self.l, d.workspace, d.session_path);
        }
    }

    /// Append one usage event per completed tool call in this step's ledger
    /// suffix `[before..]`. An observation after execution: no executor knows the
    /// journal exists.
    ///
    /// A completed step's suffix has a shape the loop GUARANTEES — no calls:
    /// exactly `[assistant]`; with calls: exactly `[assistant, tool_results]`
    /// with one result per call — so this reads the shape and asserts rather than
    /// tolerating a broken invariant. A call is recorded only when its
    /// model-facing name resolves to a real exposed `ToolDefinition.id`.
    ///
    /// Each line also carries WHICH SESSION the call served, so the slow loop can
    /// join it against `session-outcomes.jsonl`, and WHICH FROZEN IMPLEMENTATION
    /// served it. The stable id stays version-free; the version sits beside it so
    /// the same history can be read per implementation. The builtin has none.
    fn recordCompletedToolStats(self: *AgentSession, before: usize, durations_ms: []const ?u64) !void {
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
        // One result and one measurement slot per call, all in call order; the
        // multi-prong for below panics if they disagree.
        std.debug.assert(assistant.calls.len == results.len);
        std.debug.assert(assistant.calls.len == durations_ms.len);

        const ctx = self.step_ctx.tool_context;
        const session_id: ?[]const u8 = if (self.durable) |d|
            std.fs.path.stem(std.fs.path.basename(d.session_path))
        else
            null;
        for (assistant.calls, results, durations_ms) |call, result, measured| {
            // No measurement means no executor ran, so nothing to bill.
            const duration_ms = measured orelse continue;
            const t = self.composition.tools.lookup(call.tool) orelse continue;
            try tool_stats.append(self.alloc, ctx.environment.io, ctx.cwd, .{
                .tool_id = t.definition.id,
                .ok = result.ok,
                .session = session_id,
                .version = self.frozenVersionOf(t.definition.id),
                .duration_ms = duration_ms,
            });
        }
    }

    /// The frozen version of the member extension that owns `tool_id`, or null
    /// when no member does. A null is "not recorded", never an error — a missing
    /// evidence column must not be able to fail a step. The id shape is
    /// `ext:<extension-id>/<tool-name>` and ids never contain `/`. The returned
    /// slice is borrowed from the composition, which outlives the append.
    fn frozenVersionOf(self: *const AgentSession, tool_id: []const u8) ?[]const u8 {
        const prefix = "ext:";
        if (!std.mem.startsWith(u8, tool_id, prefix)) return null;
        const rest = tool_id[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const ext_id = rest[0..slash];
        for (self.composition.extensions) |e| {
            // The implementation that SERVED the call — for a session whose
            // tools run elsewhere, the build for that machine.
            if (std.mem.eql(u8, e.id, ext_id)) return e.exec_version orelse e.version;
        }
        return null;
    }
};

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
            try std.testing.expectEqual(@as(usize, 3), request.prompt_ir.turns.len);
            const repaired = request.prompt_ir.turns[2].tool_results;
            try std.testing.expectEqual(@as(usize, 1), repaired.len);
            try std.testing.expect(std.mem.indexOf(u8, repaired[0].output, "state is unknown") != null);
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

    // Step 0 issues one blocking tool call (usage 9); step 1 ends the turn
    // (usage 3). The counter picks the script per step.
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

    // A static composition, so only the ledger needs freeing — never
    // `sess.deinit`, which would try to free the static slices.
    var sess: AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &StepModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = "." },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_store = "nulya-absent-extensions-store",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");

    // Step 0: cancel it mid-tool.
    var fut = io.async(stepCall, .{&sess});
    ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) }) catch {};
    const first = try fut.cancel(io);
    try std.testing.expectEqual(loop.StepStatus.canceled, first.status);

    try std.testing.expectEqual(@as(u64, 9), sess.usage().input_tokens);

    // Step 1: runs normally, addresses the user.
    const second = try sess.step();
    try std.testing.expectEqual(loop.StepStatus.completed, second.status);
    try std.testing.expect(sess.lastAssistantDone());

    try std.testing.expectEqual(@as(u64, 12), sess.usage().input_tokens);

    try std.testing.expectEqual(@as(usize, 4), sess.l.len());
    try std.testing.expect(sess.l.view()[2] == .tool_results);
    try std.testing.expect(!sess.l.view()[2].tool_results[0].ok);
}

/// Test-only coordination: consume the first cancelation at a deterministic gate
/// (`release.wait`), re-arm it via `io.recancel()`, then run a real step so the
/// pending cancelation lands inside `prepareStep`'s first filesystem syscall.
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
    // The inbox exists, so prepareStep's `openDir` is a real cancelation point.
    try tmp.dir.createDirPath(io, ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s.inbox");

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    var model_impl = CountingModel{};
    var sess = try AgentSession.createDurable(alloc, .{
        .model = .{ .ptr = &model_impl, .vtable = &CountingModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_store = "nulya-absent-extensions-store",
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
    // Cancel only once the worker is known to sit at the gate.
    try ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) });
    const first = try fut.cancel(io);

    // Re-signaled by prepareStep's first filesystem op — a canceled outcome.
    try std.testing.expectEqual(loop.StepStatus.canceled, first.status);
    try std.testing.expectEqual(@as(u64, 0), first.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), sess.usage().input_tokens);
    try std.testing.expectEqual(@as(usize, 0), model_impl.calls); // provider never called
    try std.testing.expectEqual(@as(usize, 1), sess.l.len());
    try std.testing.expect(sess.l.view()[0] == .user_text);

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
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_store = "nulya-absent-extensions-store",
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

    // Process B: reopen and continue. Close it before C opens — the writer
    // lease is exclusive.
    {
        var b = try AgentSession.openDurable(alloc, opts, .{ .workspace = tmp.dir, .session_path = session_path });
        defer b.deinit();
        try std.testing.expectEqual(@as(usize, 2), b.l.len());
        try std.testing.expect(b.l.view()[0] == .user_text);
        try std.testing.expectEqualStrings("hello", b.l.view()[0].user_text.text);
        try std.testing.expectEqualStrings("s", b.l.header().?.session);

        try b.appendUser("again");
        _ = try b.step();
        try std.testing.expectEqual(@as(usize, 4), b.l.len());
    }

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
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_store = "nulya-absent-extensions-store",
    }, .{ .workspace = tmp.dir, .session_path = session_path, .session_id = "s" });
    defer sess.deinit();
    try sess.appendUser("go");

    // `run` would take up to 5 steps but stops at the first boundary.
    try requestCancel(alloc, io, tmp.dir, session_path);
    const taken = try sess.run(5);
    try std.testing.expectEqual(@as(usize, 1), taken);
    try std.testing.expectEqual(@as(usize, 0), model_impl.calls);
    try std.testing.expectEqual(@as(usize, 1), sess.l.len()); // only the user text

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

    // The turn never ends on its own.
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
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &ForeverModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_store = "nulya-absent-extensions-store",
    };
    defer sess.l.deinit();
    try sess.appendUser("go");

    try std.testing.expectEqual(max_steps_ceiling, try sess.run(max_steps_ceiling + 10));
    try std.testing.expectEqual(1 + 2 * max_steps_ceiling, sess.l.len());
}

test "completed step records stable ids and the frozen version behind each, never model names or hallucinated names" {
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
        .{
            .definition = .{ .id = "builtin.shell", .name = "shell", .description = "run", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = OkTool.call },
        },
    };

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
            try sink.emit(.{ .tool_use_start = .{ .index = 1, .id = "c2", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 1, .fragment = "{}" } });
            try sink.emit(.{ .tool_use_start = .{ .index = 2, .id = "c3", .name = "ghost" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 2, .fragment = "{}" } });
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
            // The stats write point reads the version from here.
            .extensions = &.{.{ .id = "web.search", .version = "v-frozen" }},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &MixedModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_store = "nulya-absent-extensions-store",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    const outcome = try sess.step();
    try std.testing.expectEqual(loop.StepStatus.completed, outcome.status);

    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", events[0].tool_id);
    try std.testing.expect(events[0].ok);
    // The stable id says WHICH tool; the version beside it says which frozen
    // implementation answered.
    try std.testing.expectEqualStrings("v-frozen", events[0].version.?);
    try std.testing.expect(events[0].at != null);
    try std.testing.expect(events[0].duration_ms != null);
    // No session, because this one is pure memory: no id to join an outcome to.
    try std.testing.expect(events[0].session == null);

    try std.testing.expectEqualStrings("builtin.shell", events[1].tool_id);
    try std.testing.expect(events[1].version == null);
}

test "a durable session's usage rows name the session, so outcomes can be joined to them" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);
    const session_path = ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s-42.jsonl";

    const SlowTool = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            // A real wait, so the monotonic clock cannot report 0.
            try std.Io.sleep(req.ctx.environment.io, .fromMilliseconds(12), .awake);
            return .{ .ok = true, .output = try a.dupe(u8, "searched") };
        }
    };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "ext:web.search/web_search", .name = "web_search", .description = "search", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = SlowTool.call },
        },
    };

    const OneCallModel = struct {
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "one-call";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "one-call-test";
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
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &OneCallModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_store = "nulya-absent-extensions-store",
        // The id the journal records is the session FILE's stem.
        .durable = .{ .workspace = tmp.dir, .session_path = session_path },
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    _ = try sess.step();

    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", events[0].tool_id);
    try std.testing.expectEqualStrings("s-42", events[0].session.?);
    try std.testing.expect(events[0].duration_ms.? >= 10);
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
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &OneCallModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_store = "nulya-absent-extensions-store",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    var fut = io.async(stepCall, .{&sess});
    try ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) });
    const outcome = try fut.cancel(io);
    try std.testing.expectEqual(loop.StepStatus.canceled, outcome.status);

    // A canceled batch is not recorded at all: the journal stays absent.
    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "a reply cut by max_tokens before it wrote any call stops the run, unlike one that carried calls" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    // Runs out of cap with no tool call. A second step would resend that turn
    // as a prefill, so the model fails the test if it is called twice.
    const TruncatedProseModel = struct {
        turns: usize = 0,

        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "truncated-prose";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "truncated-prose";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            _ = request;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.turns += 1;
            if (self.turns > 1) return error.TestUnexpectedResult; // no prefill continuation
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "a very long answer that ran out of" });
            try sink.emit(.{ .done = .max_tokens });
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
    var model_impl = TruncatedProseModel{};
    var sess: AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &.{} },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &TruncatedProseModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_store = "nulya-absent-extensions-store",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    // `lastAssistantDone` is true by shape and the run stops rather than
    // retrying; the driver reads what happened off `lastStopReason`.
    try std.testing.expectEqual(@as(usize, 1), try sess.run(5));
    try std.testing.expectEqual(@as(usize, 1), model_impl.turns);
    try std.testing.expectEqual(provider.StopReason.max_tokens, sess.lastStopReason());
    try std.testing.expect(sess.lastAssistantDone());
    try std.testing.expectEqual(@as(usize, 2), sess.l.len());
}

test "a truncated tail refuses to step in the next process until a message arrives" {
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

    // Process 1: one step, cut at the output cap before it wrote any call.
    {
        const TruncatingModel = struct {
            fn name(ptr: *anyopaque) []const u8 {
                _ = ptr;
                return "cut";
            }
            fn modelName(ptr: *anyopaque) []const u8 {
                _ = ptr;
                return "cut";
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
                try sink.emit(.{ .text_delta = "half a sen" });
                try sink.emit(.{ .done = .max_tokens });
            }
            const vtable: provider.Model.VTable = .{ .name = name, .modelName = modelName, .capabilities = capabilities, .stream = stream };
        };
        var model_impl = TruncatingModel{};
        var sess = try AgentSession.createDurable(alloc, .{
            .model = .{ .ptr = &model_impl, .vtable = &TruncatingModel.vtable },
            .step_ctx = .{
                .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
                .scratch_dir = "/tmp",
            },
            .extension_store = "nulya-absent-extensions-store",
        }, .{ .workspace = tmp.dir, .session_path = session_path, .session_id = "s" });
        defer sess.deinit();
        try sess.appendUser("go");
        try std.testing.expectEqual(@as(usize, 1), try sess.run(5));
    }

    const RefusingModel = struct {
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "refusing";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "refusing";
        }
        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }
        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            const self: *usize = @ptrCast(@alignCast(ptr));
            self.* += 1;
            // The tail must never end on the assistant: that is the prefill.
            const turns = request.prompt_ir.turns;
            if (turns.len != 0 and turns[turns.len - 1] == .assistant) return error.TestUnexpectedResult;
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "the rest, from a fresh message" });
            try sink.emit(.{ .done = .end_turn });
        }
        const vtable: provider.Model.VTable = .{ .name = name, .modelName = modelName, .capabilities = capabilities, .stream = stream };
    };
    var calls: usize = 0;
    var sess = try AgentSession.openDurable(alloc, .{
        .model = .{ .ptr = &calls, .vtable = &RefusingModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_store = "nulya-absent-extensions-store",
    }, .{ .workspace = tmp.dir, .session_path = session_path });
    defer sess.deinit();

    try std.testing.expect(sess.lastAssistantTruncated());
    // Without the refusal this step resends the truncated turn as a prefill.
    try std.testing.expectError(error.TruncatedTurnNeedsInput, sess.step());
    try std.testing.expectEqual(@as(usize, 0), calls); // provider never called
    try std.testing.expectEqual(@as(usize, 2), sess.l.len()); // and nothing appended

    try sess.appendUser("continue please");
    const outcome = try sess.step();
    try std.testing.expectEqual(loop.StepStatus.completed, outcome.status);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(!sess.lastAssistantTruncated());
}

test "a truncated turn's unexecuted calls are not recorded as tool usage" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try sessionTmpCwd(alloc, io, tmp);
    defer alloc.free(cwd);

    const Boom = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            _ = req;
            _ = a;
            return error.TestUnexpectedResult; // a truncated call must never reach its executor
        }
    };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "ext:web.search/web_search", .name = "web_search", .description = "search", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = Boom.call },
        },
    };

    const TruncatedCallModel = struct {
        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "truncated-call";
        }
        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "truncated-call";
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
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"q\": \"unf" } });
            try sink.emit(.{ .done = .max_tokens });
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
    var model_impl = TruncatedCallModel{};
    var sess: AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = .{ .ptr = &model_impl, .vtable = &TruncatedCallModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .model_options = .{},
        .extension_store = "nulya-absent-extensions-store",
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    const outcome = try sess.step();
    // The step completed: assistant turn plus a matching marker batch…
    try std.testing.expectEqual(loop.StepStatus.completed, outcome.status);
    try std.testing.expectEqual(provider.StopReason.max_tokens, outcome.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), sess.l.len());
    try std.testing.expect(!sess.l.view()[2].tool_results[0].ok);

    // …but no executor ran, so the journal has nothing to observe.
    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}
