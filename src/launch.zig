//! Shared session-launch helpers for the `nulya session *` CLI and the bare
//! `nulya` demo.
//!
//! Both surfaces need the same three things: a deterministic scripted provider
//! (the offline stand-in when no API key is configured), a way to build a model
//! from a config profile, and the conventions for session file paths and ids —
//! so the demo runs the same durable-session path the CLI does.

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
const remote = @import("environment/remote/mod.zig");
const store = @import("extension/store.zig");
const ext_manifest = @import("extension/manifest.zig");
const trust = @import("journals/trust.zig");
const toml = @import("toml");
const build_options = @import("config_options");

/// This build's version string, straight from `build.zig.zon` `.version` (build.zig
/// passes it through). Stamped into every new session header as provenance
/// (`ledger.Stamp`); nothing branches on it.
pub const version: []const u8 = build_options.version;

pub const default_openai_model = "gpt-4o-mini";
pub const default_openai_base_url = "https://api.openai.com/v1";

pub const sessions_dir = ".nulya/sessions";
pub const scratch_dir = ".nulya/scratch";

/// Scratch owned by exactly ONE session: `.nulya/scratch/<session-id>`. Spill
/// filenames inside are deterministic (ledger seq + call index, `emit.zig`), so
/// the session id is the only thing keeping two concurrent sessions — a fork's
/// parent and child, a compact driver and its observer — from writing the same
/// file. Caller owns the result.
pub fn sessionScratchDir(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    // `/` on every OS (`emit.joinRel`): this prefix reaches the model in every
    // spill footer and task receipt, and the rest of it is already spelled so.
    return emit.joinRel(alloc, &.{ scratch_dir, id });
}

/// Where that session's background tasks live: `<scratch>/<id>/tasks`, one
/// directory per task. Beside the spills on purpose — a session's whole
/// byproduct is one subtree, so `rm -rf .nulya/scratch/<id>` clears it in one
/// move. Caller owns it.
pub fn sessionTasksDir(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    const scratch = try sessionScratchDir(alloc, id);
    defer alloc.free(scratch);
    return emit.joinRel(alloc, &.{ scratch, tasks_subdir });
}

pub const tasks_subdir = "tasks";

/// The offline stand-in for a real model (`NULYA_SCRIPTED_MODE`'s modes),
/// re-exported so callers keep saying `launch.ScriptedProvider` — its
/// implementation lives in `providers/scripted.zig`.
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

/// Resolve `profile_name` (+ an optional model id) into the model IDENTITY
/// frozen at session creation — the ONE model-resolution decision.
/// It is credential-aware, so what gets frozen is exactly what will run: a
/// profile whose credential is not resolvable falls back to the scripted
/// identity here, and `buildFromDescriptor` then builds scripted too — no fork
/// between "what ran" and "what the header says".
///
/// The header never holds a secret: it records the env var NAME (`api_key_env`)
/// and the profile name, and the credential itself is re-resolved on every
/// resume — so which place it comes from is not part of the identity. The codex
/// profile's credential is the Codex CLI's `auth.json`, which is why this needs
/// `io`.
///
/// `model_id` overrides the profile's default (`ProviderProfile.defaultModel`)
/// and is taken as given: a driver may name any id the endpoint serves. Slices
/// borrow the config profile; the caller freezes copies into the header before
/// config is dropped.
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
        // A scripted PROFILE freezes the id it was asked for: the stand-in
        // ignores it, but the shell's catalog lookups (`[[models]]`, e.g. the
        // `--image` gate) ask the frozen identity what model this is. The
        // keyless fallbacks below keep the BARE identity — there the id the
        // caller asked for is precisely what did not happen.
        .scripted => .{ .provider = "scripted", .model = chosen },
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
/// (its own `api_key`, the user's file) wins over `env` (`api_key_env`), which
/// wins over `file` (`credentials_file`) — so the key a person pasted into
/// nulya's own config is the one that runs even if a stale variable is still
/// exported, and an exported variable still beats the file for the length of
/// that shell. `scripted` needs nothing.
pub const CredentialSource = enum { none, config, env, file, login, builtin };

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
        else if (fileValue(alloc, io, env, profile.api_key_env)) |v| blk: {
            alloc.free(v);
            break :blk .file;
        } else .none,
        .codex => if (codex.Auth.available(alloc, io, env)) .login else .none,
    };
}

