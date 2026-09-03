//! Shared session-launch helpers for the `nulya session *` CLI and the bare
//! `nulya` demo: the scripted stand-in (used when no API key is configured),
//! model building from a config profile, and session path/id conventions.

const std = @import("std");
const builtin = @import("builtin");
const provider = @import("provider.zig");
const openai = @import("providers/openai.zig");
const anthropic = @import("providers/anthropic.zig");
const codex = @import("providers/codex.zig");
const config = @import("config.zig");
const ledger = @import("ledger.zig");
const emit = @import("emit.zig");
const environment = @import("environment.zig");
const ext_site = @import("extension/site.zig");
const remote = @import("environment/remote/mod.zig");
const build_options = @import("config_options");

/// This build's version string, from `build.zig.zon`. Stamped into every new
/// session header as provenance; nothing branches on it.
pub const version: []const u8 = build_options.version;

pub const default_openai_model = "gpt-4o-mini";
pub const default_openai_base_url = "https://api.openai.com/v1";

pub const sessions_dir = ".nulya/sessions";
pub const scratch_dir = ".nulya/scratch";

/// Scratch owned by exactly ONE session: `.nulya/scratch/<session-id>`. Spill
/// filenames inside are deterministic, so the session id is the only thing
/// keeping two concurrent sessions apart. Caller owns the result.
pub fn sessionScratchDir(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    // `/` on every OS: this prefix reaches the model in spill footers.
    return emit.joinRel(alloc, &.{ scratch_dir, id });
}

/// `<scratch>/<id>/tasks`, one directory per task. Caller owns it.
pub fn sessionTasksDir(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    const scratch = try sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    return emit.joinRel(alloc, &.{ scratch, tasks_subdir });
}

pub const tasks_subdir = "tasks";

/// The offline stand-in for a real model (`NULYA_SCRIPTED_MODE`'s modes).
pub const ScriptedProvider = @import("providers/scripted.zig").ScriptedProvider;

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

/// Resolve `profile_name` (+ an optional model id) into the model IDENTITY frozen
/// at session creation. Credential-aware, so what is frozen is what will run: a
/// profile whose credential is not resolvable freezes the scripted identity.
///
/// The header never holds a secret — only the env var NAME and the profile name;
/// the credential is re-resolved on every resume. The codex profile's credential
/// is the Codex CLI's `auth.json`, hence `io`.
///
/// Slices borrow the config profile; the caller freezes copies into the header
/// before config is dropped.
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
        // A scripted PROFILE freezes the id it was asked for: `[[models]]` lookups
        // ask the frozen identity. The keyless fallbacks keep the BARE identity.
        .scripted => .{ .provider = "scripted", .model = chosen },
        // Only a resolvable credential yields a durable API identity.
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
/// (its own `api_key`) wins over `env` (`api_key_env`), so a stale exported
/// variable cannot override the config. `scripted` needs nothing.
pub const CredentialSource = enum { none, config, env, login, builtin };

pub fn credentialSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    profile: config.ProviderProfile,
    env: *const std.process.Environ.Map,
) CredentialSource {
    return switch (profile.kind) {
        .scripted => .builtin,
        .openai, .anthropic => if (inlineKey(profile) != null)
            .config
        else if (envValue(env, profile.api_key_env) != null)
            .env
        else
            .none,
        .codex => if (codex.Auth.available(alloc, io, env)) .login else .none,
    };
}

/// Whether `profile` can run right now — the test `resolveDescriptor` applies.
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
    /// across every `session step` process. Empty means an unnamed scope.
    cache_key: []const u8 = "",
    /// The profile's own `api_key` from the user's config, when it has one.
    /// Wins over the env var. Never stored anywhere by this module.
    inline_key: ?[]const u8 = null,
};

/// Build the model from a frozen descriptor, at creation and on resume. It
/// re-resolves only the credential — `opts.inline_key`, else the environment, or
/// for codex the Codex CLI's auth file — and stores no secret. There is NO
/// scripted fallback: a frozen real provider whose credential is gone fails with
/// `MissingCredential`. An empty or scripted descriptor builds scripted.
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

