//! The immutable conversation ledger (DESIGN §1, §3).
//!
//! The ledger is append-only. Its ENTIRE mutable API is `append`. Reads hand
//! back a const view. There is deliberately no edit / delete / reorder: a
//! correction is a new appended event, never an in-place change. This is what
//! lets the request byte-prefix stay stable within a cache generation, which is
//! what keeps the prompt cache hitting (DESIGN §1).

const std = @import("std");

/// A tool call requested by the assistant within one step.
pub const ToolCall = struct {
    id: []const u8,
    tool: []const u8,
    /// Raw JSON args string (the exact bytes the model produced).
    args_json: []const u8,
};

/// One tool's result inside a batched result turn.
pub const ToolResultEntry = struct {
    call_id: []const u8,
    ok: bool,
    output: []const u8,
    spill_path: ?[]const u8 = null,
};

/// The event log's alphabet. Kept minimal for the skeleton; DESIGN §3 lists the
/// full set (tool_available_note, registry_selection, compaction, …).
pub const Event = union(enum) {
    user_text: []const u8,
    assistant: struct {
        text: []const u8,
        /// Zero or more tool calls. Multiple calls in one assistant turn are the
        /// batch the loop executes together (DESIGN §0.2, §4).
        calls: []const ToolCall,
    },
    /// Exactly ONE user turn carrying every result from a batch. Never split
    /// per-tool — that would be one model round-trip per tool (DESIGN §0.2).
    tool_results: []const ToolResultEntry,
};

pub const Ledger = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(Event),
    /// Cache generation (DESIGN §1). Bumps only on tool-set / system change or
    /// compaction — never on a plain append. Wired here for later use.
    generation: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) Ledger {
        return .{ .alloc = alloc, .events = .empty };
    }

    pub fn deinit(self: *Ledger) void {
        self.events.deinit(self.alloc);
    }

    /// The only mutation. Appends one event to the end. No other write exists.
    pub fn append(self: *Ledger, e: Event) !void {
        try self.events.append(self.alloc, e);
    }

    /// Read-only view. Callers get a const slice; they cannot mutate history.
    pub fn view(self: *const Ledger) []const Event {
        return self.events.items;
    }

    pub fn len(self: *const Ledger) usize {
        return self.events.items.len;
    }
};

test "ledger only grows and preserves order" {
    var l = Ledger.init(std.testing.allocator);
    defer l.deinit();
    try l.append(.{ .user_text = "a" });
    try l.append(.{ .user_text = "b" });
    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expectEqualStrings("a", l.view()[0].user_text);
    try std.testing.expectEqualStrings("b", l.view()[1].user_text);
}
