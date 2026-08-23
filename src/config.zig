//! Layered Nulya configuration (DESIGN §9.5).
//!
//! The loader resolves `default -> system -> user -> project`, with the project
//! layer passed through the "can tighten, cannot loosen" trust boundary. Disk
//! config is parsed into an effective value at conversation start; it is not a
//! second mutable state store.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");
const config_options = @import("config_options");
const environment = @import("environment.zig");
const provider = @import("provider.zig");

pub const default_toml = config_options.default_toml;

pub const ProviderKind = enum {
    scripted,
    openai,
    anthropic,
    /// The ChatGPT-subscription Codex backend. Its credential is the Codex CLI's
    /// `auth.json`, not an env var, so `api_key_env` is unused for it.
    codex,
};

pub const EnvironmentBackend = enum {
    local,
    remote,
    sandbox,
};

pub const ShellDialect = enum {
    auto,
    bash,
    powershell,

    pub fn toLocalOption(self: ShellDialect) ?environment.Dialect {
        return switch (self) {
            .auto => null,
            .bash => .bash,
            .powershell => .powershell,
        };
    }
};

/// A profile says HOW to reach a provider (kind, endpoint, credential name) and
/// WHICH model ids it serves; the ids' intrinsic properties live in the
/// `[[models]]` catalog (`ModelParams`), so a model reached through two
/// endpoints is described once.
pub const ProviderProfile = struct {
    name: []const u8,
    kind: ProviderKind = .openai,
    /// The default model id for `session new --profile <name>` without `--model`.
    /// Empty means the first of `models`, else the provider's built-in default.
    model: []const u8 = "",
    /// Selectable model ids (a picker's list). Empty means just `model`.
    models: []const []const u8 = &.{},
    base_url: []const u8 = "",
    api_key_env: []const u8 = "",
    api_key: ?[]const u8 = null,
    /// Profile-wide effort override; `Config.defaultEffort` prefers it over the
    /// catalog's `default_effort`.
    effort: ?[]const u8 = null,

    /// The model id a session gets when none is named. `""` means "let the
    /// provider default" (`launch.resolveDescriptor` fills it in).
    pub fn defaultModel(self: ProviderProfile) []const u8 {
        if (self.model.len != 0) return self.model;
        return if (self.models.len != 0) self.models[0] else "";
    }
};

/// Intrinsic properties of one model id, independent of which profile serves
/// it: a display label, the reasoning-effort dial it accepts, and its context
/// window. Purely descriptive — the kernel never reads it; `launch`/`cli` use
/// it to default a session's effort, and `nulya config show` projects it for
/// pickers.
pub const ModelParams = struct {
    id: []const u8,
    label: []const u8 = "",
    /// Effort levels the model accepts, lowest → highest. Empty means the model
    /// has no dial (an absent effort is always legal and means the provider's
    /// default).
    efforts: []const []const u8 = &.{},
    /// Sent when neither the CLI nor the profile names an effort. Null means
    /// "send nothing" (provider default).
    default_effort: ?[]const u8 = null,
    context_window: ?u64 = null,
    /// Whether this model accepts images in a user turn. Explicit opt-in: an id
    /// with no catalog entry, or an entry that does not say so, does not accept
    /// them — `session append --image` refuses rather than guessing and letting
    /// the provider 400 mid-run (DESIGN §3.1, §14). Descriptive like every other
    /// field here; the kernel never reads it, the shell does.
    vision: bool = false,
};

pub const Provider = struct {
    active_profile: []const u8 = "",
    profiles: []ProviderProfile = &.{},
    /// How a transient model-request failure is retried (`provider.RetryPolicy`,
    /// DESIGN §13). One policy for every profile: it describes the wire, not a
    /// model. Trusted layers only.
    retry: provider.RetryPolicy = .{},

    pub fn activeProfile(self: Provider) ?ProviderProfile {
        for (self.profiles) |profile| {
            if (std.mem.eql(u8, profile.name, self.active_profile)) return profile;
        }
        return null;
    }

    pub fn findProfile(self: Provider, name: []const u8) ?ProviderProfile {
        for (self.profiles) |profile| {
            if (std.mem.eql(u8, profile.name, name)) return profile;
        }
        return null;
    }
};

