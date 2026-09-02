//! Provider-independent prompt projection: `Ledger` events -> `PromptIR`.
//!
//! The cache invariant lives here, not in provider HTTP bytes: appending to the
//! ledger must only EXTEND the projection, never rewrite an earlier turn
//! (`isStablePrefix` is that invariant in testable form). Providers serialize
//! this IR into their own cache mechanism.

const std = @import("std");
const ledger = @import("ledger.zig");

/// Upper bound for one static system prompt contribution. Shared by the
/// extension build-time check and session composition so a built version is
/// always consumable.
pub const max_system_prompt_bytes: usize = 2 * 1024 * 1024;

/// One tool call as a provider may be sent it. Same three fields as
/// `ledger.ToolCall` and borrowed from it, but a distinct type: the ledger holds
/// what the model EMITTED, this holds what may be REPLAYED. They differ when a
/// reply ran out of `max_tokens` mid-call, where the ledger's `args_json` is a
/// torn JSON prefix and the projection substitutes `{}`.
pub const ToolCall = struct {
    id: []const u8,
    tool: []const u8,
    /// Always a complete JSON value — that is this type's whole guarantee.
    args_json: []const u8,
};

/// One tool result as a provider may be sent it: the ledger entry minus
/// `spill_path` (where the kernel parked overflowing bytes — not model-visible).
/// Borrowed from the ledger entry.
pub const ToolResult = struct {
    call_id: []const u8,
    ok: bool,
    output: []const u8,
};

/// One projected ledger event: the MODEL-VISIBLE subset of `ledger.Event`, with
/// the turn kept whole (every wire needs turn-level structure: an assistant
/// message carries its text and calls together, a batch of results is one turn).
///
/// `assistant.usage`, `assistant.stop_reason`, a result's `spill_path` and an
/// event's inbox `origin` have no field in this type: "not projected" is a
/// property of the type rather than a rule someone has to keep following.
pub const Turn = union(enum) {
    user_text: UserText,
    assistant: Assistant,
    /// One batch = one turn; the provider decides how many wire messages that is.
    tool_results: []const ToolResult,
    /// A machine fact from outside the step — its text only. A note's `source`
    /// and `meta` are bookkeeping for readers, never model-visible.
    note: []const u8,

    /// A user turn's model-visible content. Every field of `ledger.UserText` is
    /// model-visible, so the images are the LEDGER's slice borrowed whole —
    /// nothing to copy, hence no per-projection storage the way `calls` needs.
    pub const UserText = struct {
        text: []const u8,
        images: []const ledger.Image = &.{},
    };

    pub const Assistant = struct {
        /// The turn's opaque provider reasoning items (verbatim: a JSON array as
        /// text), or `""` when there were none. Only providers that declare
        /// `thinking_replay` serialize it, always ahead of the turn's text and
        /// calls. The kernel never reads inside.
        reasoning: []const u8,
        text: []const u8,
        calls: []const ToolCall,
    };
};

pub const SystemBlock = struct {
    source: []const u8,
    bytes: []const u8,
};

pub const SystemPromptSnapshot = struct {
    blocks: []const SystemBlock,

    pub fn deinit(self: SystemPromptSnapshot, alloc: std.mem.Allocator) void {
        for (self.blocks) |block| {
            alloc.free(block.source);
            alloc.free(block.bytes);
        }
        alloc.free(self.blocks);
    }
};

pub const PromptIR = struct {
    system_blocks: []const SystemBlock,
    /// One entry per ledger event, in order. Every string BORROWS from the
    /// ledger's events, so a `PromptIR` must not outlive the ledger it was
    /// projected from.
    turns: []const Turn,
    /// Backing storage the turns' `calls` slices point into: one allocation for
    /// the whole projection rather than one per turn, so no turn owns anything.
    call_storage: []ToolCall = &.{},
    /// Same, for the turns' `tool_results` slices.
    result_storage: []ToolResult = &.{},

    /// Frees the arrays; every string in them is the ledger's.
    pub fn deinit(self: PromptIR, alloc: std.mem.Allocator) void {
        alloc.free(self.turns);
        alloc.free(self.call_storage);
        alloc.free(self.result_storage);
    }
};

pub fn project(alloc: std.mem.Allocator, events: []const ledger.Event) !PromptIR {
    return projectWithSystem(alloc, &.{}, events);
}

