//! The immutable conversation ledger.
//!
//! Append-only: the ENTIRE mutable API is `append`, reads hand back a const
//! view, and a correction is a new appended event rather than an in-place
//! change. That is what keeps the PromptIR prefix stable, and the prompt cache
//! hitting.
//!
//! Also here: the durable session file (one JSONL file per session, header line
//! + one line per event), its single-writer lease, and the cross-process inbox
//! other processes deposit events into.

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
    /// UI-only presentation JSON supplied by the tool runtime. It is ledger
    /// evidence for front ends, like `spill_path`, and PromptIR ignores it.
    presentation: ?[]const u8 = null,
};

/// What one model step cost, as the provider reported it. A FACT about the turn,
/// never projected into PromptIR. Declared here (the ledger depends on nothing)
/// and re-exported by `provider.zig`, so what a provider reports and what the
/// ledger records are one struct.
pub const Usage = struct {
    /// Non-cached input tokens.
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,

    pub fn isZero(self: Usage) bool {
        return self.input_tokens == 0 and self.output_tokens == 0 and
            self.cache_read_tokens == 0 and self.cache_write_tokens == 0;
    }

    /// Add `other` in place; summing usage is field-wise everywhere.
    pub fn add(self: *Usage, other: Usage) void {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
    }
};

/// Why the model stopped producing a turn, as the provider reported it. A FACT
/// about the turn, never projected. Declared here and re-exported by
/// `provider.zig`, so provider and ledger share one enum.
pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    other,
};

/// One image inlined into a user turn. `data` is base64 TEXT — what goes on the
/// wire and what sits in the line — and the ledger neither decodes nor validates
/// it. Which media types are acceptable, how big an image may be, and whether
/// the session's model can see one at all are decided in the shell
/// (`cli/session.zig`); a file already holding an odd value still reads back.
pub const Image = struct {
    media_type: []const u8,
    data: []const u8,
};

/// A user turn: text, plus zero or more images inlined with it. Both are
/// model-visible, so both are projected.
pub const UserText = struct {
    text: []const u8,
    images: []const Image = &.{},
};

/// The event log's alphabet.
pub const Event = union(enum) {
    user_text: UserText,
    assistant: struct {
        /// The turn's reasoning as the provider emitted it: a JSON array of
        /// opaque, provider-owned items, or `""` when there was none. The kernel
        /// never reads inside; the projection hands it back to the provider,
        /// which replays it verbatim to the SAME model — which is why a rebind
        /// stops it being replayed (`reasoningFloor`).
        reasoning: []const u8 = "",
        text: []const u8,
        /// Zero or more tool calls: the batch the loop executes together.
        calls: []const ToolCall,
        /// What this step cost, when the provider said (null when it reported
        /// nothing, and on every line written before this field existed). A fact
        /// about the turn, NOT projected. A step canceled during the provider
        /// phase has no assistant event, so its cost is simply not recorded.
        usage: ?Usage = null,
        /// Why the provider stopped this turn. A fact like `usage`, equally not
        /// projected. `end_turn` / `tool_use` are readable off the turn's SHAPE
        /// (`calls.len`) and are not written to the line; `max_tokens` / `other`
        /// are. `max_tokens` is the load-bearing one: a reply cut before it wrote
        /// a call looks byte-identical to one that finished, and replaying that
        /// tail asks the provider to continue it as a prefill — rejected outright
        /// when thinking is on.
        stop_reason: StopReason = .end_turn,
    },
    /// Exactly ONE user turn carrying every result from a batch. Never split
    /// per-tool — that would be one model round-trip per tool.
    tool_results: []const ToolResultEntry,
    /// A capability that became available mid-conversation. An APPEND, never a
    /// change to `tools[]`, so the prompt prefix stays stable. `text` is the
    /// model-facing announcement; `id` / `version` are structured so
    /// reconciliation never parses presentation text.
    capability_note: struct {
        id: []const u8,
        version: []const u8,
        text: []const u8,
    },
    /// A background command this session started has ended. Same genre as
    /// `capability_note`: a fact from another process, deposited into the inbox,
    /// drained at a step boundary, projected as one more user-role turn.
    ///
    /// Not a `tool_results` entry — the call that started the task already has
    /// its result, and one assistant batch maps to exactly one `tool_results`.
    /// Not a `user_text` either — the ledger would then claim a person said it.
    ///
    /// `task` is the full name `<session-id>/t<N>`, `exit_code` is what the
    /// supervisor saw the direct child exit with, `text` is what the model reads
    /// and the only part projected.
    task_finished: struct {
        task: []const u8,
        exit_code: u8,
        text: []const u8,
    },
    /// From here on, this session runs on a different model.
    ///
    /// The header freezes ONE identity and cannot be rewritten, so a change of
    /// identity is an APPEND. `identity` is the already RESOLVED descriptor,
    /// frozen exactly as the header's is: whoever asked for the change resolved
    /// it against config with the credential in hand. `profile` is the profile
    /// NAME, for the same display / effort lookup the header's is used for.
    ///
    /// NOT a turn — `prompt.zig` gives it no `Turn`. What it changes is what may
    /// still be REPLAYED: `reasoning` is model-locked, so everything recorded
    /// before the last rebind stops being projected (`reasoningFloor`).
    model_rebind: struct {
        profile: []const u8 = "",
        identity: ModelDescriptor,
    },
};

/// Which model this session runs on NOW: the last `model_rebind`, or the
/// header's frozen identity when there has been none.
///
/// The one answer to that question for a reader INSIDE a step, where every fact
/// is committed. Nothing else may ask `header.model_identity` what a session
/// runs on — that answers what it STARTED on, a different question. Outside a
/// step, deposits count too: ask `scanSession`.
pub const Identity = struct { profile: []const u8, identity: ModelDescriptor };

pub fn effectiveIdentity(header: Header, events: []const Event) Identity {
    return lastRebind(events) orelse .{ .profile = header.model, .identity = header.model_identity };
}

/// Do these two name the same running model? The whole `Identity`, profile
/// included: the descriptor says which model over which wire, the profile says
/// which credential reaches it. Every "is this already what we run on" test asks
/// THIS one — a comparison covering less of the frozen unit makes a real change
/// look like a no-op, and a no-op is silent.
pub fn identityEqual(a: Identity, b: Identity) bool {
    return std.mem.eql(u8, a.profile, b.profile) and
        std.mem.eql(u8, a.identity.provider, b.identity.provider) and
        std.mem.eql(u8, a.identity.model, b.identity.model) and
        std.mem.eql(u8, a.identity.base_url, b.identity.base_url) and
        std.mem.eql(u8, a.identity.api_key_env, b.identity.api_key_env);
}

/// Index of the last `.model_rebind` event, or null when there has been none.
/// The one backward scan both `lastRebind` and `reasoningFloor` need.
fn lastRebindIndex(events: []const Event) ?usize {
    var at = events.len;
    while (at > 0) {
        at -= 1;
        if (events[at] == .model_rebind) return at;
    }
    return null;
}

/// The last `model_rebind`, or null when this session still runs on what its
/// header froze.
pub fn lastRebind(events: []const Event) ?Identity {
    const at = lastRebindIndex(events) orelse return null;
    const r = events[at].model_rebind;
    return .{ .profile = r.profile, .identity = r.identity };
}

/// How many events precede the identity in force — the index before which the
/// projection stops replaying `reasoning`. Zero when the session never rebound.
pub fn reasoningFloor(events: []const Event) usize {
    const at = lastRebindIndex(events) orelse return 0;
    return at + 1;
}

