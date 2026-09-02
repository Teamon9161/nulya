//! The offline stand-in for a real model: deterministic, terminating, no
//! network. Used whenever a session's provider is empty or `"scripted"`; every
//! offline e2e drives it through `NULYA_SCRIPTED_MODE`.

const std = @import("std");
const provider = @import("../provider.zig");
const prompt = @import("../prompt.zig");

/// The modes `NULYA_SCRIPTED_MODE` selects:
///
///   finish (default): one `shell` call, then end the turn once a tool result is
///                     in the transcript (a turn takes two steps).
///   loop:             always call `shell`, never end the turn — only
///                     `--max-steps` stops it.
///   truncate:         every reply is cut by `max_tokens` mid tool call.
///   handoff:          call `handoff` once with a complete brief, then end the
///                     turn in the session forked from it.
///   wrapup:           like `loop` until a user turn asks it to stop and report.
///   wrapdefy:         the same run with a model that does NOT take the hint;
///                     each call writes a file named for which side of the ask
///                     it is on, so a test sees whether a tool RAN.
///   readfile:         call `read` once on a fixed file name — the one mode
///                     exercising an EXTENSION tool, so a remote workspace can
///                     be asked whose files `read` reads.
///   background:       start ONE background command and end the turn, saying
///                     `background done` once a note turn is in the transcript.
pub const ScriptedProvider = struct {
    mode: Mode = .finish,

    pub const Mode = enum { finish, loop, truncate, handoff, batch, background, wrapup, wrapdefy, readfile };

    /// The file the `readfile` mode asks for, workspace-relative. Fixed, so a
    /// test can put a DIFFERENT body at this name on each machine.
    pub const read_target = "remote-sentinel.txt";
    const read_args =
        \\{"path":"remote-sentinel.txt"}
    ;

    /// The opening words of what a runner sends a sub-agent whose steps ran out.
    /// Spelled out, not imported: it lives in a separate artifact.
    pub const wrap_up_opening = "Your step budget is spent";

    /// The files the `wrapdefy` mode's two commands create. Two names because
    /// the question is which ROUND ran a tool; the ABSENCE of the second is what
    /// a test asserts.
    pub const defiant_before_file = "wrapup-before.txt";
    pub const defiant_after_file = "wrapup-after.txt";
    /// What it says once the refusal is in front of it: a deny is a
    /// `tool_results` entry, and reading one takes a turn.
    pub const defiant_report = "denied, so here is what I found";
    const defiant_before_args = "{\"command\":\"echo ran > " ++ defiant_before_file ++ "\"}";
    const defiant_after_args = "{\"command\":\"echo ran > " ++ defiant_after_file ++ "\"}";

    /// What the `background` mode's command prints. `echo` means the same thing
    /// in both dialects, so the stand-in needs no dialect of its own.
    pub const background_marker = "scripted-background-marker";
    const background_args =
        \\{"command":"echo scripted-background-marker","background":true}
    ;

    /// The fixed brief the `handoff` mode proposes: three complete sections so
    /// the real bundled tool accepts it, plus a sentinel a test can follow into
    /// the child session.
    pub const handoff_sentinel = "PHASE-2-SENTINEL";
    const handoff_args =
        \\{"done":"Phase 1 is finished: read the map and listed what matters.","next_task":"Phase 2: PHASE-2-SENTINEL — write the note and stop.","keep":"The sentinel PHASE-2-SENTINEL identifies this handover."}
    ;

    /// The marker a carried brief starts with: this session was forked from
    /// another, so nothing is left to hand off. Spelled out, not imported.
    const summary_marker = "<nulya:context-summary>";

    pub fn fromEnv(env: *const std.process.Environ.Map) ScriptedProvider {
        const m = env.get("NULYA_SCRIPTED_MODE") orelse "";
        return .{ .mode = std.meta.stringToEnum(Mode, m) orelse .finish };
    }

    pub fn handle(self: *ScriptedProvider) provider.Model {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted-demo";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = alloc;
        const self: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        try sink.emit(.started);

        if (self.mode == .finish and hasToolResult(request.prompt_ir.turns)) {
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .end_turn });
            return;
        }
        if (self.mode == .truncate) {
            try sink.emit(.{ .text_delta = "Let me probe" });
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo hel" } });
            try sink.emit(.{ .done = .max_tokens });
            return;
        }
        // Three calls in ONE turn: the shape a serial gate is actually asked
        // about (the kernel offers call N only once N-1 has run).
        if (self.mode == .batch) {
            if (hasToolResult(request.prompt_ir.turns)) {
                try sink.emit(.{ .text_delta = "done" });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            try sink.emit(.{ .text_delta = "Let me look around." });
            inline for (.{ "one", "two", "three" }, 0..) |word, i| {
                try sink.emit(.{ .tool_use_start = .{ .index = i, .id = "b" ++ word, .name = "shell" } });
                try sink.emit(.{ .tool_use_input_delta = .{
                    .index = i,
                    .fragment = "{\"command\":\"echo batch-" ++ word ++ "\"}",
                } });
            }
            try sink.emit(.{ .done = .tool_use });
            return;
        }
        if (self.mode == .wrapup) {
            if (hasUserTextContaining(request.prompt_ir.turns, wrap_up_opening)) {
                try sink.emit(.{ .text_delta = "here is what I found before the budget ran out" });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "w1", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo still-looking\"}" } });
            try sink.emit(.{ .done = .tool_use });
            return;
        }
        if (self.mode == .wrapdefy) {
            // A call the gate refused, detected by `ok == false` rather than by
            // wording: every other result in this mode is an `echo` that worked.
            if (hasFailedToolResult(request.prompt_ir.turns)) {
                try sink.emit(.{ .text_delta = defiant_report });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            const asked = hasUserTextContaining(request.prompt_ir.turns, wrap_up_opening);
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = if (asked) "d2" else "d1", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{
                .index = 0,
                .fragment = if (asked) defiant_after_args else defiant_before_args,
            } });
            try sink.emit(.{ .done = .tool_use });
            return;
        }
        if (self.mode == .readfile) {
            if (hasToolResult(request.prompt_ir.turns)) {
                try sink.emit(.{ .text_delta = "read done" });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "r1", .name = "read" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = read_args } });
            try sink.emit(.{ .done = .tool_use });
            return;
        }
        if (self.mode == .background) {
            // The report landed, distinguishable from "read nothing".
            if (hasTaskReport(request.prompt_ir.turns)) {
                try sink.emit(.{ .text_delta = "background done" });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            // The receipt came back but the task has not finished: end the turn
            // and leave stepping again to the driver — that is policy.
            if (hasToolResult(request.prompt_ir.turns)) {
                try sink.emit(.{ .text_delta = "waiting" });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "bg1", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = background_args } });
            try sink.emit(.{ .done = .tool_use });
            return;
        }
        if (self.mode == .handoff) {
            // The handoff already happened this turn: stop, so a parent stepped
            // again terminates instead of proposing a second handover.
            if (hasToolResult(request.prompt_ir.turns)) {
                try sink.emit(.{ .text_delta = "handoff proposed" });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            // A carried brief means this IS the next phase: end here.
            if (hasCarriedBrief(request.prompt_ir.turns)) {
                try sink.emit(.{ .text_delta = "done" });
                try sink.emit(.{ .done = .end_turn });
                return;
            }
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "h1", .name = "handoff" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = handoff_args } });
            try sink.emit(.{ .done = .tool_use });
            return;
        }

        try sink.emit(.{ .text_delta = "Let me probe the environment." });
        try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo hello-from-nulya\"}" } });
        try sink.emit(.{ .done = .tool_use });
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

