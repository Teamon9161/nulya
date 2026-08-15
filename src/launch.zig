//! Shared session-launch helpers for the `nulya session *` CLI and the bare
//! `nulya` demo (DESIGN §14, PLAN §3.2).
//!
//! Both surfaces need the same three things: a deterministic scripted provider
//! (the offline stand-in when no API key is configured), a way to build a model
//! from a config profile, and the conventions for session file paths and ids.
//! Keeping them here means the demo runs through the exact same durable-session
//! path the CLI does.

const std = @import("std");
const provider = @import("provider.zig");
const prompt = @import("prompt.zig");
const openai = @import("providers/openai.zig");
const anthropic = @import("providers/anthropic.zig");
const codex = @import("providers/codex.zig");
const config = @import("config.zig");
const ledger = @import("ledger.zig");

pub const default_openai_model = "gpt-4o-mini";
pub const default_openai_base_url = "https://api.openai.com/v1";

pub const sessions_dir = ".nulya/sessions";
pub const scratch_dir = ".nulya/scratch";

/// A deterministic, terminating scripted provider — the offline stand-in for a
/// real model (DESIGN §13). Two modes, selected by `NULYA_SCRIPTED_MODE`:
///
///   finish (default): make one `shell` call, then end the turn once a tool
///                     result is already in the transcript. A turn completes in
///                     two steps, so a `session step` reaches an end state.
///   loop:             always make one `shell` call and never end the turn, so a
///                     `--max-steps` cap is the only thing that stops it.
pub const ScriptedProvider = struct {
    mode: Mode = .finish,

    pub const Mode = enum { finish, loop };

    pub fn fromEnv(env: *const std.process.Environ.Map) ScriptedProvider {
        const m = env.get("NULYA_SCRIPTED_MODE") orelse "";
        return .{ .mode = if (std.mem.eql(u8, m, "loop")) .loop else .finish };
    }

    pub fn handle(self: *ScriptedProvider) provider.Model {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted-demo";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = alloc;
        const self: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        try sink.emit(.started);

        if (self.mode == .finish and hasToolResult(request.prompt_ir.stable_blocks)) {
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .end_turn });
            return;
        }

        try sink.emit(.{ .text_delta = "Let me probe the environment." });
        try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo hello-from-nulya\"}" } });
        try sink.emit(.{ .done = .tool_use });
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

fn hasToolResult(blocks: []const prompt.StableBlock) bool {
    for (blocks) |b| {
        if (b.kind == .tool_result) return true;
    }
    return false;
}

/// Owns whichever concrete provider a session uses; `model()` hands out a stable
/// handle into it. Caller keeps this as a `var` so the handle stays valid.
pub const ModelHolder = union(enum) {
    scripted: ScriptedProvider,
    openai: openai.OpenAiProvider,
    anthropic: anthropic.AnthropicProvider,
    codex: codex.CodexProvider,

    pub fn deinit(self: *ModelHolder) void {
        switch (self.*) {
            .scripted => {},
            .openai => |*p| p.deinit(),
            .anthropic => |*p| p.deinit(),
            .codex => |*p| p.deinit(),
        }
    }

    pub fn model(self: *ModelHolder) provider.Model {
        return switch (self.*) {
            .scripted => |*p| p.handle(),
            .openai => |*p| p.modelHandle(),
            .anthropic => |*p| p.modelHandle(),
            .codex => |*p| p.modelHandle(),
        };
    }
};

