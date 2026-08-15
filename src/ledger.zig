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
    /// When set, every appended event is also persisted as one JSONL line to the
    /// session file (DESIGN §3). A ledger created with `init` is pure memory (the
    /// test/in-process shape); `createDurable` / `openDurable` add the backend.
    durable: ?Durable = null,

    pub fn init(alloc: std.mem.Allocator) Ledger {
        return .{ .alloc = alloc, .events = .empty };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.events.items) |e| freeEvent(self.alloc, e);
        self.events.deinit(self.alloc);
        if (self.durable) |*d| d.deinit(self.alloc);
    }

    /// The only mutation. Appends one event to the end. No other write exists.
    ///
    /// `append` takes a snapshot of the event payload. Callers may free, reset,
    /// or reuse every slice passed in after this returns successfully; ledger
    /// history remains stable because all nested bytes are ledger-owned. When the
    /// ledger is durable, the event is persisted as one JSONL line before the call
    /// returns; a persistence failure rewinds the in-memory append so memory and
    /// file never diverge.
    pub fn append(self: *Ledger, e: Event) !void {
        const owned = try cloneEvent(self.alloc, e);
        errdefer freeEvent(self.alloc, owned);
        try self.events.append(self.alloc, owned);
        if (self.durable) |*d| {
            // seq is the 1-based file position; the just-appended event is at it.
            const seq: u64 = self.events.items.len;
            d.persist(self.alloc, e, seq) catch |err| {
                _ = self.events.pop(); // undo memory append; errdefer frees `owned`
                return err;
            };
        }
    }

    /// The frozen session header, when this ledger is backed by a session file.
    pub fn header(self: *const Ledger) ?Header {
        if (self.durable) |*d| return d.owned_header.value;
        return null;
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

// ── Durable session file (DESIGN §3) ───────────────────────────────────────
//
// A session is one JSONL file: line 1 is the frozen header, every later line is
// one `{"seq":n,...}` event. One file = one generation = one cache scope, so the
// PromptIR stable-block prefix invariant is a filesystem property (a file only
// grows). The header freezes the session composition (active extension versions
// + the native tool selection), so any process that reopens the file rebuilds
// the identical composition without re-scanning `current` or re-ranking usage.

/// A parent pointer for fork / compaction: the file and cut point a session
/// branched from. Absent for a root session.
pub const ParentRef = struct {
    session: []const u8,
    seq: u64,
};

/// One frozen active extension: which immutable version was pinned at session
/// start. Reopening reads this exact version, never the live `current`.
pub const PinnedExtensionRef = struct {
    id: []const u8,
    version: []const u8,
};

/// The session composition frozen into the header. `active` is every extension
/// pinned for the session; `native_tools` is the subset of stable tool ids
/// exposed directly to the model this session (DESIGN §5.1).
pub const FrozenComposition = struct {
    active: []const PinnedExtensionRef = &.{},
    native_tools: []const []const u8 = &.{},
    max_tools: u32 = 8,
};

/// The first line of a session file. Everything the model sees is a pure
/// function of this header plus the appended events.
pub const Header = struct {
    v: u32 = 1,
    session: []const u8,
    parent: ?ParentRef = null,
    model: []const u8 = "",
    created: []const u8 = "",
    composition: FrozenComposition = .{},
};

/// An owning copy of a parsed header (its own arena backs every nested slice).
pub const OwnedHeader = struct {
    arena: std.heap.ArenaAllocator,
    value: Header,

    pub fn deinit(self: *OwnedHeader) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const LedgerError = error{
    /// A complete (non-torn) line is not a valid header/event, or a `seq` is out
    /// of order. A torn final line (interrupted write) is tolerated, not this.
    CorruptLedger,
    /// The file's first line is not a `"kind":"header"` record.
    MissingHeader,
};

const Durable = struct {
    io: std.Io,
    file: std.Io.File,
    /// Byte offset where the next line is written (end of file).
    end: u64,
    owned_header: OwnedHeader,

    fn deinit(self: *Durable, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.owned_header.deinit();
        self.file.close(self.io);
    }

    fn persist(self: *Durable, alloc: std.mem.Allocator, e: Event, seq: u64) !void {
        const line = try encodeEventLine(alloc, e, seq);
        defer alloc.free(line);
        try self.file.writePositionalAll(self.io, line, self.end);
        self.end += line.len;
    }
};

/// Create a new session file at `path` (relative to `dir`), writing `header` as
/// line 1, and return a durable ledger with no events yet. The parent directory
/// must already exist. Fails if the file already exists.
pub fn createDurable(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, hdr: Header) !Ledger {
    const line = try encodeHeaderLine(alloc, hdr);
    defer alloc.free(line);

    var file = try dir.createFile(io, path, .{ .truncate = true, .read = true, .exclusive = true });
    errdefer file.close(io);
    try file.writePositionalAll(io, line, 0);

    var owned = try dupeHeader(alloc, hdr);
    errdefer owned.deinit();

    return .{
        .alloc = alloc,
        .events = .empty,
        .durable = .{ .io = io, .file = file, .end = line.len, .owned_header = owned },
    };
}

/// Reopen an existing session file: parse the header, replay every complete
/// event line into memory, and keep the file open for further appends. A torn
/// final line (an interrupted write) is dropped and the file truncated back to
/// the last complete line, so appends resume cleanly. An interrupted tool batch
/// (a complete assistant-with-calls line with no following results) is a legal
/// tail; the caller repairs it with `loop.completeInterruptedToolBatch`.
pub fn openDurable(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Ledger {
    const bytes = try dir.readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(bytes);

    const clean_end = lastCompleteLineEnd(bytes);

    // First complete line must be the header.
    var it = std.mem.splitScalar(u8, bytes[0..clean_end], '\n');
    const header_line = firstNonBlank(&it) orelse return error.MissingHeader;
    var owned = try parseHeaderLine(alloc, header_line);
    errdefer owned.deinit();

    var l = Ledger.init(alloc);
    errdefer l.deinit();

    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try replayEventLine(&l, line);
    }

    var file = try dir.createFile(io, path, .{ .truncate = false, .read = true });
    errdefer file.close(io);
    if (clean_end != bytes.len) try file.setLength(io, clean_end);

    l.durable = .{ .io = io, .file = file, .end = clean_end, .owned_header = owned };
    return l;
}

/// Absolute offset just past the last `\n` in `bytes` (a torn tail after it is
/// dropped). Equals `bytes.len` when the file ends with a newline.
fn lastCompleteLineEnd(bytes: []const u8) u64 {
    if (bytes.len == 0) return 0;
    if (bytes[bytes.len - 1] == '\n') return bytes.len;
    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '\n') return i + 1;
    }
    return 0;
}

