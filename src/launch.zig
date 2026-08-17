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
const environment = @import("environment.zig");
const store = @import("extension/store.zig");
const build_options = @import("config_options");

/// This build's version string, straight from `build.zig.zon` `.version` (build.zig
/// passes it through). Stamped into every new session header as provenance
/// (`ledger.Stamp`, DESIGN §3.4); nothing branches on it.
pub const version: []const u8 = build_options.version;

pub const default_openai_model = "gpt-4o-mini";
pub const default_openai_base_url = "https://api.openai.com/v1";

pub const sessions_dir = ".nulya/sessions";
pub const scratch_dir = ".nulya/scratch";

/// Scratch owned by exactly ONE session: `.nulya/scratch/<session-id>`. Spill
/// filenames inside are deterministic (ledger seq + call index, `emit.zig`), so
/// the session id is the only thing keeping two concurrent sessions — a fork's
/// parent and child, a compact driver and its observer — from writing the same
/// file (base-tools.md §2). Caller owns the result.
pub fn sessionScratchDir(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ scratch_dir, id });
}

/// A deterministic, terminating scripted provider — the offline stand-in for a
/// real model (DESIGN §13). Three modes, selected by `NULYA_SCRIPTED_MODE`:
///
///   finish (default): make one `shell` call, then end the turn once a tool
///                     result is already in the transcript. A turn completes in
///                     two steps, so a `session step` reaches an end state.
///   loop:             always make one `shell` call and never end the turn, so a
///                     `--max-steps` cap is the only thing that stops it.
///   truncate:         every reply is cut by `max_tokens` mid tool call (a torn
///                     JSON prefix, then `done: max_tokens`), so the loop's
///                     truncated-turn path and `run`'s streak stop are testable.
pub const ScriptedProvider = struct {
    mode: Mode = .finish,

    pub const Mode = enum { finish, loop, truncate };

    pub fn fromEnv(env: *const std.process.Environ.Map) ScriptedProvider {
        const m = env.get("NULYA_SCRIPTED_MODE") orelse "";
        return .{ .mode = std.meta.stringToEnum(Mode, m) orelse .finish };
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

        if (self.mode == .finish and hasToolResult(request.prompt_ir.turns)) {
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .end_turn });
            return;
        }
        if (self.mode == .truncate) {
            try sink.emit(.{ .text_delta = "Let me probe" });
            try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
            try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo hel" } });
            try sink.emit(.{ .done = .max_tokens });
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

fn hasToolResult(turns: []const prompt.Turn) bool {
    for (turns) |turn| {
        if (turn == .tool_results) return true;
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

/// Resolve `profile_name` (+ an optional model id) into the model IDENTITY
/// frozen at session creation — the ONE model-resolution decision (DESIGN §3).
/// It is credential-aware, so what gets frozen is exactly what will run: a
/// profile whose credential is not resolvable falls back to the scripted
/// identity here, and `buildFromDescriptor` then builds scripted too — no fork
/// between "what ran" and "what the header says".
///
/// The header never holds a secret: it records the env var NAME (`api_key_env`)
/// and the profile name, and the credential itself is re-resolved on every
/// resume — from the profile's own `api_key` in the user's config, else from the
/// environment. Both are the user's own mutable places; neither is model-visible
/// state, so which one it comes from is not part of the identity. The codex
/// profile's credential is the Codex CLI's `auth.json`, which is why this needs
/// `io`.
///
/// `model_id` overrides the profile's default model (`ProviderProfile.defaultModel`)
/// and is taken as given — a picker offers the catalog's ids, but a driver may
/// name any id the endpoint serves. Slices borrow the config profile; the caller
/// freezes copies into the header before config is dropped.
pub fn resolveDescriptor(
    alloc: std.mem.Allocator,
    io: std.Io,
    prov: config.Provider,
    env: *const std.process.Environ.Map,
    profile_name: []const u8,
    model_id: ?[]const u8,
) ledger.ModelDescriptor {
    const scripted: ledger.ModelDescriptor = .{ .provider = "scripted" };
    const profile = prov.findProfile(profile_name) orelse return scripted;
    const chosen = nonEmpty(model_id orelse "", profile.defaultModel());
    const keyed = credentialSource(alloc, io, profile, env) != .none;
    return switch (profile.kind) {
        .scripted => scripted,
        // Only a resolvable credential yields a durable API identity; otherwise
        // this session is (and stays) scripted.
        .openai => if (!keyed) scripted else .{
            .provider = "openai",
            .model = nonEmpty(chosen, default_openai_model),
            .base_url = nonEmpty(profile.base_url, default_openai_base_url),
            .api_key_env = profile.api_key_env,
        },
        .anthropic => if (!keyed) scripted else .{
            .provider = "anthropic",
            .model = nonEmpty(chosen, anthropic.default_model),
            .base_url = nonEmpty(profile.base_url, anthropic.default_base_url),
            .api_key_env = profile.api_key_env,
        },
        .codex => if (!keyed) scripted else .{
            .provider = "codex",
            .model = nonEmpty(chosen, codex.default_model),
        },
    };
}

/// Where a profile's credential comes from right now, if anywhere. `config`
/// (its own `api_key`, the user's file) wins over `env` (`api_key_env`), so the
/// key a person pasted into nulya's own config is the one that runs even if a
/// stale variable is still exported. `scripted` needs nothing.
pub const CredentialSource = enum { none, config, env, login, builtin };

pub fn credentialSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    profile: config.ProviderProfile,
    env: *const std.process.Environ.Map,
) CredentialSource {
    return switch (profile.kind) {
        .scripted => .builtin,
        .openai, .anthropic => if (inlineKey(profile) != null) .config else if (envValue(env, profile.api_key_env) != null) .env else .none,
        .codex => if (codex.Auth.available(alloc, io, env)) .login else .none,
    };
}

/// Whether `profile` can run right now — the same test `resolveDescriptor`
/// applies, exposed so a picker can mark which rows a session can actually
/// start on (and say what is missing when it cannot).
pub fn credentialAvailable(
    alloc: std.mem.Allocator,
    io: std.Io,
    profile: config.ProviderProfile,
    env: *const std.process.Environ.Map,
) bool {
    return credentialSource(alloc, io, profile, env) != .none;
}

/// The profile's own `api_key`, when it has a non-empty one.
pub fn inlineKey(profile: config.ProviderProfile) ?[]const u8 {
    const key = profile.api_key orelse return null;
    return if (key.len == 0) null else key;
}

pub const BuildIdentityError = error{ MissingCredential, ProviderUnavailable, OutOfMemory };

pub const BuildOptions = struct {
    /// The durable session id. Providers with an explicit prompt-cache key
    /// (codex) derive theirs from it, so one conversation is one cache scope
    /// across every `session step` process. Empty is legal and simply means an
    /// unnamed scope.
    cache_key: []const u8 = "",
    /// The profile's own `api_key` from the user's config, when it has one —
    /// the caller looks it up by the header's profile name. Wins over the env
    /// var (`credentialSource`). Never stored anywhere by this module.
    inline_key: ?[]const u8 = null,
};

/// Build the model from a frozen descriptor — used both at creation (from the
/// just-resolved descriptor, so the running model == the frozen identity) and on
/// resume (from the header). It re-resolves only the credential — the config's
/// `api_key` (`opts.inline_key`), else the environment, or for codex the Codex
/// CLI's auth file — and stores no secret. There is deliberately NO scripted
/// fallback: a session frozen as a real provider whose credential is gone fails
/// with `MissingCredential` rather than silently degrading to scripted (DESIGN
/// §3). An empty/legacy or scripted descriptor builds the scripted provider,
/// needing no credential.
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
    const inline_key: ?[]const u8 = if (opts.inline_key) |k| (if (k.len != 0) k else null) else null;
    if (std.mem.eql(u8, desc.provider, "openai")) {
        const api_key = inline_key orelse envValue(env, desc.api_key_env) orelse return error.MissingCredential;
        return .{ .openai = try openai.OpenAiProvider.init(alloc, io, .{
            .api_key = api_key,
            .model = nonEmpty(desc.model, default_openai_model),
            .base_url = nonEmpty(desc.base_url, default_openai_base_url),
        }) };
    }
    if (std.mem.eql(u8, desc.provider, "anthropic")) {
        const api_key = inline_key orelse envValue(env, desc.api_key_env) orelse return error.MissingCredential;
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

/// The execution environment a session runs its tools behind, per config
/// (DESIGN §8). Only `local` exists: `sandbox` / `remote` parse but have no
/// implementation, so they are refused HERE — at the one place a session's
/// environment is built — rather than silently running locally under a config
/// that asked for isolation.
pub fn localEnvironment(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
) !environment.LocalEnvironment {
    if (cfg.environment.backend != .local) return error.UnsupportedEnvironmentBackend;
    return environment.LocalEnvironment.init(alloc, io, .{ .dialect = cfg.environment.shell.toLocalOption() });
}

/// The extension store roots this process searches, in order (DESIGN §7.2):
///
///   1. the workspace's `.nulya/extensions` (relative — resolved against cwd);
///   2. the user's `<NULYA_HOME | ~/.nulya>/extensions`, so a capability built
///      once is available in every workspace;
///   3. `extensions.paths` from the config — **trusted layers only**, since a
///      checkout must not be able to decide which directories on this machine
///      get to supply `current` versions (the same "project layer can only
///      narrow" invariant as DESIGN §9.5).
///
/// The first root holding an id wins, so a workspace copy shadows a user-wide
/// one. Roots that do not exist are skipped when opened. Caller owns the slice
/// and its entries (`freeExtensionRoots`).
pub fn extensionRoots(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cfg: *const config.Config,
) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer freeExtensionRoots(alloc, roots.items);

    try roots.append(alloc, try alloc.dupe(u8, store.workspace_root_rel));

    if (try userExtensionsRoot(alloc, env)) |user| try roots.append(alloc, user);

    for (cfg.extensions.paths) |p| {
        if (p.len != 0) try roots.append(alloc, try alloc.dupe(u8, p));
    }
    return roots.toOwnedSlice(alloc);
}

/// `<NULYA_HOME | ~/.nulya>/extensions` — the user-level store, where `--user`
/// writes. Null when this machine has no home directory at all. Caller owns it.
pub fn userExtensionsRoot(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    const home = try config.userHome(alloc, env);
    defer alloc.free(home);
    if (home.len == 0) return null;
    return try std.fs.path.join(alloc, &.{ home, "extensions" });
}

pub fn freeExtensionRoots(alloc: std.mem.Allocator, roots: []const []const u8) void {
    for (roots) |r| alloc.free(r);
    alloc.free(roots);
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

/// The current instant as RFC3339 UTC (`2026-08-16T09:31:00Z`) — what a session
/// header's `created` and an outcome journal line's `at` record. Second
/// granularity: these are human-facing timestamps for ordering and reading, not
/// a measurement. Caller owns the result.
pub fn rfc3339Now(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    const ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return rfc3339FromUnixSeconds(alloc, if (ms < 0) 0 else @intCast(@divFloor(ms, 1000)));
}

fn rfc3339FromUnixSeconds(alloc: std.mem.Allocator, secs: u64) ![]u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
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

test "extension roots search workspace, then user, then trusted config paths" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("NULYA_HOME", if (@import("builtin").os.tag == .windows) "D:\\home\\.nulya" else "/home/me/.nulya");

    var cfg = config.Config.init(alloc);
    defer cfg.deinit();
    cfg.extensions = .{ .paths = &.{ "/opt/shared/extensions", "" } };

    const roots = try extensionRoots(alloc, &env, &cfg);
    defer freeExtensionRoots(alloc, roots);
    try std.testing.expectEqual(@as(usize, 3), roots.len); // the empty spec is dropped
    try std.testing.expectEqualStrings(store.workspace_root_rel, roots[0]);
    try std.testing.expectEqualStrings(
        if (@import("builtin").os.tag == .windows) "D:\\home\\.nulya\\extensions" else "/home/me/.nulya/extensions",
        roots[1],
    );
    try std.testing.expectEqualStrings("/opt/shared/extensions", roots[2]);

    // No home at all: the workspace root is still there, and `--user` has
    // nowhere to write rather than guessing a path.
    var homeless: std.process.Environ.Map = .init(alloc);
    defer homeless.deinit();
    var bare = config.Config.init(alloc);
    defer bare.deinit();
    const only_workspace = try extensionRoots(alloc, &homeless, &bare);
    defer freeExtensionRoots(alloc, only_workspace);
    try std.testing.expectEqual(@as(usize, 1), only_workspace.len);
    try std.testing.expect((try userExtensionsRoot(alloc, &homeless)) == null);
}

test "rfc3339 renders a UTC instant, and now() is one of them" {
    const alloc = std.testing.allocator;
    const zero = try rfc3339FromUnixSeconds(alloc, 0);
    defer alloc.free(zero);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", zero);

    const day = try rfc3339FromUnixSeconds(alloc, 1_786_872_667);
    defer alloc.free(day);
    try std.testing.expectEqualStrings("2026-08-16T09:31:07Z", day);

    // A leap day is not off by one.
    const leap = try rfc3339FromUnixSeconds(alloc, 1_709_251_199);
    defer alloc.free(leap);
    try std.testing.expectEqualStrings("2024-02-29T23:59:59Z", leap);

    const now = try rfc3339Now(alloc, std.testing.io);
    defer alloc.free(now);
    try std.testing.expectEqual(@as(usize, 20), now.len);
    try std.testing.expectEqual(@as(u8, 'Z'), now[19]);
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
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", null).provider);
    try std.testing.expect(!credentialAvailable(alloc, std.testing.io, prov.findProfile("openai").?, &env));

    // openai profile with the env credential present -> a durable openai identity,
    // resolved (defaulted) model/base_url, referenced by env var name only.
    try env.put("OPENAI_API_KEY", "sk-test");
    const d = resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", null);
    try std.testing.expectEqualStrings("openai", d.provider);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", d.api_key_env);
    try std.testing.expectEqualStrings(default_openai_model, d.model);
    try std.testing.expectEqualStrings(default_openai_base_url, d.base_url);
    try std.testing.expect(credentialAvailable(alloc, std.testing.io, prov.findProfile("openai").?, &env));

    // A named model id overrides the profile default and is frozen as given.
    const picked = resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", "gpt-x");
    try std.testing.expectEqualStrings("gpt-x", picked.model);
    // An empty id means "profile default", same as none.
    try std.testing.expectEqualStrings(default_openai_model, resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", "").model);

    // A profile's own api_key (the user's config file) is a credential too: the
    // identity freezes openai with an EMPTY api_key_env — the header still holds
    // no secret; resume finds the key by profile name (`BuildOptions.inline_key`).
    const inline_id = resolveDescriptor(alloc, std.testing.io, prov, &env, "inline", null);
    try std.testing.expectEqualStrings("openai", inline_id.provider);
    try std.testing.expectEqualStrings("", inline_id.api_key_env);
    try std.testing.expectEqual(CredentialSource.config, credentialSource(alloc, std.testing.io, prov.findProfile("inline").?, &env));
    try std.testing.expectEqual(CredentialSource.env, credentialSource(alloc, std.testing.io, prov.findProfile("openai").?, &env));
    try std.testing.expectEqual(CredentialSource.builtin, credentialSource(alloc, std.testing.io, prov.findProfile("local").?, &env));

    // Scripted and unknown profiles freeze the scripted identity.
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "local", null).provider);
    try std.testing.expect(credentialAvailable(alloc, std.testing.io, prov.findProfile("local").?, &env));
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "nope", null).provider);
}

