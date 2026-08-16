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
const prompt = @import("../prompt.zig");
const provider = @import("../provider.zig");
const tool = @import("../tool.zig");
const wire = @import("wire.zig");

const backend_url = "https://chatgpt.com/backend-api/codex/responses";
const token_url = "https://auth.openai.com/oauth/token";
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
                try self.refresh(alloc, request.stall_ms);
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

    /// Exchange the refresh token for fresh credentials and write them back to
    /// auth.json, exactly as the Codex CLI does, so the two stay interchangeable.
    fn refresh(self: *CodexProvider, alloc: std.mem.Allocator, stall_ms: u64) !void {
        if (self.auth.refresh_token.len == 0) return error.MissingCredential;
        // `{f}` on a byte slice emits a complete JSON string, quotes included.
        const body = try std.fmt.allocPrint(alloc,
            \\{{"client_id":"{s}","grant_type":"refresh_token","refresh_token":{f},"scope":"openid profile email"}}
        , .{ client_id, std.json.fmt(self.auth.refresh_token, .{}) });
        defer alloc.free(body);

        const response = try wire.postJson(&self.client, alloc, .{ .url = token_url, .body = body, .stall_ms = stall_ms });
        defer alloc.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, response, .{});
        defer parsed.deinit();

        const access = wire.string(parsed.value, "access_token") orelse return error.CodexRefreshFailed;
        if (access.len == 0) return error.CodexRefreshFailed;
        const refresh_token = wire.string(parsed.value, "refresh_token") orelse "";
        try self.auth.replaceTokens(alloc, access, refresh_token);
        self.auth.save(alloc, self.io, self.env, wire.string(parsed.value, "id_token")) catch {};
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
    try writeInput(&jw, alloc, request.prompt_ir.stable_blocks);
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

fn writeInput(jw: *std.json.Stringify, alloc: std.mem.Allocator, blocks: []const prompt.StableBlock) !void {
    try jw.beginArray();
    for (blocks) |block| switch (block.kind) {
        .user_text, .capability_note => try writeMessageItem(jw, "user", "input_text", block.bytes),
        // The turn's `reasoning` items exactly as they came back — id, summary
        // and `encrypted_content` — placed before the output they preceded, which
        // is the position the model produced them in.
        .reasoning => try wire.writeReasoningItems(jw, alloc, block.bytes),
        .assistant_text => if (block.bytes.len != 0) try writeMessageItem(jw, "assistant", "output_text", block.bytes),
        .tool_call => {
            const call = wire.parseToolCall(block.bytes);
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call");
            try jw.objectField("call_id");
            try jw.write(call.id);
            try jw.objectField("name");
            try jw.write(call.name);
            // Arguments are a JSON *string* on this wire, not an object.
            try jw.objectField("arguments");
            try jw.write(call.args_json);
            try jw.endObject();
        },
        .tool_result => {
            const result = wire.parseToolResult(block.bytes);
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call_output");
            try jw.objectField("call_id");
            try jw.write(result.id);
            try jw.objectField("output");
            try jw.write(result.output);
            try jw.endObject();
        },
    };
    try jw.endArray();
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

test "history serializes to flat Responses items and effort off becomes none" {
    const alloc = std.testing.allocator;
    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try l.append(.{ .user_text = "hello" });
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
    try l.append(.{ .user_text = "hello" });
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
    try l.append(.{ .user_text = "hi" });
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