/// Project the ledger into what a provider may be sent.
///
/// The ledger holds the FACT (what the model emitted); this holds what is legal
/// to replay. One place they differ: on a turn cut off by `max_tokens`, an
/// `args_json` that is not a complete JSON value becomes `{}` — replaying a
/// torn prefix would 400 every later request of the session, while the line
/// keeps saying what happened.
pub fn projectWithSystem(alloc: std.mem.Allocator, system_blocks: []const SystemBlock, events: []const ledger.Event) !PromptIR {
    var total_calls: usize = 0;
    var total_results: usize = 0;
    for (events) |event| switch (event) {
        .assistant => |as| total_calls += as.calls.len,
        .tool_results => |results| total_results += results.len,
        else => {},
    };

    // Every event is a turn.
    const turns = try alloc.alloc(Turn, events.len);
    errdefer alloc.free(turns);
    const call_storage = try alloc.alloc(ToolCall, total_calls);
    errdefer alloc.free(call_storage);
    const result_storage = try alloc.alloc(ToolResult, total_results);
    errdefer alloc.free(result_storage);

    var call_at: usize = 0;
    var result_at: usize = 0;
    for (events, turns) |event, *turn| {
        switch (event) {
            .user_text => |u| turn.* = .{ .user_text = .{ .text = u.text, .images = u.images } },
            .assistant => |as| {
                const calls = call_storage[call_at..][0..as.calls.len];
                call_at += calls.len;
                const truncated = as.stop_reason == .max_tokens;
                for (as.calls, calls) |src, *dst| dst.* = .{
                    .id = src.id,
                    .tool = src.tool,
                    .args_json = if (truncated and !try std.json.validate(alloc, src.args_json)) "{}" else src.args_json,
                };
                turn.* = .{ .assistant = .{
                    .reasoning = as.reasoning,
                    .text = as.text,
                    .calls = calls,
                } };
            },
            .tool_results => |results| {
                const projected = result_storage[result_at..][0..results.len];
                result_at += projected.len;
                for (results, projected) |src, *dst| dst.* = .{ .call_id = src.call_id, .ok = src.ok, .output = src.output };
                turn.* = .{ .tool_results = projected };
            },
            .note => |n| turn.* = .{ .note = n.text },
        }
    }
    return .{
        .system_blocks = system_blocks,
        .turns = turns,
        .call_storage = call_storage,
        .result_storage = result_storage,
    };
}

/// The cache invariant in testable form: same tag and equal payloads, turn by
/// turn.
pub fn isStablePrefix(prefix: []const Turn, full: []const Turn) bool {
    if (prefix.len > full.len) return false;
    for (prefix, full[0..prefix.len]) |a, b| {
        if (!turnsEqual(a, b)) return false;
    }
    return true;
}

fn turnsEqual(a: Turn, b: Turn) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .user_text => |u| blk: {
            const other = b.user_text;
            if (!std.mem.eql(u8, u.text, other.text)) break :blk false;
            if (u.images.len != other.images.len) break :blk false;
            for (u.images, other.images) |x, y| {
                if (!std.mem.eql(u8, x.media_type, y.media_type)) break :blk false;
                if (!std.mem.eql(u8, x.data, y.data)) break :blk false;
            }
            break :blk true;
        },
        .note => |text| std.mem.eql(u8, text, b.note),
        .assistant => |as| blk: {
            const other = b.assistant;
            if (!std.mem.eql(u8, as.reasoning, other.reasoning)) break :blk false;
            if (!std.mem.eql(u8, as.text, other.text)) break :blk false;
            if (as.calls.len != other.calls.len) break :blk false;
            for (as.calls, other.calls) |x, y| {
                if (!std.mem.eql(u8, x.id, y.id)) break :blk false;
                if (!std.mem.eql(u8, x.tool, y.tool)) break :blk false;
                if (!std.mem.eql(u8, x.args_json, y.args_json)) break :blk false;
            }
            break :blk true;
        },
        .tool_results => |results| blk: {
            const other = b.tool_results;
            if (results.len != other.len) break :blk false;
            for (results, other) |x, y| {
                if (!std.mem.eql(u8, x.call_id, y.call_id)) break :blk false;
                if (x.ok != y.ok) break :blk false;
                if (!std.mem.eql(u8, x.output, y.output)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "PromptIR turns extend by prefix on append" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = .{ .text = "first" } });
    const p1 = try project(alloc, l.view());
    defer p1.deinit(alloc);

    try l.append(.{ .assistant = .{ .text = "ok", .calls = &.{} } });
    const p2 = try project(alloc, l.view());
    defer p2.deinit(alloc);

    try std.testing.expect(isStablePrefix(p1.turns, p2.turns));
}

