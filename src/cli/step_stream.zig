//! The `session step --stream` line protocol (tui.md §2.2): one JSON object per
//! line on stdout, written AS the step runs instead of once it is over.
//!
//! Its own file because it is a wire format, not a verb: `session.zig` decides
//! whether to stream, this decides what a streamed line looks like — and a TUI
//! parses every byte of it, so the format is worth reading in one piece.

const std = @import("std");
const ledger = @import("../ledger.zig");
const loop = @import("../loop.zig");
const provider = @import("../provider.zig");
const printErr = @import("common.zig").printErr;

/// Lines carrying a `stream` field are transient observations; lines without one
/// are ledger events in exactly the `session events` shape. Under `--stream`
/// stdout carries nothing else — diagnostics become
/// `{"stream":"run","event":"error"}`.
///
/// This is the whole protocol in one place: `loop.StepObserver` hands it facts,
/// it turns them into lines. It never touches the session, so it stays pure
/// observation (physics: model-visible state changes only by `append`).
pub const StepStream = struct {
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    /// Ledger index of the first event not yet flushed as a line.
    printed: usize = 0,
    /// A read-only handle on the session's ledger, so events can be reported the
    /// moment they EXIST rather than only when the step is over.
    ///
    /// The one event that exists before the model is asked anything is a
    /// `user_text` the step boundary drained from the inbox (DESIGN §3.4), and a
    /// front end that shows a turn optimistically has no way to learn it landed
    /// until the line arrives: for a whole step it goes on saying "queued" about
    /// a message the model is visibly already answering. Absent, this behaves
    /// exactly as before — every line at `stepEnd`.
    ledger_view: ?*const ledger.Ledger = null,
    /// How the most recent step ended, for the `run done` line's `stopped`.
    last_status: loop.StepStatus = .completed,
    /// First write failure, if any. An observer must not fail the step, so the
    /// error is parked here and reported by the caller as a non-zero exit.
    err: ?anyerror = null,

    fn note(self: *StepStream, e: anyerror) void {
        if (self.err == null) self.err = e;
    }

    pub fn observer(self: *StepStream) loop.StepObserver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: loop.StepObserver.VTable = .{
        .modelEvent = onModelEvent,
        .modelRetry = onModelRetry,
        .toolBegin = onToolBegin,
        .toolEnd = onToolEnd,
        .stepEnd = onStepEnd,
    };

    fn onModelEvent(ptr: *anyopaque, event: provider.StreamEvent) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        // A complete reasoning item is opaque provider bytes kept for replay, not
        // something to render; `thinking_delta` is the display channel (§2.2).
        if (event == .reasoning_item) return;
        // The turn is under way, so the step boundary is behind us and whatever
        // it drained is already a ledger fact. Report it before the first delta:
        // the ORDER a reader sees is then "the message landed, and here is the
        // answer to it", which is the order it actually happened in.
        if (event == .started) {
            if (self.ledger_view) |l| self.flushEvents(l.view()) catch |e| self.note(e);
        }
        self.modelLine(event) catch |e| self.note(e);
    }

    fn onModelRetry(ptr: *anyopaque, retry: loop.RetryNotice) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.retryLine(retry) catch |e| self.note(e);
    }

    fn onToolBegin(ptr: *anyopaque, call: ledger.ToolCall) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.toolBeginLine(call) catch |e| self.note(e);
    }

    fn onToolEnd(ptr: *anyopaque, call: ledger.ToolCall, ok: bool) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.toolEndLine(call, ok) catch |e| self.note(e);
    }

    fn onStepEnd(ptr: *anyopaque, events: []const ledger.Event, step_outcome: loop.StepOutcome) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.last_status = step_outcome.status;
        // Ledger lines first, then the boundary marker: a reader that has seen
        // `step end` knows it has every event of that step.
        self.flushEvents(events) catch |e| self.note(e);
        self.stepEndLine(step_outcome) catch |e| self.note(e);
    }

    /// Emit every ledger event not yet reported, in `session events` shape. The
    /// seq of view index i is i+1 — the same numbering the session file uses.
    pub fn flushEvents(self: *StepStream, events: []const ledger.Event) !void {
        while (self.printed < events.len) : (self.printed += 1) {
            const line = try ledger.encodeEventLine(self.alloc, events[self.printed], self.printed + 1);
            defer self.alloc.free(line);
            try self.out.writeAll(line);
        }
        try self.out.flush();
    }

    fn modelLine(self: *StepStream, event: provider.StreamEvent) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("model");
        try jw.objectField("event");
        switch (event) {
            .started => try jw.write("started"),
            .text_delta => |t| {
                try jw.write("text_delta");
                try jw.objectField("text");
                try jw.write(t);
            },
            .thinking_delta => |t| {
                try jw.write("thinking_delta");
                try jw.objectField("text");
                try jw.write(t);
            },
            .reasoning_item => unreachable, // filtered in onModelEvent
            .tool_use_start => |s| {
                try jw.write("tool_use_start");
                try jw.objectField("index");
                try jw.write(s.index);
                try jw.objectField("id");
                try jw.write(s.id);
                try jw.objectField("name");
                try jw.write(s.name);
            },
            .tool_use_input_delta => |d| {
                try jw.write("tool_use_input_delta");
                try jw.objectField("index");
                try jw.write(d.index);
                try jw.objectField("fragment");
                try jw.write(d.fragment);
            },
            .usage => |u| {
                try jw.write("usage");
                try jw.objectField("input_tokens");
                try jw.write(u.input_tokens);
                try jw.objectField("output_tokens");
                try jw.write(u.output_tokens);
                try jw.objectField("cache_read_tokens");
                try jw.write(u.cache_read_tokens);
                try jw.objectField("cache_write_tokens");
                try jw.write(u.cache_write_tokens);
            },
            .done => |stop| {
                try jw.write("done");
                try jw.objectField("stop");
                try jw.write(@tagName(stop));
            },
        }
        try jw.endObject();
        try self.endLine();
    }

    /// The model request failed transiently; the loop is about to send it again.
    /// A reader drops whatever this turn streamed so far — the retry starts over.
    fn retryLine(self: *StepStream, retry: loop.RetryNotice) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("model");
        try jw.objectField("event");
        try jw.write("retry");
        try jw.objectField("attempt");
        try jw.write(retry.attempt);
        try jw.objectField("max_retries");
        try jw.write(retry.max_retries);
        try jw.objectField("delay_ms");
        try jw.write(retry.delay_ms);
        try jw.objectField("error");
        try jw.write(@errorName(retry.err));
        try jw.endObject();
        try self.endLine();
    }

    fn toolBeginLine(self: *StepStream, call: ledger.ToolCall) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("tool");
        try jw.objectField("event");
        try jw.write("begin");
        try jw.objectField("call_id");
        try jw.write(call.id);
        try jw.objectField("tool");
        try jw.write(call.tool);
        try jw.endObject();
        try self.endLine();
    }

    /// `call_id` alone identifies the call — the reader already learned its tool
    /// from the matching `begin` (and from `tool_use_start` before that).
    fn toolEndLine(self: *StepStream, call: ledger.ToolCall, ok: bool) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("tool");
        try jw.objectField("event");
        try jw.write("end");
        try jw.objectField("call_id");
        try jw.write(call.id);
        try jw.objectField("ok");
        try jw.write(ok);
        try jw.endObject();
        try self.endLine();
    }

    fn stepEndLine(self: *StepStream, step_outcome: loop.StepOutcome) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("step");
        try jw.objectField("event");
        try jw.write("end");
        try jw.objectField("status");
        try jw.write(@tagName(step_outcome.status));
        // Only the reply-was-cut fact is worth a column: end_turn / tool_use are
        // already visible from the events, and the line stays as it was for them.
        if (step_outcome.stop_reason == .max_tokens) {
            try jw.objectField("stop");
            try jw.write("max_tokens");
        }
        try jw.endObject();
        try self.endLine();
    }

    pub fn runDone(self: *StepStream, steps: usize, stopped: []const u8) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("run");
        try jw.objectField("event");
        try jw.write("done");
        try jw.objectField("steps");
        try jw.write(steps);
        try jw.objectField("stopped");
        try jw.write(stopped);
        try jw.endObject();
        try self.endLine();
    }

    pub fn runError(self: *StepStream, message: []const u8) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("run");
        try jw.objectField("event");
        try jw.write("error");
        try jw.objectField("message");
        try jw.write(message);
        try jw.endObject();
        try self.endLine();
    }

    /// One line, flushed: the reader consumes stdout line by line as it arrives.
    fn endLine(self: *StepStream) !void {
        try self.out.writeByte('\n');
        try self.out.flush();
    }
};