/// The model-facing tool face: how many tools a session may expose at all, and
/// which extension tools take one of those slots. Both are decisions, never
/// derived — nothing in the kernel reads usage to fill a slot (DESIGN §5.1).
pub const Registry = struct {
    max_tools: u32 = 20,
    pinned_native_tools: []const []const u8 = &.{},
};

pub const Environment = struct {
    backend: EnvironmentBackend = .local,
    shell: ShellDialect = .auto,
};

pub const Extensions = struct {
    paths: []const []const u8 = &.{},
    /// Extension ids that are a MEMBER of every session opened in this
    /// workspace (DESIGN §5.1) — skills into the catalog, system prompts into
    /// the system blocks, tools reachable through the CLI. The standing half of
    /// the membership axis, exactly as `registry.pinned_native_tools` is the
    /// standing half of the tool-face axis; `session new --with` is the
    /// per-session half of this one, and the shell joins the two before the
    /// composition ever sees them.
    ///
    /// Each entry is a bare id, resolved at `current` when the session opens.
    /// No version here on purpose: pinning a version in config would make
    /// `ext activate` stop meaning anything for these packages, and rolling
    /// back would need a config edit instead of one verb.
    with: []const []const u8 = &.{},
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    provider: Provider = .{},
    /// The `[[models]]` catalog, merged by `id` across trusted layers.
    models: []ModelParams = &.{},
    registry: Registry = .{},
    environment: Environment = .{},
    extensions: Extensions = .{},

    pub fn init(alloc: std.mem.Allocator) Config {
        return .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn arenaAlloc(self: *Config) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn findModel(self: *const Config, id: []const u8) ?ModelParams {
        for (self.models) |m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }

    /// The effort a session runs with when its driver names none: the profile's
    /// override first, then the catalog default for the model id, else nothing
    /// (provider default). Both inputs are what a session header carries
    /// (`model` = profile name, `model_identity.model` = model id), so a step
    /// can re-derive this without the config being frozen.
    pub fn defaultEffort(self: *const Config, profile_name: []const u8, model_id: []const u8) ?[]const u8 {
        if (self.provider.findProfile(profile_name)) |p| {
            if (p.effort) |e| return e;
            // A codex profile stops here. The catalog describes an id as the
            // public API serves it, and the subscription serves several of the
            // same ids with a different dial and its own per-model default —
            // which the backend applies when nothing is sent. Sending the
            // catalog's default instead would silently overrule it; "auto" here
            // has to mean the subscription's auto (DESIGN §9.5).
            if (p.kind == .codex) return null;
        }
        if (self.findModel(model_id)) |m| return m.default_effort;
        return null;
    }
};

const RawConfig = struct {
    provider: ?RawProvider = null,
    models: ?[]const RawModelParams = null,
    registry: ?RawRegistry = null,
    environment: ?RawEnvironment = null,
    extensions: ?RawExtensions = null,
};

const RawProvider = struct {
    active_profile: ?[]const u8 = null,
    profiles: ?[]const RawProviderProfile = null,
    retry: ?RawRetry = null,
};

const RawRetry = struct {
    max_retries: ?u32 = null,
    initial_backoff_ms: ?u64 = null,
    max_backoff_ms: ?u64 = null,
    stall_timeout_ms: ?u64 = null,
};

const RawProviderProfile = struct {
    name: ?[]const u8 = null,
    kind: ?ProviderKind = null,
    model: ?[]const u8 = null,
    models: ?[]const []const u8 = null,
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};

const RawModelParams = struct {
    id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    efforts: ?[]const []const u8 = null,
    default_effort: ?[]const u8 = null,
    context_window: ?u64 = null,
    vision: ?bool = null,
};

const RawRegistry = struct {
    max_tools: ?u32 = null,
    pinned_native_tools: ?[]const []const u8 = null,
};

const RawEnvironment = struct {
    backend: ?EnvironmentBackend = null,
    shell: ?ShellDialect = null,
};

const RawExtensions = struct {
    paths: ?[]const []const u8 = null,
    with: ?[]const []const u8 = null,
};

pub fn load(alloc: std.mem.Allocator, io: std.Io, host_env: *const std.process.Environ.Map) !Config {
    var cfg = Config.init(alloc);
    errdefer cfg.deinit();

    try mergeToml(&cfg, default_toml, .trusted);

    var paths = try ConfigPaths.init(alloc, host_env);
    defer paths.deinit(alloc);

    if (try readFileMaybe(alloc, io, paths.system)) |source| {
        defer alloc.free(source);
        try mergeToml(&cfg, source, .trusted);
    }
    if (try readFileMaybe(alloc, io, paths.user)) |source| {
        defer alloc.free(source);
        try mergeToml(&cfg, source, .trusted);
    }
    if (try readFileMaybe(alloc, io, project_config_path)) |source| {
        defer alloc.free(source);
        try mergeToml(&cfg, source, .project);
    }

    return cfg;
}

test "user config lives at ~/.nulya/config.toml, NULYA_HOME relocates it" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("HOME", if (builtin.os.tag == .windows) "C:\\Users\\me" else "/home/me");
    try env.put("USERPROFILE", "C:\\Users\\me");

    var paths = try ConfigPaths.init(alloc, &env);
    const expect_user = if (builtin.os.tag == .windows) "C:\\Users\\me\\.nulya\\config.toml" else "/home/me/.nulya/config.toml";
    try std.testing.expectEqualStrings(expect_user, paths.user);
    paths.deinit(alloc);

    try env.put("NULYA_HOME", if (builtin.os.tag == .windows) "D:\\alt" else "/alt");
    paths = try ConfigPaths.init(alloc, &env);
    try std.testing.expectEqualStrings(if (builtin.os.tag == .windows) "D:\\alt\\config.toml" else "/alt/config.toml", paths.user);
    paths.deinit(alloc);
}

