//! Provider-independent prompt projection (DESIGN §1, §13).
//!
//! The cache invariant is not about complete provider HTTP request bytes. The
//! kernel owns a stable logical projection first; providers serialize this IR
//! into their own cache mechanism.

const std = @import("std");
const ledger = @import("ledger.zig");

/// Upper bound for one static system prompt contribution. Shared by the
/// extension build-time check and session composition so a built version is
/// always consumable.
pub const max_system_prompt_bytes: usize = 2 * 1024 * 1024;

pub const BlockKind = enum {
    user_text,
    /// An assistant turn's opaque reasoning items (`ledger.Event.assistant
    /// .reasoning`, verbatim). Always emitted BEFORE that turn's `assistant_text`
    /// / `tool_call` blocks — every wire that replays reasoning wants it ahead
    /// of the visible output — and only when non-empty. Providers that cannot
    /// replay it (`thinking_replay == false`) skip the block; the kernel never
    /// reads inside.
    reasoning,
    assistant_text,
    tool_call,
    tool_result,
    /// A mid-conversation capability announcement (DESIGN §5.3). Just another
    /// appended block, so it extends the stable prefix without bumping the
    /// generation — the cache keeps hitting.
    capability_note,
};

pub const StableBlock = struct {
    kind: BlockKind,
    bytes: []const u8,
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
    stable_blocks: []const StableBlock,

    pub fn deinit(self: PromptIR, alloc: std.mem.Allocator) void {
        for (self.stable_blocks) |block| alloc.free(block.bytes);
        alloc.free(self.stable_blocks);
    }
};

pub fn project(alloc: std.mem.Allocator, events: []const ledger.Event) !PromptIR {
    return projectWithSystem(alloc, &.{}, events);
}

pub fn projectWithSystem(alloc: std.mem.Allocator, system_blocks: []const SystemBlock, events: []const ledger.Event) !PromptIR {
    var blocks: std.ArrayList(StableBlock) = .empty;
    errdefer {
        for (blocks.items) |block| alloc.free(block.bytes);
        blocks.deinit(alloc);
    }

    for (events) |event| switch (event) {
        .user_text => |text| try appendBlock(alloc, &blocks, .user_text, text),
        .assistant => |as| {
            if (as.reasoning.len != 0) try appendBlock(alloc, &blocks, .reasoning, as.reasoning);
            try appendBlock(alloc, &blocks, .assistant_text, as.text);
            for (as.calls) |call| {
                const bytes = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ call.id, call.tool, call.args_json });
                errdefer alloc.free(bytes);
                try blocks.append(alloc, .{ .kind = .tool_call, .bytes = bytes });
            }
        },
        .tool_results => |results| {
            for (results) |result| {
                const bytes = try std.fmt.allocPrint(alloc, "{s}\n{}\n{s}", .{ result.call_id, result.ok, result.output });
                errdefer alloc.free(bytes);
                try blocks.append(alloc, .{ .kind = .tool_result, .bytes = bytes });
            }
        },
        .capability_note => |note| try appendBlock(alloc, &blocks, .capability_note, note.text),
    };

    const stable_slice = try blocks.toOwnedSlice(alloc);
    return .{ .system_blocks = system_blocks, .stable_blocks = stable_slice };
}

fn appendBlock(
    alloc: std.mem.Allocator,
    blocks: *std.ArrayList(StableBlock),
    kind: BlockKind,
    bytes: []const u8,
) !void {
    const owned = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned);
    try blocks.append(alloc, .{ .kind = kind, .bytes = owned });
}

pub fn isStablePrefix(prefix: []const StableBlock, full: []const StableBlock) bool {
    if (prefix.len > full.len) return false;
    for (prefix, full[0..prefix.len]) |a, b| {
        if (a.kind != b.kind) return false;
        if (!std.mem.eql(u8, a.bytes, b.bytes)) return false;
    }
    return true;
}

test "PromptIR stable blocks extend by prefix on append" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = "first" });
    const p1 = try project(alloc, l.view());
    defer p1.deinit(alloc);

    try l.append(.{ .assistant = .{ .text = "ok", .calls = &.{} } });
    const p2 = try project(alloc, l.view());
    defer p2.deinit(alloc);

    try std.testing.expect(isStablePrefix(p1.stable_blocks, p2.stable_blocks));
}