/// The user credential file: `<NULYA_HOME | ~/.nulya>/credentials.toml`.
///
/// A child process does not inherit secrets (`environment.isSecretKey` strips
/// them), so a background task — or an extension acting as a driver — cannot
/// resolve an `api_key_env` credential, and anything it creates would have had
/// no key. `codex` never had this problem: its credential is a FILE
/// (`~/.codex/auth.json`) and `HOME` is not a secret.
///
/// The keys are env var NAMES, so a durable credential still travels only
/// through `api_key_env` and this is a second place those names are answered
/// from. TOML because it is human-written settings, like `config.toml`, which it
/// sits beside and shares a parser with.
pub const credentials_file = "credentials.toml";

pub fn credentialFilePath(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    const home = try config.userHome(alloc, env);
    defer alloc.free(home);
    if (home.len == 0) return null;
    return try std.fs.path.join(alloc, &.{ home, credentials_file });
}

/// Said at most once per process, not once per profile lookup.
var warned_credentials_mode = false;

/// The value the credential file gives for `name`, or null. Caller frees.
///
/// Every failure is a null: no home, no file, unreadable, malformed, no such
/// key, empty value. A credential that cannot be read is a credential that is
/// not there, and the caller answers that with a refusal naming this path.
fn fileValue(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    name: []const u8,
) ?[]u8 {
    if (name.len == 0) return null;
    const path = (credentialFilePath(alloc, env) catch return null) orelse return null;
    defer alloc.free(path);

    // POSIX: a secret readable by everyone on the machine is worth a sentence,
    // but it is read anyway. Windows has no mode bits to judge, so it says
    // nothing.
    if (builtin.os.tag != .windows and !warned_credentials_mode) {
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
            if (@intFromEnum(st.permissions) & 0o077 != 0) {
                warned_credentials_mode = true;
                const msg = std.fmt.allocPrint(alloc, "warning: {s} is readable by other users; chmod 600 it\n", .{path}) catch return fileValueAt(alloc, io, path, name);
                defer alloc.free(msg);
                std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
            }
        } else |_| {}
    }
    return fileValueAt(alloc, io, path, name);
}