/// Resolve `profile_name` into the model IDENTITY frozen at session creation —
/// the ONE model-resolution decision (DESIGN §3). It is credential-aware, so what
/// gets frozen is exactly what will run: a profile whose durable credential is
/// not resolvable falls back to the scripted identity here, and
/// `buildFromDescriptor` then builds scripted too — no fork between "what ran"
/// and "what the header says". A durable session only ever references an API-key
/// credential by env var name; an inline `api_key` cannot be recovered at resume
/// (that would re-couple the session to mutable config), so it does not count.
/// The codex profile's credential is not an env var at all but the Codex CLI's
/// `auth.json`, which is why this needs `io`. Slices borrow the config profile;
/// the caller freezes copies into the header before config is dropped.
pub fn resolveDescriptor(
    alloc: std.mem.Allocator,
    io: std.Io,
    prov: config.Provider,
    env: *const std.process.Environ.Map,
    profile_name: []const u8,
) ledger.ModelDescriptor {
    const scripted: ledger.ModelDescriptor = .{ .provider = "scripted" };
    const profile = prov.findProfile(profile_name) orelse return scripted;
    return switch (profile.kind) {
        .scripted => scripted,
        // Only a resolvable env credential yields a durable API identity;
        // otherwise this session is (and stays) scripted.
        .openai => if (envValue(env, profile.api_key_env) == null) scripted else .{
            .provider = "openai",
            .model = nonEmpty(profile.model, default_openai_model),
            .base_url = nonEmpty(profile.base_url, default_openai_base_url),
            .api_key_env = profile.api_key_env,
        },
        .anthropic => if (envValue(env, profile.api_key_env) == null) scripted else .{
            .provider = "anthropic",
            .model = nonEmpty(profile.model, anthropic.default_model),
            .base_url = nonEmpty(profile.base_url, anthropic.default_base_url),
            .api_key_env = profile.api_key_env,
        },
        .codex => if (!codex.Auth.available(alloc, io, env)) scripted else .{
            .provider = "codex",
            .model = nonEmpty(profile.model, codex.default_model),
        },
    };
}

pub const BuildIdentityError = error{ MissingCredential, ProviderUnavailable, OutOfMemory };

pub const BuildOptions = struct {
    /// The durable session id. Providers with an explicit prompt-cache key
    /// (codex) derive theirs from it, so one conversation is one cache scope
    /// across every `session step` process. Empty is legal and simply means an
    /// unnamed scope.
    cache_key: []const u8 = "",
};

/// Build the model from a frozen descriptor — used both at creation (from the
/// just-resolved descriptor, so the running model == the frozen identity) and on
/// resume (from the header). It re-resolves only the credential from the
/// environment (or, for codex, from the Codex CLI's auth file) and stores no
/// secret. There is deliberately NO scripted fallback: a session frozen as a real
/// provider whose credential is gone fails with `MissingCredential` rather than
/// silently degrading to scripted (DESIGN §3). An empty/legacy or scripted
/// descriptor builds the scripted provider, needing no credential.
pub fn buildFromDescriptor(
    alloc: std.mem.Allocator,
    io: std.Io,
    desc: ledger.ModelDescriptor,
    env: *const std.process.Environ.Map,
    opts: BuildOptions,
) BuildIdentityError!ModelHolder {
    if (desc.provider.len == 0 or std.mem.eql(u8, desc.provider, "scripted")) {
        return .{ .scripted = ScriptedProvider.fromEnv(env) };
    }
    if (std.mem.eql(u8, desc.provider, "openai")) {
        const api_key = envValue(env, desc.api_key_env) orelse return error.MissingCredential;
        return .{ .openai = try openai.OpenAiProvider.init(alloc, io, .{
            .api_key = api_key,
            .model = nonEmpty(desc.model, default_openai_model),
            .base_url = nonEmpty(desc.base_url, default_openai_base_url),
        }) };
    }
    if (std.mem.eql(u8, desc.provider, "anthropic")) {
        const api_key = envValue(env, desc.api_key_env) orelse return error.MissingCredential;
        return .{ .anthropic = try anthropic.AnthropicProvider.init(alloc, io, .{
            .api_key = api_key,
            .model = nonEmpty(desc.model, anthropic.default_model),
            .base_url = nonEmpty(desc.base_url, anthropic.default_base_url),
        }) };
    }
    if (std.mem.eql(u8, desc.provider, "codex")) {
        return .{ .codex = try codex.CodexProvider.init(alloc, io, .{
            .model = nonEmpty(desc.model, codex.default_model),
            .cache_key = opts.cache_key,
            .env = env,
        }) };
    }
    return error.ProviderUnavailable;
}

fn envValue(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

pub fn nonEmpty(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len == 0) fallback else value;
}

/// Session file path relative to the workspace: `.nulya/sessions/<id>.jsonl`.
/// Caller owns the result.
pub fn sessionPath(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}.jsonl", .{ sessions_dir, id });
}

