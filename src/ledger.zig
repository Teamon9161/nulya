//! The immutable conversation ledger (DESIGN §1, §3).
//!
//! The ledger is append-only. Its ENTIRE mutable API is `append`. Reads hand
//! back a const view. There is deliberately no edit / delete / reorder: a
//! correction is a new appended event, never an in-place change. This is what
//! lets the PromptIR stable-block prefix stay stable within a cache generation,
//! which is what keeps the prompt cache hitting (DESIGN §1).

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
/// full set (capability_note, registry_selection, compaction, …).
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
    /// A capability that became available mid-conversation (DESIGN §5.3). It is
    /// an APPEND, never a change to `tools[]`: the prompt prefix stays stable so
    /// the cache keeps hitting, and the model can invoke the new extension via
    /// `shell` on its next step. `text` is the model-facing announcement; `id` and
    /// `version` are structured so reconciliation never parses presentation text.
    capability_note: struct {
        id: []const u8,
        version: []const u8,
        text: []const u8,
    },
};

pub const Ledger = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(Event),

    pub fn init(alloc: std.mem.Allocator) Ledger {
        return .{ .alloc = alloc, .events = .empty };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.events.items) |e| freeEvent(self.alloc, e);
        self.events.deinit(self.alloc);
    }

    /// The only mutation. Appends one event to the end. No other write exists.
    ///
    /// `append` takes a snapshot of the event payload. Callers may free, reset,
    /// or reuse every slice passed in after this returns successfully; ledger
    /// history remains stable because all nested bytes are ledger-owned.
    pub fn append(self: *Ledger, e: Event) !void {
        const owned = try cloneEvent(self.alloc, e);
        errdefer freeEvent(self.alloc, owned);
        try self.events.append(self.alloc, owned);
    }

    /// Read-only view. Callers get a const slice; they cannot mutate history.
    pub fn view(self: *const Ledger) []const Event {
        return self.events.items;
    }

    pub fn len(self: *const Ledger) usize {
        return self.events.items.len;
    }
};

fn cloneEvent(alloc: std.mem.Allocator, e: Event) !Event {
    return switch (e) {
        .user_text => |text| .{ .user_text = try alloc.dupe(u8, text) },
        .assistant => |as| blk: {
            const text = try alloc.dupe(u8, as.text);
            errdefer alloc.free(text);
            const calls = try cloneToolCalls(alloc, as.calls);
            errdefer freeToolCalls(alloc, calls);
            break :blk .{ .assistant = .{ .text = text, .calls = calls } };
        },
        .tool_results => |results| .{ .tool_results = try cloneToolResults(alloc, results) },
        .capability_note => |note| blk: {
            const id = try alloc.dupe(u8, note.id);
            errdefer alloc.free(id);
            const version = try alloc.dupe(u8, note.version);
            errdefer alloc.free(version);
            const text = try alloc.dupe(u8, note.text);
            break :blk .{ .capability_note = .{ .id = id, .version = version, .text = text } };
        },
    };
}

fn freeEvent(alloc: std.mem.Allocator, e: Event) void {
    switch (e) {
        .user_text => |text| alloc.free(text),
        .assistant => |as| {
            alloc.free(as.text);
            freeToolCalls(alloc, as.calls);
        },
        .tool_results => |results| freeToolResults(alloc, results),
        .capability_note => |note| {
            alloc.free(note.id);
            alloc.free(note.version);
            alloc.free(note.text);
        },
    }
}

fn cloneToolCalls(alloc: std.mem.Allocator, calls: []const ToolCall) ![]const ToolCall {
    const owned = try alloc.alloc(ToolCall, calls.len);
    errdefer alloc.free(owned);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |call| freeToolCall(alloc, call);
    }

    for (calls, 0..) |call, i| {
        owned[i] = .{
            .id = try alloc.dupe(u8, call.id),
            .tool = &.{},
            .args_json = &.{},
        };
        errdefer alloc.free(owned[i].id);
        owned[i].tool = try alloc.dupe(u8, call.tool);
        errdefer alloc.free(owned[i].tool);
        owned[i].args_json = try alloc.dupe(u8, call.args_json);
        initialized += 1;
    }
    return owned;
}

fn freeToolCalls(alloc: std.mem.Allocator, calls: []const ToolCall) void {
    for (calls) |call| freeToolCall(alloc, call);
    alloc.free(calls);
}

fn freeToolCall(alloc: std.mem.Allocator, call: ToolCall) void {
    alloc.free(call.id);
    alloc.free(call.tool);
    alloc.free(call.args_json);
}

fn cloneToolResults(alloc: std.mem.Allocator, results: []const ToolResultEntry) ![]const ToolResultEntry {
    const owned = try alloc.alloc(ToolResultEntry, results.len);
    errdefer alloc.free(owned);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |result| freeToolResult(alloc, result);
    }

    for (results, 0..) |result, i| {
        owned[i] = .{
            .call_id = try alloc.dupe(u8, result.call_id),
            .ok = result.ok,
            .output = &.{},
            .spill_path = null,
        };
        errdefer alloc.free(owned[i].call_id);
        owned[i].output = try alloc.dupe(u8, result.output);
        errdefer alloc.free(owned[i].output);
        if (result.spill_path) |path| owned[i].spill_path = try alloc.dupe(u8, path);
        initialized += 1;
    }
    return owned;
}

fn freeToolResults(alloc: std.mem.Allocator, results: []const ToolResultEntry) void {
    for (results) |result| freeToolResult(alloc, result);
    alloc.free(results);
}

fn freeToolResult(alloc: std.mem.Allocator, result: ToolResultEntry) void {
    alloc.free(result.call_id);
    alloc.free(result.output);
    if (result.spill_path) |path| alloc.free(path);
}

test "ledger only grows and preserves order" {
    var l = Ledger.init(std.testing.allocator);
    defer l.deinit();
    try l.append(.{ .user_text = "a" });
    try l.append(.{ .user_text = "b" });
    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expectEqualStrings("a", l.view()[0].user_text);
    try std.testing.expectEqualStrings("b", l.view()[1].user_text);
}