const LayerKind = enum { trusted, project };

fn mergeToml(cfg: *Config, source: []const u8, kind: LayerKind) !void {
    var parser = toml.Parser(RawConfig).init(cfg.arena.child_allocator);
    defer parser.deinit();

    const parsed = try parser.parseString(source);
    defer parsed.deinit();

    switch (kind) {
        .trusted => try mergeTrusted(cfg, parsed.value),
        .project => try mergeProject(cfg, parsed.value),
    }
}

fn mergeTrusted(cfg: *Config, raw: RawConfig) !void {
    const arena = cfg.arenaAlloc();

    if (raw.provider) |p| {
        if (p.active_profile) |name| cfg.provider.active_profile = try arena.dupe(u8, name);
        if (p.profiles) |profiles| for (profiles) |profile| try upsertProfile(cfg, profile);
        if (p.retry) |retry| {
            if (retry.max_retries) |n| cfg.provider.retry.max_retries = n;
            if (retry.initial_backoff_ms) |ms| cfg.provider.retry.initial_backoff_ms = ms;
            if (retry.max_backoff_ms) |ms| cfg.provider.retry.max_backoff_ms = ms;
            if (retry.stall_timeout_ms) |ms| cfg.provider.retry.stall_timeout_ms = ms;
        }
    }

    if (raw.models) |models| for (models) |model| try upsertModel(cfg, model);

    if (raw.registry) |registry| {
        if (registry.max_tools) |max_tools| cfg.registry.max_tools = max_tools;
        if (registry.pinned_native_tools) |tools| cfg.registry.pinned_native_tools = try dupeStringList(arena, tools);
    }

    if (raw.environment) |env| {
        if (env.backend) |backend| cfg.environment.backend = backend;
        if (env.shell) |shell| cfg.environment.shell = shell;
    }

    if (raw.extensions) |extensions| {
        if (extensions.paths) |paths| cfg.extensions.paths = try dupeStringList(arena, paths);
        if (extensions.with) |with| cfg.extensions.with = try dupeStringList(arena, with);
    }
}