/// The execution environment a session runs its tools behind, per config. Only
/// `local` exists: `sandbox` parses but has no implementation and is refused here
/// rather than silently running locally under a config that asked for isolation.
///
/// `session` names the durable session background tasks belong to; null means a
/// `shell {background:true}` has nowhere to report to. `ext_store` is THIS
/// machine's extension store; a caller that runs no extension may pass empty.
pub fn localEnvironment(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    session: ?environment.SessionRef,
    ext_store: []const u8,
    diag: ext_site.Diag,
) !environment.LocalEnvironment {
    if (cfg.environment.backend != .local) return error.UnsupportedEnvironmentBackend;
    return environment.LocalEnvironment.init(alloc, io, .{
        .dialect = cfg.environment.shell.toLocalOption(),
        .session = session,
        .extension_store = ext_store,
        .diag = diag,
    });
}

/// The remote vocabulary, re-exported so a CLI refusal can quote it.
pub const remote_spec_syntax = remote.spec_syntax;

/// Whether an `--env` spec names the REMOTE backend (the workspace lives over
/// there) rather than plain `local`.
pub fn isRemoteSpec(exec: []const u8) bool {
    return remote.isSpec(environment.normalizeExecSpec(exec));
}

/// The sentences the two retired exec-target spellings get. A header frozen with
/// one refuses rather than being re-read as the `remote:` spelling.
pub const legacy_ssh_hint =
    "ssh as an exec target was retired; use --env remote:ssh:<destination> instead " ++
    "to move the whole workspace there (see --workspace)";
pub const legacy_wsl_hint =
    "wsl as an exec target was retired; use --env remote:wsl[:<distro>] instead " ++
    "to move the whole workspace there (see --workspace)";

/// Null unless `spec` (already `normalizeExecSpec`d) is the retired
/// `ssh:<destination>` spelling. Callers must test `remote:ssh:` first.
pub fn legacySshHint(spec: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, spec, "ssh:")) return null;
    return legacy_ssh_hint;
}

/// Null unless `spec` (already `normalizeExecSpec`d) is the retired `wsl` or
/// `wsl:<distro>` spelling. Callers must test `remote:wsl…` first.
pub fn legacyWslHint(spec: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, spec, "wsl") and !std.mem.startsWith(u8, spec, "wsl:")) return null;
    return legacy_wsl_hint;
}

/// Either retired hint, whichever (if either) `spec` matches.
pub fn legacyExecHint(spec: []const u8) ?[]const u8 {
    return legacySshHint(spec) orelse legacyWslHint(spec);
}

/// Say why an `--env` spec cannot be used, or null when it can — so a CLI verb
/// can refuse BEFORE it creates anything.
pub fn execTargetRefusal(exec: []const u8) ?[]const u8 {
    const spec = environment.normalizeExecSpec(exec);
    if (spec.len == 0) return null;
    if (remote.isSpec(spec)) {
        const launch = remote.parseSpec(spec) catch
            return "unrecognized (want " ++ remote.spec_syntax ++ ")";
        if (!remote.supportedOnHost(launch)) return "cannot be reached from this host (wsl needs Windows)";
        return null;
    }
    if (legacyExecHint(spec)) |hint| return hint;
    return "unrecognized (want " ++ remote.spec_syntax ++ ")";
}

/// The local backend or the remote channel; one shape for every verb.
pub const SessionEnvironment = union(enum) {
    local: environment.LocalEnvironment,
    remote: remote.RemoteEnvironment,

    pub fn handle(self: *SessionEnvironment) environment.Environment {
        return switch (self.*) {
            .local => |*l| l.environment(),
            .remote => |*r| r.environment(),
        };
    }

    pub fn deinit(self: *SessionEnvironment) void {
        switch (self.*) {
            .local => |*l| l.deinit(),
            .remote => |*r| r.deinit(),
        }
    }

    /// Let this session's children name the session they are in, in two halves:
    /// `NULYA_SESSION` is the session FILE's path and is published LOCALLY ONLY
    /// (it names a file on this machine); `NULYA_SESSION_ID` is the identity,
    /// true wherever the process runs, so it travels.
    pub fn publishSession(self: *SessionEnvironment, session_path: []const u8, session_id: []const u8) !void {
        switch (self.*) {
            .local => |*l| try l.publishSession(session_path, session_id),
            .remote => |*r| try r.publishSession(session_id),
        }
    }
};

