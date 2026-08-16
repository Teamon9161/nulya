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

/// What one model step cost, as the provider reported it. A FACT about the turn
/// (like `assistant.reasoning`), never projected into PromptIR: the model does
/// not read its own bill. Declared here rather than reused from `provider.zig`
/// so the ledger keeps depending on nothing — `provider` → `prompt` → `ledger`
/// already runs the other way.
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn isZero(self: Usage) bool {
        return self.input_tokens == 0 and self.output_tokens == 0 and
            self.cache_read_tokens == 0 and self.cache_write_tokens == 0;
    }
};

/// The event log's alphabet. Kept minimal for the skeleton; DESIGN §3 lists the
/// full set (capability_note, registry_selection, compaction, …).
pub const Event = union(enum) {
    user_text: []const u8,
    assistant: struct {
        /// The turn's reasoning as the provider emitted it: a JSON array of
        /// opaque, provider-owned items (signed / encrypted chain-of-thought), or
        /// `""` when there was none. A FACT about the turn, not model-visible
        /// text: the kernel never reads inside it; the projection hands it back
        /// to the provider, which replays it verbatim to the same model so the
        /// model's own reasoning survives across tool steps (DESIGN §13). It is
        /// model-locked by construction — the session's `model_identity` is
        /// frozen (§3.4), so nothing else ever sees it.
        reasoning: []const u8 = "",
        text: []const u8,
        /// Zero or more tool calls. Multiple calls in one assistant turn are the
        /// batch the loop executes together (DESIGN §0.2, §4).
        calls: []const ToolCall,
        /// What this step cost, when the provider said (null when it reported
        /// nothing, and for every line written before this field existed). Like
        /// `reasoning`, it is a fact about the turn and is NOT projected: cost
        /// is evidence for the slow loop and for front ends, not model-visible
        /// text. A step canceled during the provider phase has no assistant
        /// event to hang usage on, so its cost is simply not recorded — honest,
        /// and not worth a new event kind.
        usage: ?Usage = null,
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
    /// Delivery ids of inbox proposals already applied to this ledger (DESIGN
    /// §3.4). Each drained event persists its inbox filename as `origin` on its
    /// JSONL line; this set is that column, rebuilt on replay. It makes inbox
    /// application EXACTLY-once: a crash between "append to ledger" and "delete
    /// inbox file" leaves the file behind, and the next drain sees the origin
    /// already here and skips it. Never projected into PromptIR — it is a
    /// delivery-bookkeeping column, not model-visible state.
    origins: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(alloc: std.mem.Allocator) Ledger {
        return .{ .alloc = alloc, .events = .empty };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.events.items) |e| freeEvent(self.alloc, e);
        self.events.deinit(self.alloc);
        var it = self.origins.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.origins.deinit(self.alloc);
        if (self.durable) |*d| d.deinit();
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
        return self.appendInternal(e, null);
    }

    /// Append `e` and record `origin` as its inbox delivery id (persisted on the
    /// JSONL line so the exactly-once guarantee survives crash + reopen). Only
    /// `drainInbox` uses this; ordinary appends carry no origin.
    pub fn appendWithOrigin(self: *Ledger, e: Event, origin: []const u8) !void {
        return self.appendInternal(e, origin);
    }

    fn appendInternal(self: *Ledger, e: Event, origin: ?[]const u8) !void {
        // Prepare origin tracking up front — dupe the key and reserve the map
        // slot — so that once the durable line is written nothing left can fail
        // and desync the set from the file. A duplicate origin needs no slot.
        var origin_key: ?[]u8 = null;
        if (origin) |o| {
            if (!self.origins.contains(o)) {
                origin_key = try self.alloc.dupe(u8, o);
                self.origins.ensureUnusedCapacity(self.alloc, 1) catch |err| {
                    self.alloc.free(origin_key.?);
                    return err;
                };
            }
        }
        errdefer if (origin_key) |k| self.alloc.free(k);

        const owned = try cloneEvent(self.alloc, e);
        errdefer freeEvent(self.alloc, owned);
        try self.events.append(self.alloc, owned);
        if (self.durable) |*d| {
            // seq is the 1-based file position; the just-appended event is at it.
            const seq: u64 = self.events.items.len;
            d.persist(self.alloc, e, seq, origin) catch |err| {
                _ = self.events.pop(); // undo memory append; errdefer frees `owned`
                return err;
            };
        }
        // Committed: record the origin (reserved above, so this cannot fail).
        if (origin_key) |k| self.origins.putAssumeCapacity(k, {});
    }

    /// True if an inbox proposal with delivery id `origin` was already applied.
    pub fn containsOrigin(self: *const Ledger, origin: []const u8) bool {
        return self.origins.contains(origin);
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

    /// True if the ledger already announced extension `id` at `version`.
    pub fn containsNote(self: *const Ledger, id: []const u8, version: []const u8) bool {
        for (self.events.items) |event| switch (event) {
            .capability_note => |note| if (std.mem.eql(u8, note.id, id) and std.mem.eql(u8, note.version, version)) return true,
            else => {},
        };
        return false;
    }
};

fn cloneEvent(alloc: std.mem.Allocator, e: Event) !Event {
    return switch (e) {
        .user_text => |text| .{ .user_text = try alloc.dupe(u8, text) },
        .assistant => |as| blk: {
            const reasoning = try alloc.dupe(u8, as.reasoning);
            errdefer alloc.free(reasoning);
            const text = try alloc.dupe(u8, as.text);
            errdefer alloc.free(text);
            const calls = try cloneToolCalls(alloc, as.calls);
            errdefer freeToolCalls(alloc, calls);
            break :blk .{ .assistant = .{ .reasoning = reasoning, .text = text, .calls = calls, .usage = as.usage } };
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
            alloc.free(as.reasoning);
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

// ── Durable session file (DESIGN §3.4) ──────────────────────────────────────
//
// A session is one JSONL file: line 1 is the frozen header, every later line is
// one `{"seq":n,...}` event. One file = one generation = one cache scope, so the
// PromptIR stable-block prefix invariant is a filesystem property (a file only
// grows). The header freezes the session composition (active extension versions
// + the native tool selection), so any process that reopens the file rebuilds
// the identical composition without re-scanning `current` or re-ranking usage.
//
// The file has exactly ONE writer, enforced by an exclusive advisory lock taken
// atomically when the writer opens the file: a second writer's open fails fast
// with `error.SessionBusy` rather than racing. The lock is held for the writer's
// whole lifetime and released by the OS when the handle closes (so a crashed
// writer leaves no stale lock). Every other process — a `nulya ext activate` in
// the model's shell, a driver's `session append` — PROPOSES events through the
// sibling inbox directory (below), and the writer appends them at its next step
// boundary. Readers open the file read-only (no lock), so the lease never blocks
// them. `persist`'s length guard stays as a second-layer assertion.

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
};

/// The RESOLVED model identity frozen at session creation (DESIGN §3, physics
/// §2/§5): config chooses the model when a session is created; config can never
/// change the model of an existing session. On resume the writer reconstructs
/// exactly this model, re-resolving only the credential from `api_key_env` in
/// the environment — no secret is stored, and there is no silent fallback to a
/// different provider. `provider == ""` marks a legacy header with no frozen
/// identity (treated as scripted).
pub const ModelDescriptor = struct {
    /// `"scripted"` | `"openai"` (the `config.ProviderKind` tag name).
    provider: []const u8 = "",
    /// The concrete model name, already defaulted (e.g. `gpt-4o-mini`), not a
    /// profile alias.
    model: []const u8 = "",
    base_url: []const u8 = "",
    /// The env var the credential is read from on resume (a name, not a secret).
    api_key_env: []const u8 = "",
};

/// The first line of a session file. Its JSON shape IS this struct — encoded and
/// decoded by `std.json` typed (de)serialization — so the wire format and the
/// type cannot drift. Everything the model sees is a pure function of this
/// header plus the appended events.
pub const Header = struct {
    kind: []const u8 = "header",
    v: u32 = 1,
    session: []const u8 = "",
    parent: ?ParentRef = null,
    /// The provider PROFILE name selected at creation — kept for display and for
    /// resolving generation options (e.g. effort). The model IDENTITY is frozen
    /// separately in `model_identity`, which config changes can never alter.
    model: []const u8 = "",
    model_identity: ModelDescriptor = .{},
    created: []const u8 = "",
    composition: FrozenComposition = .{},
};

/// A parsed header that owns every nested string (arena-backed). `.value` is
/// the header; `deinit()` frees it.
pub const OwnedHeader = std.json.Parsed(Header);

pub const LedgerError = error{
    /// A complete (non-torn) line is not a valid header/event, or a `seq` is out
    /// of order. A torn final line (interrupted write) is tolerated, not this.
    CorruptLedger,
    /// The file's first line is not a `"kind":"header"` record.
    MissingHeader,
    /// Another process already holds the session's writer lease (its exclusive
    /// advisory lock). The single-writer guarantee: only one writer opens the
    /// file at a time, so two `session step` runs can never interleave writes.
    SessionBusy,
};

/// Strings are always copied out of the input, so a parsed value never aliases
/// a line slice the caller frees. Unknown fields are ignored so a newer writer's
/// extra fields never break an older reader.
const json_opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = true };

const Durable = struct {
    io: std.Io,
    file: std.Io.File,
    /// The writer lease: an exclusive advisory lock on the sibling `<stem>.lock`
    /// file, held for this writer's whole lifetime and released by the OS when
    /// the handle closes (so a crash leaves no stale lock). The lock lives on a
    /// dedicated sidecar, never on the session file itself: on Windows a file's
    /// own lock is mandatory and would block readers, so locking `<stem>.lock`
    /// instead keeps `readHeader` / `events` tails unblocked.
    lock_file: std.Io.File,
    /// Byte offset where the next line is written (end of file).
    end: u64,
    owned_header: OwnedHeader,

    fn deinit(self: *Durable) void {
        self.owned_header.deinit();
        self.file.close(self.io);
        self.lock_file.close(self.io);
    }

    fn persist(self: *Durable, alloc: std.mem.Allocator, e: Event, seq: u64, origin: ?[]const u8) !void {
        const line = try encodeEventLineOrigin(alloc, e, seq, origin);
        defer alloc.free(line);
        // No concurrency check here: the exclusive `<id>.lock` lease is the sole
        // single-writer primitive, so no other cooperating writer can be at this
        // offset. A non-cooperating external edit is a corruption concern, caught
        // by replay / seq / JSON validation on the next open — not something an
        // extra `length()` syscall per append should half-guard against.
        try self.file.writePositionalAll(self.io, line, self.end);
        self.end += line.len;
    }
};

/// Acquire the exclusive writer lease for the session at `path` (relative to
/// `dir`): an advisory lock on the sibling `<stem>.lock`, taken non-blocking so a
/// second writer fails fast with `error.SessionBusy` instead of racing. The
/// returned handle must stay open for the writer's lifetime; closing it releases
/// the lease. Caller frees nothing else.
fn acquireWriterLease(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    const lock_path = try siblingPath(alloc, path, ".lock");
    defer alloc.free(lock_path);
    return dir.createFile(io, lock_path, .{ .truncate = false, .read = true, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => error.SessionBusy,
        else => err,
    };
}

/// Create a new session file at `path` (relative to `dir`), writing `hdr` as
/// line 1, and return a durable ledger with no events yet. The parent directory
/// must already exist. Fails if the file already exists.
pub fn createDurable(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, hdr: Header) !Ledger {
    const line = try encodeHeaderLine(alloc, hdr);
    defer alloc.free(line);
    // The owning copy of the header is the parsed line: create and open share
    // one codec path, and what is in memory is exactly what is on disk.
    const owned = try parseHeaderLine(alloc, line);
    errdefer owned.deinit();

    var lock_file = try acquireWriterLease(alloc, io, dir, path);
    errdefer lock_file.close(io);

    var file = try dir.createFile(io, path, .{ .truncate = true, .read = true, .exclusive = true });
    errdefer file.close(io);
    try file.writePositionalAll(io, line, 0);

    return .{
        .alloc = alloc,
        .events = .empty,
        .durable = .{ .io = io, .file = file, .lock_file = lock_file, .end = line.len, .owned_header = owned },
    };
}

/// Reopen an existing session file AS ITS WRITER: parse the header, replay every
/// complete event line into memory, and keep the file open for further appends.
/// A torn final line (an interrupted write by the previous writer) is dropped
/// and the file truncated back to the last complete line, so appends resume
/// cleanly. An interrupted tool batch (a complete assistant-with-calls line with
/// no following results) is a legal tail; the caller repairs it with
/// `loop.completeInterruptedToolBatch`. Readers must not use this — see
/// `readHeader` and the raw-line tail in `cli.zig`.
pub fn openDurable(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Ledger {
    // Take the writer lease FIRST: once held, no other writer is mid-append, so
    // the bytes read below are a stable snapshot (readers never write).
    var lock_file = try acquireWriterLease(alloc, io, dir, path);
    errdefer lock_file.close(io);

    const bytes = try dir.readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(bytes);

    const clean_end = lastCompleteLineEnd(bytes);

    // First complete line must be the header.
    var it = std.mem.splitScalar(u8, bytes[0..clean_end], '\n');
    const header_line = firstNonBlank(&it) orelse return error.MissingHeader;
    const owned = try parseHeaderLine(alloc, header_line);
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

    l.durable = .{ .io = io, .file = file, .lock_file = lock_file, .end = clean_end, .owned_header = owned };
    return l;
}

/// Read and parse only the header line of a session file, without replaying its
/// events or touching the file — a `session step` process resolves its model
/// profile from this before opening the whole session. Caller owns the result.
pub fn readHeader(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !OwnedHeader {
    const bytes = try dir.readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    const line = firstNonBlank(&it) orelse return error.MissingHeader;
    return parseHeaderLine(alloc, line);
}

/// Absolute offset just past the last `\n` in `bytes` (a torn tail after it is
/// dropped). Equals `bytes.len` when the file ends with a newline.
pub fn lastCompleteLineEnd(bytes: []const u8) u64 {
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
    const parsed = try parseEventLine(l.alloc, line);
    defer parsed.deinit();
    if (parsed.value.seq != l.events.items.len + 1) return error.CorruptLedger;
    const e = try toEvent(parsed.arena.allocator(), parsed.value);
    // Rebuild the delivery-id set from the persisted `origin` column so inbox
    // application stays exactly-once across a crash + reopen.
    if (parsed.value.origin) |o| try l.appendWithOrigin(e, o) else try l.append(e);
}

// ── Header / event codec ────────────────────────────────────────────────────
//
// The header is a typed round-trip of `Header`. Events keep the flat
// `{"seq":n,"kind":"…",…}` shape drivers read from `session step` / `events`
// stdout; encoding is written out by kind, decoding goes through `WireEvent`.

pub fn encodeHeaderLine(alloc: std.mem.Allocator, hdr: Header) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(hdr, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Parse one header LINE (the file's first line). `readHeader` is the usual
/// entry point; this is public for readers that already hold the file's bytes
/// and would otherwise read it twice (`nulya session list`).
pub fn parseHeaderLine(gpa: std.mem.Allocator, line: []const u8) !OwnedHeader {
    const parsed = std.json.parseFromSlice(Header, gpa, std.mem.trim(u8, line, " \t\r\n"), json_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptLedger,
    };
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.kind, "header")) return error.MissingHeader;
    if (parsed.value.session.len == 0) return error.CorruptLedger;
    return parsed;
}

pub fn encodeEventLine(alloc: std.mem.Allocator, e: Event, seq: u64) ![]u8 {
    return encodeEventLineOrigin(alloc, e, seq, null);
}

/// Like `encodeEventLine`, but also writes an `origin` field (the inbox delivery
/// id) when present. `origin` is a durable dedup column, never projected to the
/// model — only `drainInbox`'d events carry it.
pub fn encodeEventLineOrigin(alloc: std.mem.Allocator, e: Event, seq: u64, origin: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("seq");
    try jw.write(seq);
    if (origin) |o| try writeField(&jw, "origin", o);
    try encodeEventBody(&jw, e);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Encode just the event body (kind + payload), without the `seq` envelope. Used
/// for inbox event files, where `seq` is assigned on drain.
pub fn encodeEventBody(jw: *std.json.Stringify, e: Event) !void {
    try jw.objectField("kind");
    switch (e) {
        .user_text => |t| {
            try jw.write("user_text");
            try writeField(jw, "text", t);
        },
        .assistant => |as| {
            try jw.write("assistant");
            // Written only when present, so lines without reasoning keep their
            // pre-existing shape byte-for-byte. Carried as a JSON *string* (the
            // provider's array, escaped): the ledger stores it, never parses it.
            if (as.reasoning.len != 0) try writeField(jw, "reasoning", as.reasoning);
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
            // Written only when the provider reported a cost, so a line without
            // usage keeps its pre-existing shape byte-for-byte.
            if (as.usage) |u| {
                try jw.objectField("usage");
                try jw.write(u);
            }
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

/// The flat wire shape of one event line (`{"seq":n,"kind":"…",…}`) or one inbox
/// body (same, without `seq`). Kind-specific fields are optional here; `toEvent`
/// checks the ones its kind requires.
pub const WireEvent = struct {
    seq: u64 = 0,
    /// Inbox delivery id, present only on drained events (see `Ledger.origins`).
    origin: ?[]const u8 = null,
    kind: []const u8,
    text: ?[]const u8 = null,
    /// Assistant reasoning items (see `Event.assistant.reasoning`); absent on
    /// lines written before the field existed, and on turns without any.
    reasoning: ?[]const u8 = null,
    /// What the step cost (see `Event.assistant.usage`); absent on lines written
    /// before the field existed, and on turns the provider priced at nothing.
    usage: ?Usage = null,
    calls: ?[]const WireCall = null,
    results: ?[]const ToolResultEntry = null,
    id: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub const WireCall = struct {
    id: []const u8,
    tool: []const u8,
    args: []const u8,
};

/// Parse one event line or inbox body. Caller owns the result.
pub fn parseEventLine(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(WireEvent) {
    return std.json.parseFromSlice(WireEvent, gpa, bytes, json_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptLedger,
    };
}

/// View a parsed wire event as a ledger `Event`. Strings are borrowed from `w`;
/// `a` backs only the converted calls array — pass the `Parsed` arena. The
/// result is meant to be handed straight to `append`, which deep-copies.
pub fn toEvent(a: std.mem.Allocator, w: WireEvent) !Event {
    if (std.mem.eql(u8, w.kind, "user_text")) {
        return .{ .user_text = w.text orelse return error.CorruptLedger };
    }
    if (std.mem.eql(u8, w.kind, "assistant")) {
        const wire_calls = w.calls orelse &.{};
        const calls = try a.alloc(ToolCall, wire_calls.len);
        for (wire_calls, calls) |wc, *c| c.* = .{ .id = wc.id, .tool = wc.tool, .args_json = wc.args };
        return .{ .assistant = .{
            .reasoning = w.reasoning orelse "",
            .text = w.text orelse return error.CorruptLedger,
            .calls = calls,
            .usage = w.usage,
        } };
    }
    if (std.mem.eql(u8, w.kind, "tool_results")) {
        return .{ .tool_results = w.results orelse return error.CorruptLedger };
    }
    if (std.mem.eql(u8, w.kind, "capability_note")) {
        return .{ .capability_note = .{
            .id = w.id orelse return error.CorruptLedger,
            .version = w.version orelse return error.CorruptLedger,
            .text = w.text orelse return error.CorruptLedger,
        } };
    }
    return error.CorruptLedger;
}

// ── Cross-process inbox (DESIGN §3.4) ───────────────────────────────────────
//
// The session file has one writer. Any other process proposes an event by
// depositing one `<name>.json` file (an event body, no `seq`) into the sibling
// directory `<stem>.inbox/`; the writer drains the inbox at its next step
// boundary — after repairing any interrupted batch, before the model runs — so
// a drained event never lands inside a tool batch and the prompt prefix stays
// append-only. Deposits are atomic (write `.tmp`, rename), so a drain never
// reads a half-written body.

/// `<dir>/<stem><suffix>` for a session file path: the naming rule for every
/// per-session sibling (`.inbox`, `.cancel`). Purely lexical, so it preserves
/// whether `session_path` is relative or absolute. Caller owns the result.
pub fn siblingPath(alloc: std.mem.Allocator, session_path: []const u8, suffix: []const u8) ![]u8 {
    const stem = std.fs.path.stem(std.fs.path.basename(session_path));
    const name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
    defer alloc.free(name);
    if (std.fs.path.dirname(session_path)) |dir| return std.fs.path.join(alloc, &.{ dir, name });
    return alloc.dupe(u8, name);
}

pub fn inboxPath(alloc: std.mem.Allocator, session_path: []const u8) ![]u8 {
    return siblingPath(alloc, session_path, ".inbox");
}

/// Deposit `e` as `<inbox>/<name>.json`, creating the inbox if needed. `base` is
/// the directory `session_path` is relative to. `name` must be filesystem-safe:
/// a depositor wanting idempotence picks a deterministic name (capability notes
/// use `note-<id>-<version>`); one wanting a distinct event every time picks a
/// fresh one. Two deposits with the same name collapse to one event.
pub fn depositEvent(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8, name: []const u8, e: Event) !void {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    try base.createDirPath(io, inbox);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try encodeEventBody(&jw, e);
    try jw.endObject();

    const tmp_rel = try std.fmt.allocPrint(alloc, "{s}{c}{s}.tmp", .{ inbox, std.fs.path.sep, name });
    defer alloc.free(tmp_rel);
    const final_rel = try std.fmt.allocPrint(alloc, "{s}{c}{s}.json", .{ inbox, std.fs.path.sep, name });
    defer alloc.free(final_rel);
    try base.writeFile(io, .{ .sub_path = tmp_rel, .data = out.written() });
    try base.rename(tmp_rel, base, final_rel, io);
}

/// Drain every deposited `.json` in the session inbox into `l`, in filename
/// order, deleting each file once appended. A missing inbox is a no-op.
///
/// Application is EXACTLY-once even though delivery is at-least-once: each event
/// records its inbox filename as `origin` on the ledger line, so a crash between
/// append and delete leaves the file behind and the next drain skips it (its
/// origin is already in the ledger). Capability notes additionally dedupe on
/// content (id+version), so re-announcing a version under any name is a no-op.
pub fn drainInbox(alloc: std.mem.Allocator, io: std.Io, l: *Ledger, base: std.Io.Dir, session_path: []const u8) !void {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);

    var dir = base.openDir(io, inbox, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names.items) |name| {
        // The inbox filename is the proposal's stable delivery id. If it was
        // already applied (a crash left the file behind after the append), just
        // delete it — never re-apply.
        if (l.containsOrigin(name)) {
            try dir.deleteFile(io, name);
            continue;
        }
        const bytes = try dir.readFileAlloc(io, name, alloc, .limited(4 << 20));
        defer alloc.free(bytes);
        const parsed = try parseEventLine(alloc, bytes);
        defer parsed.deinit();
        const e = try toEvent(parsed.arena.allocator(), parsed.value);
        // Content dedup for notes: never announce the same version twice, even
        // if re-proposed under a different filename.
        const already_content = switch (e) {
            .capability_note => |n| l.containsNote(n.id, n.version),
            else => false,
        };
        if (!already_content) try l.appendWithOrigin(e, name);
        try dir.deleteFile(io, name);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

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
                try std.testing.expectEqualStrings(as.reasoning, y.assistant.reasoning);
                try std.testing.expectEqualStrings(as.text, y.assistant.text);
                try std.testing.expectEqual(as.usage, y.assistant.usage);
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
    .model_identity = .{ .provider = "openai", .model = "gpt-4o-mini", .base_url = "https://api.openai.com/v1", .api_key_env = "OPENAI_API_KEY" },
    .created = "2026-08-15T00:00:00Z",
    .composition = .{
        .active = &.{.{ .id = "web.search", .version = "v-0123456789abcdef01234567" }},
        .native_tools = &.{"ext:web.search/web_search"},
    },
};

test "header encode/parse round-trips every field" {
    const alloc = std.testing.allocator;
    const line = try encodeHeaderLine(alloc, sample_header);
    defer alloc.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "{\"kind\":\"header\","));

    const owned = try parseHeaderLine(alloc, line);
    defer owned.deinit();
    const h = owned.value;
    try std.testing.expectEqual(@as(u32, 1), h.v);
    try std.testing.expectEqualStrings("s-test", h.session);
    try std.testing.expectEqualStrings("s-parent", h.parent.?.session);
    try std.testing.expectEqual(@as(u64, 41), h.parent.?.seq);
    try std.testing.expectEqualStrings("openai", h.model);
    try std.testing.expectEqualStrings("openai", h.model_identity.provider);
    try std.testing.expectEqualStrings("gpt-4o-mini", h.model_identity.model);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", h.model_identity.base_url);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", h.model_identity.api_key_env);
    try std.testing.expectEqual(@as(usize, 1), h.composition.active.len);
    try std.testing.expectEqualStrings("web.search", h.composition.active[0].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", h.composition.active[0].version);
    try std.testing.expectEqual(@as(usize, 1), h.composition.native_tools.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", h.composition.native_tools[0]);
}

test "a root header has a null parent after round-trip; unknown fields are ignored" {
    const alloc = std.testing.allocator;
    const line = try encodeHeaderLine(alloc, .{ .session = "s-root" });
    defer alloc.free(line);
    const owned = try parseHeaderLine(alloc, line);
    defer owned.deinit();
    try std.testing.expect(owned.value.parent == null);

    // A header written by a newer nulya with an extra field still parses.
    const newer = try parseHeaderLine(alloc, "{\"kind\":\"header\",\"session\":\"s\",\"composition\":{\"max_tools\":8},\"future\":1}");
    defer newer.deinit();
    try std.testing.expectEqualStrings("s", newer.value.session);
}

fn writeSampleEvents(l: *Ledger) !void {
    try l.append(.{ .user_text = "hi" });
    try l.append(.{ .assistant = .{
        .reasoning = "[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig==\"}]",
        .text = "running",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo one\"}" }},
        .usage = .{ .input_tokens = 1200, .output_tokens = 80, .cache_read_tokens = 1100 },
    } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "one\n[exit 0]" }} });
    try l.append(.{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "note text" } });
}

test "assistant reasoning is stored opaquely, round-trips, and is optional on the wire" {
    const alloc = std.testing.allocator;
    var expected = Ledger.init(alloc);
    defer expected.deinit();
    try writeSampleEvents(&expected);

    // Every line encodes and decodes to the same event, reasoning included.
    for (expected.view(), 1..) |e, seq| {
        const line = try encodeEventLine(alloc, e, seq);
        defer alloc.free(line);
        const parsed = try parseEventLine(alloc, line);
        defer parsed.deinit();
        const back = try toEvent(parsed.arena.allocator(), parsed.value);
        try expectEventsEqual(&.{e}, &.{back});
    }
    // The array rides as one escaped JSON string; a turn without reasoning
    // does not carry the field at all (old readers and old lines agree).
    const with = try encodeEventLine(alloc, expected.view()[1], 2);
    defer alloc.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "\"reasoning\":\"[{\\\"type\\\":\\\"thinking\\\"") != null);
    const without = try encodeEventLine(alloc, .{ .assistant = .{ .text = "t", .calls = &.{} } }, 3);
    defer alloc.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "reasoning") == null);

    // A pre-reasoning line decodes to an empty reasoning, not an error.
    const legacy = try parseEventLine(alloc, "{\"seq\":1,\"kind\":\"assistant\",\"text\":\"old\",\"calls\":[]}");
    defer legacy.deinit();
    const old = try toEvent(legacy.arena.allocator(), legacy.value);
    try std.testing.expectEqualStrings("", old.assistant.reasoning);
    try std.testing.expectEqualStrings("old", old.assistant.text);
}

test "assistant usage round-trips as a fact on the line, and legacy lines read as absent" {
    const alloc = std.testing.allocator;

    // Present: written as one object after `calls`, decoded field for field.
    const priced: Event = .{ .assistant = .{
        .text = "t",
        .calls = &.{},
        .usage = .{ .input_tokens = 1200, .output_tokens = 80, .cache_read_tokens = 1100, .cache_write_tokens = 7 },
    } };
    const line = try encodeEventLine(alloc, priced, 1);
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"kind\":\"assistant\",\"text\":\"t\",\"calls\":[],\"usage\":{\"input_tokens\":1200,\"output_tokens\":80,\"cache_read_tokens\":1100,\"cache_write_tokens\":7}}\n",
        line,
    );
    const parsed = try parseEventLine(alloc, line);
    defer parsed.deinit();
    const back = try toEvent(parsed.arena.allocator(), parsed.value);
    try expectEventsEqual(&.{priced}, &.{back});

    // Absent: the line keeps the shape it had before the field existed…
    const unpriced = try encodeEventLine(alloc, .{ .assistant = .{ .text = "t", .calls = &.{} } }, 2);
    defer alloc.free(unpriced);
    try std.testing.expectEqualStrings("{\"seq\":2,\"kind\":\"assistant\",\"text\":\"t\",\"calls\":[]}\n", unpriced);

    // …and such a line (every line written before M5b) reads back as null, not
    // as a zero cost: "not recorded" and "cost nothing" are different facts.
    const legacy = try parseEventLine(alloc, "{\"seq\":1,\"kind\":\"assistant\",\"text\":\"old\",\"calls\":[]}");
    defer legacy.deinit();
    try std.testing.expect((try toEvent(legacy.arena.allocator(), legacy.value)).assistant.usage == null);
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
    try std.testing.expectEqual(@as(usize, 4), reopened.len());
    try std.testing.expectEqualStrings("s-test", reopened.header().?.session);
    try std.testing.expectEqualStrings("ext:web.search/web_search", reopened.header().?.composition.native_tools[0]);
    try std.testing.expect(reopened.containsNote("demo", "v-aaaa"));
    try std.testing.expect(!reopened.containsNote("demo", "v-bbbb"));
    try std.testing.expect(std.mem.startsWith(u8, reopened.view()[1].assistant.reasoning, "[{\"type\":\"thinking\""));

    // The persisted seqs are strictly 1..N (proven by replay's own seq check).
    const raw = try tmp.dir.readFileAlloc(io, "s.jsonl", alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"seq\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"seq\":4,") != null);

    // Appending after reopen continues the seq sequence and persists. Close this
    // writer before the next opens — the lease permits only one writer at a time.
    try reopened.append(.{ .user_text = "again" });
    const reopened_events = reopened.len();
    reopened.deinit();

    var third = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer third.deinit();
    try std.testing.expectEqual(@as(usize, 5), third.len());
    try std.testing.expectEqual(reopened_events, third.len());
    try std.testing.expectEqualStrings("again", third.view()[4].user_text);
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
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expectEqualStrings("kept", l.view()[0].user_text);

    // The torn tail was truncated, so the next append lands cleanly. Close this
    // writer before reopening — the lease permits only one writer at a time.
    try l.append(.{ .user_text = "next" });
    l.deinit();

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