fn mergeProject(cfg: *Config, raw: RawConfig) !void {
    const arena = cfg.arenaAlloc();

    if (raw.provider) |provider_cfg| {
        // Project config may select a trusted profile, but it may not define or
        // mutate profiles: base_url/api_key_env in a checkout are a secret and
        // request-routing boundary. The `[[models]]` catalog is likewise trusted
        // layers only — a checkout should not be able to change what a model id
        // means to the picker or which effort a session silently defaults to.
        if (provider_cfg.active_profile) |name| {
            if (cfg.provider.findProfile(name) != null) cfg.provider.active_profile = try arena.dupe(u8, name);
        }
    }

    if (raw.registry) |registry| {
        if (registry.max_tools) |max_tools| cfg.registry.max_tools = @min(cfg.registry.max_tools, max_tools);
        if (registry.pinned_native_tools) |tools| cfg.registry.pinned_native_tools = try dupeStringList(arena, tools);
    }

    if (raw.environment) |env| {
        if (env.backend) |backend| {
            if (backendStrictness(backend) >= backendStrictness(cfg.environment.backend)) cfg.environment.backend = backend;
        }
    }

    // `extensions.with` IS read here, for `pinned_native_tools`' reason: it can
    // only name a package this machine already holds and already trusts (the
    // §9 gate stands in front of it), so a checkout cannot use it to introduce
    // code — only to select among what is here. A project-level house-style
    // prompt is exactly the use, and it lasts as long as the checkout is open.
    if (raw.extensions) |extensions| {
        if (extensions.with) |with| cfg.extensions.with = try dupeStringList(arena, with);
    }

    // `extensions.paths` is deliberately NOT read here, and that is the
    // difference. A store root decides which DIRECTORIES on this machine get to
    // supply `current` versions — i.e. which code a session may run — so a
    // checkout adding one would widen authority, the exact thing the project
    // layer may never do (DESIGN §9.5). Trusted layers (system / user) still
    // set it.
}

fn upsertProfile(cfg: *Config, raw: RawProviderProfile) !void {
    const name = raw.name orelse return;
    const arena = cfg.arenaAlloc();

    for (cfg.provider.profiles, 0..) |*profile, i| {
        if (std.mem.eql(u8, profile.name, name)) {
            try mergeProfileFields(arena, &cfg.provider.profiles[i], raw);
            return;
        }
    }

    const next = try arena.alloc(ProviderProfile, cfg.provider.profiles.len + 1);
    @memcpy(next[0..cfg.provider.profiles.len], cfg.provider.profiles);
    next[cfg.provider.profiles.len] = .{ .name = try arena.dupe(u8, name) };
    try mergeProfileFields(arena, &next[cfg.provider.profiles.len], raw);
    cfg.provider.profiles = next;
}

fn mergeProfileFields(arena: std.mem.Allocator, profile: *ProviderProfile, raw: RawProviderProfile) !void {
    if (raw.kind) |kind| profile.kind = kind;
    if (raw.model) |model| profile.model = try arena.dupe(u8, model);
    if (raw.models) |models| profile.models = try dupeStringList(arena, models);
    if (raw.base_url) |base_url| profile.base_url = try arena.dupe(u8, base_url);
    if (raw.api_key_env) |api_key_env| profile.api_key_env = try arena.dupe(u8, api_key_env);
    if (raw.api_key) |api_key| profile.api_key = try arena.dupe(u8, api_key);
    if (raw.effort) |effort| profile.effort = try arena.dupe(u8, effort);
}