fn firstNonBlank(it: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len != 0) return line;
    }
    return null;
}

/// Parse one event line and append it to `l` (in-memory only — the ledger is not
/// yet durable during replay). Validates that `seq` matches the position.
fn replayEventLine(l: *Ledger, line: []const u8) !void {
    const alloc = l.alloc;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return error.CorruptLedger;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.CorruptLedger,
    };

    const seq = switch (obj.get("seq") orelse return error.CorruptLedger) {
        .integer => |i| i,
        else => return error.CorruptLedger,
    };
    if (seq < 0 or @as(u64, @intCast(seq)) != l.events.items.len + 1) return error.CorruptLedger;

    const kind = jsonString(obj, "kind") orelse return error.CorruptLedger;
    if (std.mem.eql(u8, kind, "user_text")) {
        try l.append(.{ .user_text = jsonString(obj, "text") orelse return error.CorruptLedger });
    } else if (std.mem.eql(u8, kind, "assistant")) {
        const text = jsonString(obj, "text") orelse return error.CorruptLedger;
        const calls = try parseCalls(alloc, obj);
        defer alloc.free(calls);
        try l.append(.{ .assistant = .{ .text = text, .calls = calls } });
    } else if (std.mem.eql(u8, kind, "tool_results")) {
        const results = try parseResults(alloc, obj);
        defer alloc.free(results);
        try l.append(.{ .tool_results = results });
    } else if (std.mem.eql(u8, kind, "capability_note")) {
        try l.append(.{ .capability_note = .{
            .id = jsonString(obj, "id") orelse return error.CorruptLedger,
            .version = jsonString(obj, "version") orelse return error.CorruptLedger,
            .text = jsonString(obj, "text") orelse return error.CorruptLedger,
        } });
    } else return error.CorruptLedger;
}

