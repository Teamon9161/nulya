//! Codex backend: the Responses endpoint the Codex CLI uses
//! (`chatgpt.com/backend-api/codex/responses`), authenticated with the OAuth
//! tokens `codex login` leaves in `~/.codex/auth.json`. No API key is involved —
//! usage bills against the ChatGPT subscription. Named for the backend, not the
//! protocol: a plain Chat Completions endpoint is `providers/openai.zig`.
//!
//! Three wire differences from Chat Completions matter here:
//!  - History is a flat list of typed *items* (message / function_call /
//!    function_call_output), not role messages.
//!  - The prompt cache is keyed by the `session_id` header (the backend writes
//!    it over the body's `prompt_cache_key`). Nulya has a real durable session
//!    id, so the key is derived from it and the cache survives across separate
//!    `nulya session step` processes — not just within one.
//!  - The endpoint 400s on `max_output_tokens` at any value, so a caller that
//!    needs a short answer has to ask for it in the prompt.
//!
//! Reasoning IS replayed. With `store: false` the model's chain-of-thought comes
//! back as a `reasoning` item whose `encrypted_content` (requested via
//! `include`) only this model can read; each such item is emitted whole as a
//! `reasoning_item`, kept on the ledger's `assistant` event, and sent back
//! verbatim ahead of the function_call it preceded (DESIGN §3.1, §13). The
//! backend accepts a history without them, but then the model re-derives its
//! plan at every tool step; with them its reasoning is continuous across the
//! whole tool loop, the way the Codex CLI itself replays it.

const std = @import("std");
const config = @import("../config.zig");
const prompt = @import("../prompt.zig");
const provider = @import("../provider.zig");
const tool = @import("../tool.zig");
const wire = @import("wire.zig");

const backend_url = "https://chatgpt.com/backend-api/codex/responses";
const token_url = "https://auth.openai.com/oauth/token";
/// The subscription's model catalogue — the same endpoint the Codex CLI polls to
/// fill `models_cache.json`, authenticated exactly like `/responses`.
const models_url = "https://chatgpt.com/backend-api/codex/models";
/// The Codex CLI's public OAuth client id. Reusing it means the tokens refreshed
/// here are the same ones a `codex login` produces, so both tools share the file.
const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";

pub const default_model = "gpt-5.5";

pub const Config = struct {
    model: []const u8 = default_model,
    /// The durable session id. Hashed into the stable per-conversation cache
    /// scope; empty means "one scope per process".
    cache_key: []const u8 = "",
    /// The host environment, consulted only for `CODEX_HOME` / the home dir.
    env: *const std.process.Environ.Map,
};

pub const InitError = error{ MissingCredential, OutOfMemory };

pub const CodexProvider = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    client: std.http.Client,
    model: []const u8,
    auth: Auth,
    /// `session_id` header / `prompt_cache_key`, in UUID shape because that is
    /// what the backend expects. Derived from the session id, so it is the same
    /// value every time this session is stepped, from any process.
    session_uuid: [36]u8,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, cfg: Config) InitError!CodexProvider {
        const model = try alloc.dupe(u8, cfg.model);
        errdefer alloc.free(model);
        var auth = try Auth.load(alloc, io, cfg.env) orelse return error.MissingCredential;
        errdefer auth.deinit(alloc);

        return .{
            .alloc = alloc,
            .io = io,
            .env = cfg.env,
            .client = .{ .allocator = alloc, .io = io, .read_buffer_size = 64 * 1024 },
            .model = model,
            .auth = auth,
            .session_uuid = stableUuid(cfg.cache_key),
        };
    }

    pub fn deinit(self: *CodexProvider) void {
        self.client.deinit();
        self.auth.deinit(self.alloc);
        self.alloc.free(self.model);
        self.* = undefined;
    }

    pub fn modelHandle(self: *CodexProvider) provider.Model {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "codex";
    }

    fn modelName(ptr: *anyopaque) []const u8 {
        const self: *CodexProvider = @ptrCast(@alignCast(ptr));
        return self.model;
    }

    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{ .thinking_replay = true };
    }

    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        const self: *CodexProvider = @ptrCast(@alignCast(ptr));
        const body = try buildRequestJson(alloc, self.model, &self.session_uuid, request);
        defer alloc.free(body);

        var state: StreamState = .{ .alloc = alloc, .sink = sink };
        // One retry, and only for 401: the access token is short-lived, so an
        // expired one is routine rather than a fault. A 401 arrives before any
        // SSE data, so the retry cannot duplicate emitted events.
        self.send(alloc, body, &state, request.stall_ms) catch |err| switch (err) {
            error.Unauthorized => {
                try self.auth.refresh(alloc, self.io, self.env, &self.client, request.stall_ms);
                try self.send(alloc, body, &state, request.stall_ms);
            },
            else => return err,
        };

        if (!state.done) return error.StreamEndedEarly;
    }

    fn send(self: *CodexProvider, alloc: std.mem.Allocator, body: []const u8, state: *StreamState, stall_ms: u64) !void {
        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.auth.access_token});
        defer alloc.free(auth);
        return wire.postSse(&self.client, alloc, .{
            .url = backend_url,
            .body = body,
            .authorization = auth,
            .stall_ms = stall_ms,
            .extra_headers = &.{
                .{ .name = "chatgpt-account-id", .value = self.auth.account_id },
                .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
                .{ .name = "originator", .value = "codex_cli_rs" },
                .{ .name = "accept", .value = "text/event-stream" },
                .{ .name = "session_id", .value = &self.session_uuid },
            },
        }, state, StreamState.onData);
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