pub const Ledger = struct {
    alloc: std.mem.Allocator,
    /// Every byte an appended event owns. A ledger is append-only and released
    /// whole, so its payloads have exactly one lifetime and one arena expresses
    /// it. `append` copies what it is given; the caller's slices are free the
    /// moment it returns.
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(Event),
    /// When set, every appended event is also persisted as one JSONL line. A
    /// ledger created with `init` is pure memory; `createDurable` /
    /// `openDurable` add the backend.
    durable: ?Durable = null,
    /// Delivery ids of inbox proposals already applied. A drained event persists
    /// its inbox filename(s) as `origin` / `origins` on its line, and this set is
    /// rebuilt from both on replay — which is what makes inbox application
    /// EXACTLY-once: a crash between appending and deleting the inbox file leaves
    /// the file behind, and the next drain skips it. Never projected.
    origins: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(alloc: std.mem.Allocator) Ledger {
        return .{ .alloc = alloc, .arena = .init(alloc), .events = .empty };
    }

    pub fn deinit(self: *Ledger) void {
        // One release for every event payload and every origin key. The two
        // containers themselves stay on the backing allocator: an ArrayList and a
        // hash map grow by reallocating, which an arena cannot reuse.
        self.arena.deinit();
        self.events.deinit(self.alloc);
        self.origins.deinit(self.alloc);
        if (self.durable) |*d| d.deinit();
    }

    /// The only mutation. Appends one event to the end. No other write exists.
    ///
    /// Takes a SNAPSHOT of the payload: callers may free or reuse every slice
    /// passed in once this returns. When the ledger is durable the event is
    /// persisted before the call returns, and a persistence failure rewinds the
    /// in-memory append so memory and file never diverge.
    pub fn append(self: *Ledger, e: Event) !void {
        return self.appendInternal(e, &.{});
    }

    /// Append `e` and record `origin` as its inbox delivery id (persisted on the
    /// JSONL line so the exactly-once guarantee survives crash + reopen).
    pub fn appendWithOrigin(self: *Ledger, e: Event, origin: []const u8) !void {
        return self.appendWithOrigins(e, &.{origin});
    }

    /// One drained user turn may represent several queued inbox proposals. All
    /// delivery ids ride on the same line so merging never weakens exactly-once.
    pub fn appendWithOrigins(self: *Ledger, e: Event, origins: []const []const u8) !void {
        return self.appendInternal(e, origins);
    }

    fn appendInternal(self: *Ledger, e: Event, origins: []const []const u8) !void {
        const owner = self.arena.allocator();
        var origin_keys: std.ArrayList([]u8) = .empty;
        defer origin_keys.deinit(self.alloc);
        for (origins) |origin| {
            if (self.origins.contains(origin)) continue;
            try origin_keys.append(self.alloc, try owner.dupe(u8, origin));
        }
        try self.origins.ensureUnusedCapacity(self.alloc, @intCast(origin_keys.items.len));

        const owned = try cloneEvent(owner, e);
        try self.events.append(self.alloc, owned);
        if (self.durable) |*d| {
            const seq: u64 = self.events.items.len;
            d.persist(self.alloc, e, seq, origins) catch |err| {
                _ = self.events.pop();
                return err;
            };
        }
        for (origin_keys.items) |key| self.origins.putAssumeCapacity(key, {});
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

/// Deep-copy `e` into the ledger's arena. `a` is always `Ledger.arena`, hence no
/// unwind path: a copy that fails half way leaves its pieces in the arena, which
/// is released as one.
fn cloneEvent(a: std.mem.Allocator, e: Event) !Event {
    return switch (e) {
        .user_text => |u| .{ .user_text = .{
            .text = try a.dupe(u8, u.text),
            .images = try cloneImages(a, u.images),
        } },
        .assistant => |as| .{ .assistant = .{
            .reasoning = try a.dupe(u8, as.reasoning),
            .text = try a.dupe(u8, as.text),
            .calls = try cloneToolCalls(a, as.calls),
            .usage = as.usage,
            .stop_reason = as.stop_reason,
        } },
        .tool_results => |results| .{ .tool_results = try cloneToolResults(a, results) },
        .capability_note => |note| .{ .capability_note = .{
            .id = try a.dupe(u8, note.id),
            .version = try a.dupe(u8, note.version),
            .text = try a.dupe(u8, note.text),
        } },
        .task_finished => |t| .{ .task_finished = .{
            .task = try a.dupe(u8, t.task),
            .exit_code = t.exit_code,
            .text = try a.dupe(u8, t.text),
        } },
        .model_rebind => |r| .{ .model_rebind = .{
            .profile = try a.dupe(u8, r.profile),
            .identity = .{
                .provider = try a.dupe(u8, r.identity.provider),
                .model = try a.dupe(u8, r.identity.model),
                .base_url = try a.dupe(u8, r.identity.base_url),
                .api_key_env = try a.dupe(u8, r.identity.api_key_env),
            },
        } },
    };
}

fn cloneImages(a: std.mem.Allocator, images: []const Image) ![]const Image {
    if (images.len == 0) return &.{};
    const owned = try a.alloc(Image, images.len);
    for (images, owned) |img, *out| out.* = .{
        .media_type = try a.dupe(u8, img.media_type),
        .data = try a.dupe(u8, img.data),
    };
    return owned;
}

fn cloneToolCalls(a: std.mem.Allocator, calls: []const ToolCall) ![]const ToolCall {
    const owned = try a.alloc(ToolCall, calls.len);
    for (calls, owned) |call, *out| out.* = .{
        .id = try a.dupe(u8, call.id),
        .tool = try a.dupe(u8, call.tool),
        .args_json = try a.dupe(u8, call.args_json),
    };
    return owned;
}

fn cloneToolResults(a: std.mem.Allocator, results: []const ToolResultEntry) ![]const ToolResultEntry {
    const owned = try a.alloc(ToolResultEntry, results.len);
    for (results, owned) |result, *out| out.* = .{
        .call_id = try a.dupe(u8, result.call_id),
        .ok = result.ok,
        .output = try a.dupe(u8, result.output),
        .spill_path = if (result.spill_path) |path| try a.dupe(u8, path) else null,
        .presentation = if (result.presentation) |p| try a.dupe(u8, p) else null,
    };
    return owned;
}

// ── Durable session file ──────────────────────────────────────
//
// A session is one JSONL file: line 1 is the frozen header, every later line is
// one `{"seq":n,...}` event. One file = one generation = one cache scope, so the
// prefix invariant is a filesystem property (a file only grows). The header
// freezes the composition, so any process reopening the file rebuilds the
// identical composition without re-scanning `current`.
//
// Exactly ONE writer, enforced by an exclusive advisory lock taken when the
// writer opens the file: a second writer fails fast with `error.SessionBusy`
// rather than racing, and the OS releases the lock when the handle closes.
// Every other process PROPOSES events through the sibling inbox directory
// (below), and the writer appends them at its next step boundary. Readers open
// read-only and take no lock, so the lease never blocks them.

/// A parent pointer for fork / compaction: the file and cut point a session
/// branched from. Absent for a root session.
pub const ParentRef = struct {
    session: []const u8,
    seq: u64,
};

/// One member extension of a session, frozen: which immutable version this
/// session composed. Reopening reads this exact version, never the live
/// `current`. Says nothing about whether its tools take a native slot — that is
/// `native_tools`.
pub const ExtensionRef = struct {
    id: []const u8,
    version: []const u8,
    /// Which frozen version actually SERVES a tool call, when that is not
    /// `version` itself: a session whose tools run on another machine needs the
    /// build for THAT machine's target, and a compiled package's two builds are
    /// two versions of one package. Empty for every ordinary session, and for
    /// data / script members, whose identity does not depend on a target.
    exec_version: []const u8 = "",
};

/// The session composition frozen into the header.
///
/// `active` is every MEMBER extension at its frozen version — what was activated
/// when the session began plus whatever `session new --with` brought in. The
/// name is a v1 wire leftover from when membership could only come from
/// activation; the struct field name IS the JSON key, so renaming it would break
/// every existing session file. Rename it at the next header version, not before.
///
/// `native_tools` is the subset of stable tool ids exposed directly to the model.
///
/// `prompts` is the per-session system prompt text from `session new --prompt`
/// — bytes, not a reference.
pub const FrozenComposition = struct {
    active: []const ExtensionRef = &.{},
    native_tools: []const []const u8 = &.{},
    prompts: []const InlinePrompt = &.{},
};

/// One system prompt frozen into the header by VALUE.
///
/// Text whose lifetime is one session's lives in the session file: a store
/// reference would make resume depend on a shared artifact still existing
/// (`ext prune` would break it) and a path would drift. `source` is an opaque
/// label the kernel only carries — it names the block in `PromptIR` and means
/// nothing to the kernel.
pub const InlinePrompt = struct {
    source: []const u8 = "",
    text: []const u8 = "",
};

/// The RESOLVED model identity frozen at session creation: config chooses the
/// model when a session is created and can never change an existing session's.
/// On resume the writer reconstructs exactly this model, re-resolving only the
/// credential named by `api_key_env` — no secret is stored, and there is no
/// silent fallback to a different provider. `provider == ""` marks a legacy
/// header with no frozen identity (treated as scripted).
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

/// Which nulya created a session — PROVENANCE ONLY, never enforcement.
///
/// The kernel system prompt and the builtin tool definitions are compile-time
/// constants of the BINARY, yet they enter every session's frozen model-visible
/// state, so upgrading nulya changes them for every existing session — the one
/// thing freezing the composition into the header cannot cover, since those
/// bytes were never in it. Recording them makes it visible: `version` is the
/// build's version string, `kernel_hash` a digest over the kernel prompt plus
/// every builtin definition (`composition.kernelHash`). A resume whose hash
/// differs warns and runs; an empty stamp is a header written before this
/// existed — unknown, never a warning.
pub const Stamp = struct {
    version: []const u8 = "",
    kernel_hash: []const u8 = "",
};

/// The session file format this binary reads and writes. Unknown FIELDS are
/// tolerated (a newer writer may add some without changing what the old ones
/// mean), but a different `v` is not: it announces that the old meanings no
/// longer hold, so `parseHeaderLine` refuses the file rather than reading a
/// future format as if it were this one.
pub const format_version: u32 = 1;

/// The first line of a session file. Its JSON shape IS this struct — field names
/// are the on-disk keys — so the format and the type cannot drift. Everything
/// the model sees is a pure function of this header plus the appended events.
///
/// New facts are added as DEFAULTED fields, never a version bump: an old header
/// then reads back exactly as it always did and `v` stays 1.
pub const Header = struct {
    kind: []const u8 = "header",
    v: u32 = format_version,
    session: []const u8 = "",
    parent: ?ParentRef = null,
    /// The provider PROFILE name selected at creation — kept for display and for
    /// resolving generation options (e.g. effort). The model IDENTITY is frozen
    /// separately in `model_identity`, which config changes can never alter.
    model: []const u8 = "",
    model_identity: ModelDescriptor = .{},
    /// WHERE this session's `shell` commands run: `""` = this host, `wsl`,
    /// `wsl:<distro>` (`environment.ExecTarget`'s spec), or a `remote:…` spec
    /// that moves the whole workspace rather than just the command.
    ///
    /// Frozen because a transcript only means something against the machine that
    /// produced it — paths, the platform the model believes it is on, and which
    /// files a later step can still see all come from here. It never reaches the
    /// model's prompt.
    environment: []const u8 = "",
    /// The absolute directory ON THAT MACHINE this session works in — set only
    /// when `environment` names the remote backend, where the workspace lives
    /// elsewhere and "." has to mean something over there. Frozen for the same
    /// reason the target is.
    remote_workspace: []const u8 = "",
    created: []const u8 = "",
    /// Which binary wrote this session (see `Stamp`). Provenance, not a gate.
    nulya: Stamp = .{},
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
    /// The header declares a `v` this binary does not implement — the file was
    /// written by a newer nulya. Refused rather than read as `format_version`:
    /// a future format may keep the same field names and mean other things.
    UnsupportedLedgerVersion,
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
    /// The writer lease: an exclusive advisory lock on the sibling `<stem>.lock`,
    /// held for this writer's whole lifetime and released by the OS when the
    /// handle closes. It lives on a sidecar and never on the session file itself:
    /// on Windows a file's own lock is mandatory and would block readers.
    lock_file: std.Io.File,
    /// Byte offset where the next line is written (end of file).
    end: u64,
    owned_header: OwnedHeader,

    fn deinit(self: *Durable) void {
        self.owned_header.deinit();
        self.file.close(self.io);
        self.lock_file.close(self.io);
    }

    fn persist(self: *Durable, alloc: std.mem.Allocator, e: Event, seq: u64, origins: []const []const u8) !void {
        const line = try encodeEventLineOrigins(alloc, e, seq, origins);
        defer alloc.free(line);
        // No concurrency check here: the exclusive `<id>.lock` lease is the sole
        // single-writer primitive, so no cooperating writer can be at this
        // offset. An external edit is corruption, caught by replay / seq / JSON
        // validation on the next open.
        try self.file.writePositionalAll(self.io, line, self.end);
        self.end += line.len;
    }
};

/// Acquire the exclusive writer lease for the session at `path` (relative to
/// `dir`): an advisory lock on the sibling `<stem>.lock`, taken non-blocking so a
/// second writer fails fast with `error.SessionBusy` instead of racing. The
/// returned handle must stay open for the writer's lifetime; closing it releases
/// the lease. Caller frees nothing else.
///
/// Public because one caller is not a writer at all: `pruneSession` has to know
/// that nobody is writing, and that is a question only taking the lease can
/// answer — probing a lock races with whoever is about to take it.
pub fn acquireWriterLease(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
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
        .arena = .init(alloc),
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

/// Iterates the complete (non-torn), non-blank lines of a ledger/session byte
/// buffer: drop the torn tail (`lastCompleteLineEnd`), split on `\n`, trim,
/// skip blanks. Several readers share exactly this walk. Skipping the header
/// line (line 1, when present) is left to the caller — some readers decode it
/// differently than the rest, and some only want it counted.
pub const CompleteLines = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *CompleteLines) ?[]const u8 {
        while (self.it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len != 0) return line;
        }
        return null;
    }
};

pub fn completeLines(bytes: []const u8) CompleteLines {
    const end: usize = @intCast(lastCompleteLineEnd(bytes));
    return .{ .it = std.mem.splitScalar(u8, bytes[0..end], '\n') };
}

/// Parse one event line and append it to `l` (in-memory only — the ledger is not
/// yet durable during replay). Validates that `seq` matches the position.
fn replayEventLine(l: *Ledger, line: []const u8) !void {
    const parsed = try parseEventLine(l.alloc, line);
    defer parsed.deinit();
    if (parsed.value.seq != l.events.items.len + 1) return error.CorruptLedger;
    const e = try toEvent(parsed.arena.allocator(), parsed.value);
    // Rebuild every delivery id. `origin` is the v1 single-proposal shape;
    // `origins` is used only when one drained user turn merged several files.
    if (parsed.value.origins) |origins| {
        try l.appendWithOrigins(e, origins);
    } else if (parsed.value.origin) |origin| {
        try l.appendWithOrigin(e, origin);
    } else try l.append(e);
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
/// entry point; this is public for readers that already hold the file's bytes.
pub fn parseHeaderLine(gpa: std.mem.Allocator, line: []const u8) !OwnedHeader {
    const parsed = std.json.parseFromSlice(Header, gpa, std.mem.trim(u8, line, " \t\r\n"), json_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptLedger,
    };
    errdefer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.kind, "header")) return error.MissingHeader;
    // Unknown fields were ignored above (a same-version writer may add some);
    // a different `v` is the one thing that cannot be ignored.
    if (parsed.value.v != format_version) return error.UnsupportedLedgerVersion;
    if (parsed.value.session.len == 0) return error.CorruptLedger;
    return parsed;
}

pub fn encodeEventLine(alloc: std.mem.Allocator, e: Event, seq: u64) ![]u8 {
    return encodeEventLineOrigins(alloc, e, seq, &.{});
}

