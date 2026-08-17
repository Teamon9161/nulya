//! `nulya config show` (DESIGN §14): the read-only projection of the effective
//! provider profiles and model catalog a picker — or the agent, through `shell`
//! — reads before opening a session. It decides nothing and never prints a
//! secret: only the env var NAME and whether a credential is usable right now.

const std = @import("std");
const config = @import("../config.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");
const environment = @import("../environment.zig");
const printRaw = common.printRaw;
const printErr = common.printErr;
const sliceHasFlag = common.sliceHasFlag;

pub fn dispatchConfig(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return common.usageSection(io, common.config_usage);
    if (std.mem.eql(u8, args[0], "show")) return configShow(alloc, io, sliceHasFlag(args[1..], "--json"));
    try printErr(io, "unknown `config` subcommand; usage: nulya config show [--json]\n");
    return 1;
}

/// The projection a picker (or the agent, via shell) reads: the EFFECTIVE
/// provider profiles after the whole config chain, each with whether its
/// credential is usable right now, plus the model catalog. Never a secret —
/// only the env var NAME and a boolean. Shell-level, like `session new`: it
/// decides nothing, it shows what `session new` would see.
const ConfigView = struct {
    /// Where the chain reads from, so a front end writes to the same place it
    /// shows — never a second guess at "where is home".
    paths: Paths,
    active_profile: []const u8,
    profiles: []const ProfileView,
    models: []const config.ModelParams,
    /// The merged `[registry]` — the tool face this workspace opens a session
    /// with. Effective values only, not which layer contributed them: the
    /// question a reader has is "what are today's pins", and answering it here
    /// is what keeps them from reading the config files themselves, one of
    /// which may hold an inline `api_key`. Typed as `config.Registry`, so the
    /// two names printed are the two keys to write back.
    registry: config.Registry,

    const Paths = struct {
        system: []const u8,
        user: []const u8,
        project: []const u8,
    };

    const ProfileView = struct {
        name: []const u8,
        kind: []const u8,
        base_url: []const u8,
        api_key_env: []const u8,
        /// Whether `session new --profile <name>` would freeze this provider
        /// (true) or fall back to scripted (false).
        credential: bool,
        /// Where the credential comes from: `config` (the profile's own
        /// api_key), `env` (api_key_env is set), `login` (codex auth file),
        /// `builtin` (scripted), `none`.
        credential_source: []const u8,
        /// The default model id and the selectable list (never empty for a
        /// real provider: at least the default).
        model: []const u8,
        models: []const []const u8,
        effort: ?[]const u8,
    };
};

fn configShow(alloc: std.mem.Allocator, io: std.Io, as_json: bool) !u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();
    var paths = try config.ConfigPaths.init(alloc, &host);
    defer paths.deinit(alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const views = try a.alloc(ConfigView.ProfileView, cfg.provider.profiles.len);
    for (cfg.provider.profiles, 0..) |p, i| {
        const default_model = p.defaultModel();
        const models: []const []const u8 = if (p.models.len != 0)
            p.models
        else if (default_model.len != 0)
            try a.dupe([]const u8, &.{default_model})
        else
            &.{};
        const cred = launch.credentialSource(alloc, io, p, &host);
        views[i] = .{
            .name = p.name,
            .kind = @tagName(p.kind),
            .base_url = p.base_url,
            .api_key_env = p.api_key_env,
            .credential = cred != .none,
            .credential_source = @tagName(cred),
            .model = default_model,
            .models = models,
            .effort = p.effort,
        };
    }
    const view: ConfigView = .{
        .paths = .{ .system = paths.system, .user = paths.user, .project = config.project_config_path },
        .active_profile = cfg.provider.active_profile,
        .profiles = views,
        .models = cfg.models,
        .registry = cfg.registry,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (as_json) {
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.write(view);
        try out.writer.writeByte('\n');
    } else {
        try writeConfigText(&out.writer, view);
    }
    try printRaw(io, out.written());
    return 0;
}

fn writeConfigText(w: *std.Io.Writer, view: ConfigView) !void {
    try w.print("config files (later layers override; only the project one is untrusted):\n  system   {s}\n  user     {s}\n  project  {s}\n\n", .{ view.paths.system, view.paths.user, view.paths.project });
    try w.print("active profile: {s}\n\nprofiles:\n", .{view.active_profile});
    for (view.profiles) |p| {
        try w.print("  {s: <20} {s: <10} {s}", .{ p.name, p.kind, if (p.credential) "ready  " else "no key " });
        if (std.mem.eql(u8, p.credential_source, "config")) {
            try w.writeAll(" api_key in config");
        } else if (p.api_key_env.len != 0) {
            try w.print(" {s}", .{p.api_key_env});
        } else if (std.mem.eql(u8, p.kind, "codex")) {
            try w.writeAll(" ~/.codex/auth.json");
        }
        if (p.effort) |e| try w.print(" effort={s}", .{e});
        try w.print("\n      model: {s}", .{p.model});
        if (p.models.len > 1) {
            try w.writeAll("  [");
            for (p.models, 0..) |m, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeAll(m);
            }
            try w.writeAll("]");
        }
        if (p.base_url.len != 0) try w.print("\n      {s}", .{p.base_url});
        try w.writeByte('\n');
    }
    try w.writeAll("\nmodels:\n");
    for (view.models) |m| {
        try w.print("  {s: <22} {s: <18}", .{ m.id, m.label });
        if (m.context_window) |c| try w.print("  ctx {d: >7}", .{c});
        if (m.efforts.len != 0) {
            try w.writeAll("  effort ");
            for (m.efforts, 0..) |e, i| {
                if (i != 0) try w.writeByte('|');
                try w.writeAll(e);
            }
            try w.print(" (default {s})", .{m.default_effort orelse "auto"});
        }
        try w.writeByte('\n');
    }
    // The tool face, under the exact key names a reader writes back into a
    // config file. An empty pin list is printed as such rather than omitted:
    // "no extension tool is native here" is the answer, not a missing section.
    try w.print("\nregistry:\n  max_tools            {d}\n  pinned_native_tools  ", .{view.registry.max_tools});
    if (view.registry.pinned_native_tools.len == 0) {
        try w.writeAll("(none)");
    } else {
        for (view.registry.pinned_native_tools, 0..) |pin, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(pin);
        }
    }
    try w.writeByte('\n');
}