fn hasToolResult(turns: []const prompt.Turn) bool {
    for (turns) |turn| {
        if (turn == .tool_results) return true;
    }
    return false;
}

/// Did any tool call in this transcript come back not-ok? In the modes that use
/// this, a gate refusal is the only way that happens.
fn hasFailedToolResult(turns: []const prompt.Turn) bool {
    for (turns) |turn| switch (turn) {
        .tool_results => |results| for (results) |result| {
            if (!result.ok) return true;
        },
        else => {},
    };
    return false;
}

fn hasUserTextContaining(turns: []const prompt.Turn, needle: []const u8) bool {
    for (turns) |turn| switch (turn) {
        .user_text => |u| if (std.mem.indexOf(u8, u.text, needle) != null) return true,
        else => {},
    };
    return false;
}

fn hasTaskReport(turns: []const prompt.Turn) bool {
    for (turns) |turn| {
        if (turn == .note) return true;
    }
    return false;
}

/// Does this transcript open on a brief carried in from another session? A fork
/// deposits it as an ordinary `user_text`, so "which phase am I in" is a
/// property of the projection, exactly as it is for a real model.
fn hasCarriedBrief(turns: []const prompt.Turn) bool {
    for (turns) |turn| switch (turn) {
        .user_text => |u| if (std.mem.startsWith(u8, u.text, ScriptedProvider.summary_marker)) return true,
        else => {},
    };
    return false;
}