// --------------------------------------------------------------------- auth --

/// The subscription credential, read from (and written back to) the Codex CLI's
/// `auth.json`. A nulya session never stores it: `Auth.load` reads the file at
/// build time and the session header only records that the provider is `codex`.
pub const Auth = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    account_id: []const u8,

    pub fn deinit(self: *Auth, alloc: std.mem.Allocator) void {
        alloc.free(self.access_token);
        alloc.free(self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    /// Null when there is no usable credential (no home dir, no file, no tokens).
    pub fn load(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) error{OutOfMemory}!?Auth {
        const path = (try homePath(alloc, env, "auth.json")) orelse return null;
        defer alloc.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return null;
        defer alloc.free(text);

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return null;
        defer parsed.deinit();
        const tokens = wire.field(parsed.value, "tokens") orelse return null;
        const access = wire.string(tokens, "access_token") orelse return null;
        if (access.len == 0) return null;

        var out: Auth = .{
            .access_token = try alloc.dupe(u8, access),
            .refresh_token = try alloc.dupe(u8, wire.string(tokens, "refresh_token") orelse ""),
            .account_id = try alloc.dupe(u8, wire.string(tokens, "account_id") orelse ""),
        };
        errdefer out.deinit(alloc);
        return out;
    }

    /// Whether a subscription credential exists right now — the codex answer to
    /// "is this profile usable", checked where other providers check an env var.
    pub fn available(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
        var a = (load(alloc, io, env) catch return false) orelse return false;
        a.deinit(alloc);
        return true;
    }

    /// Exchange the refresh token for fresh credentials and write them back to
    /// auth.json, exactly as the Codex CLI does, so the two stay interchangeable.
    /// It lives on `Auth` rather than on the provider because the tokens and the
    /// file are `Auth`'s: a 401 on the model stream and a 401 on the catalogue
    /// fetch (`refreshCatalog`) are the same repair.
    pub fn refresh(
        self: *Auth,
        alloc: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        client: *std.http.Client,
        stall_ms: u64,
    ) !void {
        if (self.refresh_token.len == 0) return error.MissingCredential;
        // `{f}` on a byte slice emits a complete JSON string, quotes included.
        const body = try std.fmt.allocPrint(alloc,
            \\{{"client_id":"{s}","grant_type":"refresh_token","refresh_token":{f},"scope":"openid profile email"}}
        , .{ client_id, std.json.fmt(self.refresh_token, .{}) });
        defer alloc.free(body);

        const response = try wire.postJson(client, alloc, .{ .url = token_url, .body = body, .stall_ms = stall_ms });
        defer alloc.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, response, .{});
        defer parsed.deinit();

        const access = wire.string(parsed.value, "access_token") orelse return error.CodexRefreshFailed;
        if (access.len == 0) return error.CodexRefreshFailed;
        const refresh_token = wire.string(parsed.value, "refresh_token") orelse "";
        try self.replaceTokens(alloc, access, refresh_token);
        self.save(alloc, io, env, wire.string(parsed.value, "id_token")) catch {};
    }

    fn replaceTokens(self: *Auth, alloc: std.mem.Allocator, access: []const u8, refresh_token: []const u8) !void {
        const new_access = try alloc.dupe(u8, access);
        alloc.free(self.access_token);
        self.access_token = new_access;
        // An empty `refresh_token` in the response means "keep the old one".
        if (refresh_token.len == 0) return;
        const new_refresh = try alloc.dupe(u8, refresh_token);
        alloc.free(self.refresh_token);
        self.refresh_token = new_refresh;
    }

    /// Persist refreshed tokens without discarding fields the Codex CLI owns.
    fn save(self: *const Auth, alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, id_token: ?[]const u8) !void {
        const path = (try homePath(alloc, env, "auth.json")) orelse return;
        defer alloc.free(path);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(text);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        // Mutate only the token fields, in place: every other key in the file
        // (`OPENAI_API_KEY`, `auth_mode`, …) belongs to the Codex CLI and is
        // written back untouched.
        const tokens = parsed.value.object.getPtr("tokens") orelse return;
        if (tokens.* != .object) return;
        const arena = parsed.arena.allocator();
        try tokens.object.put(arena, "access_token", .{ .string = self.access_token });
        try tokens.object.put(arena, "refresh_token", .{ .string = self.refresh_token });
        if (id_token) |t| try tokens.object.put(arena, "id_token", .{ .string = t });

        const encoded = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
        defer alloc.free(encoded);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded });
    }
};