fn parseCalls(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]ToolCall {
    const arr = switch (obj.get("calls") orelse return alloc.alloc(ToolCall, 0)) {
        .array => |a| a,
        else => return error.CorruptLedger,
    };
    const calls = try alloc.alloc(ToolCall, arr.items.len);
    errdefer alloc.free(calls);
    for (arr.items, 0..) |cv, i| {
        const co = switch (cv) {
            .object => |o| o,
            else => return error.CorruptLedger,
        };
        calls[i] = .{
            .id = jsonString(co, "id") orelse return error.CorruptLedger,
            .tool = jsonString(co, "tool") orelse return error.CorruptLedger,
            .args_json = jsonString(co, "args") orelse return error.CorruptLedger,
        };
    }
    return calls;
}

fn parseResults(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![]ToolResultEntry {
    const arr = switch (obj.get("results") orelse return error.CorruptLedger) {
        .array => |a| a,
        else => return error.CorruptLedger,
    };
    const results = try alloc.alloc(ToolResultEntry, arr.items.len);
    errdefer alloc.free(results);
    for (arr.items, 0..) |rv, i| {
        const ro = switch (rv) {
            .object => |o| o,
            else => return error.CorruptLedger,
        };
        const ok = switch (ro.get("ok") orelse return error.CorruptLedger) {
            .bool => |b| b,
            else => return error.CorruptLedger,
        };
        const spill: ?[]const u8 = switch (ro.get("spill_path") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            .null => null,
            else => return error.CorruptLedger,
        };
        results[i] = .{
            .call_id = jsonString(ro, "call_id") orelse return error.CorruptLedger,
            .ok = ok,
            .output = jsonString(ro, "output") orelse return error.CorruptLedger,
            .spill_path = spill,
        };
    }
    return results;
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// ── Header / event encoders ─────────────────────────────────────────────────

pub fn encodeHeaderLine(alloc: std.mem.Allocator, hdr: Header) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try writeField(&jw, "kind", "header");
    try jw.objectField("v");
    try jw.write(hdr.v);
    try writeField(&jw, "session", hdr.session);
    try jw.objectField("parent");
    if (hdr.parent) |p| {
        try jw.beginObject();
        try writeField(&jw, "session", p.session);
        try jw.objectField("seq");
        try jw.write(p.seq);
        try jw.endObject();
    } else try jw.write(null);
    try writeField(&jw, "model", hdr.model);
    try writeField(&jw, "created", hdr.created);
    try jw.objectField("composition");
    try jw.beginObject();
    try jw.objectField("active");
    try jw.beginArray();
    for (hdr.composition.active) |a| {
        try jw.beginObject();
        try writeField(&jw, "id", a.id);
        try writeField(&jw, "version", a.version);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("native_tools");
    try jw.beginArray();
    for (hdr.composition.native_tools) |t| try jw.write(t);
    try jw.endArray();
    try jw.objectField("max_tools");
    try jw.write(hdr.composition.max_tools);
    try jw.endObject();
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn encodeEventLine(alloc: std.mem.Allocator, e: Event, seq: u64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("seq");
    try jw.write(seq);
    try encodeEventBody(&jw, e);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Encode just the event body (kind + payload), without the `seq` envelope. Used
/// for cross-process inbox event files, where `seq` is assigned on drain.
pub fn encodeEventBody(jw: *std.json.Stringify, e: Event) !void {
    try jw.objectField("kind");
    switch (e) {
        .user_text => |t| {
            try jw.write("user_text");
            try writeField(jw, "text", t);
        },
        .assistant => |as| {
            try jw.write("assistant");
            try writeField(jw, "text", as.text);
            try jw.objectField("calls");
            try jw.beginArray();
            for (as.calls) |c| {
                try jw.beginObject();
                try writeField(jw, "id", c.id);
                try writeField(jw, "tool", c.tool);
                try writeField(jw, "args", c.args_json);
                try jw.endObject();
            }
            try jw.endArray();
        },
        .tool_results => |rs| {
            try jw.write("tool_results");
            try jw.objectField("results");
            try jw.beginArray();
            for (rs) |r| {
                try jw.beginObject();
                try writeField(jw, "call_id", r.call_id);
                try jw.objectField("ok");
                try jw.write(r.ok);
                try writeField(jw, "output", r.output);
                try jw.objectField("spill_path");
                if (r.spill_path) |p| try jw.write(p) else try jw.write(null);
                try jw.endObject();
            }
            try jw.endArray();
        },
        .capability_note => |n| {
            try jw.write("capability_note");
            try writeField(jw, "id", n.id);
            try writeField(jw, "version", n.version);
            try writeField(jw, "text", n.text);
        },
    }
}

fn writeField(jw: *std.json.Stringify, name: []const u8, value: []const u8) !void {
    try jw.objectField(name);
    try jw.write(value);
}

// ── Header parsing ──────────────────────────────────────────────────────────

fn parseHeaderLine(gpa: std.mem.Allocator, line: []const u8) !OwnedHeader {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return error.CorruptLedger;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.CorruptLedger,
    };
    const kind = jsonString(obj, "kind") orelse return error.MissingHeader;
    if (!std.mem.eql(u8, kind, "header")) return error.MissingHeader;

    const v: u32 = switch (obj.get("v") orelse return error.CorruptLedger) {
        .integer => |i| std.math.cast(u32, i) orelse return error.CorruptLedger,
        else => return error.CorruptLedger,
    };
    const session = try a.dupe(u8, jsonString(obj, "session") orelse return error.CorruptLedger);
    const model = try a.dupe(u8, jsonString(obj, "model") orelse "");
    const created = try a.dupe(u8, jsonString(obj, "created") orelse "");

    const parent: ?ParentRef = switch (obj.get("parent") orelse std.json.Value{ .null = {} }) {
        .null => null,
        .object => |po| .{
            .session = try a.dupe(u8, jsonString(po, "session") orelse return error.CorruptLedger),
            .seq = switch (po.get("seq") orelse return error.CorruptLedger) {
                .integer => |i| @intCast(i),
                else => return error.CorruptLedger,
            },
        },
        else => return error.CorruptLedger,
    };

    const comp = try parseComposition(a, obj);

    return .{ .arena = arena, .value = .{
        .v = v,
        .session = session,
        .parent = parent,
        .model = model,
        .created = created,
        .composition = comp,
    } };
}

fn parseComposition(a: std.mem.Allocator, obj: std.json.ObjectMap) !FrozenComposition {
    const co = switch (obj.get("composition") orelse return FrozenComposition{}) {
        .object => |o| o,
        else => return error.CorruptLedger,
    };
    var active: std.ArrayList(PinnedExtensionRef) = .empty;
    if (co.get("active")) |av| switch (av) {
        .array => |arr| for (arr.items) |ev| {
            const eo = switch (ev) {
                .object => |o| o,
                else => return error.CorruptLedger,
            };
            try active.append(a, .{
                .id = try a.dupe(u8, jsonString(eo, "id") orelse return error.CorruptLedger),
                .version = try a.dupe(u8, jsonString(eo, "version") orelse return error.CorruptLedger),
            });
        },
        else => return error.CorruptLedger,
    };
    var native: std.ArrayList([]const u8) = .empty;
    if (co.get("native_tools")) |nv| switch (nv) {
        .array => |arr| for (arr.items) |tv| {
            switch (tv) {
                .string => |s| try native.append(a, try a.dupe(u8, s)),
                else => return error.CorruptLedger,
            }
        },
        else => return error.CorruptLedger,
    };
    const max_tools: u32 = switch (co.get("max_tools") orelse std.json.Value{ .integer = 8 }) {
        .integer => |i| std.math.cast(u32, i) orelse return error.CorruptLedger,
        else => return error.CorruptLedger,
    };
    return .{
        .active = try active.toOwnedSlice(a),
        .native_tools = try native.toOwnedSlice(a),
        .max_tools = max_tools,
    };
}

/// Deep-copy a borrowed header into a self-owning `OwnedHeader`.
fn dupeHeader(gpa: std.mem.Allocator, hdr: Header) !OwnedHeader {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Duplicate the (always non-empty) session id first so the arena's first
    // allocation has a real size; a zero-length `alloc` as an arena's first
    // request can leak its backing node.
    const session = try a.dupe(u8, hdr.session);

    const active = try dupeExtensionRefs(a, hdr.composition.active);
    const native = try dupeStrings(a, hdr.composition.native_tools);

    const parent: ?ParentRef = if (hdr.parent) |p|
        .{ .session = try a.dupe(u8, p.session), .seq = p.seq }
    else
        null;

    return .{ .arena = arena, .value = .{
        .v = hdr.v,
        .session = session,
        .parent = parent,
        .model = try a.dupe(u8, hdr.model),
        .created = try a.dupe(u8, hdr.created),
        .composition = .{ .active = active, .native_tools = native, .max_tools = hdr.composition.max_tools },
    } };
}

fn dupeExtensionRefs(a: std.mem.Allocator, refs: []const PinnedExtensionRef) ![]const PinnedExtensionRef {
    if (refs.len == 0) return &.{};
    const out = try a.alloc(PinnedExtensionRef, refs.len);
    for (refs, 0..) |ref, i| {
        out[i] = .{ .id = try a.dupe(u8, ref.id), .version = try a.dupe(u8, ref.version) };
    }
    return out;
}

fn dupeStrings(a: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    if (strings.len == 0) return &.{};
    const out = try a.alloc([]const u8, strings.len);
    for (strings, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
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

fn expectEventsEqual(a: []const Event, b: []const Event) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqual(std.meta.activeTag(x), std.meta.activeTag(y));
        switch (x) {
            .user_text => |t| try std.testing.expectEqualStrings(t, y.user_text),
            .assistant => |as| {
                try std.testing.expectEqualStrings(as.text, y.assistant.text);
                try std.testing.expectEqual(as.calls.len, y.assistant.calls.len);
                for (as.calls, y.assistant.calls) |c, d| {
                    try std.testing.expectEqualStrings(c.id, d.id);
                    try std.testing.expectEqualStrings(c.tool, d.tool);
                    try std.testing.expectEqualStrings(c.args_json, d.args_json);
                }
            },
            .tool_results => |rs| {
                try std.testing.expectEqual(rs.len, y.tool_results.len);
                for (rs, y.tool_results) |r, s| {
                    try std.testing.expectEqualStrings(r.call_id, s.call_id);
                    try std.testing.expectEqual(r.ok, s.ok);
                    try std.testing.expectEqualStrings(r.output, s.output);
                }
            },
            .capability_note => |n| {
                try std.testing.expectEqualStrings(n.id, y.capability_note.id);
                try std.testing.expectEqualStrings(n.version, y.capability_note.version);
                try std.testing.expectEqualStrings(n.text, y.capability_note.text);
            },
        }
    }
}

const sample_header: Header = .{
    .session = "s-test",
    .parent = .{ .session = "s-parent", .seq = 41 },
    .model = "openai",
    .created = "2026-08-15T00:00:00Z",
    .composition = .{
        .active = &.{.{ .id = "web.search", .version = "v-0123456789abcdef01234567" }},
        .native_tools = &.{"ext:web.search/web_search"},
        .max_tools = 8,
    },
};

test "header encode/parse round-trips every field" {
    const alloc = std.testing.allocator;
    const line = try encodeHeaderLine(alloc, sample_header);
    defer alloc.free(line);

    var owned = try parseHeaderLine(alloc, line);
    defer owned.deinit();
    const h = owned.value;
    try std.testing.expectEqual(@as(u32, 1), h.v);
    try std.testing.expectEqualStrings("s-test", h.session);
    try std.testing.expectEqualStrings("s-parent", h.parent.?.session);
    try std.testing.expectEqual(@as(u64, 41), h.parent.?.seq);
    try std.testing.expectEqualStrings("openai", h.model);
    try std.testing.expectEqual(@as(usize, 1), h.composition.active.len);
    try std.testing.expectEqualStrings("web.search", h.composition.active[0].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", h.composition.active[0].version);
    try std.testing.expectEqual(@as(usize, 1), h.composition.native_tools.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", h.composition.native_tools[0]);
    try std.testing.expectEqual(@as(u32, 8), h.composition.max_tools);
}

test "a root header has a null parent after round-trip" {
    const alloc = std.testing.allocator;
    const line = try encodeHeaderLine(alloc, .{ .session = "s-root" });
    defer alloc.free(line);
    var owned = try parseHeaderLine(alloc, line);
    defer owned.deinit();
    try std.testing.expect(owned.value.parent == null);
}

fn writeSampleEvents(l: *Ledger) !void {
    try l.append(.{ .user_text = "hi" });
    try l.append(.{ .assistant = .{
        .text = "running",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo one\"}" }},
    } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "one\n[exit 0]" }} });
    try l.append(.{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "note text" } });
}

