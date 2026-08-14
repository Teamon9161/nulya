//! Provider-independent prompt projection (DESIGN §1, §13).
//!
//! The cache invariant is not about complete provider HTTP request bytes. The
//! kernel owns a stable logical projection first; providers serialize this IR
//! into their own cache mechanism.

const std = @import("std");
const ledger = @import("ledger.zig");

pub const BlockKind = enum {
    user_text,
    assistant_text,
    tool_call,
    tool_result,
};

pub const StableBlock = struct {
    kind: BlockKind,
    bytes: []const u8,
};

pub const PromptIR = struct {
    stable_blocks: []const StableBlock,

    pub fn deinit(self: PromptIR, alloc: std.mem.Allocator) void {
        for (self.stable_blocks) |block| alloc.free(block.bytes);
        alloc.free(self.stable_blocks);
    }
};

/// Current skeleton has no generation-changing event types yet. Keeping this as
/// a projection function prevents a second mutable copy of generation state from
/// living on `Ledger`; compaction/system/tool-selection events can extend it.
pub fn currentGeneration(events: []const ledger.Event) u64 {
    _ = events;
    return 0;
}

pub fn project(alloc: std.mem.Allocator, events: []const ledger.Event) !PromptIR {
    var blocks: std.ArrayList(StableBlock) = .empty;
    errdefer {
        for (blocks.items) |block| alloc.free(block.bytes);
        blocks.deinit(alloc);
    }

    for (events) |event| switch (event) {
        .user_text => |text| try appendBlock(alloc, &blocks, .user_text, text),
        .assistant => |as| {
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
    };

    return .{ .stable_blocks = try blocks.toOwnedSlice(alloc) };
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
    try std.testing.expectEqual(@as(u64, 0), currentGeneration(l.view()));
}