/// `$CODEX_HOME/<name>`, else `~/.codex/<name>`. Null when no home is known.
fn homePath(alloc: std.mem.Allocator, env: *const std.process.Environ.Map, sub: []const u8) error{OutOfMemory}!?[]u8 {
    if (env.get("CODEX_HOME")) |dir| {
        if (dir.len != 0) return try std.fs.path.join(alloc, &.{ dir, sub });
    }
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(alloc, &.{ home, ".codex", sub });
}

// ----------------------------------------------------------------- models --

/// The subscription's own model line-up, read from the file the Codex CLI keeps
/// it in (`$CODEX_HOME/models_cache.json`, else `~/.codex/models_cache.json`).
///
/// A ChatGPT subscription decides which models it serves and with what dial;
/// that is not something a person should have to restate in `config.toml`, and
/// a hardcoded list is wrong the week after it is written. So the catalogue is
/// read, never configured — `nulya config show` projects it for a picker
/// (DESIGN §9.5) and `nulya config refresh` refills the file.
///
/// The numbers are the subscription's, not the public API's: the same id is
/// served here with a smaller window (`effective_context_window_percent` of the
/// raw one — the budget Codex advertises to its own clients), an extra effort
/// level, and its own default. That is precisely why this cannot be folded into
/// the id-keyed `[[models]]` catalog, which describes an id once for every
/// endpoint that serves it.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    /// In the order the file lists them; never empty (no listable model is null).
    models: []const config.ModelParams,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Null when there is nothing usable: no home, no file, unreadable JSON, or
    /// not one listable model. Null is "this machine cannot say", never an
    /// assertion that the subscription serves nothing.
    pub fn load(
        alloc: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
    ) error{OutOfMemory}!?Catalog {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        const models = read: {
            const path = (try homePath(a, env, "models_cache.json")) orelse break :read null;
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch break :read null;
            break :read try parse(a, text);
        };
        if (models) |m| return .{ .arena = arena, .models = m };
        arena.deinit();
        return null;
    }
};