fn fileValueAt(alloc: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8) ?[]u8 {
    // `toml.Table` as the parse target is the vendored parser's own escape hatch
    // from struct mapping: this file has no fixed field names — its keys ARE the
    // `api_key_env` names a person's profiles happen to declare.
    var parser = toml.Parser(toml.Table).init(alloc);
    defer parser.deinit();
    var parsed = parser.parseFile(io, path) catch return null;
    defer parsed.deinit();
    const value = parsed.value.get(name) orelse return null;
    return switch (value) {
        .string => |s| if (s.len == 0) null else alloc.dupe(u8, s) catch null,
        else => null,
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
/// with `MissingCredential` rather than silently degrading to scripted. An empty
/// or scripted descriptor builds the scripted provider, needing no credential.
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
    // The file is the LAST place looked (`credentialSource` defines the order).
    // Owned, so it is freed the moment the provider has copied it — a secret
    // does not outlive the call that needed it.
    var from_file: ?[]u8 = null;
    defer if (from_file) |v| alloc.free(v);
    if (inline_key == null and envValue(env, desc.api_key_env) == null) {
        from_file = fileValue(alloc, io, env, desc.api_key_env);
    }
    if (std.mem.eql(u8, desc.provider, "openai")) {
        const api_key = inline_key orelse envValue(env, desc.api_key_env) orelse from_file orelse return error.MissingCredential;
        return .{ .openai = try openai.OpenAiProvider.init(alloc, io, .{
            .api_key = api_key,
            .model = nonEmpty(desc.model, default_openai_model),
            .base_url = nonEmpty(desc.base_url, default_openai_base_url),
        }) };
    }
    if (std.mem.eql(u8, desc.provider, "anthropic")) {
        const api_key = inline_key orelse envValue(env, desc.api_key_env) orelse from_file orelse return error.MissingCredential;
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
/// `local` exists: `sandbox` parses but has no implementation, so it is refused
/// HERE — at the one place a session's environment is built — rather than
/// silently running locally under a config that asked for isolation.
///
/// `session` names the durable session background tasks belong to, and is what
/// makes `startShellTask` possible at all: null (a `session new`, the demo, a
/// test) means a `shell {background:true}` has nowhere to report to and says so.
/// Both halves are computed HERE rather than derived down in the environment:
/// where a workspace keeps its sidecars is the shell layer's decision.
///
/// `ext_roots` is where THIS machine keeps extension versions (`extensionRoots`).
/// The environment needs them because resolving `(id, version)` into something
/// to spawn belongs to the machine that holds the bytes; a caller that runs no
/// extension may pass none.
pub fn localEnvironment(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    session: ?environment.SessionRef,
    ext_roots: []const []const u8,
) !environment.LocalEnvironment {
    if (cfg.environment.backend != .local) return error.UnsupportedEnvironmentBackend;
    return environment.LocalEnvironment.init(alloc, io, .{
        .dialect = cfg.environment.shell.toLocalOption(),
        .session = session,
        .extension_roots = ext_roots,
    });
}

/// The remote vocabulary, re-exported so a CLI refusal can quote it without
/// every verb file importing the backend.
pub const remote_spec_syntax = remote.spec_syntax;

/// Whether an `--env` spec names the REMOTE backend (the workspace lives over
/// there) rather than plain `local`. One predicate, so the call sites that must
/// branch cannot each invent their own test.
pub fn isRemoteSpec(exec: []const u8) bool {
    return remote.isSpec(environment.normalizeExecSpec(exec));
}

/// The sentences the two retired exec-target spellings get: `ssh:<destination>`
/// and `wsl[:<distro>]` moved only the `shell` command while the workspace,
/// extensions and every spilled file stayed on this host — neither exists any
/// more. A resume that finds one frozen into an old header gets these same
/// words appended to its own refusal, NOT a silent re-interpretation as the
/// `remote:` spelling — that one moves the whole workspace too (hence
/// `--workspace`), so which one an old session meant cannot be guessed.
pub const legacy_ssh_hint =
    "ssh as an exec target was retired; use --env remote:ssh:<destination> instead " ++
    "to move the whole workspace there (see --workspace)";
pub const legacy_wsl_hint =
    "wsl as an exec target was retired; use --env remote:wsl[:<distro>] instead " ++
    "to move the whole workspace there (see --workspace)";

/// Null unless `spec` (already `normalizeExecSpec`d) is the retired
/// `ssh:<destination>` exec-target spelling. `remote:ssh:` does not match —
/// every caller checks that first.
pub fn legacySshHint(spec: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, spec, "ssh:")) return null;
    return legacy_ssh_hint;
}

/// Null unless `spec` (already `normalizeExecSpec`d) is the retired `wsl` or
/// `wsl:<distro>` exec-target spelling. `remote:wsl…` does not match — every
/// caller checks that first.
pub fn legacyWslHint(spec: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, spec, "wsl") and !std.mem.startsWith(u8, spec, "wsl:")) return null;
    return legacy_wsl_hint;
}

/// Either retired hint, whichever (if either) `spec` matches.
pub fn legacyExecHint(spec: []const u8) ?[]const u8 {
    return legacySshHint(spec) orelse legacyWslHint(spec);
}

/// Say why an `--env` spec cannot be used, or null when it can — so a CLI verb
/// can refuse BEFORE it creates anything. The answers are kept apart: the wrong
/// machine, a retired spelling, and anything else unrecognized are different
/// fixes.
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