/// Merge a `[[models]]` entry by `id`: same id → fields overlay, new id → appended.
fn upsertModel(cfg: *Config, raw: RawModelParams) !void {
    const id = raw.id orelse return;
    const arena = cfg.arenaAlloc();

    for (cfg.models, 0..) |*model, i| {
        if (std.mem.eql(u8, model.id, id)) {
            try mergeModelFields(arena, &cfg.models[i], raw);
            return;
        }
    }

    const next = try arena.alloc(ModelParams, cfg.models.len + 1);
    @memcpy(next[0..cfg.models.len], cfg.models);
    next[cfg.models.len] = .{ .id = try arena.dupe(u8, id) };
    try mergeModelFields(arena, &next[cfg.models.len], raw);
    cfg.models = next;
}

fn mergeModelFields(arena: std.mem.Allocator, model: *ModelParams, raw: RawModelParams) !void {
    if (raw.label) |label| model.label = try arena.dupe(u8, label);
    if (raw.efforts) |efforts| model.efforts = try dupeStringList(arena, efforts);
    if (raw.default_effort) |effort| model.default_effort = try arena.dupe(u8, effort);
    if (raw.context_window) |window| model.context_window = window;
    if (raw.vision) |vision| model.vision = vision;
}

fn dupeStringList(arena: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, values.len);
    for (values, 0..) |value, i| out[i] = try arena.dupe(u8, value);
    return out;
}

fn backendStrictness(backend: EnvironmentBackend) u8 {
    return switch (backend) {
        .local => 0,
        .remote => 1,
        .sandbox => 2,
    };
}

/// The project-layer file, relative to the workspace.
pub const project_config_path = ".nulya/config.toml";

/// Where the config chain reads from. The user layer is `~/.nulya/config.toml`
/// on every platform (`%USERPROFILE%\.nulya\config.toml` on Windows) — one
/// findable place, the same shape as the workspace's own `.nulya/` — and
/// `NULYA_HOME` relocates that directory wholesale (tests, or a second identity).
/// The system layer stays where administrators expect it.
pub const ConfigPaths = struct {
    system: []const u8,
    user: []const u8,

    pub fn init(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !ConfigPaths {
        const system = if (builtin.os.tag == .windows)
            try std.fs.path.join(alloc, &.{ env.get("ProgramData") orelse "C:\\ProgramData", "nulya", "config.toml" })
        else
            try alloc.dupe(u8, "/etc/nulya/config.toml");
        errdefer alloc.free(system);
        const home = try userHome(alloc, env);
        defer alloc.free(home);
        return .{
            .system = system,
            .user = if (home.len == 0) try alloc.dupe(u8, "") else try std.fs.path.join(alloc, &.{ home, "config.toml" }),
        };
    }

    pub fn deinit(self: ConfigPaths, alloc: std.mem.Allocator) void {
        alloc.free(self.system);
        alloc.free(self.user);
    }
};

/// `$NULYA_HOME`, else `~/.nulya`. Empty when no home can be found at all.
/// Caller owns the result.
pub fn userHome(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("NULYA_HOME")) |h| {
        if (h.len != 0) return alloc.dupe(u8, h);
    }
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse "";
    if (home.len == 0) return alloc.dupe(u8, "");
    return std.fs.path.join(alloc, &.{ home, ".nulya" });
}

fn readFileMaybe(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    if (path.len == 0) return null;

    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
    defer file.close(io);

    const size = (try file.stat(io)).size;
    const content = try alloc.alloc(u8, size);
    errdefer alloc.free(content);
    if (size == 0) return content;

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(content);
    var reader = file.reader(io, &buf);
    _ = try writer.sendFileAll(&reader, .limited(size));
    try writer.flush();
    return content;
}

const TestLayer = struct {
    source: []const u8,
    project: bool = false,
};