test "assistant reasoning rides on its own turn, ahead of that turn's text and calls" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = .{ .text = "hi" } });
    try l.append(.{ .assistant = .{ .text = "plain", .calls = &.{} } });
    try l.append(.{ .user_text = .{ .text = "go" } });
    try l.append(.{ .assistant = .{
        .reasoning = "[{\"type\":\"reasoning\",\"encrypted_content\":\"…\"}]",
        .text = "",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{}" }},
    } });
    const p = try project(alloc, l.view());
    defer p.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 4), p.turns.len);
    try std.testing.expectEqualStrings("hi", p.turns[0].user_text.text);
    // No reasoning on the turn → the empty string, never a separate turn.
    try std.testing.expectEqualStrings("", p.turns[1].assistant.reasoning);
    try std.testing.expectEqualStrings("plain", p.turns[1].assistant.text);
    try std.testing.expectEqualStrings("go", p.turns[2].user_text.text);
    // With reasoning: verbatim bytes on the same turn as the text and calls it
    // came with, which is the order every wire replays them in.
    const last = p.turns[3].assistant;
    try std.testing.expectEqualStrings("[{\"type\":\"reasoning\",\"encrypted_content\":\"…\"}]", last.reasoning);
    try std.testing.expectEqualStrings("", last.text);
    try std.testing.expectEqual(@as(usize, 1), last.calls.len);
    try std.testing.expectEqualStrings("c1", last.calls[0].id);
}

test "a batch of tool results is ONE turn, and cost is not in the type at all" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = .{ .text = "go" } });
    try l.append(.{ .assistant = .{
        .text = "",
        .calls = &.{
            .{ .id = "c1", .tool = "shell", .args_json = "{}" },
            .{ .id = "c2", .tool = "shell", .args_json = "{}" },
        },
        .usage = .{ .input_tokens = 10, .output_tokens = 2 },
        .stop_reason = .max_tokens,
    } });
    try l.append(.{ .tool_results = &.{
        .{ .call_id = "c1", .ok = true, .output = "A" },
        .{ .call_id = "c2", .ok = false, .output = "B" },
    } });
    const p = try project(alloc, l.view());
    defer p.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), p.turns.len);
    try std.testing.expectEqual(@as(usize, 2), p.turns[2].tool_results.len);
    try std.testing.expectEqualStrings("c2", p.turns[2].tool_results[1].call_id);
    try std.testing.expect(!p.turns[2].tool_results[1].ok);

    // `usage` / `stop_reason` have no field in `Turn` at all, so the same
    // conversation without them projects to the very same turns.
    var plain = ledger.Ledger.init(alloc);
    defer plain.deinit();
    for (l.view()) |e| switch (e) {
        .assistant => |as| try plain.append(.{ .assistant = .{ .reasoning = as.reasoning, .text = as.text, .calls = as.calls } }),
        else => try plain.append(e),
    };
    const q = try project(alloc, plain.view());
    defer q.deinit(alloc);
    try std.testing.expectEqual(p.turns.len, q.turns.len);
    try std.testing.expect(isStablePrefix(p.turns, q.turns));
}