/// Persist one or more inbox delivery ids. One id keeps the singular `origin`
/// field, so ordinary lines stay byte-for-byte stable.
pub fn encodeEventLineOrigins(alloc: std.mem.Allocator, e: Event, seq: u64, origins: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("seq");
    try jw.write(seq);
    if (origins.len == 1) {
        try writeField(&jw, "origin", origins[0]);
    } else if (origins.len > 1) {
        try jw.objectField("origins");
        try jw.write(origins);
    }
    try encodeEventBody(&jw, e);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// Encode just the event body (kind + payload), without the `seq` envelope. Used
/// for inbox event files, where `seq` is assigned on drain.
///
/// One rule runs through every optional field below: it is written ONLY when it
/// has something to say, so a line that predates the field keeps its exact
/// shape and reads back identically.
pub fn encodeEventBody(jw: *std.json.Stringify, e: Event) !void {
    try jw.objectField("kind");
    switch (e) {
        .user_text => |u| {
            try jw.write("user_text");
            try writeField(jw, "text", u.text);
            if (u.images.len != 0) {
                try jw.objectField("images");
                try jw.write(u.images);
            }
        },
        .assistant => |as| {
            try jw.write("assistant");
            // A JSON *string* (the provider's array, escaped): stored, never
            // parsed.
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
            if (as.usage) |u| {
                try jw.objectField("usage");
                try jw.write(u);
            }
            // Written only when the SHAPE cannot already say it: `end_turn` /
            // `tool_use` are `calls.len == 0` / `!= 0`.
            switch (as.stop_reason) {
                .max_tokens, .other => try writeField(jw, "stop_reason", @tagName(as.stop_reason)),
                .end_turn, .tool_use => {},
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
                if (r.presentation) |p| try writeField(jw, "presentation", p);
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
        .task_finished => |t| {
            try jw.write("task_finished");
            try writeField(jw, "task", t.task);
            try jw.objectField("exit_code");
            try jw.write(t.exit_code);
            try writeField(jw, "text", t.text);
        },
        .model_rebind => |r| {
            try jw.write("model_rebind");
            try writeField(jw, "profile", r.profile);
            try jw.objectField("identity");
            try jw.write(r.identity);
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
    /// Inbox delivery ids, present only on drained events (see `Ledger.origins`).
    /// `origin` is the original one-file shape; `origins` is a merged user batch.
    origin: ?[]const u8 = null,
    origins: ?[]const []const u8 = null,
    kind: []const u8,
    text: ?[]const u8 = null,
    /// Images inlined with a user turn. For these domain types the wire type IS
    /// the domain type: their field names are the JSON keys.
    images: ?[]const Image = null,
    reasoning: ?[]const u8 = null,
    usage: ?Usage = null,
    /// Absent when the turn's shape already says it (`end_turn` / `tool_use`).
    stop_reason: ?[]const u8 = null,
    /// LEGACY INPUT ONLY — what the `stop_reason` field replaced. Never written
    /// again; `"truncated":true` with no `stop_reason` reads back as
    /// `.max_tokens`, which is what it meant.
    truncated: bool = false,
    calls: ?[]const WireCall = null,
    results: ?[]const ToolResultEntry = null,
    id: ?[]const u8 = null,
    version: ?[]const u8 = null,
    /// A finished background task's full name `<session-id>/t<N>` and the exit
    /// code its supervisor observed.
    task: ?[]const u8 = null,
    exit_code: ?u8 = null,
    /// The profile name and resolved descriptor of a `model_rebind`.
    profile: ?[]const u8 = null,
    identity: ?ModelDescriptor = null,
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
        return .{ .user_text = .{
            .text = w.text orelse return error.CorruptLedger,
            .images = w.images orelse &.{},
        } };
    }
    if (std.mem.eql(u8, w.kind, "assistant")) {
        const wire_calls = w.calls orelse &.{};
        const calls = try a.alloc(ToolCall, wire_calls.len);
        for (wire_calls, calls) |wc, *c| c.* = .{ .id = wc.id, .tool = wc.tool, .args_json = wc.args };
        // Written field first; then the legacy boolean; then the shape, which is
        // what every line without either one always meant.
        const stop_reason: StopReason = if (w.stop_reason) |tag|
            (std.meta.stringToEnum(StopReason, tag) orelse return error.CorruptLedger)
        else if (w.truncated)
            .max_tokens
        else if (calls.len != 0)
            .tool_use
        else
            .end_turn;
        return .{ .assistant = .{
            .reasoning = w.reasoning orelse "",
            .text = w.text orelse return error.CorruptLedger,
            .calls = calls,
            .usage = w.usage,
            .stop_reason = stop_reason,
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
    if (std.mem.eql(u8, w.kind, "model_rebind")) {
        // The descriptor is required and the profile is not: a session can be
        // rebound to a model without naming a profile, but a rebind that does
        // not say what to run is not a rebind.
        return .{ .model_rebind = .{
            .profile = w.profile orelse "",
            .identity = w.identity orelse return error.CorruptLedger,
        } };
    }
    if (std.mem.eql(u8, w.kind, "task_finished")) {
        return .{ .task_finished = .{
            .task = w.task orelse return error.CorruptLedger,
            .exit_code = w.exit_code orelse return error.CorruptLedger,
            .text = w.text orelse return error.CorruptLedger,
        } };
    }
    return error.CorruptLedger;
}

// ── Cross-process inbox ───────────────────────────────────────
//
// The session file has one writer. Any other process proposes an event by
// depositing one `<name>.json` file (an event body, no `seq`) into the sibling
// directory `<stem>.inbox/`; the writer drains it at its next step boundary —
// after repairing any interrupted batch, before the model runs — so a drained
// event never lands inside a tool batch. Deposits are atomic (write `.tmp`,
// rename), so a drain never reads a half-written body.

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
/// the directory `session_path` is relative to.
///
/// `name` is the exactly-once key and must be filesystem-safe: two deposits
/// under one name collapse into one event. A depositor wanting idempotence picks
/// a deterministic name (capability notes use `note-<id>-<version>`); one
/// wanting a distinct event every time takes it from `freshDeliveryName`.
///
/// An event too large to be read back is refused HERE
/// (`InboxEventTooLarge`), before a byte is written.
///
/// Takes the inbox's lease, so a new depositor gets the rule without having to
/// remember it. A caller already holding the lease across a read-then-deposit
/// calls `depositEventLeased` instead (taking it twice deadlocks).
pub fn depositEvent(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8, name: []const u8, e: Event) !void {
    var lease = try acquireDepositLease(alloc, io, base, session_path, .block);
    defer lease.close(io);
    return depositEventLeased(alloc, io, base, session_path, name, e);
}

/// Whether taking the deposit lease waits for whoever holds it.
///
/// A depositor WAITS: it is here to add a fact, and the other holder is about
/// to finish. `pruneSession` does NOT: it is here to take a session away, so
/// "somebody is depositing right now" is an answer, not a queue to join.
pub const DepositWait = enum { block, fail_fast };

/// The exclusive right to deposit into this session's inbox. Held by EVERY
/// writer of the inbox, for three rules:
///
///   * A gate that READS the session and then deposits must be one act.
///     `append --image` refuses a picture the model in force cannot see, and
///     `rebind` refuses a model that cannot see the pictures already here; run
///     concurrently, both read the old state, both pass, and exactly the pair
///     they exist to refuse lands. Same for a delivery id, which is minted from
///     what is already waiting (`freshDeliveryName`).
///   * A session may not be taken away between a depositor's check and its
///     write. `pruneSession` removes one only while holding this and the writer
///     lease; every deposit re-checks the session under this lease
///     (`depositEventLeased`), closing the window from the other side.
///   * Nor between the check and the START of something long-lived under it: a
///     background task's supervisor writes into the session's scratch tree for
///     as long as it runs, and `nulya task run` holds this across "does this
///     session exist" and the spawn. Together with the writer lease — which
///     covers the other way a task starts, from inside a step — that makes the
///     pair the session's lifetime freeze (`SessionLeases`).
///
/// It lives INSIDE the inbox, and is emphatically NOT the session's `.lock`:
/// that one belongs to `step`, and every gate above must work while a step runs.
/// Neither the drain nor a scan looks at anything but `*.json` there.
///
/// LOCK ORDER: nothing takes the writer lease and then this one (`step` never
/// deposits); `acquireSessionLeases`, the one place both are held, takes this
/// one first and the writer lease non-blocking. Two of THESE at once is
/// `moveDeposit` alone, in session-path order.
pub fn acquireDepositLease(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    wait: DepositWait,
) !Lease {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    try base.createDirPath(io, inbox);
    const lock_rel = try depositLockPath(alloc, session_path);
    defer alloc.free(lock_rel);
    return .{ .file = try base.createFile(io, lock_rel, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = wait == .fail_fast,
    }) };
}

/// A held lease, either of a session's two. Closing it releases the lease;
/// closing it twice is a no-op, which is what lets a callee release it at the
/// one moment it may (a lock file cannot be unlinked while its opener holds it)
/// without taking the handle away from the caller's `defer`.
pub const Lease = struct {
    file: std.Io.File,
    open: bool = true,

    pub fn close(self: *Lease, io: std.Io) void {
        if (!self.open) return;
        self.file.close(io);
        self.open = false;
    }
};

/// BOTH of a session's leases, held at once.
///
/// Only under the pair does "nothing is alive under this session" stay true
/// long enough to act on, because a long-lived writer under a session's scratch
/// tree can be started down either of two paths: `nulya task run` takes the
/// deposit lease across it, and an in-step `shell {background:true}` is covered
/// by the writer lease its step is holding. A caller that answers that question
/// under one of them alone has only narrowed the window it is racing.
///
/// The order is fixed here rather than remembered at each site: deposit lease
/// first, writer lease non-blocking. Nothing in the system takes the writer
/// lease and then a deposit lease (`step` never deposits), so this is the only
/// place the two are held at once.
pub const SessionLeases = struct {
    deposits: Lease,
    writer: Lease,

    pub fn close(self: *SessionLeases, io: std.Io) void {
        self.writer.close(io);
        self.deposits.close(io);
    }
};

/// Take both of a session's leases: `error.DepositInFlight` when somebody is
/// inside its inbox, `error.SessionBusy` when a step is writing it. Neither is
/// a queue to join — both are answers.
pub fn acquireSessionLeases(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
) !SessionLeases {
    var deposits = try leaseOrRefuse(alloc, io, base, session_path, .fail_fast);
    errdefer deposits.close(io);
    const writer = try acquireWriterLease(alloc, io, base, session_path);
    return .{ .deposits = deposits, .writer = .{ .file = writer } };
}

/// `<inbox>/.deposit.lock`.
fn depositLockPath(alloc: std.mem.Allocator, session_path: []const u8) ![]u8 {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    return std.fmt.allocPrint(alloc, "{s}{c}.deposit.lock", .{ inbox, std.fs.path.sep });
}

/// `depositEvent` for a caller that ALREADY holds the deposit lease.
pub fn depositEventLeased(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8, name: []const u8, e: Event) !void {
    // Under the lease, so it is not a guess: `pruneSession` cannot remove the
    // session between here and the rename below.
    base.access(io, session_path, .{}) catch return error.NoSuchSession;

    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try encodeEventBody(&jw, e);
    try jw.endObject();
    if (out.written().len > max_inbox_event_bytes) return error.InboxEventTooLarge;

    try base.createDirPath(io, inbox);

    const tmp_rel = try std.fmt.allocPrint(alloc, "{s}{c}{s}.tmp", .{ inbox, std.fs.path.sep, name });
    defer alloc.free(tmp_rel);
    const final_rel = try depositFilePath(alloc, session_path, name);
    defer alloc.free(final_rel);
    try base.writeFile(io, .{ .sub_path = tmp_rel, .data = out.written() });
    try base.rename(tmp_rel, base, final_rel, io);
}

/// The deposit leases of TWO sessions, held at once — what any act that changes
/// WHERE a result will land needs, because such an act touches both ends and
/// neither end may be pruned out from under it in between. Naming one session
/// twice takes one lease; taking the same lease twice would deadlock on the
/// second.
///
/// LOCK ORDER: in session-path order, never in call order — two such pairs in
/// opposite directions would otherwise each hold what the other waits for.
pub const DepositPair = struct {
    first: Lease,
    second: ?Lease,

    pub fn close(self: *DepositPair, io: std.Io) void {
        if (self.second) |*l| l.close(io);
        self.first.close(io);
    }
};

pub fn acquireDepositPair(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    a_session_path: []const u8,
    b_session_path: []const u8,
    wait: DepositWait,
) !DepositPair {
    if (std.mem.eql(u8, a_session_path, b_session_path)) {
        return .{ .first = try leaseOrRefuse(alloc, io, base, a_session_path, wait), .second = null };
    }
    const a_first = std.mem.lessThan(u8, a_session_path, b_session_path);
    const first_path = if (a_first) a_session_path else b_session_path;
    const second_path = if (a_first) b_session_path else a_session_path;

    var first = try leaseOrRefuse(alloc, io, base, first_path, wait);
    errdefer first.close(io);
    const second = try leaseOrRefuse(alloc, io, base, second_path, wait);
    return .{ .first = first, .second = second };
}

/// Move the undrained deposit `name` from one session's inbox to another's —
/// the second way a fact reaches an inbox, and the only way one leaves an inbox
/// without being drained. False when there was nothing to move, which is the
/// ordinary case once the owning session has stepped.
///
/// It is a WRITE OF BOTH INBOXES, so it holds BOTH leases: the destination's,
/// like every depositor, and the source's, because "having the lease means this
/// inbox does not change under me" is what `pruneSession` counts on when it
/// lists what a session still holds.
///
/// Under the leases: a destination session that is gone is `error.NoSuchSession`
/// and the file stays where it is; a source deposit drained in the meantime is
/// `false`.
pub fn moveDeposit(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    from_session_path: []const u8,
    to_session_path: []const u8,
    name: []const u8,
    wait: DepositWait,
) !bool {
    if (std.mem.eql(u8, from_session_path, to_session_path)) return false;

    const src = try depositFilePath(alloc, from_session_path, name);
    defer alloc.free(src);

    // Before any lock: the common answer is "nothing to move", and it costs
    // nobody the leases to say so.
    base.access(io, src, .{}) catch return false;

    var pair = try acquireDepositPair(alloc, io, base, from_session_path, to_session_path, wait);
    defer pair.close(io);
    return moveDepositLeased(alloc, io, base, from_session_path, to_session_path, name);
}

/// `moveDeposit` for a caller that ALREADY holds both inboxes' leases
/// (`acquireDepositPair`) — because the move is only half of what it has to do
/// atomically. `task retarget` is the case: the `notify` pointer it writes and
/// the deposit it moves are two physical halves of ONE routing fact, and the
/// destination has to still exist for both of them or neither.
pub fn moveDepositLeased(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    from_session_path: []const u8,
    to_session_path: []const u8,
    name: []const u8,
) !bool {
    if (std.mem.eql(u8, from_session_path, to_session_path)) return false;

    const src = try depositFilePath(alloc, from_session_path, name);
    defer alloc.free(src);
    const dst = try depositFilePath(alloc, to_session_path, name);
    defer alloc.free(dst);

    base.access(io, to_session_path, .{}) catch return error.NoSuchSession;
    // A second look under the lease: the source may have been drained while
    // this waited for it, and then there is nothing to move after all.
    base.access(io, src, .{}) catch return false;
    try base.rename(src, base, dst, io);
    return true;
}

/// `acquireDepositLease` with the caller's `fail_fast` spelled as the refusal
/// every reader of one already knows.
fn leaseOrRefuse(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    wait: DepositWait,
) !Lease {
    return acquireDepositLease(alloc, io, base, session_path, wait) catch |err| switch (err) {
        error.WouldBlock => error.DepositInFlight,
        else => err,
    };
}

/// `<inbox>/<name>.json` — where one deposited event lands.
fn depositFilePath(alloc: std.mem.Allocator, session_path: []const u8, name: []const u8) ![]u8 {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    return std.fmt.allocPrint(alloc, "{s}{c}{s}.json", .{ inbox, std.fs.path.sep, name });
}

/// The largest one deposited event may be, encoded.
///
/// The invariant it holds: whatever the inbox ACCEPTS, a step boundary can read
/// back. Enforced at the deposit, because an event accepted and then too large
/// to read is a durable fact that makes every later `drainInbox` fail. One
/// number, enforced where events are written and used where they are read
/// (`drainInbox`, `scanSession`).
///
/// Sized against what the shell already accepts for one turn: an 8 MiB `--file`
/// text plus several images, each up to 5 MiB raw and ~4/3 that as base64.
pub const max_inbox_event_bytes: usize = 32 << 20;

/// A delivery id for one more fact. Two load-bearing properties:
///
/// **Distinct on every call**, because the name IS the exactly-once key. Getting
/// it wrong is silent — a colliding second deposit is deleted at the next drain
/// and never reaches the ledger. Distinct by CONSTRUCTION only within one inbox
/// (the stamp steps past what is still waiting there); against an
/// already-drained name it is a 128-bit nonce's collision resistance, not a
/// proof.
///
/// **Sorts after every name still waiting in this inbox under the same prefix**,
/// because `drainInbox` applies files in filename order: the name is also the
/// QUEUE POSITION. That set is exactly the one whose order means something (two
/// queued messages merge into one turn in this order; of two waiting rebinds the
/// last is what the session ends on). A wall clock alone does not give it — it
/// can repeat or step backwards, and then the random tail decides — so the mint
/// reads the inbox and steps past the newest stamp there. Committed events need
/// no such care: anything still waiting is applied after all of them.
///
/// NOT defended: two mints racing (the commands where that matters serialize on
/// the deposit lease) and order ACROSS prefixes (cosmetic — a rebind is not a
/// turn).
pub fn freshDeliveryName(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    prefix: []const u8,
) ![]u8 {
    const now = std.Io.Timestamp.now(io, .real).toNanoseconds();
    var stamp: u64 = if (now < 0) 0 else @intCast(@min(now, max_stamp));
    if (try latestWaitingStamp(alloc, io, base, session_path, prefix)) |seen| {
        // `+ 1` is enough to sort after it: the stamp is a fixed-width field, so
        // the comparison never reaches the random tail.
        if (seen >= stamp and seen < max_stamp) stamp = seen + 1;
    }
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    return std.fmt.allocPrint(alloc, "{s}-{d:0>19}-{x}", .{
        prefix,
        stamp,
        std.mem.readInt(u128, &nonce, .little),
    });
}

/// The widest stamp the name's fixed-width field can hold (nanoseconds reach it
/// in 2286). A name beyond it costs only the ordering step above; the id is
/// still distinct.
const max_stamp: u64 = 9_999_999_999_999_999_999;

/// True for exactly the inbox entries that count as one deposited fact: a
/// `.json` file. The lease file and anything else alongside the deposits is not
/// — every reader of the inbox filters on this.
fn isInboxDeposit(kind: anytype, name: []const u8) bool {
    return kind == .file and std.mem.endsWith(u8, name, ".json");
}

/// The newest stamp among the names this prefix already has waiting, or null
/// when the inbox holds none. A name with no readable stamp is skipped: it is
/// foreign, and not something to order against.
fn latestWaitingStamp(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    prefix: []const u8,
) !?u64 {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    var dir = base.openDir(io, inbox, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var newest: ?u64 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!isInboxDeposit(entry.kind, entry.name)) continue;
        const stamp = stampOf(entry.name, prefix) orelse continue;
        if (newest == null or stamp > newest.?) newest = stamp;
    }
    return newest;
}

/// Whether a drainable event is waiting in this session's inbox.
pub fn inboxHoldsDeposit(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8) !bool {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    var dir = base.openDir(io, inbox, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (isInboxDeposit(entry.kind, entry.name)) return true;
    }
    return false;
}

/// How much of a session `pruneSession` may take away.
pub const PruneOptions = struct {
    /// Remove a session that HOLDS something: recorded events, waiting
    /// deposits, or both. It lifts only the refusals about what the session
    /// holds; the ones about who holds it right now (a step, a deposit in
    /// flight) are locks, not judgments, and cannot be overridden.
    force: bool = false,
};

/// What `pruneSession` took away, for a caller that has to say so out loud.
pub const PruneReport = struct {
    /// Events recorded in the ledger, not counting the header line.
    events: usize,
    /// Deposits waiting in the inbox that no step ever drained.
    deposits: usize,
    /// Something that belongs to this session is still on disk: the session
    /// itself was removed (that is what a report at all means), and one of the
    /// files that only served it would not go. A note for the caller, never an
    /// error — see the commit point in `pruneSessionLeased`.
    leftovers: bool = false,
};

/// Remove the session at `session_path` (relative to `base`) — the session file
/// and every sibling that is part of it (`.cancel`, both lease files, the inbox)
/// — or refuse and leave every byte where it is. A refusal is total; once the
/// session file is gone the call has COMMITTED, and a sibling that will not go
/// is reported in `leftovers` rather than raised.
///
/// The two facts that forbid removal are LOCKS (a step writing it, a deposit in
/// flight), and a lock can only be answered by TAKING it: a caller that probes
/// instead guesses wrong exactly when it matters, while another process sits
/// between its own check and its deposit. So every check and the removal happen
/// under BOTH leases, and the inbox lease is the one every depositor takes — a
/// supervisor delivering a task report is as much a reason to leave a session
/// alone as a queued turn is.
///
/// A caller with a lock-shaped question of its own asks it under the same pair
/// and calls `pruneSessionLeased`.
///
/// NOT here: which sessions deserve removing (a judgment; the caller names one
/// id), and anything outside the session's own files. Journal rows about a
/// pruned session stay — "no row = unknown" is the discipline, and a row is
/// evidence about something that happened.
///
/// Refusals are distinct errors so a caller can say which: `NoSuchSession`,
/// `SessionBusy` (a step holds the writer lease), `DepositInFlight`, and —
/// unless `force` — `HasEvents` and `HoldsDeposits`.
pub fn pruneSession(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    opts: PruneOptions,
) !PruneReport {
    base.access(io, session_path, .{}) catch return error.NoSuchSession;
    var leases = try acquireSessionLeases(alloc, io, base, session_path);
    defer leases.close(io);
    return pruneSessionLeased(alloc, io, base, session_path, opts, &leases);
}

/// `pruneSession` for a caller that ALREADY holds this session's leases — and
/// holds them because it had a question of its own to settle under them.
///
/// The pair is what freezes a session's LIFETIME (`SessionLeases`): with both
/// held, no new background task can appear under this session by either path.
/// The question that needs them — "is a task of this session still running?" —
/// is the caller's to answer, because reading every task directory (and, for a
/// remote session, asking another machine) is not something the ledger does.
/// Which is exactly why the leases have to be takeable from outside.
///
/// They are closed by this call when the session goes; the caller's own `defer`
/// covers every other path (closing twice is a no-op).
pub fn pruneSessionLeased(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    opts: PruneOptions,
    leases: *SessionLeases,
) !PruneReport {
    // Asked again under the leases: another prune could have finished in
    // between, and taking the deposit lease recreated the inbox it just removed.
    // Best effort on the way out — the session is already gone.
    base.access(io, session_path, .{}) catch {
        leases.writer.close(io);
        deleteSibling(alloc, io, base, session_path, ".lock") catch {};
        leases.deposits.close(io);
        removeInbox(alloc, io, base, session_path, &.{}) catch {};
        return error.NoSuchSession;
    };

    const bytes = try base.readFileAlloc(io, session_path, alloc, .unlimited);
    defer alloc.free(bytes);
    var lines = completeLines(bytes);
    var complete: usize = 0;
    while (lines.next()) |_| complete += 1;
    const events = complete -| 1;

    const names = try listInboxDeposits(alloc, io, base, session_path);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    if (!opts.force) {
        if (events != 0) return error.HasEvents;
        if (names.len != 0) return error.HoldsDeposits;
    }

    // THE COMMIT POINT. Up to here every failure is a refusal that leaves every
    // byte where it is; the session file's absence is what every other process
    // reads as "gone", and no filesystem can put it back. So nothing after this
    // line may fail the call: what is left over is reported, not raised — one
    // completion rule for the whole session, the one the caller's scratch tree
    // already follows.
    try base.deleteFile(io, session_path);

    // Each lease is closed before its own file is removed — Windows will not
    // unlink an open file, and here the opener is us.
    var leftovers = false;
    deleteSibling(alloc, io, base, session_path, ".cancel") catch {
        leftovers = true;
    };
    leases.writer.close(io);
    deleteSibling(alloc, io, base, session_path, ".lock") catch {
        leftovers = true;
    };
    leases.deposits.close(io);
    removeInbox(alloc, io, base, session_path, names) catch {
        leftovers = true;
    };

    return .{ .events = events, .deposits = names.len, .leftovers = leftovers };
}

/// Remove the deposit lock, the deposits this prune counted, and then the inbox
/// directory — which goes only if empty, since anything else in there is
/// something this prune never accounted for: a `<name>.tmp` a depositor died
/// halfway through, say. That directory is then a LEFTOVER and says so; the
/// error rides out to `pruneSessionLeased`, which is past its commit point and
/// turns it into the report's flag.
fn removeInbox(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    names: []const []u8,
) !void {
    const lock_rel = try depositLockPath(alloc, session_path);
    defer alloc.free(lock_rel);
    try deleteIfPresent(io, base, lock_rel);

    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    for (names) |name| {
        const rel = try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{ inbox, std.fs.path.sep, name });
        defer alloc.free(rel);
        try deleteIfPresent(io, base, rel);
    }
    base.deleteDir(io, inbox) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deleteSibling(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8, suffix: []const u8) !void {
    const path = try siblingPath(alloc, session_path, suffix);
    defer alloc.free(path);
    try deleteIfPresent(io, base, path);
}

fn deleteIfPresent(io: std.Io, base: std.Io.Dir, path: []const u8) !void {
    base.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Every deposited `.json` in this inbox, sorted in the order `drainInbox`
/// applies them — lexical by filename, which is the queue position. A missing
/// inbox directory reads as empty, not an error. Names are allocated with
/// `alloc`; the caller frees each name and the slice (or passes an arena).
fn listInboxDeposits(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8) ![][]u8 {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    var dir = base.openDir(io, inbox, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!isInboxDeposit(entry.kind, entry.name)) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(alloc);
}

/// `<prefix>-<stamp>-<nonce>.json` → `stamp`.
fn stampOf(name: []const u8, prefix: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    if (rest.len == 0 or rest[0] != '-') return null;
    const digits_and_more = rest[1..];
    const end = std.mem.indexOfScalar(u8, digits_and_more, '-') orelse return null;
    return std.fmt.parseInt(u64, digits_and_more[0..end], 10) catch null;
}

/// Drain every deposited `.json` in filename order. Consecutive user messages
/// become ONE delivery batch: one user turn, texts separated by a blank line,
/// images in FIFO order. Non-user facts stay separate events and delimit
/// batches.
///
/// EXACTLY-once holds through merging: the line persists every source filename
/// in `origins`, so a crash after append but before any delete makes a reopen
/// skip every member of that batch.
pub fn drainInbox(alloc: std.mem.Allocator, io: std.Io, l: *Ledger, base: std.Io.Dir, session_path: []const u8) !void {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);

    const names = try listInboxDeposits(alloc, io, base, session_path);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    var dir = base.openDir(io, inbox, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var batch_arena: std.heap.ArenaAllocator = .init(alloc);
    defer batch_arena.deinit();
    const batch_alloc = batch_arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var images: std.ArrayList(Image) = .empty;
    defer images.deinit(alloc);
    var batch_origins: std.ArrayList([]const u8) = .empty;
    defer batch_origins.deinit(alloc);

    for (names) |name| {
        if (l.containsOrigin(name)) {
            try dir.deleteFile(io, name);
            continue;
        }
        const bytes = try dir.readFileAlloc(io, name, alloc, .limited(max_inbox_event_bytes));
        defer alloc.free(bytes);
        const parsed = try parseEventLine(alloc, bytes);
        defer parsed.deinit();
        const e = try toEvent(parsed.arena.allocator(), parsed.value);

        if (e == .user_text) {
            if (text.items.len > 0) try text.appendSlice(alloc, "\n\n");
            try text.appendSlice(alloc, e.user_text.text);
            for (e.user_text.images) |image| try images.append(alloc, .{
                .media_type = try batch_alloc.dupe(u8, image.media_type),
                .data = try batch_alloc.dupe(u8, image.data),
            });
            try batch_origins.append(alloc, name);
            continue;
        }

        try flushInboxUsers(l, &text, &images, &batch_origins);
        for (batch_origins.items) |origin| try dir.deleteFile(io, origin);
        batch_origins.clearRetainingCapacity();

        const already_content = switch (e) {
            .capability_note => |n| l.containsNote(n.id, n.version),
            else => false,
        };
        if (!already_content) try l.appendWithOrigin(e, name);
        try dir.deleteFile(io, name);
    }

    try flushInboxUsers(l, &text, &images, &batch_origins);
    for (batch_origins.items) |origin| try dir.deleteFile(io, origin);
}

fn flushInboxUsers(
    l: *Ledger,
    text: *std.ArrayList(u8),
    images: *std.ArrayList(Image),
    origins: *std.ArrayList([]const u8),
) !void {
    if (origins.items.len == 0) return;
    try l.appendWithOrigins(.{ .user_text = .{ .text = text.items, .images = images.items } }, origins.items);
    text.clearRetainingCapacity();
    images.clearRetainingCapacity();
}

/// What a session on disk will run on at its NEXT step, for a reader that is
/// not the writer.
///
/// `effectiveIdentity` answers the same question INSIDE a step, where every fact
/// is committed. Outside one there is a third place an identity can be: the
/// inbox. A deposited `model_rebind` is as decided as an appended one — the very
/// next step boundary applies it — so a reader stopping at the committed events
/// answers with a model the session is about to leave. Every such reader (the
/// vision gates, the rebind no-op, what a fork continues on) asks HERE.
///
/// It does not open the ledger: `openDurable` takes the writer lease, and these
/// readers must work while a step is running. So it reads bytes and honours the
/// same crash-tail rule replay does; being concurrent with the writer shapes the
/// rest (see `scanSession`).
pub const SessionScan = struct {
    arena: std.heap.ArenaAllocator,
    /// The last rebind this session has been told about, committed or pending;
    /// null when it still runs on what its header froze. Decided at the end of
    /// `scanSession` from the two below.
    rebound: ?Identity = null,
    /// Whether any user turn, committed or pending, carries an image.
    has_images: bool = false,

    /// The last rebind still waiting in the inbox, in the order the drain will
    /// apply them, and whether the ledger turned out to have applied it already.
    /// Only the LAST one is kept: the drain works in filename order, so a later
    /// name being committed implies every earlier one is too.
    pending: ?struct { name: []const u8, id: Identity } = null,
    pending_drained: bool = false,
    /// The last rebind in the ledger, in ledger order.
    committed: ?Identity = null,

    /// The identity in force, given the header the same reader already holds.
    pub fn identity(self: SessionScan, header: Header) Identity {
        return self.rebound orelse .{ .profile = header.model, .identity = header.model_identity };
    }

    pub fn deinit(self: *SessionScan) void {
        self.arena.deinit();
    }

    /// The pre-filter both passes share: the decoded line, or null when it says
    /// nothing this scan cares about. An undecodable body is SKIPPED rather than
    /// fatal — only the writer gets to declare a ledger corrupt. Images fold in
    /// here because they only accumulate, so either pass may be the one to see
    /// them.
    fn look(self: *SessionScan, a: std.mem.Allocator, body: []const u8) ?WireEvent {
        // The substring tests keep a gate from decoding a whole transcript; the
        // decoded `kind` is what decides.
        const may_be_rebind = std.mem.indexOf(u8, body, "\"kind\":\"model_rebind\"") != null;
        const may_have_images = !self.has_images and std.mem.indexOf(u8, body, "\"images\":") != null;
        if (!may_be_rebind and !may_have_images) return null;
        const parsed = parseEventLine(a, body) catch return null;
        if (std.mem.eql(u8, parsed.value.kind, "user_text")) {
            if (parsed.value.images) |images| {
                if (images.len != 0) self.has_images = true;
            }
        }
        if (!std.mem.eql(u8, parsed.value.kind, "model_rebind")) return null;
        if (parsed.value.identity == null) return null;
        return parsed.value;
    }

    fn observeDeposit(self: *SessionScan, a: std.mem.Allocator, name: []const u8, body: []const u8) void {
        const line = self.look(a, body) orelse return;
        self.pending = .{ .name = name, .id = identityOfLine(line) };
    }

    fn observeCommitted(self: *SessionScan, a: std.mem.Allocator, body: []const u8) void {
        const line = self.look(a, body) orelse return;
        self.committed = identityOfLine(line);
        // The same fact seen twice: this line IS the deposit the inbox pass
        // read, drained between the two passes.
        if (self.pending) |p| {
            if (line.origin) |o| {
                if (std.mem.eql(u8, o, p.name)) self.pending_drained = true;
            }
        }
    }
};

fn identityOfLine(line: WireEvent) Identity {
    return .{ .profile = line.profile orelse "", .identity = line.identity.? };
}

pub fn scanSession(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8) !SessionScan {
    var scan: SessionScan = .{ .arena = .init(alloc) };
    errdefer scan.arena.deinit();
    const a = scan.arena.allocator();

    // The INBOX first and the ledger second — the opposite of the order the
    // drain applies them in, because a drain appends to the ledger and THEN
    // deletes the file. Ledger-first would let a fact be in NEITHER pass:
    // committed just after the ledger was read, deleted just before the inbox
    // was listed. This way round, every fact decided before the scan began shows
    // up in at least one pass.
    try scanInbox(&scan, a, io, base, session_path);
    try scanLedger(&scan, a, io, base, session_path);

    // A file still waiting is applied AFTER everything committed, so it wins —
    // but only while it is still genuinely waiting. The inbox pass reads files
    // one at a time, so a concurrent drain can commit AND delete a LATER deposit
    // between two of those reads, leaving this scan holding an earlier one and
    // blind to the later one. The deposit's own delivery id settles it: if the
    // ledger carries it as an `origin`, the drain has been through and its last
    // committed rebind is the newer truth (also the right answer for a file left
    // behind by a crash between append and delete).
    const pending_wins = scan.pending != null and !scan.pending_drained;
    scan.rebound = if (pending_wins) scan.pending.?.id else scan.committed;
    return scan;
}

/// Every deposited body still waiting, in the order the drain will apply it.
fn scanInbox(scan: *SessionScan, a: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8) !void {
    const inbox = try inboxPath(a, session_path);
    const names = try listInboxDeposits(a, io, base, session_path); // arena-allocated; nothing to free here
    var dir = base.openDir(io, inbox, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    for (names) |name| {
        // A file that vanished between the listing and here was drained by the
        // writer; the ledger pass is where it turns up.
        const body = dir.readFileAlloc(io, name, a, .limited(max_inbox_event_bytes)) catch continue;
        scan.observeDeposit(a, name, body);
    }
}

/// Every committed line, in ledger order, minus the torn tail replay drops too.
fn scanLedger(scan: *SessionScan, a: std.mem.Allocator, io: std.Io, base: std.Io.Dir, session_path: []const u8) !void {
    const bytes = try base.readFileAlloc(io, session_path, a, .unlimited);
    var lines = completeLines(bytes);
    var header_seen = false;
    while (lines.next()) |line| {
        if (!header_seen) {
            header_seen = true;
            continue;
        }
        scan.observeCommitted(a, line);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "Usage.add sums every field in place and treats zero as the identity" {
    var total: Usage = .{};
    try std.testing.expect(total.isZero());
    total.add(.{ .input_tokens = 1, .output_tokens = 2, .cache_read_tokens = 3, .cache_write_tokens = 4 });
    total.add(.{ .input_tokens = 10, .output_tokens = 20, .cache_read_tokens = 30, .cache_write_tokens = 40 });
    // A step whose provider reported nothing contributes nothing.
    total.add(.{});
    try std.testing.expectEqual(Usage{
        .input_tokens = 11,
        .output_tokens = 22,
        .cache_read_tokens = 33,
        .cache_write_tokens = 44,
    }, total);
}

test "ledger only grows and preserves order" {
    var l = Ledger.init(std.testing.allocator);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "a" } });
    try l.append(.{ .user_text = .{ .text = "b" } });
    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expectEqualStrings("a", l.view()[0].user_text.text);
    try std.testing.expectEqualStrings("b", l.view()[1].user_text.text);
}

fn expectEventsEqual(a: []const Event, b: []const Event) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqual(std.meta.activeTag(x), std.meta.activeTag(y));
        switch (x) {
            .user_text => |t| {
                try std.testing.expectEqualStrings(t.text, y.user_text.text);
                try std.testing.expectEqual(t.images.len, y.user_text.images.len);
                for (t.images, y.user_text.images) |i, j| {
                    try std.testing.expectEqualStrings(i.media_type, j.media_type);
                    try std.testing.expectEqualStrings(i.data, j.data);
                }
            },
            .assistant => |as| {
                try std.testing.expectEqualStrings(as.reasoning, y.assistant.reasoning);
                try std.testing.expectEqualStrings(as.text, y.assistant.text);
                try std.testing.expectEqual(as.usage, y.assistant.usage);
                try std.testing.expectEqual(as.stop_reason, y.assistant.stop_reason);
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
                    try std.testing.expectEqual(r.spill_path != null, s.spill_path != null);
                    if (r.spill_path) |p| try std.testing.expectEqualStrings(p, s.spill_path.?);
                    try std.testing.expectEqual(r.presentation != null, s.presentation != null);
                    if (r.presentation) |p| try std.testing.expectEqualStrings(p, s.presentation.?);
                }
            },
            .capability_note => |n| {
                try std.testing.expectEqualStrings(n.id, y.capability_note.id);
                try std.testing.expectEqualStrings(n.version, y.capability_note.version);
                try std.testing.expectEqualStrings(n.text, y.capability_note.text);
            },
            .task_finished => |t| {
                try std.testing.expectEqualStrings(t.task, y.task_finished.task);
                try std.testing.expectEqual(t.exit_code, y.task_finished.exit_code);
                try std.testing.expectEqualStrings(t.text, y.task_finished.text);
            },
            .model_rebind => |r| {
                try std.testing.expectEqualStrings(r.profile, y.model_rebind.profile);
                try std.testing.expectEqualStrings(r.identity.provider, y.model_rebind.identity.provider);
                try std.testing.expectEqualStrings(r.identity.model, y.model_rebind.identity.model);
                try std.testing.expectEqualStrings(r.identity.base_url, y.model_rebind.identity.base_url);
                try std.testing.expectEqualStrings(r.identity.api_key_env, y.model_rebind.identity.api_key_env);
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
    .nulya = .{ .version = "0.0.0", .kernel_hash = "abc123" },
    .composition = .{
        .active = &.{.{ .id = "web.search", .version = "v-0123456789abcdef01234567" }},
        .native_tools = &.{"ext:web.search/web_search"},
        .prompts = &.{.{ .source = "agent-explore", .text = "You are a scout.\n" }},
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
    try std.testing.expectEqualStrings("0.0.0", h.nulya.version);
    try std.testing.expectEqualStrings("abc123", h.nulya.kernel_hash);
    try std.testing.expectEqual(@as(usize, 1), h.composition.active.len);
    try std.testing.expectEqualStrings("web.search", h.composition.active[0].id);
    try std.testing.expectEqualStrings("v-0123456789abcdef01234567", h.composition.active[0].version);
    try std.testing.expectEqual(@as(usize, 1), h.composition.native_tools.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", h.composition.native_tools[0]);
    // The inline prompt rides as VALUE, so resume needs nothing but this file.
    try std.testing.expectEqual(@as(usize, 1), h.composition.prompts.len);
    try std.testing.expectEqualStrings("agent-explore", h.composition.prompts[0].source);
    try std.testing.expectEqualStrings("You are a scout.\n", h.composition.prompts[0].text);
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
    // …and a header written before the provenance stamp existed reads back as
    // an EMPTY stamp: unknown, which is never a mismatch to warn about.
    try std.testing.expectEqualStrings("", newer.value.nulya.version);
    try std.testing.expectEqualStrings("", newer.value.nulya.kernel_hash);
    // Same for a header written before inline prompts existed: no field, no
    // prompts — the header `v` stays 1 because the old meanings all still hold.
    try std.testing.expectEqual(@as(usize, 0), newer.value.composition.prompts.len);
}

test "a header from a future ledger version is refused, not read as v1" {
    const alloc = std.testing.allocator;
    // Extra fields are forgiven; a different `v` is not — the same field names
    // may mean something else in a format this binary never implemented.
    try std.testing.expectError(
        error.UnsupportedLedgerVersion,
        parseHeaderLine(alloc, "{\"kind\":\"header\",\"v\":2,\"session\":\"s\"}"),
    );
    // The check is on the exact version, so an older one is refused too.
    try std.testing.expectError(
        error.UnsupportedLedgerVersion,
        parseHeaderLine(alloc, "{\"kind\":\"header\",\"v\":0,\"session\":\"s\"}"),
    );
    const ours = try parseHeaderLine(alloc, "{\"kind\":\"header\",\"v\":1,\"session\":\"s\"}");
    defer ours.deinit();
    try std.testing.expectEqual(format_version, ours.value.v);
}

/// How many events `writeSampleEvents` writes, so the round-trip tests below
/// say "all of them" rather than restating a number.
const sample_event_count = 5;

fn writeSampleEvents(l: *Ledger) !void {
    try l.append(.{ .user_text = .{ .text = "hi" } });
    try l.append(.{ .assistant = .{
        .reasoning = "[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig==\"}]",
        .text = "running",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo one\"}" }},
        .usage = .{ .input_tokens = 1200, .output_tokens = 80, .cache_read_tokens = 1100 },
        .stop_reason = .tool_use,
    } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "one\n[exit 0]" }} });
    try l.append(.{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "note text" } });
    try l.append(.{ .model_rebind = .{
        .profile = "anthropic",
        .identity = .{ .provider = "anthropic", .model = "claude-sonnet-5", .base_url = "https://api.anthropic.com", .api_key_env = "ANTHROPIC_API_KEY" },
    } });
}

test "the model a session runs on is the last rebind, or the header when there is none" {
    const alloc = std.testing.allocator;
    var l = Ledger.init(alloc);
    defer l.deinit();
    const header: Header = .{ .model = "openai", .model_identity = .{ .provider = "openai", .model = "gpt-4o-mini" } };

    // No rebind: the header, and nothing before it to stop replaying.
    try l.append(.{ .user_text = .{ .text = "hi" } });
    try std.testing.expectEqualStrings("gpt-4o-mini", effectiveIdentity(header, l.view()).identity.model);
    try std.testing.expectEqual(@as(usize, 0), reasoningFloor(l.view()));
    try std.testing.expect(lastRebind(l.view()) == null);

    try l.append(.{ .model_rebind = .{ .profile = "anthropic", .identity = .{ .provider = "anthropic", .model = "claude-sonnet-5" } } });
    try l.append(.{ .assistant = .{ .reasoning = "[{}]", .text = "after", .calls = &.{} } });
    // The last one wins, and everything before it is behind the floor.
    try l.append(.{ .model_rebind = .{ .profile = "openai", .identity = .{ .provider = "openai", .model = "gpt-5.6-sol" } } });
    const now = effectiveIdentity(header, l.view());
    try std.testing.expectEqualStrings("openai", now.profile);
    try std.testing.expectEqualStrings("gpt-5.6-sol", now.identity.model);
    try std.testing.expectEqual(l.view().len, reasoningFloor(l.view()));
}

test "a reader outside the step sees the rebind that is still in the inbox" {
    // A deposited rebind is as decided as an appended one — the next step
    // boundary applies it — so a gate stopping at the committed events would
    // judge against a model already on its way out.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";
    const header: Header = .{ .model = "openai", .model_identity = .{ .provider = "openai", .model = "gpt-4o-mini" } };

    {
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s", .model = header.model, .model_identity = header.model_identity });
        defer l.deinit();
        try l.append(.{ .model_rebind = .{ .profile = "anthropic", .identity = .{ .provider = "anthropic", .model = "committed" } } });
    }

    {
        var scan = try scanSession(alloc, io, tmp.dir, spath);
        defer scan.deinit();
        try std.testing.expectEqualStrings("committed", scan.identity(header).identity.model);
        try std.testing.expect(!scan.has_images);
    }

    // Two more, deposited and not yet drained: the drain applies files in
    // filename order, so the last name is the one in force. Names are spelled
    // out rather than minted — the rule under test is the drain's order, not how
    // well a clock separates two calls.
    try depositEvent(alloc, io, tmp.dir, spath, "rebind-0001", .{ .model_rebind = .{ .profile = "p", .identity = .{ .provider = "openai", .model = "pending-1" } } });
    try depositEvent(alloc, io, tmp.dir, spath, "rebind-0002", .{ .model_rebind = .{ .profile = "p", .identity = .{ .provider = "openai", .model = "pending-2" } } });
    try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = .{
        .text = "look",
        .images = &.{.{ .media_type = "image/png", .data = "x" }},
    } });

    var scan = try scanSession(alloc, io, tmp.dir, spath);
    defer scan.deinit();
    try std.testing.expectEqualStrings("pending-2", scan.identity(header).identity.model);
    // The image arrives at the same boundary, so it counts as held already.
    try std.testing.expect(scan.has_images);

    // And what the scan predicted is what the drain does.
    var l = try openDurable(alloc, io, tmp.dir, spath);
    defer l.deinit();
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqualStrings("pending-2", effectiveIdentity(header, l.view()).identity.model);
}

test "a rebind still waiting outranks one already committed" {
    // The passes run in the opposite order from the one events are applied in,
    // so this is the rule that repairs it: what is still waiting is applied
    // after everything committed, and wins even though it was read first.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";
    const header: Header = .{ .model = "openai", .model_identity = .{ .provider = "openai", .model = "frozen" } };

    {
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s", .model = header.model, .model_identity = header.model_identity });
        defer l.deinit();
        try l.append(.{ .model_rebind = .{ .profile = "p", .identity = .{ .provider = "openai", .model = "committed" } } });
    }
    try depositEvent(alloc, io, tmp.dir, spath, "rebind-0001", .{ .model_rebind = .{ .profile = "p", .identity = .{ .provider = "openai", .model = "waiting" } } });

    var scan = try scanSession(alloc, io, tmp.dir, spath);
    defer scan.deinit();
    try std.testing.expectEqualStrings("waiting", scan.identity(header).identity.model);
}

test "a deposit the ledger already applied does not outrank what came after it" {
    // The interleaving this defends against, frozen as state: the file the scan
    // read has already been applied (its delivery id is right there as
    // `origin`), and a newer rebind is committed behind it. A flat "waiting
    // wins" would answer with a model two facts out of date.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";
    const header: Header = .{ .model = "openai", .model_identity = .{ .provider = "openai", .model = "frozen" } };

    {
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s", .model = header.model, .model_identity = header.model_identity });
        defer l.deinit();
        try l.appendWithOrigin(.{ .model_rebind = .{ .profile = "p", .identity = .{ .provider = "openai", .model = "first" } } }, "rebind-0001.json");
        try l.appendWithOrigin(.{ .model_rebind = .{ .profile = "p", .identity = .{ .provider = "openai", .model = "second" } } }, "rebind-0002.json");
    }
    try depositEvent(alloc, io, tmp.dir, spath, "rebind-0001", .{ .model_rebind = .{ .profile = "p", .identity = .{ .provider = "openai", .model = "first" } } });

    var scan = try scanSession(alloc, io, tmp.dir, spath);
    defer scan.deinit();
    try std.testing.expectEqualStrings("second", scan.identity(header).identity.model);
}

test "an event too large to read back is refused at the deposit" {
    // The invariant: whatever the inbox accepts, a step boundary can read back.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";
    {
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s", .model = "openai", .model_identity = .{ .provider = "openai", .model = "m" } });
        l.deinit();
    }

    const oversized = try alloc.alloc(u8, max_inbox_event_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.InboxEventTooLarge,
        depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = .{ .text = oversized } }),
    );

    // Refused before a byte is written: nothing is left waiting.
    var l = try openDurable(alloc, io, tmp.dir, spath);
    defer l.deinit();
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 0), l.len());
}

