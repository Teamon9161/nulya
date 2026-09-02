//! `nulya config show`: the read-only projection of the effective provider
//! profiles and model catalog a picker — or the agent, through `shell` — reads
//! before opening a session. It decides nothing and never prints a secret: only
//! the env var NAME and whether a credential is usable right now.

const std = @import("std");
const codex = @import("../providers/codex.zig");
const config = @import("../config.zig");
const launch = @import("../launch.zig");
const common = @import("common.zig");
const environment = @import("../environment.zig");
const printRaw = common.printRaw;
const printErr = common.printErr;
const sliceHasFlag = common.sliceHasFlag;

pub fn dispatchConfig(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return common.usageSection(io, common.config_usage);
    // `show` never touches the network; `refresh` goes there first.
    if (std.mem.eql(u8, args[0], "show")) return configShow(alloc, io, .{
        .as_json = sliceHasFlag(args[1..], "--json"),
    });
    if (std.mem.eql(u8, args[0], "refresh")) return configShow(alloc, io, .{
        .as_json = sliceHasFlag(args[1..], "--json"),
        .refresh = true,
    });
    try printErr(io, "unknown `config` subcommand; usage: nulya config show [--json] | refresh [--json]\n");
    return 1;
}

const ShowOptions = struct {
    as_json: bool,
    /// Ask each usable codex profile's endpoint for its live model catalogue
    /// and write it to the Codex CLI's cache before projecting. Set only by
    /// `config refresh`, the one verb in this family that goes to the network.
    refresh: bool = false,
};

/// The projection a picker (or the agent, via shell) reads: the EFFECTIVE
/// provider profiles after the whole config chain, each with whether its
/// credential is usable right now, plus the model catalog. Never a secret —
/// only the env var NAME and a boolean. It shows what `session new` would see.
const ConfigView = struct {
    /// Where the chain reads from, so a front end writes to the same place it
    /// shows.
    paths: Paths,
    active_profile: []const u8,
    profiles: []const ProfileView,
    models: []const config.ModelParams,
    /// The merged `[registry]` — the tool face this workspace opens a session
    /// with. Effective values only, not which layer contributed them. Typed as
    /// `config.Registry`, so the two names printed are the two keys to write
    /// back.
    registry: config.Registry,
    /// The other standing axis: which packages are a member of every session
    /// opened here. Projected for the same reason as the pins: a reader who
    /// cannot see it here goes and reads the config files, one of which may
    /// hold an inline `api_key`.
    ///
    /// `extensions.paths` is deliberately not projected: it names directories
    /// this machine will run code from, and `nulya ext list` already shows a
    /// store root as such.
    extensions: ExtensionsView,

    const ExtensionsView = struct {
        with: []const []const u8,
    };

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
        /// What THIS profile's own endpoint says about the ids in `models`,
        /// parallel to it (`catalog[i]` describes `models[i]`). Null — every
        /// profile but codex — means "look the id up in the top-level `models`
        /// catalog".
        ///
        /// A ChatGPT subscription serves several of the same ids with a smaller
        /// window, an extra effort level and its own defaults, so only its own
        /// `codex.Catalog` describes what a session on it would get.
        catalog: ?[]const config.ModelParams = null,
    };
};