/// The shell layer's two answers about reaching another machine: where the
/// story of doing so is told, and how to produce an agent for a machine this
/// build's own bytes cannot serve. They travel together because a path that
/// has an opinion about one always has an opinion about the other, and because
/// the second one's whole job is to narrate a minute of waiting through the first.
pub const Reach = struct {
    diag: ext_site.Diag = .{},
    build_agent: ?remote.AgentBuilder = null,
    build_id: []const u8 = "",
};

/// Build the environment a session runs behind. `exec` decides which of the two
/// it is; everything else applies to the local one. A remote spec CONNECTS here —
/// transport spawned, handshake completed — so a failure is loud and at the top
/// of the step. Anything else is `error.InvalidExecTarget`, never a local fallback.
pub fn sessionEnvironment(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    session: ?environment.SessionRef,
    exec: []const u8,
    workspace: []const u8,
    ext_store: []const u8,
    ssh_password: ?[]const u8,
    reach: Reach,
) !SessionEnvironment {
    const spec = environment.normalizeExecSpec(exec);
    if (remote.isSpec(spec)) {
        if (cfg.environment.backend != .local) return error.UnsupportedEnvironmentBackend;
        // No store path: which version means which file is the far agent's
        // answer, given against ITS own store.
        return .{
            .remote = try remote.RemoteEnvironment.connect(alloc, io, .{
                .spec = spec,
                .workspace = workspace,
                .version = version,
                // A background task's name and delivery belong to the machine
                // holding the ledger, whichever machine runs the command.
                .session = session,
                .ssh_password = ssh_password,
                // A session that cannot reach its own machine is a session that
                // does not exist, so this is the one path that always makes the
                // reach work if it can.
                .install = .auto,
                .build_agent = reach.build_agent,
                .build_id = reach.build_id,
                .diag = reach.diag,
            }),
        };
    }
    if (spec.len != 0) return error.InvalidExecTarget;
    return .{ .local = try localEnvironment(alloc, io, cfg, session, ext_store, reach.diag) };
}

/// `<NULYA_HOME | ~/.nulya>/store` — the ONE place built extension versions live
/// on this machine. Empty when there is no home directory. Caller owns it.
pub fn storePath(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const home = (try userHomeDir(alloc, env)) orelse return alloc.dupe(u8, "");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, "store" });
}

/// `<NULYA_HOME | ~/.nulya>` — the user layer: the user config and the store.
/// Null when this machine has no home directory. Caller owns it.
pub fn userHomeDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    const home = try config.userHome(alloc, env);
    if (home.len == 0) {
        alloc.free(home);
        return null;
    }
    return home;
}

/// Release a caller-owned list of strings.
pub fn freeStringList(alloc: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| alloc.free(s);
    alloc.free(list);
}

/// Session file path relative to the workspace: `.nulya/sessions/<id>.jsonl`.
/// Caller owns the result.
pub fn sessionPath(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}.jsonl", .{ sessions_dir, id });
}