/// The execution environment a session runs its tools behind: the local backend
/// or the remote channel. A union rather than two call paths so every verb keeps
/// one shape — build it, hand out the handle, deinit.
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
    ///
    ///   - `NULYA_SESSION` is the session FILE's path, published LOCALLY ONLY:
    ///     it names a file on this machine, so handing it to a process on
    ///     another one would be a lie a package could act on (a capability note
    ///     deposited into nothing, a handoff written where no driver looks).
    ///   - `NULYA_SESSION_ID` is the session's identity, true wherever the
    ///     process runs, so it travels. A package that only ever wanted the id
    ///     (a scratch key, a journal column) keeps working when the workspace
    ///     moved.
    pub fn publishSession(self: *SessionEnvironment, session_path: []const u8, session_id: []const u8) !void {
        switch (self.*) {
            .local => |*l| try l.publishSession(session_path, session_id),
            .remote => |*r| try r.publishSession(session_id),
        }
    }
};

/// Build the environment a session runs behind. `exec` decides which of the two
/// it is; everything else (config backend, the session ref for background tasks)
/// applies to the local one.
///
/// A remote spec CONNECTS here — the transport is spawned and the handshake
/// completes — because there is no honest way to hand back a handle to a machine
/// that has not answered. A failure is therefore loud and at the top of the step.
///
/// Anything that is neither empty (local) nor a `remote:…` spec is
/// `error.InvalidExecTarget` — a retired exec-target spelling (frozen into a
/// header from before it retired) or plain garbage both refuse here rather
/// than falling back to running the command on this host.
pub fn sessionEnvironment(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    session: ?environment.SessionRef,
    exec: []const u8,
    workspace: []const u8,
    ext_roots: []const []const u8,
    ssh_password: ?[]const u8,
) !SessionEnvironment {
    const spec = environment.normalizeExecSpec(exec);
    if (remote.isSpec(spec)) {
        if (cfg.environment.backend != .local) return error.UnsupportedEnvironmentBackend;
        // No store roots: a remote environment resolves nothing here. Which
        // version means which file is the far agent's answer, given against ITS
        // roots.
        return .{
            .remote = try remote.RemoteEnvironment.connect(alloc, io, .{
                .spec = spec,
                .workspace = workspace,
                .version = version,
                // The same two halves the local one gets, and for the same reason:
                // a background task's NAME and its delivery belong to the machine
                // holding the ledger, whichever machine runs the command.
                .session = session,
                .ssh_password = ssh_password,
            }),
        };
    }
    if (spec.len != 0) return error.InvalidExecTarget;
    return .{ .local = try localEnvironment(alloc, io, cfg, session, ext_roots) };
}

/// The extension store roots this process searches, in order:
///
///   1. the workspace's `.nulya/extensions` (relative — resolved against cwd);
///   2. the user's `<NULYA_HOME | ~/.nulya>/extensions`, so a capability built
///      once is available in every workspace;
///   3. `extensions.paths` from the config — **trusted layers only**, since a
///      checkout must not be able to decide which directories on this machine
///      get to supply `current` versions (a project layer can only narrow).
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
    const home = (try userHomeDir(alloc, env)) orelse return null;
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{ home, "extensions" });
}

/// `<NULYA_HOME | ~/.nulya>` — the user layer: the user config, the user store,
/// the trust journal. Null when this machine has no home directory at all, which
/// is the one case where nothing user-level can be read or written. Caller owns it.
pub fn userHomeDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    const home = try config.userHome(alloc, env);
    if (home.len == 0) {
        alloc.free(home);
        return null;
    }
    return home;
}