fn configShow(alloc: std.mem.Allocator, io: std.Io, opts: ShowOptions) !u8 {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();
    var paths = try config.ConfigPaths.init(alloc, &host);
    defer paths.deinit(alloc);

    // Before the projection, so what prints below is what was just fetched. A
    // failed refresh still projects whatever is on disk, but decides the exit
    // code.
    const refreshed = if (opts.refresh) try refreshCodexCatalogs(alloc, io, &cfg, &host) else true;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Each profile that has one owns its catalogue's storage; they outlive the
    // view they are projected into.
    var catalogs: std.ArrayList(codex.Catalog) = .empty;
    defer {
        for (catalogs.items) |*c| c.deinit();
        catalogs.deinit(alloc);
    }

    const views = try a.alloc(ConfigView.ProfileView, cfg.provider.profiles.len);
    for (cfg.provider.profiles, 0..) |p, i| {
        const default_model = p.defaultModel();
        var models: []const []const u8 = if (p.models.len != 0)
            p.models
        else if (default_model.len != 0)
            try a.dupe([]const u8, &.{default_model})
        else
            &.{};
        var catalog: ?[]const config.ModelParams = null;
        if (try endpointCatalog(alloc, io, &host, p)) |loaded| {
            try catalogs.append(alloc, loaded);
            const listed = try orderByDefault(a, catalogs.items[catalogs.items.len - 1].models, default_model);
            models = listed.ids;
            catalog = listed.params;
        }
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
            .catalog = catalog,
        };
    }
    const view: ConfigView = .{
        .paths = .{ .system = paths.system, .user = paths.user, .project = config.project_config_path },
        .active_profile = cfg.provider.active_profile,
        .profiles = views,
        .models = cfg.models,
        .registry = cfg.registry,
        .extensions = .{ .with = cfg.extensions.with },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (opts.as_json) {
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.write(view);
        try out.writer.writeByte('\n');
    } else {
        try writeConfigText(&out.writer, view);
    }
    try printRaw(io, out.written());
    return if (refreshed) 0 else 1;
}

/// The catalogue this profile's own endpoint publishes, when it publishes one
/// and the profile has not been told what it serves: today, a codex profile
/// with no `models` list reads the Codex CLI's cache. An explicit `models` in
/// any config layer wins — a discovered list never overrules a written one.
///
/// `io` and the environment are arguments rather than looked up here, so a test
/// can point `CODEX_HOME` at a fixture and this stays the one code path.
fn endpointCatalog(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    p: config.ProviderProfile,
) !?codex.Catalog {
    if (p.kind != .codex or p.models.len != 0) return null;
    return codex.Catalog.load(alloc, io, env);
}

/// The catalogue as the two parallel lists the view carries, with the profile's
/// default model first when it is one of them: `models[0]` is what a picker
/// opens on, and it is what `ProviderProfile.defaultModel` would pick for a
/// profile that names no `model`.
fn orderByDefault(
    a: std.mem.Allocator,
    params: []const config.ModelParams,
    default_id: []const u8,
) !struct { ids: []const []const u8, params: []const config.ModelParams } {
    const ordered = try a.alloc(config.ModelParams, params.len);
    var at: usize = 0;
    for (params) |m| {
        if (std.mem.eql(u8, m.id, default_id)) {
            ordered[at] = m;
            at += 1;
        }
    }
    for (params) |m| {
        if (!std.mem.eql(u8, m.id, default_id)) {
            ordered[at] = m;
            at += 1;
        }
    }
    const ids = try a.alloc([]const u8, ordered.len);
    for (ordered, 0..) |m, i| ids[i] = m.id;
    return .{ .ids = ids, .params = ordered };
}