/// One cache document → the model parameters it states. Everything the file
/// carries beyond these (base instructions, tool policies, service tiers) is the
/// Codex CLI's business, not a description of the id.
///
/// Both shapes are accepted — the file is always `{"models":[…]}`, but the
/// endpoint may answer with a bare array — so one function validates what is
/// fetched and reads what is on disk. Everything is allocated in `arena`, which
/// must also outlive `text` (JSON strings without escapes alias it).
fn parse(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const config.ModelParams {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    const listed = switch (wire.field(doc, "models") orelse doc) {
        .array => |a| a.items,
        else => return null,
    };

    var out: std.ArrayList(config.ModelParams) = .empty;
    for (listed) |m| {
        // `hide` is how the catalogue carries models that exist but are not
        // offered (an internal review model, say): listing them would put a
        // choice in a picker that is not the user's to make.
        if (!eqlString(wire.string(m, "visibility"), "list")) continue;
        const slug = wire.string(m, "slug") orelse continue;
        if (slug.len == 0) continue;

        var efforts: std.ArrayList([]const u8) = .empty;
        if (wire.field(m, "supported_reasoning_levels")) |levels| {
            if (levels == .array) {
                for (levels.array.items) |level| {
                    if (wire.string(level, "effort")) |e| try efforts.append(arena, e);
                }
            }
        }
        try out.append(arena, .{
            .id = slug,
            .label = wire.string(m, "display_name") orelse "",
            .efforts = try efforts.toOwnedSlice(arena),
            .default_effort = nonEmptyString(wire.string(m, "default_reasoning_level")),
            .context_window = effectiveWindow(m),
            // Deliberately not claimed here even though the entry says whether
            // it takes images: the `session append --image` gate reads the
            // id-keyed `[[models]]` catalog (DESIGN §3.1/§9.5), so a claim in
            // this projection is one nothing honours.
            .vision = false,
        });
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(arena);
}

/// The window the subscription actually gives you: the raw one, times the
/// percentage it reserves for its own clients. A model that states no window is
/// kept without one (`?u64` already means "not stated") rather than dropped —
/// a listed model is selectable whether or not it says how big it is.
fn effectiveWindow(m: std.json.Value) ?u64 {
    const raw = wire.field(m, "context_window") orelse return null;
    if (raw != .integer and raw != .float) return null;
    const window = wire.uint(m, "context_window");
    const percent = if (wire.field(m, "effective_context_window_percent") != null)
        @min(wire.uint(m, "effective_context_window_percent"), 100)
    else
        100;
    return window * percent / 100;
}

fn nonEmptyString(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Fetch the live catalogue and write it into the Codex CLI's own cache file, so
/// every later read — this binary's and the CLI's — sees today's line-up. There
/// is no `codex login` in nulya, so nothing refreshes this on its own: the only
/// trigger is `nulya config refresh` (DESIGN §14).
///
/// `client_version` is this binary's version string (the endpoint takes it as a
/// query parameter, as the CLI does). A 401 means the short-lived access token
/// expired, which is routine: refresh once and retry, exactly as the model
/// stream does.
pub fn refreshCatalog(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    client_version: []const u8,
) !void {
    var auth = (try Auth.load(alloc, io, env)) orelse return error.MissingCredential;
    defer auth.deinit(alloc);
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(alloc, "{s}?client_version={s}", .{ models_url, client_version });
    defer alloc.free(url);

    const body = fetchCatalog(alloc, &client, &auth, url) catch |err| switch (err) {
        error.Unauthorized => blk: {
            try auth.refresh(alloc, io, env, &client, catalog_stall_ms);
            break :blk try fetchCatalog(alloc, &client, &auth, url);
        },
        else => return err,
    };
    defer alloc.free(body);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const response = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.CodexCatalogUnreadable;
    // Refuse to overwrite a good cache with an answer that describes no model:
    // the same predicate the reader applies, so what is written is what will be
    // read back.
    if ((try parse(a, body)) == null) return error.CodexCatalogEmpty;
    try saveCatalog(alloc, io, env, a, response);
}

/// A projection is not a step: a catalogue that goes quiet should fail in
/// seconds and leave the file alone, not hold `config show` for two minutes the
/// way a reasoning model legitimately may (`provider.RetryPolicy.stall_timeout_ms`).
const catalog_stall_ms = 15_000;

fn fetchCatalog(alloc: std.mem.Allocator, client: *std.http.Client, auth: *const Auth, url: []const u8) ![]u8 {
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{auth.access_token});
    defer alloc.free(authorization);
    return wire.getJson(client, alloc, .{
        .url = url,
        .body = "",
        .authorization = authorization,
        .stall_ms = catalog_stall_ms,
        .extra_headers = &.{
            .{ .name = "chatgpt-account-id", .value = auth.account_id },
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "originator", .value = "codex_cli_rs" },
        },
    });
}

/// Write the fetched models into `models_cache.json`. The file belongs to the
/// Codex CLI, so only `models` is replaced and every other key it keeps there
/// (`fetched_at`, `etag`, `client_version`) is written back untouched — the same
/// discipline as `Auth.save`, and the reason nothing here invents that
/// metadata: a stale etag costs the CLI one conditional request, a fabricated
/// one could cost it the truth.
fn saveCatalog(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    arena: std.mem.Allocator,
    response: std.json.Value,
) !void {
    const path = (try homePath(alloc, env, "models_cache.json")) orelse return error.NoCodexHome;
    defer alloc.free(path);

    // The endpoint may answer with a bare array; the cache is always the object
    // form, because that is the shape the CLI reads.
    const models = wire.field(response, "models") orelse response;
    var doc: std.json.Value = .{ .object = .empty };
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20))) |existing| {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, existing, .{})) |old| {
            if (old == .object) doc = old;
        } else |_| {}
    } else |_| {}
    try doc.object.put(arena, "models", models);

    const encoded = try std.fmt.allocPrint(alloc, "{f}", .{std.json.fmt(doc, .{ .whitespace = .indent_2 })});
    defer alloc.free(encoded);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded });
}

/// A UUID-shaped, deterministic name hash. The backend wants UUID syntax; what
/// matters to us is that the same session id always maps to the same value, so
/// its prompt cache is one scope across processes.
fn stableUuid(name: []const u8) [36]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(name, &digest, .{});
    // RFC 4122 variant/version bits, so the string parses as a v4-shaped UUID.
    digest[6] = (digest[6] & 0x0f) | 0x40;
    digest[8] = (digest[8] & 0x3f) | 0x80;

    var out: [36]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    const groups = [_]usize{ 4, 2, 2, 2, 6 };
    var at: usize = 0;
    for (groups, 0..) |len, i| {
        if (i != 0) w.writeByte('-') catch unreachable;
        w.print("{x}", .{digest[at..][0..len]}) catch unreachable;
        at += len;
    }
    return out;
}