test "a delivery id is distinct, and sorts after what is already waiting" {
    // Order is a property of the INBOX, not of the clock: the deposit below
    // carries a stamp from the far future and the next name still has to land
    // after it — which is what makes two rebinds issued in a row apply in that
    // order even if the clock repeated or stepped back.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";

    var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s" });
    defer l.deinit();

    const first = try freshDeliveryName(alloc, io, tmp.dir, spath, "rebind");
    defer alloc.free(first);
    const second = try freshDeliveryName(alloc, io, tmp.dir, spath, "rebind");
    defer alloc.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));

    try depositEvent(alloc, io, tmp.dir, spath, "rebind-9000000000000000000-ff", .{ .user_text = .{ .text = "from the future" } });
    const after = try freshDeliveryName(alloc, io, tmp.dir, spath, "rebind");
    defer alloc.free(after);
    try std.testing.expect(std.mem.lessThan(u8, "rebind-9000000000000000000-ff.json", after));

    // Another prefix is another queue; it does not drag this one forward.
    const other = try freshDeliveryName(alloc, io, tmp.dir, spath, "msg");
    defer alloc.free(other);
    try std.testing.expect(std.mem.lessThan(u8, other, "msg-9000000000000000000"));
}

test "pruneSession removes what a session is made of, and refuses history unless forced" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A name and nothing else: the default case, and the whole session goes.
    {
        const spath = "empty.jsonl";
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "empty" });
        l.deinit();

        const report = try pruneSession(alloc, io, tmp.dir, spath, .{});
        try std.testing.expectEqual(@as(usize, 0), report.events);
        try std.testing.expectEqual(@as(usize, 0), report.deposits);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, spath, .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "empty.lock", .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "empty.inbox", .{}));
        // Twice is a refusal: exit is only ever "gone because this removed it".
        try std.testing.expectError(error.NoSuchSession, pruneSession(alloc, io, tmp.dir, spath, .{}));
    }

    // History, and a turn nobody drained: two reasons to say no, one flag that
    // lifts both.
    {
        const spath = "held.jsonl";
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "held" });
        try l.append(.{ .user_text = .{ .text = "recorded" } });
        l.deinit();

        try std.testing.expectError(error.HasEvents, pruneSession(alloc, io, tmp.dir, spath, .{}));
        try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = .{ .text = "queued" } });
        try std.testing.expectError(error.HasEvents, pruneSession(alloc, io, tmp.dir, spath, .{}));
        // Still there: a refusal removes nothing.
        try tmp.dir.access(io, spath, .{});

        const report = try pruneSession(alloc, io, tmp.dir, spath, .{ .force = true });
        try std.testing.expectEqual(@as(usize, 1), report.events);
        try std.testing.expectEqual(@as(usize, 1), report.deposits);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, spath, .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "held.inbox", .{}));
    }

    // A queued turn on its own is its own reason, and its own error.
    {
        const spath = "queued.jsonl";
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "queued" });
        l.deinit();
        try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = .{ .text = "not yet stepped" } });
        try std.testing.expectError(error.HoldsDeposits, pruneSession(alloc, io, tmp.dir, spath, .{}));
        _ = try pruneSession(alloc, io, tmp.dir, spath, .{ .force = true });
    }

    // A step holding the writer lease is not a judgment a flag can overrule.
    {
        const spath = "busy.jsonl";
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "busy" });
        defer l.deinit();
        try std.testing.expectError(error.SessionBusy, pruneSession(alloc, io, tmp.dir, spath, .{ .force = true }));
        try tmp.dir.access(io, spath, .{});
    }

    // The lease is the caller's to hold: `session prune` takes it, settles "is
    // a background task alive under this session" under it, and only then hands
    // it over — so a task cannot appear between the answer and the removal.
    {
        const spath = "leased.jsonl";
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "leased" });
        l.deinit();

        var held = try acquireSessionLeases(alloc, io, tmp.dir, spath);
        defer held.close(io);
        _ = try pruneSessionLeased(alloc, io, tmp.dir, spath, .{}, &held);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, spath, .{}));
    }
}