/// `nulya config refresh`: fetch today's catalogue for every codex profile whose
/// subscription credential is present right now, and write it to the file the
/// projection reads. Returns false when the refresh did not happen — a failure,
/// or nothing to refresh at all — which the caller turns into exit 1; the
/// projection is still printed either way.
fn refreshCodexCatalogs(
    alloc: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    env: *const std.process.Environ.Map,
) !bool {
    var ok = true;
    var attempted = false;
    for (cfg.provider.profiles) |p| {
        if (p.kind != .codex) continue;
        if (launch.credentialSource(alloc, io, p, env) != .login) continue;
        attempted = true;
        codex.refreshCatalog(alloc, io, env, launch.version) catch |err| {
            ok = false;
            try common.printErrFmt(alloc, io, "config refresh: {s}: {s}\n", .{ p.name, @errorName(err) });
        };
    }
    if (!attempted) {
        try printErr(io, "config refresh: no profile with a live catalogue to refresh (codex needs `codex login`)\n");
        return false;
    }
    return ok;
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
        // A profile with its own catalogue prints it in full below instead —
        // those ids are NOT described by the shared catalog at the bottom.
        if (p.catalog == null and p.models.len > 1) {
            try w.writeAll("  [");
            for (p.models, 0..) |m, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeAll(m);
            }
            try w.writeAll("]");
        }
        if (p.base_url.len != 0) try w.print("\n      {s}", .{p.base_url});
        try w.writeByte('\n');
        if (p.catalog) |catalog| {
            try w.writeAll("      models from ~/.codex/models_cache.json:\n");
            for (catalog) |m| {
                try w.writeAll("    ");
                try writeModelLine(w, m);
            }
        }
    }
    try w.writeAll("\nmodels:\n");
    for (view.models) |m| try writeModelLine(w, m);
    // Under the exact key names a reader writes back into a config file.
    try w.print("\nregistry:\n  max_tools            {d}\n", .{view.registry.max_tools});
    // An empty list prints as "(none)": that is an answer, a missing section is
    // not.
    try w.writeAll("\nextensions:\n  with                 ");
    if (view.extensions.with.len == 0) {
        try w.writeAll("(none)");
    } else {
        for (view.extensions.with, 0..) |id, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(id);
        }
    }
    try w.writeByte('\n');
}

/// One model's parameters, in the same columns wherever they come from — the
/// shared `[[models]]` catalog or a profile's own endpoint.
fn writeModelLine(w: *std.Io.Writer, m: config.ModelParams) !void {
    try w.print("  {s: <22} {s: <18}", .{ m.id, m.label });
    if (m.context_window) |c| try w.print("  ctx {d: >7}", .{c});
    // Only when true: absence of the word is absence of the claim, which is
    // how the `--image` gate reads it.
    if (m.vision) try w.writeAll("  vision");
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
    cfg.registry = .{ .max_tools = 6 };
    cfg.extensions = .{ .with = &.{ "guide", "std:read,grep" } };

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
        .extensions = .{ .with = cfg.extensions.with },
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

    const registry = root.get("registry").?.object;
    try std.testing.expectEqual(@as(i64, 6), registry.get("max_tools").?.integer);
    const projected_with = root.get("extensions").?.object.get("with").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), projected_with.len);
    try std.testing.expectEqualStrings("guide", projected_with[0].string);
    // A member's tool selection rides along verbatim: the projection is what a
    // reader writes back.
    try std.testing.expectEqualStrings("std:read,grep", projected_with[1].string);
    // `extensions.paths` is NOT projected.
    try std.testing.expect(root.get("extensions").?.object.get("paths") == null);

    // The plain-text form mentions each profile and the model line.
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try writeConfigText(&text.writer, view);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "ds ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "no key") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "effort off|low|high|max (default auto)") != null);
    // Under the same key names the config file uses, so reading is enough to write.
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "max_tools            6") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "with                 guide, std:read,grep") != null);
}