test "scripted provider mode comes from the environment" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try std.testing.expectEqual(ScriptedProvider.Mode.finish, ScriptedProvider.fromEnv(&env).mode);
    try env.put("NULYA_SCRIPTED_MODE", "loop");
    try std.testing.expectEqual(ScriptedProvider.Mode.loop, ScriptedProvider.fromEnv(&env).mode);
    try env.put("NULYA_SCRIPTED_MODE", "handoff");
    try std.testing.expectEqual(ScriptedProvider.Mode.handoff, ScriptedProvider.fromEnv(&env).mode);
}

/// Collect one scripted turn against a hand-built transcript, exactly as the
/// loop does. Caller owns the result (`ModelTurn.deinit`).
fn scriptedTurn(alloc: std.mem.Allocator, mode: ScriptedProvider.Mode, turns: []const prompt.Turn) !provider.ModelTurn {
    var scripted: ScriptedProvider = .{ .mode = mode };
    var collector: provider.TurnCollector = .init(alloc);
    defer collector.deinit();
    const ir: prompt.PromptIR = .{ .system_blocks = &.{}, .turns = turns };
    try scripted.handle().stream(alloc, .{ .prompt_ir = &ir, .tools = &.{} }, collector.sink());
    return collector.finish();
}

test "the scripted handoff mode plays a two-phase goal: propose, then stop, then work in the child" {
    const alloc = std.testing.allocator;

    {
        const turn = try scriptedTurn(alloc, .handoff, &.{.{ .user_text = .{ .text = "reach the goal" } }});
        defer turn.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), turn.calls.len);
        try std.testing.expectEqualStrings("handoff", turn.calls[0].tool);
        try std.testing.expect(std.mem.indexOf(u8, turn.calls[0].args_json, ScriptedProvider.handoff_sentinel) != null);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, turn.calls[0].args_json, .{});
        defer parsed.deinit();
        for ([_][]const u8{ "done", "next_task", "keep" }) |field| {
            try std.testing.expect(parsed.value.object.get(field).?.string.len > 0);
        }
    }

    {
        const results = [_]prompt.ToolResult{.{ .call_id = "h1", .ok = true, .output = "{}" }};
        const turn = try scriptedTurn(alloc, .handoff, &.{
            .{ .user_text = .{ .text = "reach the goal" } },
            .{ .tool_results = &results },
        });
        defer turn.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), turn.calls.len);
        try std.testing.expectEqualStrings("handoff proposed", turn.text);
        try std.testing.expectEqual(provider.StopReason.end_turn, turn.stop_reason);
    }

    {
        const turn = try scriptedTurn(alloc, .handoff, &.{
            .{ .user_text = .{ .text = ScriptedProvider.summary_marker ++ "\ncarry on" } },
        });
        defer turn.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), turn.calls.len);
        try std.testing.expectEqualStrings("done", turn.text);
        try std.testing.expectEqual(provider.StopReason.end_turn, turn.stop_reason);
    }
}