/// A time-ordered, collision-resistant session id: `s-<unix-ms>-<hex>`. The
/// suffix is real randomness from `io`, not a clock-seeded PRNG: same
/// millisecond would mean same "random" suffix. Caller owns the result.
pub fn genSessionId(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Timestamp.now(io, .real);
    var suffix: [3]u8 = undefined;
    io.random(&suffix);
    return std.fmt.allocPrint(alloc, "s-{d}-{x}", .{ now.toMilliseconds(), std.mem.readInt(u24, &suffix, .little) });
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

test "the store lives under the user home, and a machine without one has none" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    const home = if (@import("builtin").os.tag == .windows) "D:\\home\\.nulya" else "/home/me/.nulya";
    try env.put("NULYA_HOME", home);

    const path = try storePath(alloc, &env);
    defer alloc.free(path);
    try std.testing.expectEqualStrings(
        if (@import("builtin").os.tag == .windows) "D:\\home\\.nulya\\store" else "/home/me/.nulya/store",
        path,
    );

    var homeless: std.process.Environ.Map = .init(alloc);
    defer homeless.deinit();
    const none = try storePath(alloc, &homeless);
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expect((try userHomeDir(alloc, &homeless)) == null);
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

    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", null).provider);
    try std.testing.expect(!credentialAvailable(alloc, std.testing.io, prov.findProfile("openai").?, &env));

    try env.put("OPENAI_API_KEY", "sk-test");
    const d = resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", null);
    try std.testing.expectEqualStrings("openai", d.provider);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", d.api_key_env);
    try std.testing.expectEqualStrings(default_openai_model, d.model);
    try std.testing.expectEqualStrings(default_openai_base_url, d.base_url);
    try std.testing.expect(credentialAvailable(alloc, std.testing.io, prov.findProfile("openai").?, &env));

    const picked = resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", "gpt-x");
    try std.testing.expectEqualStrings("gpt-x", picked.model);
    try std.testing.expectEqualStrings(default_openai_model, resolveDescriptor(alloc, std.testing.io, prov, &env, "openai", "").model);

    // An inline api_key freezes openai with an EMPTY api_key_env: no secret in
    // the header; resume finds the key by profile name.
    const inline_id = resolveDescriptor(alloc, std.testing.io, prov, &env, "inline", null);
    try std.testing.expectEqualStrings("openai", inline_id.provider);
    try std.testing.expectEqualStrings("", inline_id.api_key_env);
    try std.testing.expectEqual(CredentialSource.config, credentialSource(alloc, std.testing.io, prov.findProfile("inline").?, &env));
    try std.testing.expectEqual(CredentialSource.env, credentialSource(alloc, std.testing.io, prov.findProfile("openai").?, &env));
    try std.testing.expectEqual(CredentialSource.builtin, credentialSource(alloc, std.testing.io, prov.findProfile("local").?, &env));

    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "local", null).provider);
    try std.testing.expect(credentialAvailable(alloc, std.testing.io, prov.findProfile("local").?, &env));
    try std.testing.expectEqualStrings("scripted", resolveDescriptor(alloc, std.testing.io, prov, &env, "nope", null).provider);
}

test "credentialSource: the profile's own api_key beats its env var even when both name the same one" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var profiles = [_]config.ProviderProfile{
        .{ .name = "openai", .kind = .openai, .api_key_env = "OPENAI_API_KEY" },
        .{ .name = "inline", .kind = .openai, .api_key = "sk-inline", .api_key_env = "OPENAI_API_KEY" },
    };
    const prov: config.Provider = .{ .active_profile = "openai", .profiles = &profiles };

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try std.testing.expectEqual(CredentialSource.none, credentialSource(alloc, io, prov.findProfile("openai").?, &env));

    try env.put("OPENAI_API_KEY", "sk-from-env");
    try std.testing.expectEqual(CredentialSource.env, credentialSource(alloc, io, prov.findProfile("openai").?, &env));
    try std.testing.expectEqual(CredentialSource.config, credentialSource(alloc, io, prov.findProfile("inline").?, &env));
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
    try std.testing.expectError(error.MissingCredential, buildFromDescriptor(alloc, std.testing.io, openai_id, &env, .{}));

    try env.put("OPENAI_API_KEY", "sk-test");
    var holder = try buildFromDescriptor(alloc, std.testing.io, openai_id, &env, .{});
    defer holder.deinit();
    try std.testing.expect(holder == .openai);

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

    const from_config: ledger.ModelDescriptor = .{ .provider = "openai", .model = "gpt-x", .base_url = "https://api.openai.com/v1" };
    try std.testing.expectError(error.MissingCredential, buildFromDescriptor(alloc, std.testing.io, from_config, &env, .{}));
    var holder = try buildFromDescriptor(alloc, std.testing.io, from_config, &env, .{ .inline_key = "sk-from-config" });
    defer holder.deinit();
    try std.testing.expectEqualStrings("sk-from-config", holder.openai.api_key);

    try env.put("OPENAI_API_KEY", "sk-from-env");
    const both: ledger.ModelDescriptor = .{ .provider = "openai", .model = "gpt-x", .base_url = "https://api.openai.com/v1", .api_key_env = "OPENAI_API_KEY" };
    var preferred = try buildFromDescriptor(alloc, std.testing.io, both, &env, .{ .inline_key = "sk-from-config" });
    defer preferred.deinit();
    try std.testing.expectEqualStrings("sk-from-config", preferred.openai.api_key);
    var fallback = try buildFromDescriptor(alloc, std.testing.io, both, &env, .{ .inline_key = "" });
    defer fallback.deinit();
    try std.testing.expectEqualStrings("sk-from-env", fallback.openai.api_key);
}