test "pruneSession commits at the session file: what will not go afterwards is reported, not raised" {
    // Past that delete there is no rollback — the session's absence is what
    // every other process already reads as "gone" — so one completion rule
    // holds for the whole session: refuse everything, or finish and say what
    // was left. A directory where `.cancel` belongs is the portable way to make
    // one of those removals fail.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "stuck.jsonl";

    var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "stuck" });
    l.deinit();
    try tmp.dir.createDirPath(io, "stuck.cancel");
    try tmp.dir.writeFile(io, .{ .sub_path = "stuck.cancel/keep", .data = "" });

    const report = try pruneSession(alloc, io, tmp.dir, spath, .{});
    try std.testing.expect(report.leftovers);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, spath, .{}));
    try tmp.dir.access(io, "stuck.cancel", .{});
}

test "an inbox that will not go is a leftover too, not a silence" {
    // A depositor that died between its write and its rename leaves a `.tmp`
    // this prune never counted, so the directory stays — and the caller has to
    // hear about it, or the one thing left on disk is the one thing nobody says.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "residue.jsonl";

    var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "residue" });
    l.deinit();
    try tmp.dir.createDirPath(io, "residue.inbox");
    try tmp.dir.writeFile(io, .{ .sub_path = "residue.inbox/msg-0001.tmp", .data = "half" });

    const report = try pruneSession(alloc, io, tmp.dir, spath, .{});
    try std.testing.expect(report.leftovers);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, spath, .{}));
    try tmp.dir.access(io, "residue.inbox/msg-0001.tmp", .{});
}

