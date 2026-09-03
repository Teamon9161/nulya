//! Provider/model boundary. The loop owns ledger append/order invariants; a
//! provider owns transport state, request serialization, cache breakpoint
//! placement and wire-format normalization for one configured model.

const std = @import("std");
const ledger = @import("ledger.zig");
const prompt = @import("prompt.zig");
const tool = @import("tool.zig");

/// What the loop and the projection must know about a provider: a provider that
/// cannot replay opaque reasoning items gets the `reasoning` block skipped.
pub const ProviderCapabilities = struct {
    thinking_replay: bool = false,
};

pub const Options = struct {
    max_output_tokens: ?u32 = null,
    effort: ?[]const u8 = null,
};

/// What one turn cost, as the ledger records it. `input_tokens` is NON-cached
/// input: providers whose counters include cached tokens must subtract first.
pub const Usage = ledger.Usage;

/// Why the model stopped, as the ledger records it.
pub const StopReason = ledger.StopReason;

/// How the loop treats a wire that fails or falls silent. A provider makes ONE
/// attempt per `stream` and reports a transient fault as one of the errors
/// `isTransient` names; the loop owns the retry. Backoff before the n-th retry
/// is `initial · 2^(n-1)`, capped at `max`.
pub const RetryPolicy = struct {
    max_retries: u32 = 5,
    initial_backoff_ms: u64 = 1_000,
    max_backoff_ms: u64 = 30_000,
    /// How long the server may send nothing at all before the request counts as
    /// stalled (a `Transport` fault, retried like one). Any line, keepalives
    /// included, resets it. 0 disables.
    stall_timeout_ms: u64 = 120_000,

    pub fn backoffMs(self: RetryPolicy, attempt: u32) u64 {
        const shift: u6 = @intCast(@min(attempt -| 1, 20));
        return @min(self.initial_backoff_ms *| (@as(u64, 1) << shift), self.max_backoff_ms);
    }
};

/// The faults an identical request may cure: the connection failed, the body
/// ended before the stream's own terminator, or the server said 429 / 5xx.
/// Anything else fails the step at once.
pub fn isTransient(err: anyerror) bool {
    return switch (err) {
        error.Transport, error.StreamEndedEarly, error.RateLimited, error.ServerError => true,
        else => false,
    };
}

pub const ToolUseStart = struct {
    index: usize,
    id: []const u8,
    name: []const u8,
};

pub const ToolUseInputDelta = struct {
    index: usize,
    fragment: []const u8,
};

/// Streaming providers normalize their wire events to this shape.
pub const StreamEvent = union(enum) {
    started,
    text_delta: []const u8,
    /// Human-readable reasoning text as it streams. Display only: the collector
    /// does not keep it, and it is never replayed.
    thinking_delta: []const u8,
    /// One COMPLETE reasoning item, as one JSON value in the provider's own wire
    /// shape, emitted once whole. The collector keeps every item verbatim so the
    /// turn's reasoning can be replayed to the same model. Opaque to the kernel.
    reasoning_item: []const u8,
    tool_use_start: ToolUseStart,
    tool_use_input_delta: ToolUseInputDelta,
    usage: Usage,
    done: StopReason,
};

pub const EventSink = struct {
    ptr: *anyopaque,
    emitFn: *const fn (ptr: *anyopaque, event: StreamEvent) anyerror!void,

    pub fn emit(self: EventSink, event: StreamEvent) !void {
        return self.emitFn(self.ptr, event);
    }
};

/// Provider-neutral model request. The provider may serialize these fields in
/// any wire shape, but it must not mutate or retain borrowed slices past `stream`.
pub const Request = struct {
    prompt_ir: *const prompt.PromptIR,
    tools: []const tool.ToolDefinition,
    options: Options = .{},
    /// Transport, not a generation option: the silence budget a wire provider
    /// hands to its stall watchdog; 0 = no watchdog.
    stall_ms: u64 = 0,
};

/// One fully assembled assistant turn. All slices are owned by the caller's
/// allocator; `deinit` releases them after the ledger has cloned the event.
pub const ModelTurn = struct {
    /// The turn's reasoning items as one JSON array of opaque provider values,
    /// in emission order; `""` when the model produced none. Stored on the
    /// ledger as-is and handed back by the projection so it can replay them.
    reasoning: []const u8,
    text: []const u8,
    calls: []const ledger.ToolCall,
    /// Token accounting for this turn. Carries the cache-read counter so the loop
    /// can MEASURE the cache-generation invariant. No owned allocations.
    usage: Usage = .{},
    /// Why the model stopped. `tool_use` vs `end_turn` drive the loop;
    /// `max_tokens` says the turn was truncated mid-thought.
    stop_reason: StopReason = .end_turn,

    pub fn deinit(self: ModelTurn, alloc: std.mem.Allocator) void {
        alloc.free(self.reasoning);
        alloc.free(self.text);
        for (self.calls) |call| {
            alloc.free(call.id);
            alloc.free(call.tool);
            alloc.free(call.args_json);
        }
        alloc.free(self.calls);
    }
};

