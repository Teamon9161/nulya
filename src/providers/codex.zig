//! Codex backend: the Responses endpoint the Codex CLI uses
//! (`chatgpt.com/backend-api/codex/responses`), authenticated with the OAuth
//! tokens `codex login` leaves in `~/.codex/auth.json` — no API key; usage bills
//! against the ChatGPT subscription. Chat Completions is `providers/openai.zig`.
//!
//! Wire differences from Chat Completions:
//!  - History is a flat list of typed *items* (message / function_call /
//!    function_call_output), not role messages.
//!  - The prompt cache is keyed by the `session_id` header (the backend writes
//!    it over the body's `prompt_cache_key`), derived here from the durable
//!    session id so the cache survives across `session step` processes.
//!  - The endpoint 400s on `max_output_tokens` at any value.
//!  - Reasoning IS replayed: with `store: false` it returns as a `reasoning`
//!    item whose `encrypted_content` (requested via `include`) is kept on the
//!    ledger and sent back verbatim ahead of the function_call it preceded.

const std = @import("std");
const config = @import("../config.zig");
const prompt = @import("../prompt.zig");
const provider = @import("../provider.zig");
const tool = @import("../tool.zig");
const wire = @import("wire.zig");

const backend_url = "https://chatgpt.com/backend-api/codex/responses";
const token_url = "https://auth.openai.com/oauth/token";
/// The subscription's model catalogue, authenticated exactly like `/responses`.
const models_url = "https://chatgpt.com/backend-api/codex/models";
/// The Codex CLI's public OAuth client id: reusing it lets both tools share the
/// same `auth.json`.
const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";

pub const default_model = "gpt-5.5";

pub const Config = struct {
    model: []const u8 = default_model,
    /// The durable session id, hashed into the per-conversation cache scope;
    /// empty means "one scope per process".
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
    /// `session_id` header / `prompt_cache_key`, in the UUID shape the backend
    /// expects. Derived from the session id, so every process stepping this
    /// session sends the same value.
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
        // One retry, and only for 401 (short-lived access token). A 401 arrives
        // before any SSE data, so the retry cannot duplicate emitted events.
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
/// `auth.json`. Never stored by nulya: the header records only `codex`.
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

    /// Whether a subscription credential exists right now.
    pub fn available(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
        var a = (load(alloc, io, env) catch return false) orelse return false;
        a.deinit(alloc);
        return true;
    }

    /// Exchange the refresh token for fresh credentials and write them back to
    /// auth.json exactly as the Codex CLI does, so the two stay interchangeable.
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
        // Mutate only the token fields: every other key in the file belongs to
        // the Codex CLI and is written back untouched.
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

/// The subscription's own model line-up, read from `$CODEX_HOME/models_cache.json`
/// (else `~/.codex/`). Read only, never configured in `config.toml`. The numbers
/// are the subscription's, not the public API's — a smaller window, an extra
/// effort level, its own default — so it cannot fold into the id-keyed
/// `[[models]]` catalog, where an id is described once for every endpoint.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    /// In the order the file lists them; never empty (no listable model is null).
    models: []const config.ModelParams,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Null when there is nothing usable: no home, no file, unreadable JSON, or
    /// not one listable model — "cannot say", never "there are none".
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

/// One cache document → the model parameters it states; everything else the file
/// carries is the Codex CLI's business. Both shapes are accepted: the file is
/// always `{"models":[…]}`, the endpoint may answer with a bare array. Allocated
/// in `arena`, which must outlive `text` (unescaped JSON strings alias it).
fn parse(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?[]const config.ModelParams {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    const listed = switch (wire.field(doc, "models") orelse doc) {
        .array => |a| a.items,
        else => return null,
    };

    var out: std.ArrayList(config.ModelParams) = .empty;
    for (listed) |m| {
        // `hide` marks models that exist but are not offered; listing them
        // would put a choice in a picker that is not the user's to make.
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
            // Not claimed here: the `--image` gate reads the id-keyed
            // `[[models]]` catalog, so a claim here is one nothing honours.
            .vision = false,
        });
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(arena);
}

/// The window the subscription actually gives: the raw one, times the percentage
/// it reserves. A model that states no window is kept without one.
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

/// Fetch the live catalogue into the Codex CLI's own cache file. Nothing
/// refreshes it on its own; the only trigger is `nulya config refresh`.
/// `client_version` is this binary's version string, a query parameter here.
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
    // Never overwrite a good cache with an answer describing no model — the
    // same predicate the reader applies.
    if ((try parse(a, body)) == null) return error.CodexCatalogEmpty;
    try saveCatalog(alloc, io, env, a, response);
}

/// A projection is not a step: a catalogue that goes quiet fails in seconds and
/// leaves the file alone rather than holding `config show` for minutes.
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
/// Codex CLI, so only `models` is replaced; `fetched_at`, `etag` and the rest are
/// written back untouched and never invented.
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
    // form, the shape the CLI reads.
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

/// A UUID-shaped, deterministic name hash: the backend wants UUID syntax, and the
/// same session id must map to the same value so its cache is one scope.
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
    // Nothing is stored server-side, so reasoning that must survive to the
    // next step travels with the response, encrypted.
    try jw.objectField("include");
    try jw.beginArray();
    try jw.write("reasoning.encrypted_content");
    try jw.endArray();
    try jw.objectField("stream");
    try jw.write(true);
    // The backend overwrites this with the `session_id` header; sending it
    // keeps a captured request self-describing.
    try jw.objectField("prompt_cache_key");
    try jw.write(cache_key);
    try jw.objectField("reasoning");
    try jw.beginObject();
    if (request.options.effort) |effort| {
        try jw.objectField("effort");
        // The Responses API spells "do not reason" as `none`; `off` verbatim is
        // a 400. An absent effort stays absent, meaning the server default.
        try jw.write(if (std.mem.eql(u8, effort, "off")) "none" else effort);
    }
    try jw.objectField("summary");
    try jw.write("auto");
    try jw.endObject();
    try jw.endObject();
    return out.toOwnedSlice();
}