test "config show projects profiles with credential availability and the catalog, never a secret" {
    const alloc = std.testing.allocator;
    var cfg = config.Config.init(alloc);
    defer cfg.deinit();
    var profiles = [_]config.ProviderProfile{
        .{ .name = "ds", .kind = .openai, .base_url = "https://api.deepseek.com", .api_key_env = "DS_KEY_FOR_TEST", .model = "deepseek-v4-flash", .models = &.{ "deepseek-v4-flash", "deepseek-v4-pro" } },
        .{ .name = "inline", .kind = .openai, .api_key = "sk-secret-inline" },
        .{ .name = "scripted", .kind = .scripted, .model = "scripted-demo" },
    };
    cfg.provider = .{ .active_profile = "ds", .profiles = &profiles };
    var models = [_]config.ModelParams{
        .{ .id = "deepseek-v4-flash", .label = "DeepSeek V4 Flash", .efforts = &.{ "off", "low", "high", "max" }, .context_window = 1_000_000 },
    };
    cfg.models = &models;
    var pins = [_][]const u8{ "ext:date.now/print_date", "ext:notes/append" };
    cfg.registry = .{ .max_tools = 6, .pinned_native_tools = &pins };

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();

    // Build the view the way configShow does, against a controlled env.
    const views = try alloc.alloc(ConfigView.ProfileView, profiles.len);
    defer alloc.free(views);
    for (profiles, 0..) |p, i| {
        const cred = launch.credentialSource(alloc, std.testing.io, p, &env);
        views[i] = .{
            .name = p.name,
            .kind = @tagName(p.kind),
            .base_url = p.base_url,
            .api_key_env = p.api_key_env,
            .credential = cred != .none,
            .credential_source = @tagName(cred),
            .model = p.defaultModel(),
            .models = if (p.models.len != 0) p.models else &.{},
            .effort = p.effort,
        };
    }
    const view: ConfigView = .{
        .paths = .{ .system = "/etc/nulya/config.toml", .user = "/home/me/.nulya/config.toml", .project = config.project_config_path },
        .active_profile = "ds",
        .profiles = views,
        .models = &models,
        .registry = cfg.registry,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.write(view);
    const json = out.written();

    // Round-trips through std.json as the TUI will read it.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("ds", root.get("active_profile").?.string);
    const ps = root.get("profiles").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), ps.len);
    try std.testing.expectEqualStrings("ds", ps[0].object.get("name").?.string);
    try std.testing.expectEqual(false, ps[0].object.get("credential").?.bool);
    try std.testing.expectEqualStrings("none", ps[0].object.get("credential_source").?.string);
    try std.testing.expectEqualStrings("DS_KEY_FOR_TEST", ps[0].object.get("api_key_env").?.string);
    try std.testing.expectEqual(@as(usize, 2), ps[0].object.get("models").?.array.items.len);
    // Scripted is always runnable.
    try std.testing.expectEqual(true, ps[2].object.get("credential").?.bool);
    try std.testing.expectEqualStrings("builtin", ps[2].object.get("credential_source").?.string);
    // An inline key IS a credential (source `config`) — but the key itself never
    // appears; only the fact that the profile has one.
    try std.testing.expectEqual(true, ps[1].object.get("credential").?.bool);
    try std.testing.expectEqualStrings("config", ps[1].object.get("credential_source").?.string);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-secret-inline") == null);
    try std.testing.expect(ps[1].object.get("api_key") == null);
    // The paths ride along so a front end writes where the kernel reads.
    try std.testing.expectEqualStrings("/home/me/.nulya/config.toml", root.get("paths").?.object.get("user").?.string);
    // The catalog rides along, typed.
    const ms = root.get("models").?.array.items;
    try std.testing.expectEqualStrings("deepseek-v4-flash", ms[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 4), ms[0].object.get("efforts").?.array.items.len);
    try std.testing.expect(ms[0].object.get("default_effort").? == .null);

    // The tool face rides along too. Without it the only way to see today's
    // pins is to read the config files, and one of those layers may hold an
    // inline `api_key` — which is how this section came to be projected.
    const registry = root.get("registry").?.object;
    try std.testing.expectEqual(@as(i64, 6), registry.get("max_tools").?.integer);
    const projected_pins = registry.get("pinned_native_tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), projected_pins.len);
    try std.testing.expectEqualStrings("ext:date.now/print_date", projected_pins[0].string);

    // The plain-text form mentions each profile and the model line.
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try writeConfigText(&text.writer, view);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "ds ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "no key") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "effort off|low|high|max (default auto)") != null);
    // Under the same key names the config file uses, so reading is enough to write.
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "max_tools            6") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "pinned_native_tools  ext:date.now/print_date, ext:notes/append") != null);
}

test "config show prints an empty pin list as such, never as a missing section" {
    const alloc = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try writeConfigText(&text.writer, .{
        .paths = .{ .system = "s", .user = "u", .project = config.project_config_path },
        .active_profile = "scripted",
        .profiles = &.{},
        .models = &.{},
        .registry = .{},
    });
    // "no extension tool is native here" is an answer; a silent section is not.
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "pinned_native_tools  (none)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "max_tools            8") != null);
}