test "durable create then open replays a block-identical ledger with monotonic seq" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var l = try createDurable(alloc, io, tmp.dir, "s.jsonl", sample_header);
        defer l.deinit();
        try writeSampleEvents(&l);
        try std.testing.expectEqual(@as(usize, 4), l.len());
    }

    // Reopen in a fresh ledger: header and every event survive verbatim.
    var reopened = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 4), reopened.len());
    try std.testing.expectEqualStrings("s-test", reopened.header().?.session);
    try std.testing.expectEqualStrings("ext:web.search/web_search", reopened.header().?.composition.native_tools[0]);

    // The persisted seqs are strictly 1..N (proven by replay's own seq check).
    const raw = try tmp.dir.readFileAlloc(io, "s.jsonl", alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"seq\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"seq\":4,") != null);

    // Appending after reopen continues the seq sequence and persists.
    try reopened.append(.{ .user_text = "again" });
    var third = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 5), third.len());
    try expectEventsEqual(reopened.view(), third.view());
}

test "openDurable drops a torn final line and truncates it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header_line = try encodeHeaderLine(alloc, .{ .session = "s-torn" });
    defer alloc.free(header_line);
    const good = try encodeEventLine(alloc, .{ .user_text = "kept" }, 1);
    defer alloc.free(good);
    // A partial second event with no trailing newline: an interrupted write.
    const torn = "{\"seq\":2,\"kind\":\"user_te";
    const contents = try std.mem.concat(alloc, u8, &.{ header_line, good, torn });
    defer alloc.free(contents);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = contents });

    var l = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expectEqualStrings("kept", l.view()[0].user_text);

    // The torn tail was truncated, so the next append lands cleanly.
    try l.append(.{ .user_text = "next" });
    var reopened = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.len());
    try std.testing.expectEqualStrings("next", reopened.view()[1].user_text);
}