test "a truncated turn's torn arguments are replayable in the projection; the ledger keeps what the model wrote" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = .{ .text = "go" } });
    try l.append(.{
        .assistant = .{
            .text = "let me",
            .calls = &.{
                .{ .id = "c1", .tool = "edit", .args_json = "{\"path\":\"a.t" }, // cut mid-JSON
                .{ .id = "c2", .tool = "shell", .args_json = "{\"command\":\"ls\"}" }, // complete
            },
            .stop_reason = .max_tokens,
        },
    });
    const p = try project(alloc, l.view());
    defer p.deinit(alloc);

    const calls = p.turns[1].assistant.calls;
    // Only what is NOT a complete JSON value is substituted; a call that
    // happened to finish before the cap is sent exactly as it was written.
    try std.testing.expectEqualStrings("{}", calls[0].args_json);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", calls[1].args_json);
    // The ledger still records the fact, torn bytes and all.
    try std.testing.expectEqualStrings("{\"path\":\"a.t", l.view()[1].assistant.calls[0].args_json);

    // The substitution is scoped to a truncated turn: the same torn bytes on a
    // turn the model finished are the model's own output and stay verbatim.
    var whole = ledger.Ledger.init(alloc);
    defer whole.deinit();
    try whole.append(.{ .assistant = .{
        .text = "",
        .calls = &.{.{ .id = "c1", .tool = "edit", .args_json = "{\"path\":\"a.t" }},
        .stop_reason = .tool_use,
    } });
    const q = try project(alloc, whole.view());
    defer q.deinit(alloc);
    try std.testing.expectEqualStrings("{\"path\":\"a.t", q.turns[0].assistant.calls[0].args_json);
}

test "a user turn's images are projected, and a turn carrying them still extends the prefix" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = .{
        .text = "what is this",
        .images = &.{.{ .media_type = "image/png", .data = "iVBORw0=" }},
    } });
    const before = try project(alloc, l.view());
    defer before.deinit(alloc);

    // Model-visible, so unlike `usage` it HAS a field here — and it is the
    // ledger's own bytes, not a copy.
    const shot = before.turns[0].user_text;
    try std.testing.expectEqualStrings("what is this", shot.text);
    try std.testing.expectEqual(@as(usize, 1), shot.images.len);
    try std.testing.expectEqualStrings("image/png", shot.images[0].media_type);
    try std.testing.expectEqualStrings("iVBORw0=", shot.images[0].data);
    try std.testing.expectEqual(l.view()[0].user_text.images.ptr, shot.images.ptr);

    // Appending after an image turn leaves the image turn where it was: the
    // cached prefix survives a screenshot exactly as it survives text.
    try l.append(.{ .assistant = .{ .text = "a diagram", .calls = &.{} } });
    const after = try project(alloc, l.view());
    defer after.deinit(alloc);
    try std.testing.expect(isStablePrefix(before.turns, after.turns));

    // …and the comparison really looks at the images: the same text with a
    // different picture is a different turn, not a prefix.
    var other = ledger.Ledger.init(alloc);
    defer other.deinit();
    try other.append(.{ .user_text = .{
        .text = "what is this",
        .images = &.{.{ .media_type = "image/png", .data = "OTHER===" }},
    } });
    const q = try project(alloc, other.view());
    defer q.deinit(alloc);
    try std.testing.expect(!isStablePrefix(q.turns, after.turns));

    // Dropping the image is likewise a different turn.
    var plain = ledger.Ledger.init(alloc);
    defer plain.deinit();
    try plain.append(.{ .user_text = .{ .text = "what is this" } });
    const r = try project(alloc, plain.view());
    defer r.deinit(alloc);
    try std.testing.expect(!isStablePrefix(r.turns, after.turns));
}

test "a note appends one turn carrying only its text, whatever its source" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = .{ .text = "build it" } });
    const before = try project(alloc, l.view());
    defer before.deinit(alloc);

    const report = "[background task s-1/t3 finished] zig build test · exit 0 · 41.8s\n--- output tail ---\nok\n--- end of output ---";
    try l.append(.{ .note = .{
        .source = ledger.note_source_task,
        .text = report,
        .meta = "{\"task\":\"s-1/t3\",\"exit_code\":0}",
    } });
    try l.append(.{ .note = .{
        .source = ledger.note_source_ext,
        .text = "New capability available: `greet`.",
        .meta = "{\"id\":\"demo\",\"version\":\"v-aaaa\"}",
    } });
    const after = try project(alloc, l.view());
    defer after.deinit(alloc);

    // Just two more appended turns: the cached prefix is untouched.
    try std.testing.expect(isStablePrefix(before.turns, after.turns));
    try std.testing.expectEqual(before.turns.len + 2, after.turns.len);
    // `source` and `meta` have no field in `Turn`, so the two sources project
    // into the same shape and only the text crosses.
    try std.testing.expectEqualStrings(report, after.turns[after.turns.len - 2].note);
    try std.testing.expectEqualStrings("New capability available: `greet`.", after.turns[after.turns.len - 1].note);
}