/// This API takes one instructions string, not a block list; joining the frozen
/// blocks in order keeps the cached prefix byte-identical between turns.
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
        .note => |text| try writeMessageItem(jw, "user", "input_text", text),
        .assistant => |as| {
            // `reasoning` items exactly as they came back, in the position the
            // model produced them: before the output they preceded.
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

/// A user turn: text and inlined images as parts of ONE message item; an image is
/// an `input_image` part, and an image-only turn writes no text part.
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

/// Only an explicit rate-limit, overload, or "you can retry" failure is safe to
/// resend; anything else may be a permanent model/request problem and fails.
fn streamError(root: std.json.Value) error{ RateLimited, ServerError, CodexStreamError } {
    const response = wire.field(root, "response") orelse root;
    const response_error = wire.field(response, "error") orelse response;
    const top_error = wire.field(root, "error") orelse root;
    const code = wire.string(response_error, "code") orelse wire.string(top_error, "code") orelse "";
    const message = wire.string(response_error, "message") orelse
        wire.string(top_error, "message") orelse
        wire.string(root, "message") orelse "";

    if (containsIgnoreCase(code, "rate_limit")) return error.RateLimited;
    if (containsIgnoreCase(code, "overload") or
        containsIgnoreCase(message, "overloaded") or
        containsIgnoreCase(message, "you can retry your request")) return error.ServerError;
    return error.CodexStreamError;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const StreamState = struct {
    alloc: std.mem.Allocator,
    sink: provider.EventSink,
    saw_tool_use: bool = false,
    started: bool = false,
    done: bool = false,

    pub fn onData(self: *StreamState, data: []const u8) anyerror!bool {
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
            // A finished reasoning item carries `encrypted_content` only here,
            // and only when `include` asked for it. Without that field it
            // cannot be replayed under `store: false`, so it is not kept.
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
            return streamError(root);
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

    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", models[0].id);
    try std.testing.expectEqualStrings("GPT-5.6-Sol", models[0].label);
    try std.testing.expectEqual(@as(u64, 258_400), models[0].context_window.?);
    try std.testing.expectEqual(@as(usize, 3), models[0].efforts.len);
    try std.testing.expectEqualStrings("low", models[0].efforts[0]);
    try std.testing.expectEqualStrings("xhigh", models[0].efforts[2]);
    try std.testing.expectEqualStrings("low", models[0].default_effort.?);
    try std.testing.expectEqualStrings("bare", models[1].id);
    try std.testing.expectEqualStrings("", models[1].label);
    try std.testing.expectEqual(@as(usize, 0), models[1].efforts.len);
    try std.testing.expect(models[1].default_effort == null);
    try std.testing.expect(models[1].context_window == null);
    try std.testing.expect(!models[0].vision);

    const bare = (try parse(a,
        \\[{"slug":"gpt-5.5","visibility":"list","context_window":272000}]
    )).?;
    try std.testing.expectEqual(@as(u64, 272_000), bare[0].context_window.?);

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
    try std.testing.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"cache-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"none\",\"summary\":\"auto\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") == null);
}

test "Codex stream errors retry only the transient shapes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, expected: anyerror }{
        .{
            .json = "{\"type\":\"error\",\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"Try again later.\"}}",
            .expected = error.RateLimited,
        },
        .{
            .json = "{\"type\":\"error\",\"error\":{\"message\":\"Our servers are currently overloaded. Please try again later.\"}}",
            .expected = error.ServerError,
        },
        .{
            .json = "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"You can retry your request, or contact support.\"}}}",
            .expected = error.ServerError,
        },
        .{
            .json = "{\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"model_not_found\",\"message\":\"Unknown model.\"}}}",
            .expected = error.CodexStreamError,
        },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, streamError(parsed.value));
    }
}

test "an encrypted reasoning item is kept whole and replayed ahead of its function_call" {
    const alloc = std.testing.allocator;

    var collector = provider.TurnCollector.init(alloc);
    defer collector.deinit();
    var state: StreamState = .{ .alloc = alloc, .sink = collector.sink() };
    try std.testing.expect(!try state.onData(
        \\{"type":"response.created"}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.reasoning_summary_text.delta","delta":"planning"}
    ));
    try std.testing.expect(!try state.onData(
        \\{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"planning"}],"encrypted_content":"gAAAAA"}}
    ));
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

test "a note rides as a user input_text item" {
    const alloc = std.testing.allocator;

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .note = .{
        .source = ledger.note_source_task,
        .text = "[background task s-1/t3 finished] zig build test · exit 0",
        .meta = "{\"task\":\"s-1/t3\",\"exit_code\":0}",
    } });
    const ir = try prompt.project(alloc, l.view());
    defer ir.deinit(alloc);
    const body = try buildRequestJson(alloc, "gpt-5.5", "cache-1", .{ .prompt_ir = &ir, .tools = &.{} });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\"," ++
        "\"text\":\"[background task s-1/t3 finished] zig build test · exit 0\"}]}") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, shot_body, "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"what is this\"}," ++
        "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,iVBORw0=\"}]}") != null);
}