test "a held deposit pair freezes BOTH sessions, in path order either way round" {
    // What `task retarget` needs: the pointer it writes and the deposit it
    // moves are one routing fact, and neither end may be pruned while it is
    // being changed. Order is by path, never by call, or two opposite retargets
    // each hold what the other waits for.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var a = try createDurable(alloc, io, tmp.dir, "a.jsonl", .{ .session = "a" });
    a.deinit();
    var b = try createDurable(alloc, io, tmp.dir, "b.jsonl", .{ .session = "b" });
    b.deinit();

    {
        var pair = try acquireDepositPair(alloc, io, tmp.dir, "b.jsonl", "a.jsonl", .block);
        defer pair.close(io);
        // Both ends, not just the one named first.
        try std.testing.expectError(error.DepositInFlight, pruneSession(alloc, io, tmp.dir, "a.jsonl", .{}));
        try std.testing.expectError(error.DepositInFlight, pruneSession(alloc, io, tmp.dir, "b.jsonl", .{}));
    }

    // Naming one session twice is one lease: taking it twice would deadlock on
    // the second, and there is no second inbox to protect.
    var same = try acquireDepositPair(alloc, io, tmp.dir, "a.jsonl", "a.jsonl", .block);
    try std.testing.expect(same.second == null);
    same.close(io);

    _ = try pruneSession(alloc, io, tmp.dir, "a.jsonl", .{});
}