test "reopening a durable ledger projects a turn-identical prefix" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a couple of turns, project the tail, then close.
    var before_turns: usize = 0;
    {
        var l = try ledger.createDurable(alloc, io, tmp.dir, "s.jsonl", .{ .session = "s" });
        defer l.deinit();
        try l.append(.{ .user_text = .{ .text = "first" } });
        try l.append(.{ .assistant = .{
            .text = "run",
            .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo hi\"}" }},
        } });
        try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "hi" }} });
        const p = try project(alloc, l.view());
        defer p.deinit(alloc);
        before_turns = p.turns.len;
    }

    // A separate process reopening the file projects the same prefix, then
    // extends it by appending — the cache invariant survives resume.
    var reopened = try ledger.openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer reopened.deinit();
    const before = try project(alloc, reopened.view());
    defer before.deinit(alloc);
    try std.testing.expectEqual(before_turns, before.turns.len);

    try reopened.append(.{ .user_text = .{ .text = "second" } });
    const after = try project(alloc, reopened.view());
    defer after.deinit(alloc);
    try std.testing.expect(isStablePrefix(before.turns, after.turns));
}

test "a session written before note existed resumes and projects the identical turns" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two files, same conversation: one in the kinds a build before the merge
    // wrote, one in the kind every build writes now.
    {
        var l = try ledger.createDurable(alloc, io, tmp.dir, "new.jsonl", .{ .session = "s" });
        defer l.deinit();
        try l.append(.{ .user_text = .{ .text = "build it" } });
        try l.append(.{ .note = .{
            .source = ledger.note_source_ext,
            .text = "New capabilities from extension `demo`",
            .meta = "{\"id\":\"demo\",\"version\":\"v-aaaa\"}",
        } });
        try l.append(.{ .note = .{
            .source = ledger.note_source_task,
            .text = "[background task s/t1 finished] zig build test · exit 0",
            .meta = "{\"task\":\"s/t1\",\"exit_code\":0}",
        } });
    }
    {
        // The header is the current writer's; only the EVENT lines are old.
        var l = try ledger.createDurable(alloc, io, tmp.dir, "old.jsonl", .{ .session = "s" });
        l.deinit();
        var f = try tmp.dir.openFile(io, "old.jsonl", .{ .mode = .read_write });
        defer f.close(io);
        const lines =
            \\{"seq":1,"kind":"user_text","text":"build it"}
            \\{"seq":2,"kind":"capability_note","id":"demo","version":"v-aaaa","text":"New capabilities from extension `demo`"}
            \\{"seq":3,"kind":"task_finished","task":"s/t1","exit_code":0,"text":"[background task s/t1 finished] zig build test · exit 0"}
            \\
        ;
        try f.writePositionalAll(io, lines, (try f.stat(io)).size);
    }

    var fresh = try ledger.openDurable(alloc, io, tmp.dir, "new.jsonl");
    defer fresh.deinit();
    var old = try ledger.openDurable(alloc, io, tmp.dir, "old.jsonl");
    defer old.deinit();

    const a = try project(alloc, fresh.view());
    defer a.deinit(alloc);
    const b = try project(alloc, old.view());
    defer b.deinit(alloc);
    // Turn for turn, both ways: neither is merely a prefix of the other.
    try std.testing.expect(isStablePrefix(a.turns, b.turns));
    try std.testing.expect(isStablePrefix(b.turns, a.turns));
}

test "PromptIR carries immutable system blocks separately from ledger turns" {
    const alloc = std.testing.allocator;
    const sys = [_]SystemBlock{.{ .source = "test:system", .bytes = "base system" }};
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = .{ .text = "first" } });
    const before = try projectWithSystem(alloc, &sys, l.view());
    defer before.deinit(alloc);

    try l.append(.{ .assistant = .{ .text = "ok", .calls = &.{} } });
    const after = try projectWithSystem(alloc, &sys, l.view());
    defer after.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), before.system_blocks.len);
    try std.testing.expectEqual(@as(usize, 1), after.system_blocks.len);
    try std.testing.expectEqualStrings(before.system_blocks[0].source, after.system_blocks[0].source);
    try std.testing.expectEqualStrings(before.system_blocks[0].bytes, after.system_blocks[0].bytes);
    try std.testing.expect(isStablePrefix(before.turns, after.turns));
}