// ----------------------------------------------------------------- request --

pub fn buildRequestJson(
    alloc: std.mem.Allocator,
    model: []const u8,
    cache_key: []const u8,
    request: provider.Request,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model);
    try jw.objectField("instructions");
    try writeInstructions(&jw, alloc, request.prompt_ir.system_blocks);
    try jw.objectField("input");
    try writeInput(&jw, alloc, request.prompt_ir.turns);
    try jw.objectField("tools");
    try writeTools(&jw, request.tools);
    try jw.objectField("tool_choice");
    try jw.write("auto");
    try jw.objectField("parallel_tool_calls");
    try jw.write(true);
    try jw.objectField("store");
    try jw.write(false);
    // Nothing is stored server-side, so the reasoning that must survive to the
    // next step has to travel with the response: this asks for it encrypted.
    try jw.objectField("include");
    try jw.beginArray();
    try jw.write("reasoning.encrypted_content");
    try jw.endArray();
    try jw.objectField("stream");
    try jw.write(true);
    // The backend overwrites this with the `session_id` header, but sending it
    // keeps the body self-describing for anyone reading a captured request.
    try jw.objectField("prompt_cache_key");
    try jw.write(cache_key);
    try jw.objectField("reasoning");
    try jw.beginObject();
    if (request.options.effort) |effort| {
        try jw.objectField("effort");
        // `off` is our name for "do not reason"; the Responses API spells it
        // `none`, and sending `off` verbatim is a 400. An absent effort stays
        // absent, which means the server default — not the same thing.
        try jw.write(if (std.mem.eql(u8, effort, "off")) "none" else effort);
    }
    try jw.objectField("summary");
    try jw.write("auto");
    try jw.endObject();
    try jw.endObject();
    return out.toOwnedSlice();
}

/// This API takes one instructions string, not a block list; the frozen system
/// blocks are joined in order, which keeps the cached prefix byte-identical
/// between turns.
fn writeInstructions(jw: *std.json.Stringify, alloc: std.mem.Allocator, blocks: []const prompt.SystemBlock) !void {
    var joined: std.Io.Writer.Allocating = .init(alloc);
    defer joined.deinit();
    for (blocks, 0..) |block, i| {
        if (i != 0) try joined.writer.writeAll("\n\n");
        try joined.writer.writeAll(block.bytes);
    }
    try jw.write(joined.written());
}

/// History is flat here, so a turn simply contributes its items in order.
fn writeInput(jw: *std.json.Stringify, alloc: std.mem.Allocator, turns: []const prompt.Turn) !void {
    try jw.beginArray();
    for (turns) |turn| switch (turn) {
        .user_text => |u| try writeUserItem(jw, alloc, u),
        .capability_note => |text| try writeMessageItem(jw, "user", "input_text", text),
        .assistant => |as| {
            // The turn's `reasoning` items exactly as they came back — id,
            // summary and `encrypted_content` — placed before the output they
            // preceded, which is the position the model produced them in.
            if (as.reasoning.len != 0) try wire.writeReasoningItems(jw, alloc, as.reasoning);
            if (as.text.len != 0) try writeMessageItem(jw, "assistant", "output_text", as.text);
            for (as.calls) |call| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function_call");
                try jw.objectField("call_id");
                try jw.write(call.id);
                try jw.objectField("name");
                try jw.write(call.tool);
                // Arguments are a JSON *string* on this wire, not an object.
                try jw.objectField("arguments");
                try jw.write(call.args_json);
                try jw.endObject();
            }
        },
        .tool_results => |results| for (results) |result| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call_output");
            try jw.objectField("call_id");
            try jw.write(result.call_id);
            try jw.objectField("output");
            try jw.write(result.output);
            try jw.endObject();
        },
    };
    try jw.endArray();
}