/// Refuse to start a session composed against a workspace extension store that
/// arrived with a checkout and has never been trusted on this machine. Returns
/// `error.WorkspaceStoreUntrusted`; the CLI turns that into the message and the
/// exit code, so nothing in the kernel — not `SessionComposition`, not
/// `AgentSession` — knows trust exists.
///
/// The gate covers the WORKSPACE root only. The user store and `extensions.paths`
/// are trusted by construction (a checkout can reach neither), and the read-only
/// projections (`ext list`, `ext inspect`, `skill list`) are deliberately
/// ungated — they are the tools for deciding whether to trust.
pub fn ensureWorkspaceStoreTrusted(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    cwd: []const u8,
) !void {
    const path = (try occupiedWorkspaceStore(alloc, io, cwd)) orelse return;
    defer alloc.free(path);
    // No home at all means there is nowhere a trust could have been recorded —
    // and nowhere to record one. Refusing is the honest answer; `ext trust` is
    // where the missing home gets named.
    const home = (try userHomeDir(alloc, env)) orelse return error.WorkspaceStoreUntrusted;
    defer alloc.free(home);
    if (try trust.isTrusted(alloc, io, home, path)) return;
    return error.WorkspaceStoreUntrusted;
}

/// The workspace store's absolute real path when it HOLDS extensions, else null.
/// ONE predicate, so the gate, `ext trust` and `ext build`'s auto-trust cannot
/// disagree about whether a store is occupied.
///
/// "Holds" means an id with a `current` pointer or with at least one built
/// version: exactly the things a session can compose (`Roots.listActive`,
/// `--with`) or a CLI can execute (`ext run <id>@<version>`). A bare `<id>/`
/// directory with neither — a draft, or the empty shell a failed `ext build`
/// leaves behind around its `<id>/.lock` — holds nothing: it is inert source
/// until something local builds it, and that local build records trust.
/// Caller owns the result.
pub fn occupiedWorkspaceStore(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]u8 {
    var root = store.openRoot(io, cwd, store.workspace_root_rel) catch |err| switch (err) {
        // No workspace store at all: nothing to gate.
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer root.close(io);
    if (!try storeHoldsExtensions(alloc, io, root)) return null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return try alloc.dupe(u8, buf[0..try root.realPath(io, &buf)]);
}

fn storeHoldsExtensions(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !bool {
    const st = store.Store.init(io, root);
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!ext_manifest.isValidId(entry.name)) continue;
        if (try st.activeVersion(alloc, entry.name)) |active| {
            alloc.free(active);
            return true;
        }
        const versions = try st.listVersions(alloc, entry.name);
        defer {
            for (versions) |v| alloc.free(v);
            alloc.free(versions);
        }
        if (versions.len != 0) return true;
    }
    return false;
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

/// A time-ordered, collision-resistant session id: `s-<unix-ms>-<hex>`. The
/// suffix is real randomness from `io`, not a PRNG seeded by the clock: two
/// processes creating a session in the same millisecond would seed identically
/// and draw the same "random" suffix. Caller owns the result.
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

const fake_version = "v-0123456789abcdef01234567";

/// What a seeded store entry holds, in the terms the gate reads: a `draft` is a
/// bare `<id>/`, `built` adds a version DIRECTORY (all `listVersions` counts),
/// `active` adds the `current` pointer `activeVersion` reads. Real contents are
/// beside the point here — the predicate under test is what a store HOLDS, not
/// whether its bytes validate (that is `store.zig`'s).
const SeedKind = enum { draft, built, active };

fn seedStoreEntry(io: std.Io, ws: std.Io.Dir, id: []const u8, kind: SeedKind) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fmt.bufPrint(&buf, store.workspace_root_rel ++ "/{s}", .{id});
    try ws.createDirPath(io, base);
    if (kind == .draft) return;

    var vbuf: [std.fs.max_path_bytes]u8 = undefined;
    const vdir = try std.fmt.bufPrint(&vbuf, "{s}/versions/" ++ fake_version, .{base});
    try ws.createDirPath(io, vdir);
    if (kind == .built) return;

    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    const current = try std.fmt.bufPrint(&cbuf, "{s}/current", .{base});
    try ws.writeFile(io, .{ .sub_path = current, .data = fake_version ++ "\n" });
}