pub const Model = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        modelName: *const fn (ptr: *anyopaque) []const u8,
        capabilities: *const fn (ptr: *anyopaque) ProviderCapabilities,
        stream: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, request: Request, sink: EventSink) anyerror!void,
    };

    pub fn name(self: Model) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn modelName(self: Model) []const u8 {
        return self.vtable.modelName(self.ptr);
    }

    pub fn capabilities(self: Model) ProviderCapabilities {
        return self.vtable.capabilities(self.ptr);
    }

    pub fn stream(self: Model, alloc: std.mem.Allocator, request: Request, sink: EventSink) !void {
        return self.vtable.stream(self.ptr, alloc, request, sink);
    }
};

const ToolCallDraft = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    args: std.Io.Writer.Allocating,

    fn init(alloc: std.mem.Allocator) ToolCallDraft {
        return .{ .args = .init(alloc) };
    }

    fn deinit(self: *ToolCallDraft, alloc: std.mem.Allocator) void {
        if (self.id) |id| alloc.free(id);
        if (self.name) |name| alloc.free(name);
        self.args.deinit();
        self.* = undefined;
    }

    fn hasData(self: *ToolCallDraft) bool {
        return self.id != null or self.name != null or self.args.written().len != 0;
    }

    fn setStart(self: *ToolCallDraft, alloc: std.mem.Allocator, start: ToolUseStart) !void {
        if (start.id.len != 0) {
            const owned = try alloc.dupe(u8, start.id);
            if (self.id) |old| alloc.free(old);
            self.id = owned;
        }
        if (start.name.len != 0) {
            const owned = try alloc.dupe(u8, start.name);
            if (self.name) |old| alloc.free(old);
            self.name = owned;
        }
    }

    fn appendArgs(self: *ToolCallDraft, fragment: []const u8) !void {
        try self.args.writer.writeAll(fragment);
    }

    fn take(self: *ToolCallDraft, alloc: std.mem.Allocator) !ledger.ToolCall {
        const id = if (self.id) |id| blk: {
            self.id = null;
            break :blk id;
        } else try alloc.dupe(u8, "");
        errdefer alloc.free(id);

        const name = if (self.name) |name| blk: {
            self.name = null;
            break :blk name;
        } else try alloc.dupe(u8, "");
        errdefer alloc.free(name);

        const args_json = if (self.args.written().len == 0)
            try alloc.dupe(u8, "{}")
        else
            try self.args.toOwnedSlice();
        errdefer alloc.free(args_json);

        return .{ .id = id, .tool = name, .args_json = args_json };
    }
};

