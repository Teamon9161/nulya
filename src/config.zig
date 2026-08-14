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

pub const default_toml = config_options.default_toml;

pub const ProviderKind = enum {
    scripted,
    openai,
};

pub const PolicyHook = enum {
    off,
    auto,
    ai_reviewer,
    human_approval,
};

pub const EnvironmentBackend = enum {
    local,
    remote,
    acp,
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

pub const ProviderProfile = struct {
    name: []const u8,
    kind: ProviderKind = .openai,
    model: []const u8 = "",
    base_url: []const u8 = "",
    api_key_env: []const u8 = "",
    api_key: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};

pub const Provider = struct {
    active_profile: []const u8 = "",
    profiles: []ProviderProfile = &.{},

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

pub const RegistryWeights = struct {
    uses_recent: f64 = 1.0,
    uses_total: f64 = 0.25,
    last_used: f64 = 0.5,
    success_rate: f64 = 1.0,
};

pub const Registry = struct {
    max_tools: u32 = 8,
    pinned_native_tools: []const []const u8 = &.{},
    weights: RegistryWeights = .{},
};

pub const Policy = struct {
    hook: PolicyHook = .auto,
};

pub const Environment = struct {
    backend: EnvironmentBackend = .local,
    shell: ShellDialect = .auto,
};

pub const Compaction = struct {
    max_input_tokens: u32 = 80_000,
    target_input_tokens: u32 = 40_000,
};

pub const Extensions = struct {
    paths: []const []const u8 = &.{},
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    provider: Provider = .{},
    registry: Registry = .{},
    policy: Policy = .{},
    environment: Environment = .{},
    compaction: Compaction = .{},
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
};

const RawConfig = struct {
    provider: ?RawProvider = null,
    registry: ?RawRegistry = null,
    policy: ?RawPolicy = null,
    environment: ?RawEnvironment = null,
    compaction: ?RawCompaction = null,
    extensions: ?RawExtensions = null,
};

const RawProvider = struct {
    active_profile: ?[]const u8 = null,
    profiles: ?[]const RawProviderProfile = null,
};

const RawProviderProfile = struct {
    name: ?[]const u8 = null,
    kind: ?ProviderKind = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};

const RawRegistry = struct {
    max_tools: ?u32 = null,
    pinned_native_tools: ?[]const []const u8 = null,
    weights: ?RawRegistryWeights = null,
};

const RawRegistryWeights = struct {
    uses_recent: ?f64 = null,
    uses_total: ?f64 = null,
    last_used: ?f64 = null,
    success_rate: ?f64 = null,
};

const RawPolicy = struct {
    hook: ?PolicyHook = null,
};

const RawEnvironment = struct {
    backend: ?EnvironmentBackend = null,
    shell: ?ShellDialect = null,
};

const RawCompaction = struct {
    max_input_tokens: ?u32 = null,
    target_input_tokens: ?u32 = null,
};

const RawExtensions = struct {
    paths: ?[]const []const u8 = null,
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
    if (try readFileMaybe(alloc, io, ".nulya/config.toml")) |source| {
        defer alloc.free(source);
        try mergeToml(&cfg, source, .project);
    }

    return cfg;
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

    if (raw.provider) |provider| {
        if (provider.active_profile) |name| cfg.provider.active_profile = try arena.dupe(u8, name);
        if (provider.profiles) |profiles| for (profiles) |profile| try upsertProfile(cfg, profile);
    }

    if (raw.registry) |registry| {
        if (registry.max_tools) |max_tools| cfg.registry.max_tools = max_tools;
        if (registry.pinned_native_tools) |tools| cfg.registry.pinned_native_tools = try dupeStringList(arena, tools);
        if (registry.weights) |weights| mergeWeights(&cfg.registry.weights, weights);
    }

    if (raw.policy) |policy| {
        if (policy.hook) |hook| cfg.policy.hook = hook;
    }

    if (raw.environment) |env| {
        if (env.backend) |backend| cfg.environment.backend = backend;
        if (env.shell) |shell| cfg.environment.shell = shell;
    }

    if (raw.compaction) |compaction| {
        if (compaction.max_input_tokens) |tokens| cfg.compaction.max_input_tokens = tokens;
        if (compaction.target_input_tokens) |tokens| cfg.compaction.target_input_tokens = tokens;
    }

    if (raw.extensions) |extensions| {
        if (extensions.paths) |paths| cfg.extensions.paths = try dupeStringList(arena, paths);
    }
}

fn mergeProject(cfg: *Config, raw: RawConfig) !void {
    const arena = cfg.arenaAlloc();

    if (raw.provider) |provider_cfg| {
        // Project config may select a trusted profile, but it may not define or
        // mutate profiles: base_url/api_key_env in a checkout are a secret and
        // request-routing boundary.
        if (provider_cfg.active_profile) |name| {
            if (cfg.provider.findProfile(name) != null) cfg.provider.active_profile = try arena.dupe(u8, name);
        }
    }

    if (raw.registry) |registry| {
        if (registry.max_tools) |max_tools| cfg.registry.max_tools = @min(cfg.registry.max_tools, max_tools);
        if (registry.pinned_native_tools) |tools| cfg.registry.pinned_native_tools = try dupeStringList(arena, tools);
    }

    if (raw.policy) |policy| {
        if (policy.hook) |hook| {
            if (policyStrictness(hook) >= policyStrictness(cfg.policy.hook)) cfg.policy.hook = hook;
        }
    }

    if (raw.environment) |env| {
        if (env.backend) |backend| {
            if (backendStrictness(backend) >= backendStrictness(cfg.environment.backend)) cfg.environment.backend = backend;
        }
    }

    if (raw.extensions) |extensions| {
        if (extensions.paths) |paths| cfg.extensions.paths = try dupeStringList(arena, paths);
    }
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
    if (raw.base_url) |base_url| profile.base_url = try arena.dupe(u8, base_url);
    if (raw.api_key_env) |api_key_env| profile.api_key_env = try arena.dupe(u8, api_key_env);
    if (raw.api_key) |api_key| profile.api_key = try arena.dupe(u8, api_key);
    if (raw.effort) |effort| profile.effort = try arena.dupe(u8, effort);
}

fn mergeWeights(weights: *RegistryWeights, raw: RawRegistryWeights) void {
    if (raw.uses_recent) |value| weights.uses_recent = value;
    if (raw.uses_total) |value| weights.uses_total = value;
    if (raw.last_used) |value| weights.last_used = value;
    if (raw.success_rate) |value| weights.success_rate = value;
}

fn dupeStringList(arena: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, values.len);
    for (values, 0..) |value, i| out[i] = try arena.dupe(u8, value);
    return out;
}

fn policyStrictness(hook: PolicyHook) u8 {
    return switch (hook) {
        .off => 0,
        .auto => 1,
        .ai_reviewer => 2,
        .human_approval => 3,
    };
}

fn backendStrictness(backend: EnvironmentBackend) u8 {
    return switch (backend) {
        .local => 0,
        .remote => 1,
        .acp => 1,
        .sandbox => 2,
    };
}

const ConfigPaths = struct {
    system: []const u8,
    user: []const u8,

    fn init(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !ConfigPaths {
        if (builtin.os.tag == .windows) {
            const program_data = env.get("ProgramData") orelse "C:\\ProgramData";
            const app_data = env.get("APPDATA") orelse env.get("AppData") orelse "";
            return .{
                .system = try std.fs.path.join(alloc, &.{ program_data, "nulya", "config.toml" }),
                .user = if (app_data.len == 0) try alloc.dupe(u8, "") else try std.fs.path.join(alloc, &.{ app_data, "nulya", "config.toml" }),
            };
        }

        const home = env.get("HOME") orelse "";
        return .{
            .system = try alloc.dupe(u8, "/etc/nulya/config.toml"),
            .user = if (home.len == 0) try alloc.dupe(u8, "") else try std.fs.path.join(alloc, &.{ home, ".config", "nulya", "config.toml" }),
        };
    }

    fn deinit(self: ConfigPaths, alloc: std.mem.Allocator) void {
        alloc.free(self.system);
        alloc.free(self.user);
    }
};

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
    try std.testing.expectEqual(@as(u32, 8), cfg.registry.max_tools);
    try std.testing.expectEqual(PolicyHook.auto, cfg.policy.hook);
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

test "project layer may tighten but not loosen trusted policy or authority" {
    var cfg = try loadFromLayers(std.testing.allocator, &.{
        .{ .source = default_toml },
        .{ .source =
        \\[policy]
        \\hook = "human_approval"
        \\
        \\[environment]
        \\backend = "sandbox"
        },
        .{ .project = true, .source =
        \\[policy]
        \\hook = "off"
        \\
        \\[environment]
        \\backend = "local"
        \\
        \\[registry]
        \\max_tools = 4
        },
    });
    defer cfg.deinit();

    try std.testing.expectEqual(PolicyHook.human_approval, cfg.policy.hook);
    try std.testing.expectEqual(EnvironmentBackend.sandbox, cfg.environment.backend);
    try std.testing.expectEqual(@as(u32, 4), cfg.registry.max_tools);
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