test "the workspace store gate: only a store that HOLDS something needs trust, and only the user layer can grant it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = try alloc.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    defer alloc.free(ws_path);

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    const home = try std.fs.path.join(alloc, &.{ ws_path, "home" });
    defer alloc.free(home);
    try env.put("NULYA_HOME", home);

    // No store at all: nothing to gate, and no path to key a trust on.
    try std.testing.expect((try occupiedWorkspaceStore(alloc, io, ws_path)) == null);
    try ensureWorkspaceStoreTrusted(alloc, io, &env, ws_path);

    // An empty store, and one holding only a draft or only the empty shell a
    // failed build leaves around its lease: still nothing a session can compose.
    try tmp.dir.createDirPath(io, store.workspace_root_rel);
    try seedStoreEntry(io, tmp.dir, "drafted", .draft);
    try tmp.dir.createDirPath(io, store.workspace_root_rel ++ "/shell/versions");
    try std.testing.expect((try occupiedWorkspaceStore(alloc, io, ws_path)) == null);
    try ensureWorkspaceStoreTrusted(alloc, io, &env, ws_path);

    // A BUILT version is enough: `--with <id>@<version>` and `ext run <id>@<v>`
    // reach it without any `current`.
    try seedStoreEntry(io, tmp.dir, "built", .built);
    const occupied = (try occupiedWorkspaceStore(alloc, io, ws_path)).?;
    defer alloc.free(occupied);
    // The trust key is the store's own absolute real path, not the workspace's.
    try std.testing.expect(std.fs.path.isAbsolute(occupied));
    try std.testing.expectEqualStrings("extensions", std.fs.path.basename(occupied));
    try std.testing.expectError(error.WorkspaceStoreUntrusted, ensureWorkspaceStoreTrusted(alloc, io, &env, ws_path));

    // An active version too, and trust is what lifts the refusal.
    try seedStoreEntry(io, tmp.dir, "active", .active);
    try std.testing.expectError(error.WorkspaceStoreUntrusted, ensureWorkspaceStoreTrusted(alloc, io, &env, ws_path));
    try trust.append(alloc, io, home, occupied);
    try ensureWorkspaceStoreTrusted(alloc, io, &env, ws_path);

    // Trust is recorded in the USER layer, so pointing `NULYA_HOME` elsewhere —
    // another identity, another test — does not inherit it, and a machine with no
    // home at all has nowhere a trust could have been recorded.
    var elsewhere: std.process.Environ.Map = .init(alloc);
    defer elsewhere.deinit();
    const other_home = try std.fs.path.join(alloc, &.{ ws_path, "other-home" });
    defer alloc.free(other_home);
    try elsewhere.put("NULYA_HOME", other_home);
    try std.testing.expectError(error.WorkspaceStoreUntrusted, ensureWorkspaceStoreTrusted(alloc, io, &elsewhere, ws_path));

    var homeless: std.process.Environ.Map = .init(alloc);
    defer homeless.deinit();
    try std.testing.expect((try userHomeDir(alloc, &homeless)) == null);
    try std.testing.expectError(error.WorkspaceStoreUntrusted, ensureWorkspaceStoreTrusted(alloc, io, &homeless, ws_path));
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