/// A time-ordered, collision-resistant session id: `s-<unix-ms>-<hex>`.
/// Caller owns the result.
pub fn genSessionId(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Timestamp.now(io, .real);
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(i64, @truncate(now.toNanoseconds()))));
    const suffix = prng.random().int(u24);
    return std.fmt.allocPrint(alloc, "s-{d}-{x}", .{ now.toMilliseconds(), suffix });
}

/// A valid session id contains only path-safe characters (never `/`, `\`, `..`),
/// so a caller-supplied id cannot escape the sessions directory.
pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    // Reject any `..` component defensively.
    if (std.mem.indexOf(u8, id, "..") != null) return false;
    return true;
}

test "session id is path-safe and unique-ish" {
    const alloc = std.testing.allocator;
    const a = try genSessionId(alloc, std.testing.io);
    defer alloc.free(a);
    try std.testing.expect(isValidSessionId(a));
    try std.testing.expect(std.mem.startsWith(u8, a, "s-"));
}

test "session id validation rejects traversal" {
    try std.testing.expect(isValidSessionId("s-123-abcd"));
    try std.testing.expect(!isValidSessionId("../evil"));
    try std.testing.expect(!isValidSessionId("a/b"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId(".."));
}

test "resolveDescriptor is credential-aware: what it freezes is what will run" {
    const alloc = std.testing.allocator;
    var profiles = [_]config.ProviderProfile{
        .{ .name = "openai", .kind = .openai, .api_key_env = "OPENAI_API_KEY" },
        .{ .name = "local", .kind = .scripted },
        .{ .name = "inline", .kind = .openai, .api_key = "sk-inline", .api_key_env = "" },
    };
    const prov: config.Provider = .{ .active_profile = "openai", .profiles = &profiles };

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();

    // openai profile, no env credential -> frozen as scripted (== what runs).
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "openai").provider);

    // openai profile with the env credential present -> a durable openai identity,
    // resolved (defaulted) model/base_url, referenced by env var name only.
    try env.put("OPENAI_API_KEY", "sk-test");
    const d = resolveDescriptor(alloc, std.testing.io, prov, &env, "openai");
    try std.testing.expectEqualStrings("openai", d.provider);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", d.api_key_env);
    try std.testing.expectEqualStrings(default_openai_model, d.model);
    try std.testing.expectEqualStrings(default_openai_base_url, d.base_url);

    // An inline api_key is not usable for a durable session: no api_key_env means
    // no env-recoverable credential, so it freezes scripted, never openai.
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "inline").provider);

    // Scripted and unknown profiles freeze the scripted identity.
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "local").provider);
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "nope").provider);
}

test "buildFromDescriptor never falls back: a keyless openai identity fails loudly" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();

    const openai_id: ledger.ModelDescriptor = .{ .provider = "openai", .model = "gpt-x", .base_url = "https://api.openai.com/v1", .api_key_env = "OPENAI_API_KEY" };
    // No key in the environment -> MissingCredential, NOT a scripted session.
    try std.testing.expectError(error.MissingCredential, buildFromDescriptor(alloc, std.testing.io, openai_id, &env, .{}));

    // With the key present, it builds the frozen openai model.
    try env.put("OPENAI_API_KEY", "sk-test");
    var holder = try buildFromDescriptor(alloc, std.testing.io, openai_id, &env, .{});
    defer holder.deinit();
    try std.testing.expect(holder == .openai);

    // A scripted (or empty/legacy) identity builds scripted with no key needed.
    var scripted = try buildFromDescriptor(alloc, std.testing.io, .{ .provider = "scripted" }, &env, .{});
    defer scripted.deinit();
    try std.testing.expect(scripted == .scripted);
    var legacy = try buildFromDescriptor(alloc, std.testing.io, .{}, &env, .{});
    defer legacy.deinit();
    try std.testing.expect(legacy == .scripted);
}

test "scripted provider mode comes from the environment" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try std.testing.expectEqual(ScriptedProvider.Mode.finish, ScriptedProvider.fromEnv(&env).mode);
    try env.put("NULYA_SCRIPTED_MODE", "loop");
    try std.testing.expectEqual(ScriptedProvider.Mode.loop, ScriptedProvider.fromEnv(&env).mode);
}