pub const TurnCollector = struct {
    alloc: std.mem.Allocator,
    text: std.Io.Writer.Allocating,
    /// Complete reasoning items, verbatim, in emission order.
    reasoning: std.ArrayList([]u8) = .empty,
    calls: std.ArrayList(ToolCallDraft) = .empty,
    usage: Usage = .{},
    done: ?StopReason = null,

    pub fn init(alloc: std.mem.Allocator) TurnCollector {
        return .{ .alloc = alloc, .text = .init(alloc) };
    }

    pub fn deinit(self: *TurnCollector) void {
        self.text.deinit();
        for (self.reasoning.items) |item| self.alloc.free(item);
        self.reasoning.deinit(self.alloc);
        for (self.calls.items) |*draft| draft.deinit(self.alloc);
        self.calls.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn sink(self: *TurnCollector) EventSink {
        return .{ .ptr = self, .emitFn = emitToCollector };
    }

    fn emitToCollector(ptr: *anyopaque, event: StreamEvent) anyerror!void {
        const self: *TurnCollector = @ptrCast(@alignCast(ptr));
        return self.onEvent(event);
    }

    pub fn onEvent(self: *TurnCollector, event: StreamEvent) !void {
        switch (event) {
            .started => {},
            .text_delta => |delta| try self.text.writer.writeAll(delta),
            .thinking_delta => {},
            .reasoning_item => |item| {
                const owned = try self.alloc.dupe(u8, item);
                errdefer self.alloc.free(owned);
                try self.reasoning.append(self.alloc, owned);
            },
            .usage => |usage| self.usage = usage,
            .done => |reason| self.done = reason,
            .tool_use_start => |start| {
                const draft = try self.ensureTool(start.index);
                try draft.setStart(self.alloc, start);
            },
            .tool_use_input_delta => |delta| {
                const draft = try self.ensureTool(delta.index);
                try draft.appendArgs(delta.fragment);
            },
        }
    }

    fn ensureTool(self: *TurnCollector, index: usize) !*ToolCallDraft {
        while (self.calls.items.len <= index) {
            try self.calls.append(self.alloc, ToolCallDraft.init(self.alloc));
        }
        return &self.calls.items[index];
    }

    pub fn finish(self: *TurnCollector) !ModelTurn {
        const reasoning = try joinReasoning(self.alloc, self.reasoning.items);
        errdefer self.alloc.free(reasoning);

        const text = if (self.text.written().len == 0)
            try self.alloc.dupe(u8, "")
        else
            try self.text.toOwnedSlice();
        errdefer self.alloc.free(text);

        var count: usize = 0;
        for (self.calls.items) |*draft| {
            if (draft.hasData()) count += 1;
        }

        const calls = try self.alloc.alloc(ledger.ToolCall, count);
        errdefer self.alloc.free(calls);
        var initialized: usize = 0;
        errdefer {
            for (calls[0..initialized]) |call| {
                self.alloc.free(call.id);
                self.alloc.free(call.tool);
                self.alloc.free(call.args_json);
            }
        }

        for (self.calls.items) |*draft| {
            if (!draft.hasData()) continue;
            calls[initialized] = try draft.take(self.alloc);
            initialized += 1;
        }

        return .{
            .reasoning = reasoning,
            .text = text,
            .calls = calls,
            .usage = self.usage,
            .stop_reason = self.done orelse .end_turn,
        };
    }
};

/// `[item,item,…]` from already-serialized JSON values, or `""` for none. Items
/// are spliced, not re-encoded, so a provider gets back exactly its own bytes.
fn joinReasoning(alloc: std.mem.Allocator, items: []const []u8) ![]u8 {
    if (items.len == 0) return alloc.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try out.writer.writeByte(',');
        try out.writer.writeAll(item);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

pub fn cloneToolCall(
    alloc: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    args_json: []const u8,
) !ledger.ToolCall {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_args = try alloc.dupe(u8, args_json);
    errdefer alloc.free(owned_args);
    return .{ .id = owned_id, .tool = owned_name, .args_json = owned_args };
}

test "retry backoff doubles from initial and is capped" {
    const p: RetryPolicy = .{ .initial_backoff_ms = 1000, .max_backoff_ms = 5000 };
    try std.testing.expectEqual(@as(u64, 1000), p.backoffMs(1));
    try std.testing.expectEqual(@as(u64, 2000), p.backoffMs(2));
    try std.testing.expectEqual(@as(u64, 4000), p.backoffMs(3));
    try std.testing.expectEqual(@as(u64, 5000), p.backoffMs(4));
    try std.testing.expectEqual(@as(u64, 5000), p.backoffMs(200)); // no overflow past the cap
    try std.testing.expect(isTransient(error.Transport));
    try std.testing.expect(isTransient(error.RateLimited));
    try std.testing.expect(!isTransient(error.ApiError));
    try std.testing.expect(!isTransient(error.Canceled));
}

test "model stream is collected into owned turn" {
    const Fake = struct {
        streamed: bool = false,

        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "fake";
        }

        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "fake-model";
        }

        fn capabilities(ptr: *anyopaque) ProviderCapabilities {
            _ = ptr;
            return .{ .thinking_replay = true };
        }

        fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: Request, sink: EventSink) anyerror!void {
            _ = alloc;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.streamed = true;
            try std.testing.expectEqual(@as(usize, 1), request.prompt_ir.turns.len);
            try std.testing.expectEqual(@as(usize, 0), request.tools.len);
            try sink.emit(.started);
            try sink.emit(.{ .thinking_delta = "hmm" });
            try sink.emit(.{ .reasoning_item = "{\"type\":\"thinking\",\"thinking\":\"hmm\",\"signature\":\"sig\"}" });
            try sink.emit(.{ .reasoning_item = "{\"type\":\"redacted_thinking\",\"data\":\"xx\"}" });
            try sink.emit(.{ .text_delta = "o" });
            try sink.emit(.{ .text_delta = "k" });
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "\"echo hi\"}" } });
            try sink.emit(.{ .usage = .{ .input_tokens = 12, .cache_read_tokens = 7 } });
            try sink.emit(.{ .done = .tool_use });
        }

        const vtable: Model.VTable = .{
            .name = name,
            .modelName = modelName,
            .capabilities = capabilities,
            .stream = stream,
        };
    };

    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });

    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);

    var fake = Fake{};
    const model: Model = .{ .ptr = &fake, .vtable = &Fake.vtable };
    try std.testing.expectEqualStrings("fake", model.name());
    try std.testing.expect(model.capabilities().thinking_replay);

    var collector = TurnCollector.init(alloc);
    defer collector.deinit();
    try model.stream(alloc, .{ .prompt_ir = &ir, .tools = &.{} }, collector.sink());
    const turn = try collector.finish();
    defer turn.deinit(alloc);

    try std.testing.expect(fake.streamed);
    try std.testing.expectEqualStrings(
        "[{\"type\":\"thinking\",\"thinking\":\"hmm\",\"signature\":\"sig\"},{\"type\":\"redacted_thinking\",\"data\":\"xx\"}]",
        turn.reasoning,
    );
    try std.testing.expectEqualStrings("ok", turn.text);
    try std.testing.expectEqual(@as(usize, 1), turn.calls.len);
    try std.testing.expectEqualStrings("c1", turn.calls[0].id);
    try std.testing.expectEqualStrings("shell", turn.calls[0].tool);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", turn.calls[0].args_json);
    try std.testing.expectEqual(@as(u64, 7), turn.usage.cache_read_tokens);
    try std.testing.expectEqual(StopReason.tool_use, turn.stop_reason);
}