test "moveDeposit takes BOTH inboxes' leases, and moves only what is still there" {
    // The source is written too, so "holding this lease means this inbox does
    // not change under me" — what `pruneSession` counts on while it lists what
    // a session holds — has to be true for the source as well.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var a = try createDurable(alloc, io, tmp.dir, "a.jsonl", .{ .session = "a" });
    a.deinit();
    var b = try createDurable(alloc, io, tmp.dir, "b.jsonl", .{ .session = "b" });
    b.deinit();
    try depositEvent(alloc, io, tmp.dir, "a.jsonl", "task-a-t1", .{ .task_finished = .{ .task = "a/t1", .exit_code = 0, .text = "done" } });

    // Somebody is inside the SOURCE inbox: not a queue to join for a caller
    // that asked to be told instead.
    {
        var held = try acquireDepositLease(alloc, io, tmp.dir, "a.jsonl", .block);
        defer held.close(io);
        try std.testing.expectError(
            error.DepositInFlight,
            moveDeposit(alloc, io, tmp.dir, "a.jsonl", "b.jsonl", "task-a-t1", .fail_fast),
        );
    }
    try tmp.dir.access(io, "a.inbox/task-a-t1.json", .{});

    try std.testing.expect(try moveDeposit(alloc, io, tmp.dir, "a.jsonl", "b.jsonl", "task-a-t1", .block));
    try tmp.dir.access(io, "b.inbox/task-a-t1.json", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "a.inbox/task-a-t1.json", .{}));

    // Nothing left to move, and nowhere to move it to.
    try std.testing.expect(!try moveDeposit(alloc, io, tmp.dir, "a.jsonl", "b.jsonl", "task-a-t1", .block));
    try std.testing.expectError(
        error.NoSuchSession,
        moveDeposit(alloc, io, tmp.dir, "b.jsonl", "gone.jsonl", "task-a-t1", .block),
    );
    try tmp.dir.access(io, "b.inbox/task-a-t1.json", .{});
}

test "the inbox lease is exclusive, and a deposit into a session that is gone is refused" {
    // Both halves of the rule the lease carries: a depositor and a prune cannot
    // both be inside it, and a deposit re-checks the session there — so removal
    // and deposit cannot interleave into a fact nobody will ever drain.
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";

    var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s" });

    {
        var held = try acquireDepositLease(alloc, io, tmp.dir, spath, .block);
        defer held.close(io);
        // What `session prune` asks, and the answer that makes it refuse.
        try std.testing.expectError(
            error.WouldBlock,
            acquireDepositLease(alloc, io, tmp.dir, spath, .fail_fast),
        );
    }

    l.deinit();
    try tmp.dir.deleteFile(io, spath);
    try std.testing.expectError(
        error.NoSuchSession,
        depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = .{ .text = "too late" } }),
    );
    var dir = try tmp.dir.openDir(io, "s.inbox", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".json"));
    }
}

test "identityEqual covers the profile, not just the descriptor" {
    // Two profiles can name the same model over the same wire and still reach
    // it with different credentials, so this is a real move, not a no-op.
    const a: Identity = .{ .profile = "work", .identity = .{ .provider = "openai", .model = "m" } };
    const b: Identity = .{ .profile = "personal", .identity = .{ .provider = "openai", .model = "m" } };
    try std.testing.expect(!identityEqual(a, b));
    try std.testing.expect(identityEqual(a, a));
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

    // …and reads back as null, not a zero cost: "not recorded" and "cost
    // nothing" are different facts.
    const legacy = try parseEventLine(alloc, "{\"seq\":1,\"kind\":\"assistant\",\"text\":\"old\",\"calls\":[]}");
    defer legacy.deinit();
    try std.testing.expect((try toEvent(legacy.arena.allocator(), legacy.value)).assistant.usage == null);
}

test "user images round-trip on the line, and a text-only turn keeps its pre-image shape" {
    const alloc = std.testing.allocator;

    // Present: one column after `text`, decoded image for image.
    const shot: Event = .{ .user_text = .{
        .text = "what is this",
        .images = &.{
            .{ .media_type = "image/png", .data = "iVBORw0=" },
            .{ .media_type = "image/jpeg", .data = "/9j/4AAQ" },
        },
    } };
    const line = try encodeEventLine(alloc, shot, 1);
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"kind\":\"user_text\",\"text\":\"what is this\"," ++
            "\"images\":[{\"media_type\":\"image/png\",\"data\":\"iVBORw0=\"}," ++
            "{\"media_type\":\"image/jpeg\",\"data\":\"/9j/4AAQ\"}]}\n",
        line,
    );
    const parsed = try parseEventLine(alloc, line);
    defer parsed.deinit();
    const back = try toEvent(parsed.arena.allocator(), parsed.value);
    try expectEventsEqual(&.{shot}, &.{back});

    // Absent: byte-for-byte the line a writer without images produces.
    const plain = try encodeEventLine(alloc, .{ .user_text = .{ .text = "hi" } }, 2);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("{\"seq\":2,\"kind\":\"user_text\",\"text\":\"hi\"}\n", plain);

    // …and reads back with no images, not an error.
    const legacy = try parseEventLine(alloc, "{\"seq\":1,\"kind\":\"user_text\",\"text\":\"old\"}");
    defer legacy.deinit();
    const old = try toEvent(legacy.arena.allocator(), legacy.value);
    try std.testing.expectEqualStrings("old", old.user_text.text);
    try std.testing.expectEqual(@as(usize, 0), old.user_text.images.len);
}

test "an image deposited into the inbox is applied exactly once, images and all" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";

    const shot: Event = .{ .user_text = .{
        .text = "look",
        .images = &.{.{ .media_type = "image/png", .data = "iVBORw0=" }},
    } };
    {
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s" });
        defer l.deinit();
        try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", shot);
        try drainInbox(alloc, io, &l, tmp.dir, spath);
        // A second deposit under the SAME name is the same delivery, and the
        // origin column makes applying it twice impossible.
        try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", shot);
        try drainInbox(alloc, io, &l, tmp.dir, spath);
        try std.testing.expectEqual(@as(usize, 1), l.len());
        try expectEventsEqual(&.{shot}, l.view());
    }

    // The image survives the file: a reopened ledger replays it verbatim.
    var reopened = try openDurable(alloc, io, tmp.dir, spath);
    defer reopened.deinit();
    try expectEventsEqual(&.{shot}, reopened.view());
}