/// A models_cache.json the way the Codex CLI leaves one: the default model is
/// NOT first, one model is hidden, and the window is a percentage of the raw one.
const codex_cache_fixture =
    \\{"fetched_at":"2026-07-15T10:42:23Z","client_version":"0.144.1","models":[
    \\ {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list",
    \\  "context_window":272000,"effective_context_window_percent":95,
    \\  "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}],
    \\  "default_reasoning_level":"low"},
    \\ {"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list",
    \\  "context_window":272000,"effective_context_window_percent":95,
    \\  "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}],
    \\  "default_reasoning_level":"medium"},
    \\ {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","context_window":272000}
    \\]}
;

test "config show: a codex profile's model list and parameters come from the subscription, and an explicit list wins" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const codex_home = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "models_cache.json", .data = codex_cache_fixture });

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("CODEX_HOME", codex_home);

    const profile: config.ProviderProfile = .{ .name = "codex", .kind = .codex, .model = "gpt-5.5" };
    var loaded = (try endpointCatalog(alloc, io, &env, profile)).?;
    defer loaded.deinit();
    const listed = try orderByDefault(a, loaded.models, profile.defaultModel());

    // The hidden model is not offered, and the profile's default opens the list
    // even though the file lists it second.
    try std.testing.expectEqual(@as(usize, 2), listed.ids.len);
    try std.testing.expectEqualStrings("gpt-5.5", listed.ids[0]);
    try std.testing.expectEqualStrings("gpt-5.6-sol", listed.ids[1]);
    // `catalog[i]` describes `models[i]`, with the subscription's own numbers.
    try std.testing.expectEqualStrings(listed.ids[1], listed.params[1].id);
    try std.testing.expectEqual(@as(u64, 258_400), listed.params[1].context_window.?);
    try std.testing.expectEqualStrings("xhigh", listed.params[1].efforts[3]);
    try std.testing.expectEqualStrings("low", listed.params[1].default_effort.?);

    // An explicit `models` is a statement about what the profile serves; a
    // discovered list never overrules a written one. Nor does any other kind of
    // profile grow a catalogue.
    var told: config.ProviderProfile = profile;
    told.models = &.{"gpt-5.5"};
    try std.testing.expect((try endpointCatalog(alloc, io, &env, told)) == null);
    try std.testing.expect((try endpointCatalog(alloc, io, &env, .{ .name = "openai", .kind = .openai })) == null);

    // No cache on this machine: the profile still projects its default model,
    // described by the shared `[[models]]` catalog (catalog stays null).
    var bare: std.process.Environ.Map = .init(alloc);
    defer bare.deinit();
    const empty_home = try std.fs.path.join(a, &.{ codex_home, "empty" });
    try tmp.dir.createDirPath(io, "empty");
    try bare.put("CODEX_HOME", empty_home);
    try std.testing.expect((try endpointCatalog(alloc, io, &bare, profile)) == null);

    // The text form says where the list came from, and describes each id there
    // rather than in the shared catalog at the bottom.
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try writeConfigText(&text.writer, .{
        .paths = .{ .system = "s", .user = "u", .project = config.project_config_path },
        .active_profile = "codex",
        .profiles = &.{.{
            .name = "codex",
            .kind = "codex",
            .base_url = "",
            .api_key_env = "",
            .credential = true,
            .credential_source = "login",
            .model = "gpt-5.5",
            .models = listed.ids,
            .effort = null,
            .catalog = listed.params,
        }},
        .models = &.{},
        .registry = .{},
        .extensions = .{ .with = &.{} },
    });
    for ([_][]const u8{
        "models from ~/.codex/models_cache.json",
        "gpt-5.6-sol",
        "ctx  258400",
        "effort low|medium|high|xhigh (default low)",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, text.written(), needle) != null) catch |err| {
            std.debug.print("`config show` never mentions '{s}'\n", .{needle});
            return err;
        };
    }
}

test "config show prints both standing lists, empty ones as such rather than as a missing section" {
    const alloc = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try writeConfigText(&text.writer, .{
        .paths = .{ .system = "s", .user = "u", .project = config.project_config_path },
        .active_profile = "scripted",
        .profiles = &.{},
        .models = &.{},
        .registry = .{},
        .extensions = .{ .with = &.{} },
    });
    // "this session composes nothing" is an answer; a silent section is not.
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "max_tools            20") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "with                 (none)") != null);

    var filled: std.Io.Writer.Allocating = .init(alloc);
    defer filled.deinit();
    try writeConfigText(&filled.writer, .{
        .paths = .{ .system = "s", .user = "u", .project = config.project_config_path },
        .active_profile = "scripted",
        .profiles = &.{},
        .models = &.{},
        .registry = .{},
        .extensions = .{ .with = &.{ "guide", "std" } },
    });
    try std.testing.expect(std.mem.indexOf(u8, filled.written(), "with                 guide, std") != null);
}