/// `session step --gate`: the approval half of the protocol (DESIGN §14).
///
/// One request line out on the same stdout the stream uses, then one verdict
/// line in on stdin, per tool call, while the loop is between calls. It is a
/// `loop.ToolGate` and nothing more: it decides nothing itself — the driver on
/// the other end of the pipe does — and a denial is an ordinary tool result, so
/// the ledger is legal either way.
///
/// **Fail closed.** Anything other than a verdict this side understands is a
/// denial: an answer it cannot parse, a read that fails, and above all end of
/// input — a driver that went away has approved nothing, and every remaining
/// call in the session is denied without asking again.
pub const StepGate = struct {
    io: std.Io,
    out: *std.Io.Writer,
    in: *std.Io.Reader,
    /// stdin is done (EOF, or a read that failed): deny from here on, silently —
    /// the reason was said once, on stderr.
    closed: bool = false,
    /// First write failure, if any. Reported by the caller as a non-zero exit,
    /// the same way a dropped observation is.
    err: ?anyerror = null,

    pub fn gate(self: *StepGate) loop.ToolGate {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: loop.ToolGate.VTable = .{ .review = onReview };

    fn onReview(ptr: *anyopaque, call: ledger.ToolCall) loop.ToolGate.Decision {
        const self: *StepGate = @ptrCast(@alignCast(ptr));
        return self.ask(call) catch |e| {
            // The channel itself broke. Say so once, then deny everything: a
            // gate that cannot ask must not answer "allow" on anybody's behalf.
            if (self.err == null) self.err = e;
            if (!self.closed) {
                self.closed = true;
                self.say("gate: the approval channel failed; denying every remaining call\n");
            }
            return .{ .deny = null };
        };
    }

    fn ask(self: *StepGate, call: ledger.ToolCall) !loop.ToolGate.Decision {
        if (self.closed) return .{ .deny = null };
        try self.requestLine(call);
        const line = (try self.in.takeDelimiter('\n')) orelse {
            self.closed = true;
            self.say("gate: stdin closed before a verdict; denying this call and every one after it\n");
            return .{ .deny = null };
        };
        const verdict = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.eql(u8, verdict, "allow")) return .allow;
        if (std.mem.eql(u8, verdict, "deny")) return .{ .deny = null };
        if (std.mem.startsWith(u8, verdict, "deny ")) return .{ .deny = verdict["deny ".len..] };
        // Not a verdict. The safe reading of an answer nobody can parse is "no".
        self.say("gate: unrecognized verdict (want `allow`, `deny`, or `deny <note>`); denying this call\n");
        return .{ .deny = null };
    }

    /// One call, offered for approval. The arguments go out verbatim — the
    /// driver decides what a `shell` command or an edit path means, and it can
    /// only do that on the bytes the model actually wrote.
    fn requestLine(self: *StepGate, call: ledger.ToolCall) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("gate");
        try jw.objectField("event");
        try jw.write("request");
        try jw.objectField("call_id");
        try jw.write(call.id);
        try jw.objectField("tool");
        try jw.write(call.tool);
        try jw.objectField("args");
        try jw.write(call.args_json);
        try jw.endObject();
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    /// Diagnostics go to stderr: `--gate` implies `--stream`, whose stdout is
    /// pure protocol. A failure to write the diagnostic changes nothing about
    /// the verdict, so it is dropped rather than propagated.
    fn say(self: *StepGate, message: []const u8) void {
        printErr(self.io, message) catch {};
    }
};