/// A user turn: its text and the images inlined with it, as parts of ONE
/// message item. This wire is already a parts array, so an image is one more
/// part — an `input_image` carrying the data URI. An image-only turn writes no
/// text part rather than an empty one.
fn writeUserItem(jw: *std.json.Stringify, alloc: std.mem.Allocator, u: prompt.Turn.UserText) !void {
    if (u.images.len == 0) return writeMessageItem(jw, "user", "input_text", u.text);
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("message");
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    try jw.beginArray();
    if (u.text.len != 0) {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("input_text");
        try jw.objectField("text");
        try jw.write(u.text);
        try jw.endObject();
    }
    for (u.images) |img| {
        const uri = try wire.dataUri(alloc, img.media_type, img.data);
        defer alloc.free(uri);
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("input_image");
        try jw.objectField("image_url");
        try jw.write(uri);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeMessageItem(jw: *std.json.Stringify, role: []const u8, part_type: []const u8, text: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("message");
    try jw.objectField("role");
    try jw.write(role);
    try jw.objectField("content");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write(part_type);
    try jw.objectField("text");
    try jw.write(text);
    try jw.endObject();
    try jw.endArray();
    try jw.endObject();
}

fn writeTools(jw: *std.json.Stringify, tools: []const tool.ToolDefinition) !void {
    try jw.beginArray();
    for (tools) |def| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("function");
        try jw.objectField("name");
        try jw.write(def.name);
        try jw.objectField("description");
        try jw.write(def.description);
        try jw.objectField("strict");
        try jw.write(false);
        try jw.objectField("parameters");
        try wire.writeRaw(jw, def.input_schema);
        try jw.endObject();
    }
    try jw.endArray();
}

// ------------------------------------------------------------------ stream --

pub const StreamState = struct {
    alloc: std.mem.Allocator,
    sink: provider.EventSink,
    saw_tool_use: bool = false,
    started: bool = false,
    done: bool = false,

    pub fn onData(self: *StreamState, data: []const u8) anyerror!bool {
        // The stream ends with a `[DONE]` sentinel that is not JSON.
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{}) catch return false;
        defer parsed.deinit();
        const root = parsed.value;
        const kind = wire.string(root, "type") orelse return false;

        if (std.mem.eql(u8, kind, "response.created")) {
            if (!self.started) {
                self.started = true;
                try self.sink.emit(.started);
            }
        } else if (std.mem.eql(u8, kind, "response.output_text.delta")) {
            if (wire.string(root, "delta")) |t| try self.sink.emit(.{ .text_delta = t });
        } else if (std.mem.eql(u8, kind, "response.reasoning_summary_text.delta")) {
            if (wire.string(root, "delta")) |t| try self.sink.emit(.{ .thinking_delta = t });
        } else if (std.mem.eql(u8, kind, "response.output_item.added")) {
            const item = wire.field(root, "item") orelse return false;
            if (!eqlString(wire.string(item, "type"), "function_call")) return false;
            self.saw_tool_use = true;
            try self.sink.emit(.{ .tool_use_start = .{
                .index = @intCast(wire.uint(root, "output_index")),
                .id = wire.string(item, "call_id") orelse "",
                .name = wire.string(item, "name") orelse "",
            } });
        } else if (std.mem.eql(u8, kind, "response.function_call_arguments.delta")) {
            if (wire.string(root, "delta")) |f| {
                try self.sink.emit(.{ .tool_use_input_delta = .{
                    .index = @intCast(wire.uint(root, "output_index")),
                    .fragment = f,
                } });
            }
        } else if (std.mem.eql(u8, kind, "response.output_item.done")) {
            // A finished reasoning item carries its `encrypted_content` only here
            // (and only when `include` asked for it). Without that field the item
            // could not be replayed under `store: false` — an id the backend no
            // longer knows — so such an item is not worth keeping.
            const item = wire.field(root, "item") orelse return false;
            if (!eqlString(wire.string(item, "type"), "reasoning")) return false;
            const encrypted = wire.string(item, "encrypted_content") orelse return false;
            if (encrypted.len == 0) return false;
            const raw = try std.json.Stringify.valueAlloc(self.alloc, item, .{});
            defer self.alloc.free(raw);
            try self.sink.emit(.{ .reasoning_item = raw });
        } else if (std.mem.eql(u8, kind, "response.completed")) {
            const response = wire.field(root, "response") orelse root;
            if (wire.field(response, "usage")) |u| try self.sink.emit(.{ .usage = usageFrom(u) });
            self.done = true;
            try self.sink.emit(.{ .done = if (self.saw_tool_use) .tool_use else .end_turn });
            return true;
        } else if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "error")) {
            std.debug.print("codex stream error: {s}\n", .{data});
            return error.CodexStreamError;
        }
        return false;
    }
};

fn usageFrom(u: std.json.Value) provider.Usage {
    const input = wire.uint(u, "input_tokens");
    var cached: u64 = 0;
    if (wire.field(u, "input_tokens_details")) |details| cached = wire.uint(details, "cached_tokens");
    return .{
        // The Responses counter includes cached tokens; `provider.Usage` does not.
        .input_tokens = input -| cached,
        .output_tokens = wire.uint(u, "output_tokens"),
        .cache_read_tokens = cached,
    };
}

fn eqlString(actual: ?[]const u8, expected: []const u8) bool {
    return actual != null and std.mem.eql(u8, actual.?, expected);
}

// ------------------------------------------------------------------- tests --

const ledger = @import("../ledger.zig");