fn loadFromLayers(alloc: std.mem.Allocator, layers: []const TestLayer) !Config {
    var cfg = Config.init(alloc);
    errdefer cfg.deinit();
    for (layers) |layer| try mergeToml(&cfg, layer.source, if (layer.project) .project else .trusted);
    return cfg;
}

test "default config parses into a usable provider profile" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{.{ .source = default_toml }});
    defer cfg.deinit();

    try std.testing.expectEqualStrings("openai", cfg.provider.active_profile);
    const profile = cfg.provider.activeProfile().?;
    try std.testing.expectEqual(ProviderKind.openai, profile.kind);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", profile.api_key_env);
    try std.testing.expectEqual(@as(u32, 20), cfg.registry.max_tools);
}

test "default catalog: every model a built-in profile lists is described, and effort defaults resolve" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{.{ .source = default_toml }});
    defer cfg.deinit();

    // A profile's selectable ids all have a catalog entry (a picker never shows
    // a bare id it cannot describe), and the default is one of them.
    for (cfg.provider.profiles) |p| {
        if (p.kind == .scripted) continue;
        try std.testing.expect(p.defaultModel().len != 0);
        var default_listed = p.models.len == 0;
        for (p.models) |id| {
            try std.testing.expect(cfg.findModel(id) != null);
            if (std.mem.eql(u8, id, p.defaultModel())) default_listed = true;
        }
        try std.testing.expect(default_listed);
    }

    // DeepSeek thinks by default server-side; the catalog leaves the dial on
    // "auto" (send nothing) but lists the levels the endpoint accepts.
    const flash = cfg.findModel("deepseek-v4-flash").?;
    try std.testing.expect(flash.efforts.len != 0);
    try std.testing.expectEqualStrings("off", flash.efforts[0]);
    try std.testing.expect(cfg.defaultEffort("deepseek", "deepseek-v4-flash") == null);
}

test "[[models]] merge by id and a profile effort overrides the catalog default" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source = default_toml },
        .{ .source =
        \\[[models]]
        \\id = "deepseek-v4-flash"
        \\default_effort = "high"
        \\
        \\[[models]]
        \\id = "my-local-model"
        \\label = "Local"
        \\efforts = ["low", "high"]
        \\
        \\[[provider.profiles]]
        \\name = "deepseek-anthropic"
        \\effort = "low"
        \\
        \\[[provider.profiles]]
        \\name = "local"
        \\kind = "openai"
        \\base_url = "http://localhost:8080/v1"
        \\api_key_env = "LOCAL_KEY"
        \\models = ["my-local-model"]
        },
    });
    defer cfg.deinit();

    // Overlay kept the built-in label and added the default effort.
    const flash = cfg.findModel("deepseek-v4-flash").?;
    try std.testing.expect(flash.label.len != 0);
    try std.testing.expectEqualStrings("high", flash.default_effort.?);
    // Catalog default applies through the profile that lacks its own effort…
    try std.testing.expectEqualStrings("high", cfg.defaultEffort("deepseek", "deepseek-v4-flash").?);
    // …and a profile-level effort wins over it.
    try std.testing.expectEqualStrings("low", cfg.defaultEffort("deepseek-anthropic", "deepseek-v4-flash").?);

    // A new profile with only `models` gets its default from the list.
    const local = cfg.provider.findProfile("local").?;
    try std.testing.expectEqualStrings("my-local-model", local.defaultModel());
    try std.testing.expectEqualStrings("Local", cfg.findModel("my-local-model").?.label);
    // Unknown ids resolve to "no effort" rather than an error.
    try std.testing.expect(cfg.defaultEffort("local", "something-else") == null);
}