test "assistant reasoning projects as one opaque block ahead of the turn's text and calls" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = "hi" });
    try l.append(.{ .assistant = .{ .text = "plain", .calls = &.{} } });
    try l.append(.{ .user_text = "go" });
    try l.append(.{ .assistant = .{
        .reasoning = "[{\"type\":\"reasoning\",\"encrypted_content\":\"…\"}]",
        .text = "",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{}" }},
    } });
    const p = try project(alloc, l.view());
    defer p.deinit(alloc);

    // No reasoning → no block (a pre-reasoning ledger projects exactly as before).
    try std.testing.expectEqual(BlockKind.user_text, p.stable_blocks[0].kind);
    try std.testing.expectEqual(BlockKind.assistant_text, p.stable_blocks[1].kind);
    try std.testing.expectEqual(BlockKind.user_text, p.stable_blocks[2].kind);
    // With reasoning: reasoning, then text, then calls — verbatim bytes.
    try std.testing.expectEqual(BlockKind.reasoning, p.stable_blocks[3].kind);
    try std.testing.expectEqualStrings("[{\"type\":\"reasoning\",\"encrypted_content\":\"…\"}]", p.stable_blocks[3].bytes);
    try std.testing.expectEqual(BlockKind.assistant_text, p.stable_blocks[4].kind);
    try std.testing.expectEqual(BlockKind.tool_call, p.stable_blocks[5].kind);
    try std.testing.expectEqual(@as(usize, 6), p.stable_blocks.len);
}

test "a capability_note appends a capability_note block without breaking the prefix or generation" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = "hi" });
    const before = try project(alloc, l.view());
    defer before.deinit(alloc);

    try l.append(.{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "New capability available: `greet`." } });
    const after = try project(alloc, l.view());
    defer after.deinit(alloc);

    // Prefix-stable: the note only extends the projection (DESIGN §5.3, §1).
    try std.testing.expect(isStablePrefix(before.stable_blocks, after.stable_blocks));
    try std.testing.expectEqual(before.stable_blocks.len + 1, after.stable_blocks.len);
    const last = after.stable_blocks[after.stable_blocks.len - 1];
    try std.testing.expectEqual(BlockKind.capability_note, last.kind);
}

test "reopening a durable ledger projects a block-identical prefix" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a couple of turns, project the tail, then close.
    var before_blocks: usize = 0;
    {
        var l = try ledger.createDurable(alloc, io, tmp.dir, "s.jsonl", .{ .session = "s" });
        defer l.deinit();
        try l.append(.{ .user_text = "first" });
        try l.append(.{ .assistant = .{
            .text = "run",
            .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo hi\"}" }},
        } });
        try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "hi" }} });
        const p = try project(alloc, l.view());
        defer p.deinit(alloc);
        before_blocks = p.stable_blocks.len;
    }

    // A separate process reopening the file projects the same prefix, then
    // extends it by appending — the cache invariant survives resume.
    var reopened = try ledger.openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer reopened.deinit();
    const before = try project(alloc, reopened.view());
    defer before.deinit(alloc);
    try std.testing.expectEqual(before_blocks, before.stable_blocks.len);

    try reopened.append(.{ .user_text = "second" });
    const after = try project(alloc, reopened.view());
    defer after.deinit(alloc);
    try std.testing.expect(isStablePrefix(before.stable_blocks, after.stable_blocks));
}

test "PromptIR carries immutable system blocks separately from ledger stable blocks" {
    const alloc = std.testing.allocator;
    const sys = [_]SystemBlock{.{ .source = "test:system", .bytes = "base system" }};
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try l.append(.{ .user_text = "first" });
    const before = try projectWithSystem(alloc, &sys, l.view());
    defer before.deinit(alloc);

    try l.append(.{ .assistant = .{ .text = "ok", .calls = &.{} } });
    const after = try projectWithSystem(alloc, &sys, l.view());
    defer after.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), before.system_blocks.len);
    try std.testing.expectEqual(@as(usize, 1), after.system_blocks.len);
    try std.testing.expectEqualStrings(before.system_blocks[0].source, after.system_blocks[0].source);
    try std.testing.expectEqualStrings(before.system_blocks[0].bytes, after.system_blocks[0].bytes);
    try std.testing.expect(isStablePrefix(before.stable_blocks, after.stable_blocks));
}