test "only the local environment backend runs; sandbox is refused, not silently localized" {
    const alloc = std.testing.allocator;

    var cfg = config.Config.init(alloc);
    defer cfg.deinit();

    var local = try localEnvironment(alloc, std.testing.io, &cfg, null, &.{}, .{});
    local.deinit();

    cfg.environment.backend = .sandbox;
    try std.testing.expectError(error.UnsupportedEnvironmentBackend, localEnvironment(alloc, std.testing.io, &cfg, null, &.{}, .{}));
}

test "an exec target is refused before anything is built, and the refusals differ" {
    try std.testing.expectEqual(@as(?[]const u8, null), execTargetRefusal(""));
    try std.testing.expectEqual(@as(?[]const u8, null), execTargetRefusal("local"));
    // Told apart by identity, not substring.
    try std.testing.expectEqualStrings(legacy_ssh_hint, execTargetRefusal("ssh:me@box").?);
    try std.testing.expectEqualStrings(legacy_wsl_hint, execTargetRefusal("wsl").?);
    try std.testing.expectEqualStrings(legacy_wsl_hint, execTargetRefusal("wsl:Ubuntu").?);
    const typo = execTargetRefusal("wsl2").?;
    try std.testing.expect(!std.mem.eql(u8, typo, legacy_ssh_hint));
    try std.testing.expect(!std.mem.eql(u8, typo, legacy_wsl_hint));
}

test "legacyExecHint only fires on the two retired exec-target prefixes" {
    try std.testing.expectEqualStrings(legacy_ssh_hint, legacyExecHint("ssh:me@box").?);
    try std.testing.expectEqualStrings(legacy_wsl_hint, legacyExecHint("wsl").?);
    try std.testing.expectEqualStrings(legacy_wsl_hint, legacyExecHint("wsl:Ubuntu").?);
    try std.testing.expectEqual(@as(?[]const u8, null), legacyExecHint("local"));
    try std.testing.expectEqual(@as(?[]const u8, null), legacyExecHint("remote:ssh:me@box"));
    try std.testing.expectEqual(@as(?[]const u8, null), legacyExecHint("remote:wsl:Ubuntu"));
}

test "a session's tasks live beside its spills, under one removable subtree" {
    const alloc = std.testing.allocator;
    const scratch = try sessionScratchDir(alloc, "s-1");
    defer alloc.free(scratch);
    const tasks = try sessionTasksDir(alloc, "s-1");
    defer alloc.free(tasks);
    try std.testing.expect(std.mem.startsWith(u8, tasks, scratch));
    try std.testing.expect(std.mem.endsWith(u8, tasks, tasks_subdir));
    // Both reach the model, so both are spelled with `/` whatever the OS.
    try std.testing.expectEqualStrings(".nulya/scratch/s-1", scratch);
    try std.testing.expectEqualStrings(".nulya/scratch/s-1/tasks", tasks);
}