test "the writer holds an exclusive lease: a second writer is refused with SessionBusy" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var a = try createDurable(alloc, io, tmp.dir, "s.jsonl", .{ .session = "s" });
    try a.append(.{ .user_text = "one" });

    // While `a` holds the file open, no other process can open it as a writer:
    // both create and open fail fast rather than racing on the same offset.
    try std.testing.expectError(error.SessionBusy, createDurable(alloc, io, tmp.dir, "s.jsonl", .{ .session = "s" }));
    try std.testing.expectError(error.SessionBusy, openDurable(alloc, io, tmp.dir, "s.jsonl"));

    // A reader (read-only, no lock) is never blocked by the lease.
    var hdr = try readHeader(alloc, io, tmp.dir, "s.jsonl");
    hdr.deinit();

    // Once `a` releases the lease, the next writer opens cleanly and continues.
    a.deinit();
    var b = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 1), b.len());
    try b.append(.{ .user_text = "two" });
    try std.testing.expectEqual(@as(usize, 2), b.len());
}

test "siblingPath names <stem><suffix> next to the session file" {
    const alloc = std.testing.allocator;
    const a = try inboxPath(alloc, ".nulya/sessions/s-1.jsonl");
    defer alloc.free(a);
    try std.testing.expectEqualStrings(".nulya/sessions" ++ std.fs.path.sep_str ++ "s-1.inbox", a);

    const b = try siblingPath(alloc, "s-2.jsonl", ".cancel");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("s-2.cancel", b);
}