test "a complete but malformed middle line is a corruption error" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header_line = try encodeHeaderLine(alloc, .{ .session = "s-bad" });
    defer alloc.free(header_line);
    // A complete line (trailing newline) that is not valid JSON.
    const contents = try std.mem.concat(alloc, u8, &.{ header_line, "not json\n" });
    defer alloc.free(contents);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = contents });

    try std.testing.expectError(error.CorruptLedger, openDurable(alloc, io, tmp.dir, "s.jsonl"));
}

test "a seq that skips is rejected" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header_line = try encodeHeaderLine(alloc, .{ .session = "s-seq" });
    defer alloc.free(header_line);
    const skipped = try encodeEventLine(alloc, .{ .user_text = "x" }, 2); // should be 1
    defer alloc.free(skipped);
    const contents = try std.mem.concat(alloc, u8, &.{ header_line, skipped });
    defer alloc.free(contents);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = contents });

    try std.testing.expectError(error.CorruptLedger, openDurable(alloc, io, tmp.dir, "s.jsonl"));
}

test "a file whose first line is not a header is rejected" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = "{\"seq\":1,\"kind\":\"user_text\",\"text\":\"x\"}\n" });
    try std.testing.expectError(error.MissingHeader, openDurable(alloc, io, tmp.dir, "s.jsonl"));
}