test "the user credential file answers api_key_env names, after the config key and the environment" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];

    var profiles = [_]config.ProviderProfile{
        .{ .name = "openai", .kind = .openai, .api_key_env = "OPENAI_API_KEY" },
        .{ .name = "inline", .kind = .openai, .api_key = "sk-inline", .api_key_env = "OPENAI_API_KEY" },
        .{ .name = "nameless", .kind = .openai, .api_key_env = "" },
    };
    const prov: config.Provider = .{ .active_profile = "openai", .profiles = &profiles };
    const openai_profile = prov.findProfile("openai").?;

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("NULYA_HOME", home);

    // No file yet: nothing to find, and nothing to fail about either.
    try std.testing.expectEqual(CredentialSource.none, credentialSource(alloc, io, openai_profile, &env));

    // This test is about the VALUE, not the permission warning: the mode a
    // freshly written temp file lands on is the umask's business.
    warned_credentials_mode = true;
    try tmp.dir.writeFile(io, .{
        .sub_path = credentials_file,
        .data = "# nulya credentials\nOPENAI_API_KEY = \"sk-from-file\"\nEMPTY = \"\"\n",
    });

    // Found by the NAME the profile already declares — no second naming scheme,
    // and the profile's own config is untouched.
    try std.testing.expectEqual(CredentialSource.file, credentialSource(alloc, io, openai_profile, &env));
    try std.testing.expect(credentialAvailable(alloc, io, openai_profile, &env));
    // …and that is enough to freeze a real identity rather than degrade.
    try std.testing.expectEqualStrings("openai", resolveDescriptor(alloc, io, prov, &env, "openai", null).provider);

    // Precedence, both directions: the environment beats the file for the length
    // of that shell, and the config's own key beats both.
    try env.put("OPENAI_API_KEY", "sk-from-env");
    try std.testing.expectEqual(CredentialSource.env, credentialSource(alloc, io, openai_profile, &env));
    try std.testing.expectEqual(CredentialSource.config, credentialSource(alloc, io, prov.findProfile("inline").?, &env));

    // The value itself, and the shapes that are not one.
    const key = fileValue(alloc, io, &env, "OPENAI_API_KEY").?;
    defer alloc.free(key);
    try std.testing.expectEqualStrings("sk-from-file", key);
    // An empty value is not a credential, an absent key is not a credential, and
    // a profile that names no variable cannot be answered by name at all.
    try std.testing.expect(fileValue(alloc, io, &env, "EMPTY") == null);
    try std.testing.expect(fileValue(alloc, io, &env, "NOT_THERE") == null);
    try std.testing.expect(fileValue(alloc, io, &env, "") == null);
    try std.testing.expectEqual(CredentialSource.none, credentialSource(alloc, io, prov.findProfile("nameless").?, &env));

    // A file this build cannot parse is a credential that is not there — never an
    // error about TOML syntax in front of somebody trying to start a session.
    try tmp.dir.writeFile(io, .{ .sub_path = credentials_file, .data = "OPENAI_API_KEY = \n[[[\n" });
    try env.put("OPENAI_API_KEY", "");
    try std.testing.expect(fileValue(alloc, io, &env, "OPENAI_API_KEY") == null);
    try std.testing.expectEqual(CredentialSource.none, credentialSource(alloc, io, openai_profile, &env));

    // No home at all: the file simply does not exist as a concept.
    var homeless: std.process.Environ.Map = .init(alloc);
    defer homeless.deinit();
    try std.testing.expect((try credentialFilePath(alloc, &homeless)) == null);
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

test "only the local environment backend runs; sandbox is refused, not silently localized" {
    const alloc = std.testing.allocator;

    var cfg = config.Config.init(alloc);
    defer cfg.deinit();

    // The default backend builds an environment as usual…
    var local = try localEnvironment(alloc, std.testing.io, &cfg, null, &.{});
    local.deinit();

    // …and a backend this build cannot honour fails rather than running the
    // tools locally under a config that asked for isolation.
    cfg.environment.backend = .sandbox;
    try std.testing.expectError(error.UnsupportedEnvironmentBackend, localEnvironment(alloc, std.testing.io, &cfg, null, &.{}));
}

test "an exec target is refused before anything is built, and the refusals differ" {
    try std.testing.expectEqual(@as(?[]const u8, null), execTargetRefusal(""));
    try std.testing.expectEqual(@as(?[]const u8, null), execTargetRefusal("local"));
    // The two retired exec-target spellings are refused with SPECIFIC sentences
    // naming their `remote:` replacement, distinct from the generic
    // "unrecognized" a typo gets (which also mentions `remote:` as part of the
    // whole vocabulary, so the three are told apart by identity, not substring).
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
    // Both reach the model (spill footers, task receipts), so both are spelled
    // with `/` whatever the OS — no native separator anywhere in them.
    try std.testing.expectEqualStrings(".nulya/scratch/s-1", scratch);
    try std.testing.expectEqualStrings(".nulya/scratch/s-1/tasks", tasks);
}