test "inbox: deposits drain in name order, dedupe notes, and never touch the main file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";

    var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s" });

    // Two processes deposit: a driver's user text and a note, out of order.
    try depositEvent(alloc, io, tmp.dir, spath, "note-demo-v-aaaa", .{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "n" } });
    try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = "hello" });
    // The main file is untouched by deposits.
    try std.testing.expectEqual(@as(usize, 0), l.len());

    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expectEqualStrings("hello", l.view()[0].user_text); // "msg-…" < "note-…"
    try std.testing.expect(l.view()[1] == .capability_note);

    // Draining an empty inbox adds nothing; a re-deposited note is skipped.
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try depositEvent(alloc, io, tmp.dir, spath, "note-demo-v-aaaa", .{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "n" } });
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 2), l.len());

    // Everything drained is on disk in order. Close this writer before reopening
    // — the lease permits only one writer at a time.
    l.deinit();

    var reopened = try openDurable(alloc, io, tmp.dir, spath);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.len());
    try std.testing.expectEqualStrings("hello", reopened.view()[0].user_text);
    try std.testing.expect(reopened.containsNote("demo", "v-aaaa"));
}

test "inbox application is exactly-once across a crash between append and delete" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";

    // Deposit a user turn, then simulate a drain that appended the event (with its
    // inbox filename as origin) but CRASHED before deleting the inbox file.
    {
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s" });
        defer l.deinit();
        try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = "hello" });
        try l.appendWithOrigin(.{ .user_text = "hello" }, "msg-0001.json");
        try std.testing.expectEqual(@as(usize, 1), l.len());
    }

    // The persisted line carries the origin so a fresh writer can tell it was
    // already applied.
    const raw = try tmp.dir.readFileAlloc(io, spath, alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"origin\":\"msg-0001.json\"") != null);

    // Reopen (replay rebuilds the origin set) and drain: the leftover inbox file
    // is recognized as already-applied — deleted, never re-appended.
    var reopened = try openDurable(alloc, io, tmp.dir, spath);
    defer reopened.deinit();
    try std.testing.expect(reopened.containsOrigin("msg-0001.json"));
    try drainInbox(alloc, io, &reopened, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 1), reopened.len());
    try std.testing.expectEqualStrings("hello", reopened.view()[0].user_text);
}

test "draining a missing inbox is a no-op" {
    const alloc = std.testing.allocator;
    var l = Ledger.init(alloc);
    defer l.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try drainInbox(alloc, std.testing.io, &l, tmp.dir, "s.jsonl");
    try std.testing.expectEqual(@as(usize, 0), l.len());
}