test "a finished background task round-trips as its own kind, multi-line text and all" {
    const alloc = std.testing.allocator;

    // The real shape: the supervisor's report is several lines with its own
    // delimiters, so the round-trip has to survive escaped newlines.
    const done: Event = .{ .task_finished = .{
        .task = "s-1786-3f/t3",
        .exit_code = 0,
        .text = "[background task s-1786-3f/t3 finished] zig build test · exit 0 · 41.8s\n" ++
            "--- output tail ---\nAll 114 tests passed.\n--- end of output ---",
    } };
    const line = try encodeEventLine(alloc, done, 7);
    defer alloc.free(line);
    // A flat line like every other kind, with the two structured facts beside
    // the text a reader (or a front end) would otherwise have to parse out of it.
    try std.testing.expect(std.mem.startsWith(
        u8,
        line,
        "{\"seq\":7,\"kind\":\"task_finished\",\"task\":\"s-1786-3f/t3\",\"exit_code\":0,\"text\":\"",
    ));
    const parsed = try parseEventLine(alloc, line);
    defer parsed.deinit();
    try expectEventsEqual(&.{done}, &.{try toEvent(parsed.arena.allocator(), parsed.value)});

    // A non-zero code is the same fact, not an error to read.
    const failed: Event = .{ .task_finished = .{ .task = "s-1/t1", .exit_code = 137, .text = "killed" } };
    const failed_line = try encodeEventLine(alloc, failed, 1);
    defer alloc.free(failed_line);
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"kind\":\"task_finished\",\"task\":\"s-1/t1\",\"exit_code\":137,\"text\":\"killed\"}\n",
        failed_line,
    );

    // A line missing either structured field is corruption, never a default:
    // "which task" and "what happened to it" are not derivable from the text.
    for ([_][]const u8{
        "{\"seq\":1,\"kind\":\"task_finished\",\"exit_code\":0,\"text\":\"x\"}",
        "{\"seq\":1,\"kind\":\"task_finished\",\"task\":\"s/t1\",\"text\":\"x\"}",
        "{\"seq\":1,\"kind\":\"task_finished\",\"task\":\"s/t1\",\"exit_code\":0}",
    }) |bad| {
        const p = try parseEventLine(alloc, bad);
        defer p.deinit();
        try std.testing.expectError(error.CorruptLedger, toEvent(p.arena.allocator(), p.value));
    }
}

test "a task report deposited into the inbox is applied exactly once" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";

    const done: Event = .{ .task_finished = .{
        .task = "s/t3",
        .exit_code = 0,
        .text = "[background task s/t3 finished] echo hi · exit 0 · 0.1s",
    } };
    var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s" });
    defer l.deinit();
    // The supervisor's delivery name is DETERMINISTIC (`task-<sid>-t<N>`), so a
    // redelivery is the same name and the origin column alone makes applying it
    // twice impossible. There is no content dedup arm for this kind.
    try depositEvent(alloc, io, tmp.dir, spath, "task-s-t3", done);
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try depositEvent(alloc, io, tmp.dir, spath, "task-s-t3", done);
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try expectEventsEqual(&.{done}, l.view());

    // A DIFFERENT task under a different name is a different fact and lands.
    const second: Event = .{ .task_finished = .{ .task = "s/t4", .exit_code = 1, .text = "other" } };
    try depositEvent(alloc, io, tmp.dir, spath, "task-s-t4", second);
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 2), l.len());
}

test "a stop reason the shape cannot say is written; the two it can are not" {
    const alloc = std.testing.allocator;

    // This event and a finished one differ in nothing else: `calls` is empty in
    // both, so the shape cannot tell them apart.
    const cut: Event = .{ .assistant = .{ .text = "half a sen", .calls = &.{}, .stop_reason = .max_tokens } };
    const line = try encodeEventLine(alloc, cut, 1);
    defer alloc.free(line);
    try std.testing.expectEqualStrings(
        "{\"seq\":1,\"kind\":\"assistant\",\"text\":\"half a sen\",\"calls\":[],\"stop_reason\":\"max_tokens\"}\n",
        line,
    );
    const parsed = try parseEventLine(alloc, line);
    defer parsed.deinit();
    try expectEventsEqual(&.{cut}, &.{try toEvent(parsed.arena.allocator(), parsed.value)});

    // A reply that ended on its own carries no `"stop_reason"`: an empty `calls`
    // array already says `end_turn`.
    const whole = try encodeEventLine(alloc, .{ .assistant = .{ .text = "half a sen", .calls = &.{} } }, 1);
    defer alloc.free(whole);
    try std.testing.expectEqualStrings("{\"seq\":1,\"kind\":\"assistant\",\"text\":\"half a sen\",\"calls\":[]}\n", whole);

    // Same for a turn that stopped to call a tool: `calls` is non-empty, so the
    // line carries no stop reason and still reads back as `tool_use`.
    const calling: Event = .{ .assistant = .{
        .text = "",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{}" }},
        .stop_reason = .tool_use,
    } };
    const call_line = try encodeEventLine(alloc, calling, 2);
    defer alloc.free(call_line);
    try std.testing.expect(std.mem.indexOf(u8, call_line, "stop_reason") == null);
    const call_parsed = try parseEventLine(alloc, call_line);
    defer call_parsed.deinit();
    try expectEventsEqual(&.{calling}, &.{try toEvent(call_parsed.arena.allocator(), call_parsed.value)});

    // A line with neither field reads back as "ended on its own".
    const legacy = try parseEventLine(alloc, "{\"seq\":1,\"kind\":\"assistant\",\"text\":\"old\",\"calls\":[]}");
    defer legacy.deinit();
    try std.testing.expectEqual(StopReason.end_turn, (try toEvent(legacy.arena.allocator(), legacy.value)).assistant.stop_reason);

    // The boolean this field replaced still reads: `truncated:true` is
    // `max_tokens`. It is never written again.
    const old_bool = try parseEventLine(alloc, "{\"seq\":9,\"kind\":\"assistant\",\"text\":\"half a sen\",\"calls\":[],\"truncated\":true}");
    defer old_bool.deinit();
    try std.testing.expectEqual(StopReason.max_tokens, (try toEvent(old_bool.arena.allocator(), old_bool.value)).assistant.stop_reason);

    // An unknown tag is corruption, not a silently-defaulted turn.
    const bogus = try parseEventLine(alloc, "{\"seq\":1,\"kind\":\"assistant\",\"text\":\"x\",\"calls\":[],\"stop_reason\":\"whenever\"}");
    defer bogus.deinit();
    try std.testing.expectError(error.CorruptLedger, toEvent(bogus.arena.allocator(), bogus.value));
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
        try std.testing.expectEqual(@as(usize, sample_event_count), l.len());
    }

    // Reopen in a fresh ledger: header and every event survive verbatim.
    var reopened = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    try std.testing.expectEqual(@as(usize, sample_event_count), reopened.len());
    try std.testing.expectEqualStrings("s-test", reopened.header().?.session);
    try std.testing.expectEqualStrings("ext:web.search/web_search", reopened.header().?.composition.native_tools[0]);
    try std.testing.expect(reopened.containsNote("demo", "v-aaaa"));
    try std.testing.expect(!reopened.containsNote("demo", "v-bbbb"));
    try std.testing.expect(std.mem.startsWith(u8, reopened.view()[1].assistant.reasoning, "[{\"type\":\"thinking\""));

    // The persisted seqs are strictly 1..N (proven by replay's own seq check).
    const raw = try tmp.dir.readFileAlloc(io, "s.jsonl", alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"seq\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, std.fmt.comptimePrint("\"seq\":{d},", .{sample_event_count})) != null);

    // Appending after reopen continues the seq sequence. Close this writer
    // before the next opens: the lease permits only one at a time.
    try reopened.append(.{ .user_text = .{ .text = "again" } });
    const reopened_events = reopened.len();
    reopened.deinit();

    var third = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer third.deinit();
    try std.testing.expectEqual(reopened_events, third.len());
    try std.testing.expectEqualStrings("again", third.view()[sample_event_count].user_text.text);
}

test "openDurable drops a torn final line and truncates it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header_line = try encodeHeaderLine(alloc, .{ .session = "s-torn" });
    defer alloc.free(header_line);
    const good = try encodeEventLine(alloc, .{ .user_text = .{ .text = "kept" } }, 1);
    defer alloc.free(good);
    // A partial second event with no trailing newline: an interrupted write.
    const torn = "{\"seq\":2,\"kind\":\"user_te";
    const contents = try std.mem.concat(alloc, u8, &.{ header_line, good, torn });
    defer alloc.free(contents);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = contents });

    var l = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expectEqualStrings("kept", l.view()[0].user_text.text);

    // The torn tail was truncated, so the next append lands cleanly.
    try l.append(.{ .user_text = .{ .text = "next" } });
    l.deinit();

    var reopened = try openDurable(alloc, io, tmp.dir, "s.jsonl");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.len());
    try std.testing.expectEqualStrings("next", reopened.view()[1].user_text.text);
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
    const skipped = try encodeEventLine(alloc, .{ .user_text = .{ .text = "x" } }, 2); // should be 1
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
    try a.append(.{ .user_text = .{ .text = "one" } });

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
    try b.append(.{ .user_text = .{ .text = "two" } });
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

    // Deposits may arrive out of directory iteration order. Filename order is
    // FIFO, and adjacent user proposals become one turn before the note.
    try depositEvent(alloc, io, tmp.dir, spath, "note-demo-v-aaaa", .{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "n" } });
    try depositEvent(alloc, io, tmp.dir, spath, "msg-0002", .{ .user_text = .{
        .text = "second",
        .images = &.{.{ .media_type = "image/png", .data = "two" }},
    } });
    try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = .{
        .text = "first",
        .images = &.{.{ .media_type = "image/jpeg", .data = "one" }},
    } });
    try std.testing.expectEqual(@as(usize, 0), l.len());

    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expectEqualStrings("first\n\nsecond", l.view()[0].user_text.text);
    try std.testing.expectEqualStrings("image/jpeg", l.view()[0].user_text.images[0].media_type);
    try std.testing.expectEqualStrings("image/png", l.view()[0].user_text.images[1].media_type);
    try std.testing.expect(l.view()[1] == .capability_note);

    // Draining an empty inbox adds nothing; a re-deposited note is skipped.
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try depositEvent(alloc, io, tmp.dir, spath, "note-demo-v-aaaa", .{ .capability_note = .{ .id = "demo", .version = "v-aaaa", .text = "n" } });
    try drainInbox(alloc, io, &l, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 2), l.len());

    // Everything drained is on disk in order.
    l.deinit();

    var reopened = try openDurable(alloc, io, tmp.dir, spath);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.len());
    try std.testing.expectEqualStrings("first\n\nsecond", reopened.view()[0].user_text.text);
    try std.testing.expect(reopened.containsOrigin("msg-0001.json"));
    try std.testing.expect(reopened.containsOrigin("msg-0002.json"));
    try std.testing.expect(reopened.containsNote("demo", "v-aaaa"));
}

test "inbox application is exactly-once across a crash between append and delete" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spath = "s.jsonl";

    // Simulate a merged drain that appended one turn but CRASHED before deleting
    // either source file.
    {
        var l = try createDurable(alloc, io, tmp.dir, spath, .{ .session = "s" });
        defer l.deinit();
        try depositEvent(alloc, io, tmp.dir, spath, "msg-0001", .{ .user_text = .{ .text = "first" } });
        try depositEvent(alloc, io, tmp.dir, spath, "msg-0002", .{ .user_text = .{ .text = "second" } });
        try l.appendWithOrigins(
            .{ .user_text = .{ .text = "first\n\nsecond" } },
            &.{ "msg-0001.json", "msg-0002.json" },
        );
        try std.testing.expectEqual(@as(usize, 1), l.len());
    }
    // It managed to delete the first source before dying; the second remains.
    try tmp.dir.deleteFile(io, "s.inbox" ++ std.fs.path.sep_str ++ "msg-0001.json");

    const raw = try tmp.dir.readFileAlloc(io, spath, alloc, .unlimited);
    defer alloc.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"origins\":[\"msg-0001.json\",\"msg-0002.json\"]") != null);

    // Replay rebuilds both ids. Draining the one leftover file only deletes it;
    // it cannot recreate part or all of the already-committed turn.
    var reopened = try openDurable(alloc, io, tmp.dir, spath);
    defer reopened.deinit();
    try std.testing.expect(reopened.containsOrigin("msg-0001.json"));
    try std.testing.expect(reopened.containsOrigin("msg-0002.json"));
    try drainInbox(alloc, io, &reopened, tmp.dir, spath);
    try std.testing.expectEqual(@as(usize, 1), reopened.len());
    try std.testing.expectEqualStrings("first\n\nsecond", reopened.view()[0].user_text.text);
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
