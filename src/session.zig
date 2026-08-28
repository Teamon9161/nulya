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
const tool_stats = @import("journals/tool_stats.zig");
const store = @import("extension/store.zig");

/// The most kernel steps one `run` may take, whatever the caller asks for
/// (DESIGN §4, §14). A driver can lower the budget per call, never raise it.
///
/// A RUNAWAY GUARD, NOT A BUDGET. It exists so a loop that has stopped making
/// progress cannot bill without end, and it is set high enough that honest work
/// never reaches it — because a ceiling the model can feel is a ceiling that
/// distorts the work. At 50 it was felt: a single ordinary editing pass spends
/// one step per tool batch, and a session that made fifty of them had to be
/// resumed by hand twice in the middle, which teaches the model nothing except
/// that it is running out of room.
pub const max_steps_ceiling: usize = 500;

/// Consecutive RETRIABLE `max_tokens` steps before `run` stops on its own. Only a
/// truncation that carried tool calls is retriable: it ends in a marker batch, so
/// stepping again shows the model what happened and one retry usually fits. A
/// text-only truncation is not retried at all — see `run` — so this bound is never
/// reached through those. Two retries in a row mean the cap is genuinely too small
/// for what is being asked, which no retry fixes and every retry bills a full
/// prefix for; the driver (and the person) has to hear about it.
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
    extension_roots: []const []const u8,
    /// Set for durable sessions: the session file's location, used to drain the
    /// cross-process capability-note inbox each step (DESIGN §3, §5.3).
    durable: ?DurableRef = null,
    total_usage: provider.Usage = .{},

    pub const Options = struct {
        model: provider.Model,
        step_ctx: loop.StepContext,
        model_options: provider.Options = .{},
        /// Store roots to search, in order (DESIGN §7.2). The default is the
        /// workspace root alone; a CLI adds the user root and any trusted
        /// `extensions.paths` at the session-setup boundary.
        extension_roots: []const []const u8 = &.{store.workspace_root_rel},
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
        /// The creating binary's version string (`launch.version`). The other
        /// half of the header's provenance stamp — the kernel hash — comes from
        /// the kernel itself, so a caller can only get it right (DESIGN §3.4).
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
        const comp = try composition.SessionComposition.init(alloc, tool_ctx.environment.io, tool_ctx.cwd, opts.extension_roots, opts.registry);
        errdefer comp.deinit(alloc);

        return .{
            .alloc = alloc,
            .l = ledger.Ledger.init(alloc),
            .composition = comp,
            .model = opts.model,
            .step_ctx = opts.step_ctx,
            .model_options = opts.model_options,
            .extension_roots = opts.extension_roots,
        };
    }

    pub fn createDurable(alloc: std.mem.Allocator, opts: Options, d: CreateDurableOptions) !AgentSession {
        const tool_ctx = opts.step_ctx.tool_context;
        const io = tool_ctx.environment.io;
        var comp = try composition.SessionComposition.init(alloc, io, tool_ctx.cwd, opts.extension_roots, opts.registry);
        errdefer comp.deinit(alloc);

        // Freeze the resolved composition into the header: the member extensions
        // at their frozen versions and which of their tools are native this
        // session. Any process reopening the file rebuilds the identical
        // composition.
        const active = try alloc.alloc(ledger.ExtensionRef, comp.extensions.len);
        defer alloc.free(active);
        for (comp.extensions, 0..) |e, i| active[i] = .{ .id = e.id, .version = e.version };
        const native = try alloc.alloc([]const u8, comp.extension_tool_bindings.len);
        defer alloc.free(native);
        for (comp.extension_tool_bindings, 0..) |b, i| native[i] = b.definition.id;

        // Provenance: which binary froze the model-visible state this header
        // describes. The kernel prompt and the builtin definitions are the part
        // of that state the header could not otherwise name (DESIGN §3.4).
        const kernel_hash = try composition.kernelHash(alloc);
        defer alloc.free(kernel_hash);

        var l = try ledger.createDurable(alloc, io, d.workspace, d.session_path, .{
            .session = d.session_id,
            .parent = d.parent,
            .model = d.model_profile,
            .model_identity = d.model_identity,
            .created = d.created,
            .nulya = .{ .version = d.nulya_version, .kernel_hash = kernel_hash },
            // The inline prompts go in by VALUE — they have no store entry to
            // point at, and freezing the bytes is what lets a resume rebuild
            // the identical system blocks from this file alone (DESIGN §3).
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
            .extension_roots = opts.extension_roots,
            .durable = .{ .workspace = d.workspace, .session_path = owned_path },
        };
    }

    pub fn openDurable(alloc: std.mem.Allocator, opts: Options, d: OpenDurableOptions) !AgentSession {
        const tool_ctx = opts.step_ctx.tool_context;
        const io = tool_ctx.environment.io;
        var l = try ledger.openDurable(alloc, io, d.workspace, d.session_path);
        errdefer l.deinit();
        const hdr = l.header().?;
        var comp = try composition.SessionComposition.initFrozen(alloc, io, tool_ctx.cwd, opts.extension_roots, hdr.composition);
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
            .extension_roots = opts.extension_roots,
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

    /// Run one step. Cancellation is reported as `StepOutcome.status == .canceled`
    /// (never an error), whether it came from the host canceling the running
    /// step's `Future` or from a `requestCancel` marker consumed at this step's
    /// boundary; the host decides what to do next. Usage is accumulated for
    /// canceled and completed steps alike, since the ledger is left in a legal
    /// state either way. A canceled step does not poison the session — the next
    /// `step()` runs normally.
    ///
    /// Fails with `error.TruncatedTurnNeedsInput` when the ledger ends on a reply
    /// the provider cut off (`lastAssistantTruncated`): stepping it would ask the
    /// provider to continue its own message as a prefill. Nothing is appended, so
    /// the session is fine — it wants a message, not a retry.
    pub fn step(self: *AgentSession) !loop.StepOutcome {
        const outcome = try self.stepInner();
        // The step boundary is the one place where the ledger is guaranteed
        // legal (tui.md §2.2), so it is where an observer gets a read-only look
        // at the events this step produced. Pure observation: it cannot change
        // the outcome, and a step without an observer runs identically.
        if (self.step_ctx.observer) |obs| obs.stepEnd(self.l.view(), outcome);
        return outcome;
    }

    fn stepInner(self: *AgentSession) !loop.StepOutcome {
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
        // Checked AFTER prepareStep: a drained inbox event is exactly the new
        // input that makes the ledger steppable again, so a `session append` racing
        // with this step must be seen first.
        if (self.lastAssistantTruncated()) return error.TruncatedTurnNeedsInput;
        const prompt_ir = try prompt.projectWithSystem(self.alloc, self.composition.system_prompts.blocks, self.l.view());
        defer prompt_ir.deinit(self.alloc);
        // Ledger position before this step's turns: everything appended from
        // here on is this step's assistant turn plus, when it carried tool
        // calls, the single batched tool_results turn.
        const before = self.l.len();
        // How long each call took, for the usage journal below. A step-local
        // buffer, so a duration cannot outlive the step that measured it: it is
        // journal evidence, and neither the ledger nor `StepOutcome` — which
        // every caller of `step()` receives — has any business carrying it.
        var durations_ms: std.ArrayList(?u64) = .empty;
        defer durations_ms.deinit(self.alloc);
        const outcome = try loop.runStepWithPrompt(self.alloc, &self.l, self.model, &prompt_ir, self.composition.tools, self.step_ctx, self.model_options, &durations_ms);
        self.total_usage.add(outcome.usage);
        // Stats are an observation AFTER execution (`tool_stats.zig`), so they are
        // recorded only for a step whose tools actually ran. A reply cut by
        // `max_tokens` closes its batch with marker results the loop wrote without
        // calling any executor: recording those `ok=false` markers would bill the
        // tools for the model's output cap and skew the very success rates
        // evolution reads (DESIGN §4).
        const tools_executed = outcome.status == .completed and outcome.stop_reason != .max_tokens;
        if (tools_executed) {
            // Tool usage stats are auxiliary durable metadata, not conversation
            // truth: a recording failure never rewinds the ledger or turns a
            // completed invocation into a failure. Host faults (OOM, real I/O
            // errors) propagate; a cancel landing after the step's real work
            // already finished is host execution control, so the completed
            // outcome is reported as-is and this step's events go unrecorded.
            self.recordCompletedToolStats(before, durations_ms.items) catch |err| switch (err) {
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
    /// stops the run, and so do `max_truncated_streak` truncated replies in a
    /// row. Returns the number of steps taken; `lastStopReason` says how the
    /// final step's reply ended.
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
            // The streak above is reachable only through truncations that carried
            // tool calls, and that asymmetry is deliberate (DESIGN §4). A truncated
            // reply WITH calls ends in a marker batch, so stepping again shows the
            // model what happened and asks it to retry. A truncated reply with NO
            // calls leaves the ledger ending on an assistant turn — stepping again
            // would send that back as a prefill for the model to continue, which
            // providers reject outright when thinking is on. So it stops here,
            // looking "done" by shape, and `lastStopReason` tells the driver the
            // turn was cut: continuing is the person's move (a new message), not
            // the kernel's.
            if (self.lastAssistantDone()) break;
        }
        return taken;
    }

    pub fn usage(self: *const AgentSession) provider.Usage {
        return self.total_usage;
    }

    /// Why the model stopped in the most recent turn on record — the ledger's
    /// LAST assistant event, or `end_turn` when there is none yet. Read from the
    /// durable fact rather than remembered in memory, so a process that only
    /// resumed the session answers exactly like the process that ran the step
    /// (DESIGN §3.1). `max_tokens` means that reply was cut off — the driver's
    /// cue that "the assistant is done" is not what happened.
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

    /// Whether the ledger ends on a reply the provider cut at its output cap. That
    /// tail is not steppable: projected as-is it becomes a trailing assistant
    /// message, which the provider reads as a prefill to continue and rejects
    /// outright when thinking is on (DESIGN §4). In-process, `run` never reaches
    /// that state — it stops on the truncated step. Across processes the ledger is
    /// all there is, which is exactly why the stop reason is a durable fact on the
    /// assistant event and not a field that dies with the process. Appending
    /// anything (a user message, a drained inbox event) clears it.
    pub fn lastAssistantTruncated(self: *const AgentSession) bool {
        if (self.l.len() == 0) return false;
        return switch (self.l.view()[self.l.len() - 1]) {
            .assistant => |as| as.stop_reason == .max_tokens,
            else => false,
        };
    }

    /// Whether the ledger's last event is an assistant turn with no tool calls.
    /// Pure ledger SHAPE — it does not know why the model stopped, and a reply cut
    /// by `max_tokens` before it wrote a call has exactly this shape. Pair it with
    /// `lastStopReason` when the question is "did the assistant finish?".
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
    ///
    /// Each line also carries WHICH SESSION the call served, so the slow loop
    /// can join it against `session-outcomes.jsonl` instead of seeing an
    /// undifferentiated pile of calls. An in-memory session has no durable id
    /// and simply omits it.
    ///
    /// …and WHICH FROZEN IMPLEMENTATION served it, looked up in this session's
    /// frozen member list — the one truth about member versions, held right
    /// here in `self.composition`. The stable id stays version-free (a tool's
    /// history is one history); the version sits beside it so the same history
    /// can also be read per implementation. The builtin has none.
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
        // One tool_results entry per assistant call, and one measurement slot per
        // call: a completed step reached every one of them, and the loop filled
        // all three in call order. The multi-prong for below panics if the
        // lengths ever disagree.
        std.debug.assert(assistant.calls.len == results.len);
        std.debug.assert(assistant.calls.len == durations_ms.len);

        const ctx = self.step_ctx.tool_context;
        const session_id: ?[]const u8 = if (self.durable) |d|
            std.fs.path.stem(std.fs.path.basename(d.session_path))
        else
            null;
        for (assistant.calls, results, durations_ms) |call, result, measured| {
            // No measurement means no executor ran: a gate denied the call
            // (DESIGN §4). Journalling it would bill the tool for somebody's
            // refusal, the same skew a `max_tokens` marker batch would cause.
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
    /// when no member does: the builtin (`builtin.shell` names no extension)
    /// and — in theory unreachable, since every binding came from a member — a
    /// stable id whose extension is not in the frozen list. A null there is
    /// "not recorded", the same honest gap an old journal line carries; it is
    /// never an error, because a missing evidence column must not be able to
    /// fail a step. The id shape is `ext:<extension-id>/<tool-name>` and ids
    /// never contain `/`, so reading the id segment needs no validation here:
    /// it arrives from a frozen `ToolDefinition`, not from a user. The returned
    /// slice is borrowed from the composition, which outlives the append.
    fn frozenVersionOf(self: *const AgentSession, tool_id: []const u8) ?[]const u8 {
        const prefix = "ext:";
        if (!std.mem.startsWith(u8, tool_id, prefix)) return null;
        const rest = tool_id[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const ext_id = rest[0..slash];
        for (self.composition.extensions) |e| {
            if (std.mem.eql(u8, e.id, ext_id)) return e.version;
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
            // user_text, assistant(call), and the repaired batch as ONE turn.
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
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
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_roots = &.{"nulya-absent-extensions-root"},
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
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_roots = &.{store.workspace_root_rel},
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
        try std.testing.expectEqualStrings("hello", b.l.view()[0].user_text.text);
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
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd },
            .scratch_dir = "/tmp",
        },
        .extension_roots = &.{"nulya-absent-extensions-root"},
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();
    try sess.appendUser("go");

    try std.testing.expectEqual(max_steps_ceiling, try sess.run(max_steps_ceiling + 10));
    // user + (assistant, tool_results) per step
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

    // One real extension call (web_search), one builtin (shell) and one name
    // the model invented (ghost): the real calls resolve to their stable ids,
    // the hallucinated one is skipped.
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
            // The one truth about member versions: the stats write point reads
            // the version out of here, not out of a copy in the binding.
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
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
    // implementation answered this call — looked up in the frozen member list.
    try std.testing.expectEqualStrings("v-frozen", events[0].version.?);
    // Every recorded call carries a stamp and a measurement…
    try std.testing.expect(events[0].at != null);
    try std.testing.expect(events[0].duration_ms != null);
    // …and no session, because this one is pure memory: there is no id to join
    // an outcome to, and inventing one would be a lie.
    try std.testing.expect(events[0].session == null);

    // The builtin is the kernel: it has no implementation version to record,
    // which is a different fact from an unrecorded one only in that no honest
    // writer could ever fill it in.
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
            // A real wait, so the measurement is of something rather than of
            // nothing: the clock is monotonic, so this cannot come back as 0.
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
        // What makes this session identifiable: the id the journal records is
        // the session FILE's stem, exactly as `session outcome <id>` spells it.
        .durable = .{ .workspace = tmp.dir, .session_path = session_path },
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    _ = try sess.step();

    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", events[0].tool_id);
    // The session id is the file's stem — the same id `session outcome` writes,
    // which is the whole point of recording it.
    try std.testing.expectEqualStrings("s-42", events[0].session.?);
    // A call that really waited is measured as having taken time.
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    var fut = io.async(stepCall, .{&sess});
    try ready.waitTimeout(io, .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(5000) }) });
    const outcome = try fut.cancel(io);
    try std.testing.expectEqual(loop.StepStatus.canceled, outcome.status);

    // A canceled batch is not recorded as a failure (or anything): the journal
    // stays absent.
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

    // Writes long prose and runs out of cap with no tool call. A second step would
    // resend that assistant turn as a prefill, so the run must not take one — the
    // model is asked to fail the test if it is called twice.
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    // One step, well under the budget: `lastAssistantDone` is true by shape, and
    // the run stops there rather than retrying the way a truncation with calls is
    // retried (DESIGN §4). What the reply lost is not lost silently — the driver
    // reads it off `lastStopReason` and asks the person for a new message.
    try std.testing.expectEqual(@as(usize, 1), try sess.run(5));
    try std.testing.expectEqual(@as(usize, 1), model_impl.turns);
    try std.testing.expectEqual(provider.StopReason.max_tokens, sess.lastStopReason());
    try std.testing.expect(sess.lastAssistantDone());
    // user + the truncated assistant; no calls, so no batch.
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

    // Process 1: one step, cut at the output cap before it wrote any call. `run`
    // stops there, and the fact goes to disk with the turn.
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
            .extension_roots = &.{"nulya-absent-extensions-root"},
        }, .{ .workspace = tmp.dir, .session_path = session_path, .session_id = "s" });
        defer sess.deinit();
        try sess.appendUser("go");
        try std.testing.expectEqual(@as(usize, 1), try sess.run(5));
    }

    // Process 2 sees only the ledger; nothing about process 1's run survives it.
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
            // The tail this step was handed must never end on the assistant: that
            // is the prefill the provider rejects with thinking on.
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
    }, .{ .workspace = tmp.dir, .session_path = session_path });
    defer sess.deinit();

    try std.testing.expect(sess.lastAssistantTruncated());
    // The refusal is the whole point: without it this step sends the truncated
    // assistant turn back as a prefill for the model to continue.
    try std.testing.expectError(error.TruncatedTurnNeedsInput, sess.step());
    try std.testing.expectEqual(@as(usize, 0), calls); // provider never called
    try std.testing.expectEqual(@as(usize, 2), sess.l.len()); // and nothing appended

    // A message is what the session wants, not a retry: it clears the tail and
    // the session steps normally again.
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
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    const outcome = try sess.step();
    // The step completed as far as the host is concerned — the ledger has its
    // assistant turn and a matching marker batch...
    try std.testing.expectEqual(loop.StepStatus.completed, outcome.status);
    try std.testing.expectEqual(provider.StopReason.max_tokens, outcome.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), sess.l.len());
    try std.testing.expect(!sess.l.view()[2].tool_results[0].ok);

    // ...but no executor ran, so the journal has nothing to observe. Recording the
    // marker would charge web_search a failure it never earned.
    const events = try tool_stats.readAll(alloc, io, cwd);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}