test "session step --stream emits the tui.md §2.2 line protocol in order" {
    const environment = @import("../environment.zig");
    const launch = @import("../launch.zig");
    const session = @import("../session.zig");
    const tool = @import("../tool.zig");
    const stoppedReason = @import("session.zig").stoppedReason;
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = cwd_buf[0..try tmp.dir.realPath(io, &cwd_buf)];

    // A stand-in for `shell` so the protocol test never spawns a subprocess; the
    // scripted provider (the same one `NULYA_SCRIPTED_MODE` selects) drives it.
    const FakeShell = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            _ = req;
            return .{ .ok = true, .output = try a.dupe(u8, "ok") };
        }
    };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "nulya.shell", .name = "shell", .description = "shell", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = FakeShell.call },
        },
    };

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    var scripted: launch.ScriptedProvider = .{ .mode = .finish };
    var sess: session.AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = scripted.handle(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd_path },
            .scratch_dir = "/tmp",
            .observer = stream.observer(),
        },
        .model_options = .{},
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    stream.printed = sess.l.len(); // as `session step` does: only this run's events
    const steps = try sess.run(5);
    try stream.runDone(steps, stoppedReason(stream.last_status, sess.lastStopReason(), sess.lastAssistantDone()));
    try std.testing.expect(stream.err == null);

    // Step 1 calls a tool, step 2 addresses the user. Per step: model deltas →
    // tool begin/end → the ledger events that step appended → the step boundary.
    // Then one run verdict for the whole invocation.
    const expected =
        \\{"stream":"model","event":"started"}
        \\{"stream":"model","event":"text_delta","text":"Let me probe the environment."}
        \\{"stream":"model","event":"tool_use_start","index":0,"id":"c1","name":"shell"}
        \\{"stream":"model","event":"tool_use_input_delta","index":0,"fragment":"{\"command\":\"echo hello-from-nulya\"}"}
        \\{"stream":"model","event":"done","stop":"tool_use"}
        \\{"stream":"tool","event":"begin","call_id":"c1","tool":"shell"}
        \\{"stream":"tool","event":"end","call_id":"c1","ok":true}
        \\{"seq":2,"kind":"assistant","text":"Let me probe the environment.","calls":[{"id":"c1","tool":"shell","args":"{\"command\":\"echo hello-from-nulya\"}"}]}
        \\{"seq":3,"kind":"tool_results","results":[{"call_id":"c1","ok":true,"output":"ok","spill_path":null}]}
        \\{"stream":"step","event":"end","status":"completed"}
        \\{"stream":"model","event":"started"}
        \\{"stream":"model","event":"text_delta","text":"done"}
        \\{"stream":"model","event":"done","stop":"end_turn"}
        \\{"seq":4,"kind":"assistant","text":"done","calls":[]}
        \\{"stream":"step","event":"end","status":"completed"}
        \\{"stream":"run","event":"done","steps":2,"stopped":"end_turn"}
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a reply cut by max_tokens is recorded replayable, closed with a marker, retried once, and the run stops with stopped=max_tokens" {
    const environment = @import("../environment.zig");
    const launch = @import("../launch.zig");
    const session = @import("../session.zig");
    const tool = @import("../tool.zig");
    const stoppedReason = @import("session.zig").stoppedReason;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = cwd_buf[0..try tmp.dir.realPath(io, &cwd_buf)];

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
            .definition = .{ .id = "nulya.shell", .name = "shell", .description = "shell", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = Boom.call },
        },
    };
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    var scripted: launch.ScriptedProvider = .{ .mode = .truncate };
    var sess: session.AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = scripted.handle(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = cwd_path },
            .scratch_dir = "/tmp",
            .observer = stream.observer(),
        },
        .model_options = .{},
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    stream.printed = sess.l.len();
    // Budget 5, but two truncated replies in a row stop the run on their own.
    const steps = try sess.run(5);
    try stream.runDone(steps, stoppedReason(stream.last_status, sess.lastStopReason(), sess.lastAssistantDone()));
    try std.testing.expect(stream.err == null);
    try std.testing.expectEqual(@as(usize, session.max_truncated_streak), steps);

    // Per step: the ledger line records the torn args exactly as the model
    // produced them, the batch is closed by a marker result, and the boundary
    // line says the reply was cut.
    const written = out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"calls\":[{\"id\":\"c1\",\"tool\":\"shell\",\"args\":\"{\\\"command\\\":\\\"echo hel\"}]") != null);
    // …and the projection — what a provider would be sent — carries a complete
    // JSON value in their place (DESIGN §4).
    const prompt = @import("../prompt.zig");
    const ir = try prompt.project(alloc, sess.l.view());
    defer ir.deinit(alloc);
    try std.testing.expectEqualStrings("{}", ir.turns[1].assistant.calls[0].args_json);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"ok\":false,\"output\":\"not executed: the reply hit its output cap (max_tokens)") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "{\"stream\":\"step\",\"event\":\"end\",\"status\":\"completed\",\"stop\":\"max_tokens\"}") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "{\"stream\":\"run\",\"event\":\"done\",\"steps\":2,\"stopped\":\"max_tokens\"}\n"));
    // user + 2 × (assistant, marker batch): the model never got past its cap.
    try std.testing.expectEqual(@as(usize, 5), sess.l.len());
}