test "a profile's default model comes from `model`, else the first of `models`" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("K", "v");

    var profiles = [_]config.ProviderProfile{
        .{ .name = "listed", .kind = .openai, .api_key_env = "K", .models = &.{ "first", "second" } },
        .{ .name = "both", .kind = .openai, .api_key_env = "K", .model = "explicit", .models = &.{ "first", "explicit" } },
    };
    const prov: config.Provider = .{ .profiles = &profiles };
    try std.testing.expectEqualStrings("first", resolveDescriptor(alloc, std.testing.io, prov, &env, "listed", null).model);
    try std.testing.expectEqualStrings("explicit", resolveDescriptor(alloc, std.testing.io, prov, &env, "both", null).model);
    try std.testing.expectEqualStrings("second", resolveDescriptor(alloc, std.testing.io, prov, &env, "listed", "second").model);
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

test "an identity with no api_key_env resumes on the config's own api_key, and that key wins over the env" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();

    // Frozen from a profile whose only credential was its inline api_key.
    const from_config: ledger.ModelDescriptor = .{ .provider = "openai", .model = "gpt-x", .base_url = "https://api.openai.com/v1" };
    try std.testing.expectError(error.MissingCredential, buildFromDescriptor(alloc, std.testing.io, from_config, &env, .{}));
    var holder = try buildFromDescriptor(alloc, std.testing.io, from_config, &env, .{ .inline_key = "sk-from-config" });
    defer holder.deinit();
    try std.testing.expectEqualStrings("sk-from-config", holder.openai.api_key);

    // Both present: the config's key runs, the env var is the fallback.
    try env.put("OPENAI_API_KEY", "sk-from-env");
    const both: ledger.ModelDescriptor = .{ .provider = "openai", .model = "gpt-x", .base_url = "https://api.openai.com/v1", .api_key_env = "OPENAI_API_KEY" };
    var preferred = try buildFromDescriptor(alloc, std.testing.io, both, &env, .{ .inline_key = "sk-from-config" });
    defer preferred.deinit();
    try std.testing.expectEqualStrings("sk-from-config", preferred.openai.api_key);
    var fallback = try buildFromDescriptor(alloc, std.testing.io, both, &env, .{ .inline_key = "" });
    defer fallback.deinit();
    try std.testing.expectEqualStrings("sk-from-env", fallback.openai.api_key);
}

test "scripted provider mode comes from the environment" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try std.testing.expectEqual(ScriptedProvider.Mode.finish, ScriptedProvider.fromEnv(&env).mode);
    try env.put("NULYA_SCRIPTED_MODE", "loop");
    try std.testing.expectEqual(ScriptedProvider.Mode.loop, ScriptedProvider.fromEnv(&env).mode);
}

test "only the local environment backend runs; sandbox / remote are refused, not silently localized" {
    const alloc = std.testing.allocator;

    var cfg = config.Config.init(alloc);
    defer cfg.deinit();

    // The default backend builds an environment as usual…
    var local = try localEnvironment(alloc, std.testing.io, &cfg);
    local.deinit();

    // …and a backend this build cannot honour fails rather than running the
    // tools locally under a config that asked for isolation (DESIGN §8).
    cfg.environment.backend = .sandbox;
    try std.testing.expectError(error.UnsupportedEnvironmentBackend, localEnvironment(alloc, std.testing.io, &cfg));
    cfg.environment.backend = .remote;
    try std.testing.expectError(error.UnsupportedEnvironmentBackend, localEnvironment(alloc, std.testing.io, &cfg));
}