test "the prompt cache key is derived from the session id, so it is stable across processes" {
    const a = stableUuid("s-1700000000000-abc123");
    const b = stableUuid("s-1700000000000-abc123");
    const other = stableUuid("s-1700000000001-abc123");
    try std.testing.expectEqualStrings(&a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &other));
    // UUID shape: 8-4-4-4-12 hex.
    try std.testing.expectEqual(@as(usize, 36), a.len);
    for ([_]usize{ 8, 13, 18, 23 }) |i| try std.testing.expectEqual(@as(u8, '-'), a[i]);
    for (a, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect(std.ascii.isHex(c));
    }
}

test "the subscription's catalogue is read, not configured: listable models only, the effective window, its own dial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const models = (try parse(a,
        \\{"fetched_at":"2026-07-15T10:42:23Z","etag":"W/\"abc\"","models":[
        \\  {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list",
        \\   "context_window":272000,"effective_context_window_percent":95,
        \\   "supported_reasoning_levels":[{"effort":"low","description":"…"},{"effort":"medium"},{"effort":"xhigh"}],
        \\   "default_reasoning_level":"low","base_instructions":"(the CLI's, not ours)"},
        \\  {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide",
        \\   "context_window":272000,"effective_context_window_percent":95},
        \\  {"slug":"bare","visibility":"list"}
        \\]}
    )).?;

    // The hidden model is not a choice anyone is offered.
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", models[0].id);
    try std.testing.expectEqualStrings("GPT-5.6-Sol", models[0].label);
    // The window the subscription gives, not the raw one the public API states.
    try std.testing.expectEqual(@as(u64, 258_400), models[0].context_window.?);
    try std.testing.expectEqual(@as(usize, 3), models[0].efforts.len);
    try std.testing.expectEqualStrings("low", models[0].efforts[0]);
    try std.testing.expectEqualStrings("xhigh", models[0].efforts[2]);
    try std.testing.expectEqualStrings("low", models[0].default_effort.?);
    // An id with nothing stated is still selectable; it just claims nothing.
    try std.testing.expectEqualStrings("bare", models[1].id);
    try std.testing.expectEqualStrings("", models[1].label);
    try std.testing.expectEqual(@as(usize, 0), models[1].efforts.len);
    try std.testing.expect(models[1].default_effort == null);
    try std.testing.expect(models[1].context_window == null);
    // Vision is claimed by the id-keyed catalog the `--image` gate reads, never here.
    try std.testing.expect(!models[0].vision);

    // A missing percentage is 100 %, and the endpoint's bare-array answer reads
    // through the same function that reads the file.
    const bare = (try parse(a,
        \\[{"slug":"gpt-5.5","visibility":"list","context_window":272000}]
    )).?;
    try std.testing.expectEqual(@as(u64, 272_000), bare[0].context_window.?);

    // Nothing usable is null — "this machine cannot say", not "there are none".
    try std.testing.expect((try parse(a, "not json")) == null);
    try std.testing.expect((try parse(a, "{\"models\":[]}")) == null);
    try std.testing.expect((try parse(a, "{\"models\":[{\"slug\":\"x\",\"visibility\":\"hide\"}]}")) == null);
    try std.testing.expect((try parse(a, "{\"error\":\"unauthorized\"}")) == null);
}

test "history serializes to flat Responses items and effort off becomes none" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });
    try l.append(.{ .assistant = .{ .text = "probing", .calls = &.{
        .{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo hi\"}" },
    } } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "hi" }} });

    const sys = [_]prompt.SystemBlock{
        .{ .source = "kernel", .bytes = "base" },
        .{ .source = "ext", .bytes = "extra" },
    };
    const ir = try prompt.projectWithSystem(alloc, &sys, l.view());
    defer ir.deinit(alloc);
    const defs = [_]tool.ToolDefinition{.{
        .id = "builtin.shell",
        .name = "shell",
        .description = "run shell",
        .input_schema = "{\"type\":\"object\"}",
    }};

    const body = try buildRequestJson(alloc, "gpt-5.5", "cache-1", .{
        .prompt_ir = &ir,
        .tools = &defs,
        .options = .{ .effort = "off" },
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"base\\n\\nextra\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call\",\"call_id\":\"c1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function_call_output\",\"call_id\":\"c1\"") != null);
    // Arguments ride as a JSON string on this wire, so the braces are escaped.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"cache-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"none\",\"summary\":\"auto\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    // The endpoint 400s on this field at any value.
    try std.testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") == null);
}