test "a codex profile defaults its effort to the subscription's, never the catalog's" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source = default_toml },
        .{ .source =
        \\[[provider.profiles]]
        \\name = "codex-high"
        \\kind = "codex"
        \\model = "gpt-5.6-sol"
        \\effort = "high"
        },
    });
    defer cfg.deinit();

    // `gpt-5.6-sol` is in the catalog with default_effort = "medium" because
    // that is what OpenAI's own API does with it. The subscription serves the
    // same id with its own default, so nothing is sent and the backend decides.
    try std.testing.expectEqualStrings("medium", cfg.findModel("gpt-5.6-sol").?.default_effort.?);
    try std.testing.expectEqualStrings("medium", cfg.defaultEffort("openai", "gpt-5.6-sol").?);
    try std.testing.expect(cfg.defaultEffort("codex", "gpt-5.6-sol") == null);
    // An explicit profile effort is a decision, and still wins.
    try std.testing.expectEqualStrings("high", cfg.defaultEffort("codex-high", "gpt-5.6-sol").?);
}

test "project layer cannot touch the model catalog" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source = default_toml },
        .{ .project = true, .source =
        \\[[models]]
        \\id = "deepseek-v4-flash"
        \\default_effort = "max"
        \\
        \\[[models]]
        \\id = "injected"
        },
    });
    defer cfg.deinit();
    try std.testing.expect(cfg.findModel("deepseek-v4-flash").?.default_effort == null);
    try std.testing.expect(cfg.findModel("injected") == null);
}

test "trusted layers override scalars and merge profiles by name" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source = default_toml },
        .{ .source =
        \\[provider]
        \\active_profile = "openai"
        \\
        \\[[provider.profiles]]
        \\name = "openai"
        \\model = "gpt-4.1-mini"
        \\effort = "low"
        \\
        \\[registry]
        \\max_tools = 6
        },
    });
    defer cfg.deinit();

    const profile = cfg.provider.activeProfile().?;
    try std.testing.expectEqualStrings("gpt-4.1-mini", profile.model);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", profile.api_key_env);
    try std.testing.expectEqualStrings("low", profile.effort.?);
    try std.testing.expectEqual(@as(u32, 6), cfg.registry.max_tools);
}

test "project layer may tighten but not loosen trusted authority" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source = default_toml },
        .{ .source =
        \\[environment]
        \\backend = "sandbox"
        },
        .{ .project = true, .source =
        \\[environment]
        \\backend = "local"
        \\
        \\[registry]
        \\max_tools = 4
        },
    });
    defer cfg.deinit();

    // A checkout may narrow what runs (fewer tools) but never widen it back to a
    // looser execution backend than a trusted layer chose (DESIGN §9.5).
    try std.testing.expectEqual(EnvironmentBackend.sandbox, cfg.environment.backend);
    try std.testing.expectEqual(@as(u32, 4), cfg.registry.max_tools);
}

test "project layer cannot add an extension store root" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source =
        \\[extensions]
        \\paths = ["/opt/trusted/extensions"]
        },
        .{ .project = true, .source =
        \\[extensions]
        \\paths = ["/opt/trusted/extensions", "./vendored-extensions"]
        },
    });
    defer cfg.deinit();

    // A root is "which code may run on this machine": the trusted list stands,
    // and the checkout's addition is ignored rather than merged.
    try std.testing.expectEqual(@as(usize, 1), cfg.extensions.paths.len);
    try std.testing.expectEqualStrings("/opt/trusted/extensions", cfg.extensions.paths[0]);
}

test "project layer cannot inject provider secret routing" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source = default_toml },
        .{ .project = true, .source =
        \\[provider]
        \\active_profile = "evil"
        \\
        \\[[provider.profiles]]
        \\name = "evil"
        \\kind = "openai"
        \\base_url = "https://example.invalid/v1"
        \\api_key_env = "OPENAI_API_KEY"
        },
    });
    defer cfg.deinit();

    try std.testing.expectEqualStrings("openai", cfg.provider.active_profile);
    try std.testing.expect(cfg.provider.findProfile("evil") == null);
}