test "an encrypted reasoning item is kept whole and replayed ahead of its function_call" {
    const alloc = std.testing.allocator;

    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var state: StreamState = .{ .alloc = alloc, .sink = collector.sink() };
    try std.testing.expect(!try state.onData(
        \\{"type":"response.created"}
    ));
    // Summary text streams for display; the item itself is only complete at
    // `output_item.done`, and only useful when the encrypted payload is there.
    try std.testing.expect(!try state.onData(
        \\{"type":"response.reasoning_summary_text.delta","delta":"planning"}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"planning"}],"encrypted_content":"gAAAAA"}}
    ));
    // A reasoning item without encrypted content cannot be replayed: dropped.
    try std.testing.expect(!try state.onData(
        \\{"type":"response.output_item.done","output_index":1,"item":{"id":"rs_2","type":"reasoning","summary":[]}}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","call_id":"c1","name":"shell"}}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.function_call_arguments.delta","output_index":2,"delta":"{}"}
    ));
    try std.testing.expect(try state.onData(
        \\{"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2}}}
    ));
    const turn = try collector.finish();
    defer turn.deinit(alloc);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"planning\"}],\"encrypted_content\":\"gAAAAA\"}]",
        turn.reasoning,
    );

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hello" } });
    try l.append(.{ .assistant = .{ .reasoning = turn.reasoning, .text = turn.text, .calls = turn.calls } });
    try l.append(.{ .tool_results = &.{.{ .call_id = "c1", .ok = true, .output = "ok" }} });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);
    const body = try buildRequestJson(alloc, "gpt-5.5", "k", .{ .prompt_ir = &ir, .tools = &.{} });
    defer alloc.free(body);

    const reasoning = std.mem.indexOf(u8, body, "{\"id\":\"rs_1\",\"type\":\"reasoning\"").?;
    const call = std.mem.indexOf(u8, body, "\"type\":\"function_call\",\"call_id\":\"c1\"").?;
    const output = std.mem.indexOf(u8, body, "\"type\":\"function_call_output\"").?;
    try std.testing.expect(reasoning < call and call < output);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"encrypted_content\":\"gAAAAA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "rs_2") == null);
}

test "an absent effort means the server default, not none" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = .{ .text = "hi" } });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);

    const body = try buildRequestJson(alloc, "gpt-5.5", "k", .{ .prompt_ir = &ir, .tools = &.{} });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"summary\":\"auto\"}") != null);
}

test "SSE events collect into a turn with cache-adjusted usage" {
    const alloc = std.testing.allocator;
    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var state: StreamState = .{ .alloc = alloc, .sink = collector.sink() };

    try std.testing.expect(!try state.onData(
        \\{"type":"response.created"}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.output_text.delta","delta":"run"}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c1","name":"shell"}}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"command\":\"echo hi\"}"}
    ));
    try std.testing.expect(try state.onData(
        \\{"type":"response.completed","response":{"usage":{"input_tokens":1000,"output_tokens":9,"input_tokens_details":{"cached_tokens":900}}}}
    ));

    const turn = try collector.finish();
    defer turn.deinit(alloc);
    try std.testing.expectEqualStrings("run", turn.text);
    try std.testing.expectEqual(@as(usize, 1), turn.calls.len);
    try std.testing.expectEqualStrings("{\"command\":\"echo hi\"}", turn.calls[0].args_json);
    try std.testing.expectEqual(@as(u64, 100), turn.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 900), turn.usage.cache_read_tokens);
    try std.testing.expectEqual(provider.StopReason.tool_use, turn.stop_reason);
}

test "an image rides as an input_image part; a turn without one keeps its pre-image item byte for byte" {
    const alloc = std.testing.allocator;

    var plain = ledger.Ledger.init(alloc);
    defer plain.deinit();
    try plain.append(.{ .user_text = .{ .text = "hello" } });
    const plain_ir = try prompt.project(alloc, plain.view());
    defer plain_ir.deinit(alloc);
    const plain_body = try buildRequestJson(alloc, "gpt-5.5", "cache-1", .{ .prompt_ir = &plain_ir, .tools = &.{} });
    defer alloc.free(plain_body);
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello\"}]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_body, "input_image") == null);

    var shot = ledger.Ledger.init(alloc);
    defer shot.deinit();
    try shot.append(.{ .user_text = .{
        .text = "what is this",
        .images = &.{.{ .media_type = "image/png", .data = "iVBORw0=" }},
    } });
    const shot_ir = try prompt.project(alloc, shot.view());
    defer shot_ir.deinit(alloc);
    const shot_body = try buildRequestJson(alloc, "gpt-5.5", "cache-1", .{ .prompt_ir = &shot_ir, .tools = &.{} });
    defer alloc.free(shot_body);
    // One message item, two parts, in the order the turn holds them.
    try std.testing.expect(std.mem.indexOf(u8, shot_body, "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"what is this\"}," ++
        "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,iVBORw0=\"}]}") != null);
}
