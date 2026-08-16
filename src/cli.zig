//! CLI surface (DESIGN §14). None of these are model-facing tools: the model
//! reaches them through `shell`, keeping its tool face tiny. `nulya ext api`
//! prints THIS binary's real protocol so the model never guesses a signature.

const std = @import("std");
const builtin = @import("builtin");
const environment = @import("environment.zig");
const build_ext = @import("extension/build_ext.zig");
const store = @import("extension/store.zig");
const invoke = @import("extension/invoke.zig");
const manifest = @import("extension/manifest.zig");
const templates = @import("extension/templates.zig");
const toolchain = @import("toolchain.zig");
const ext_skills = @import("extension/skills.zig");
const notes = @import("extension/notes.zig");
const tool_stats = @import("tool_stats.zig");
const outcome = @import("outcome.zig");
const config = @import("config.zig");
const ledger = @import("ledger.zig");
const session = @import("session.zig");
const loop = @import("loop.zig");
const provider = @import("provider.zig");
const promotion = @import("promotion.zig");
const launch = @import("launch.zig");
const source = @import("source.zig");

const workspace_extensions_root = launch.workspace_extensions_root;

/// The ordered store roots this invocation searches (DESIGN §7.2), opened once.
/// Every `ext` / `skill` command goes through this instead of assuming the
/// workspace store is the only one: an extension may live in the user's
/// `~/.nulya/extensions` or in a trusted `extensions.paths` entry, and the first
/// root holding an id wins.
const RootSearch = struct {
    specs: []const []const u8,
    roots: store.Roots,

    fn open(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8) !RootSearch {
        const specs = try rootSpecs(alloc, io);
        errdefer launch.freeExtensionRoots(alloc, specs);
        const roots = try store.Roots.open(alloc, io, cwd, specs);
        return .{ .specs = specs, .roots = roots };
    }

    fn deinit(self: *RootSearch, alloc: std.mem.Allocator) void {
        self.roots.deinit();
        launch.freeExtensionRoots(alloc, self.specs);
    }
};

/// Resolve the ordered root specs from the environment + config chain. Caller
/// owns the result (`launch.freeExtensionRoots`).
fn rootSpecs(alloc: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();
    return launch.extensionRoots(alloc, &host, &cfg);
}

/// Where a write-side command puts things: the user store under `--user`, else
/// the workspace store. Caller owns the result.
fn writeRootSpec(alloc: std.mem.Allocator, io: std.Io, user: bool) !?[]u8 {
    if (!user) return try alloc.dupe(u8, workspace_extensions_root);
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    _ = io;
    return launch.userExtensionsRoot(alloc, &host);
}

/// Dispatch `args` (everything after the program name). Returns a process exit
/// code. Errors are printed and turned into a non-zero code by `main`.
pub fn dispatch(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return usage(io);
    if (std.mem.eql(u8, args[0], "ext")) return dispatchExt(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "skill")) return dispatchSkill(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "toolchain")) return dispatchToolchain(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "session")) return dispatchSession(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "src")) return dispatchSrc(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "config")) return dispatchConfig(alloc, io, args[1..]);
    try printErr(io, "unknown command; try `nulya ext`, `nulya skill`, `nulya session`, `nulya config`, `nulya src`, or `nulya toolchain`\n");
    return 1;
}

fn dispatchConfig(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len != 0 and std.mem.eql(u8, args[0], "show")) return configShow(alloc, io, sliceHasFlag(args[1..], "--json"));
    try printErr(io, "usage: nulya config show [--json]\n");
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
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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
}

fn dispatchExt(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return usage(io);
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "init")) return extInit(alloc, io, rest);
    if (std.mem.eql(u8, sub, "build")) return extBuild(alloc, io, rest);
    if (std.mem.eql(u8, sub, "run")) return extRun(alloc, io, rest);
    if (std.mem.eql(u8, sub, "activate")) return extActivate(alloc, io, rest, .activate);
    if (std.mem.eql(u8, sub, "rollback")) return extActivate(alloc, io, rest, .rollback);
    if (std.mem.eql(u8, sub, "deactivate")) return extDeactivate(alloc, io, rest);
    if (std.mem.eql(u8, sub, "list")) return extList(alloc, io);
    if (std.mem.eql(u8, sub, "inspect")) return extInspect(alloc, io, rest);
    if (std.mem.eql(u8, sub, "api")) return extApi(alloc, io, rest);

    try printErr(io, "unknown `ext` subcommand\n");
    return 1;
}

fn dispatchSkill(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return usage(io);
    if (std.mem.eql(u8, args[0], "list")) return skillList(alloc, io);
    if (std.mem.eql(u8, args[0], "load")) return skillLoad(alloc, io, args[1..]);
    try printErr(io, "unknown `skill` subcommand\n");
    return 1;
}

fn skillList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var search = try RootSearch.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer search.deinit(alloc);

    const skills = try ext_skills.listActive(alloc, &search.roots);
    defer skills.deinit(alloc);
    if (skills.skills.len == 0) {
        try printOut(alloc, io, "no skills\n", .{});
        return 0;
    }
    for (skills.skills) |s| {
        try printOut(alloc, io, "{s}\t{s}\t{s}\n", .{ s.ref, s.name, s.description });
    }
    return 0;
}

fn skillLoad(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya skill load <pinned-ref>\n");
        return 1;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var search = try RootSearch.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer search.deinit(alloc);
    const body = ext_skills.loadPinnedAcross(alloc, &search.roots, args[0]) catch |err| {
        try printOut(alloc, io, "skill load failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer alloc.free(body);
    try printOut(alloc, io, "{s}\n", .{body});
    return 0;
}

fn extInit(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var is_script = false;
    var user = false;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--script")) is_script = true else if (std.mem.eql(u8, a, "--user")) user = true else try positional.append(alloc, a);
    }
    if (positional.items.len < 1) {
        try printErr(io, "usage: nulya ext init [--script] [--user] <id> [tool]\n");
        return 1;
    }
    const id = positional.items[0];
    const tool = if (positional.items.len >= 2) positional.items[1] else id;

    // The draft goes into the chosen store root (`--user` = the user-level one),
    // and everything below is written through that root's handle, so an absolute
    // user root needs no absolute sub-paths.
    const root_spec = (try writeRootSpec(alloc, io, user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(root_spec);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd = try store.openOrCreateRoot(io, try cwdRealPath(io, &cwd_buf), root_spec);
    defer cwd.close(io);

    const dir = try alloc.dupe(u8, id);
    defer alloc.free(dir);
    const src_dir = try std.fs.path.join(alloc, &.{ dir, "src" });
    defer alloc.free(src_dir);
    const tests_dir = try std.fs.path.join(alloc, &.{ dir, "tests" });
    defer alloc.free(tests_dir);
    try cwd.createDirPath(io, src_dir);
    try cwd.createDirPath(io, tests_dir);

    if (is_script) {
        // Scaffold a script extension for the host platform: PowerShell on
        // Windows, POSIX sh elsewhere. Both are frozen and run as-is (no build).
        const windows = builtin.os.tag == .windows;
        const script_name = if (windows) "run.ps1" else "run.sh";
        const entry = if (windows) "src/run.ps1" else "src/run.sh";
        const interpreter = if (windows) "powershell" else "sh";
        const body = if (windows) templates.script_ps1 else templates.script_sh;
        const manifest_bytes = try templates.scriptManifestJson(alloc, id, tool, entry, interpreter);
        defer alloc.free(manifest_bytes);
        try writeInto(alloc, io, cwd, dir, "extension.json", manifest_bytes);
        try writeInto(alloc, io, cwd, src_dir, script_name, body);
        try writeInto(alloc, io, cwd, tests_dir, "example.json", templates.example_test_json);
        try printOut(alloc, io, "initialized script extension '{s}' at {s}{c}{s}\n", .{ id, root_spec, std.fs.path.sep, id });
        return 0;
    }

    const manifest_bytes = try templates.manifestJson(alloc, id, tool);
    defer alloc.free(manifest_bytes);
    try writeInto(alloc, io, cwd, dir, "extension.json", manifest_bytes);
    try writeInto(alloc, io, cwd, src_dir, "main.zig", templates.main_zig);
    try writeInto(alloc, io, cwd, tests_dir, "example.json", templates.example_test_json);

    try printOut(alloc, io, "initialized extension '{s}' at {s}{c}{s}\n", .{ id, root_spec, std.fs.path.sep, id });
    return 0;
}

fn extBuild(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    var user = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--user")) user = true else try positional.append(alloc, a);
    }
    if (positional.items.len < 1) {
        try printErr(io, "usage: nulya ext build <path> [--user]\n");
        return 1;
    }
    const ext_dir = positional.items[0];

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const dest_spec = (try buildDestRoot(alloc, io, cwd_path, ext_dir, user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(dest_spec);
    var dest_root = try store.openOrCreateRoot(io, cwd_path, dest_spec);
    defer dest_root.close(io);

    // A script extension needs no toolchain; only a compiled one does. Resolve
    // zig best-effort and let the build decide — it reports ZigVersionUnreadable
    // only if it actually has to compile.
    const zig_exe: ?[]u8 = resolveZig(alloc, io) catch null;
    defer if (zig_exe) |z| alloc.free(z);

    var result = build_ext.buildExtension(alloc, io, std.Io.Dir.cwd(), ext_dir, dest_root, zig_exe orelse "") catch |err| switch (err) {
        error.ZigVersionUnreadable => {
            try printOut(alloc, io, "no zig toolchain (needed to compile this extension); set NULYA_ZIG, or build nulya with -Dembed-toolchain\n", .{});
            return 1;
        },
        else => return err,
    };
    defer result.deinit(alloc);

    if (!result.compile_ok) {
        try printOut(alloc, io, "build FAILED for {s}:\n{s}\n", .{ ext_dir, result.stderr });
        return 1;
    }
    const state = if (result.already_built) "already built" else "built";
    try printOut(alloc, io, "{s}: {s} ({s}, in {s})\n", .{ ext_dir, result.version, state, dest_spec });
    return 0;
}

/// Which store root a build lands in: `--user` forces the user store; otherwise
/// a draft that already lives inside one of the search roots builds into THAT
/// root (so `.nulya/extensions/<id>` keeps building exactly where it always
/// did), and a draft anywhere else — one kept in git, say — builds into the
/// workspace store. Caller owns the result; null means `--user` with no home.
fn buildDestRoot(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    ext_dir: []const u8,
    user: bool,
) !?[]u8 {
    if (user) return writeRootSpec(alloc, io, true);

    var draft = std.Io.Dir.cwd().openDir(io, ext_dir, .{}) catch
        return try alloc.dupe(u8, workspace_extensions_root); // let the build report it
    defer draft.close(io);
    var draft_buf: [std.fs.max_path_bytes]u8 = undefined;
    const draft_real = draft_buf[0..try draft.realPath(io, &draft_buf)];

    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    for (search.roots.entries) |entry| {
        if (isInside(entry.real, draft_real)) return try alloc.dupe(u8, entry.spec);
    }
    return try alloc.dupe(u8, workspace_extensions_root);
}

/// Whether `path` sits under directory `dir` (both already resolved to real
/// absolute paths).
fn isInside(dir: []const u8, path: []const u8) bool {
    if (path.len <= dir.len) return false;
    if (!std.mem.eql(u8, path[0..dir.len], dir)) return false;
    return path[dir.len] == std.fs.path.sep or path[dir.len] == '/';
}

fn extRun(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext run <id> [tool] <json-args> | --arg k=v ...\n");
        return 1;
    }

    // Split off `--arg k=v` pairs from positional args ([id, tool?, json?]).
    var pairs: std.ArrayList([]const u8) = .empty;
    defer pairs.deinit(alloc);
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--arg") and i + 1 < args.len) {
                try pairs.append(alloc, args[i + 1]);
                i += 1;
            } else try positional.append(alloc, args[i]);
        }
    }
    if (positional.items.len == 0) {
        try printErr(io, "usage: nulya ext run <id> [tool] <json-args> | --arg k=v ...\n");
        return 1;
    }
    const id = positional.items[0];
    const use_args = pairs.items.len > 0;
    if (!use_args and positional.items.len < 2) {
        try printErr(io, "usage: nulya ext run <id> [tool] <json-args> | --arg k=v ...\n");
        return 1;
    }
    for (pairs.items) |p| {
        if (std.mem.indexOfScalar(u8, p, '=') == null) {
            try printErr(io, "--arg must be of the form k=v\n");
            return 1;
        }
    }
    var cwd_real: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_real);

    // Whichever root holds an active version of this id first (DESIGN §7.2).
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const found = (try search.roots.firstActive(alloc, id)) orelse {
        try printOut(alloc, io, "extension '{s}' has no active version; run `nulya ext build` then `nulya ext activate`\n", .{id});
        return 1;
    };
    const active = found.version;
    defer alloc.free(active);
    const ext_root = search.roots.entries[found.root].dir;
    const st = search.roots.store(found.root);

    if (!st.versionExists(alloc, id, active)) {
        try printOut(alloc, io, "active version for extension '{s}' failed integrity validation\n", .{id});
        return 1;
    }

    // The active version's frozen manifest is the runtime truth. The source-tree
    // manifest may already have changed while `current` still points at an older
    // immutable version.
    const manifest_rel = try st.versionManifestPath(alloc, id, active);
    defer alloc.free(manifest_rel);
    const manifest_bytes = ext_root.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch {
        try printOut(alloc, io, "active version for extension '{s}' is incomplete\n", .{id});
        return 1;
    };
    defer alloc.free(manifest_bytes);
    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();

    // With --arg the only extra positional is an optional tool name; otherwise
    // the last positional is the JSON and an optional tool name precedes it.
    const has_explicit_tool = if (use_args) positional.items.len >= 2 else positional.items.len >= 3;
    const tool = if (has_explicit_tool) positional.items[1] else blk: {
        if (m.tools.len == 0) {
            try printOut(alloc, io, "extension '{s}' contributes no runnable tools\n", .{id});
            return 1;
        }
        break :blk m.tools[0].name;
    };
    const rt = m.runtime orelse {
        try printOut(alloc, io, "extension '{s}' has no runtime\n", .{id});
        return 1;
    };
    const spec: ?manifest.ToolSpec = blk: {
        for (m.tools) |declared_tool| {
            if (std.mem.eql(u8, declared_tool.name, tool)) break :blk declared_tool;
        }
        break :blk null;
    };
    if (spec == null) {
        try printOut(alloc, io, "extension '{s}' does not declare tool '{s}'\n", .{ id, tool });
        return 1;
    }

    // Build the arguments JSON: from --arg pairs (typed by the tool's input
    // schema) when given, otherwise the trailing positional JSON verbatim.
    const owned_args: ?[]u8 = if (use_args) try buildArgsJson(alloc, pairs.items, spec.?.input_schema) else null;
    defer if (owned_args) |a| alloc.free(a);
    const args_json = owned_args orelse positional.items[positional.items.len - 1];

    // A compiled binary lives under `bin/`; a script under `package/`. The store
    // dispatches on runtime kind so this CLI path and session composition never
    // drift on how a frozen entry is located.
    const entry_rel = try st.versionRuntimeEntryPath(alloc, id, active, rt);
    defer alloc.free(entry_rel);
    const entry_abs = try std.fs.path.join(alloc, &.{ search.roots.entries[found.root].real, entry_rel });
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // Resolution (active version, integrity, frozen manifest, tool declaration,
    // exact entry path) is the CLI's job; from here on the helper owns encode,
    // run, decode, and diagnostics.
    const invocation = try invoke.invokeTool(alloc, lenv.environment(), entry_abs, cwd_path, tool, args_json, .{
        .timeout_ms = 30_000,
        .max_output_bytes = 1 << 20,
        .interpreter = rt.interpreter,
    });
    defer invocation.deinit(alloc);

    // Resolution already proved both `id` and `tool` against the frozen
    // manifest, so the durable stats id is exactly `ext:<id>/<tool>` —
    // version-free on purpose, the same stable identity a natively exposed
    // ToolDefinition.id carries, so CLI usage accumulates across versions.
    const stable_id = try std.fmt.allocPrint(alloc, "ext:{s}/{s}", .{ id, tool });
    defer alloc.free(stable_id);
    try tool_stats.append(alloc, io, cwd_path, stable_id, invocation.ok);

    try printOut(alloc, io, "{s}\n", .{invocation.output});
    return if (invocation.ok) 0 else 1;
}

/// Build a JSON object from `k=v` pairs, typing each value by the tool's input
/// schema (`properties.<k>.type`): integer/number/boolean are emitted as JSON
/// scalars, everything else (and any parse failure, and a missing schema) as a
/// string. Caller owns the result.
fn buildArgsJson(alloc: std.mem.Allocator, pairs: []const []const u8, input_schema: []const u8) ![]u8 {
    const parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, alloc, input_schema, .{}) catch null;
    defer if (parsed) |p| p.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    for (pairs) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=').?; // pre-checked by caller
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        try jw.objectField(key);
        try writeTypedValue(&jw, val, schemaType(parsed, key));
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

fn schemaType(parsed: ?std.json.Parsed(std.json.Value), key: []const u8) ?[]const u8 {
    const p = parsed orelse return null;
    const root = switch (p.value) {
        .object => |o| o,
        else => return null,
    };
    const props = switch (root.get("properties") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const prop = switch (props.get(key) orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (prop.get("type") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn writeTypedValue(jw: *std.json.Stringify, val: []const u8, ty: ?[]const u8) !void {
    if (ty) |t| {
        if (std.mem.eql(u8, t, "integer")) {
            if (std.fmt.parseInt(i64, val, 10)) |n| return jw.write(n) else |_| {}
        } else if (std.mem.eql(u8, t, "number")) {
            if (std.fmt.parseFloat(f64, val)) |n| return jw.write(n) else |_| {}
        } else if (std.mem.eql(u8, t, "boolean")) {
            if (std.mem.eql(u8, val, "true")) return jw.write(true);
            if (std.mem.eql(u8, val, "false")) return jw.write(false);
        }
    }
    return jw.write(val); // string, or an unparseable scalar left as text
}

const ActivateMode = enum { activate, rollback };

fn extActivate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8, mode: ActivateMode) !u8 {
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    var user = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--user")) user = true else try positional.append(alloc, a);
    }
    if (positional.items.len < 2) {
        try printErr(io, "usage: nulya ext activate|rollback [--user] <id> <version>\n");
        return 1;
    }
    const id = positional.items[0];
    const version = positional.items[1];

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    var ext_root = (try openTargetRoot(alloc, io, cwd_path, id, version, user)) orelse {
        try printOut(alloc, io, "no store root holds extension '{s}' (and no home for --user)\n", .{id});
        return 1;
    };
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);
    (switch (mode) {
        .activate => st.activate(alloc, id, version),
        .rollback => st.rollback(alloc, id, version),
    }) catch |err| {
        try printOut(alloc, io, "{s} failed: {s}\n", .{ @tagName(mode), @errorName(err) });
        return 1;
    };

    // If this CLI runs inside a live session (NULYA_SESSION names its file,
    // relative to the workspace cwd), deposit a capability note into that
    // session's inbox so the session announces the newly-active version at its
    // next step boundary (DESIGN §3, §5.3). Best-effort: a note-deposit failure
    // never fails the activation the model just performed.
    depositSessionNote(alloc, io, ext_root, id, version) catch {};

    try printOut(alloc, io, "{s}: current -> {s}\n", .{ id, version });
    return 0;
}

/// Deposit a capability note for `id@version` into the current session's inbox
/// when `NULYA_SESSION` is set. The variable holds the session file path relative
/// to the workspace cwd, so both the file and its `<stem>.inbox` sibling resolve
/// against `cwd()`.
fn depositSessionNote(alloc: std.mem.Allocator, io: std.Io, ext_root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    const session_path = host.get("NULYA_SESSION") orelse return;
    if (session_path.len == 0) return;
    try notes.depositActiveNote(alloc, io, std.Io.Dir.cwd(), session_path, ext_root, id, version);
}

/// The root an `activate` / `rollback` / `deactivate` acts on: the user store
/// under `--user`, else the first root that actually holds this version, else
/// the first root that has the extension at all — so the operation lands where
/// the extension lives rather than always in the workspace. Null means there is
/// nowhere to act (and, for `--user`, no home directory).
fn openTargetRoot(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    id: []const u8,
    version: ?[]const u8,
    user: bool,
) !?std.Io.Dir {
    if (user) {
        const spec = (try writeRootSpec(alloc, io, true)) orelse return null;
        defer alloc.free(spec);
        return try store.openOrCreateRoot(io, cwd_path, spec);
    }
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const index = blk: {
        if (version) |v| {
            if (search.roots.firstWithVersion(alloc, id, v)) |i| break :blk i;
        }
        break :blk (search.roots.firstWithId(id) catch null) orelse return null;
    };
    // Reopen independently: `search` owns the handles it is about to close.
    return try store.openOrCreateRoot(io, cwd_path, search.roots.entries[index].spec);
}

fn extDeactivate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    var user = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--user")) user = true else try positional.append(alloc, a);
    }
    if (positional.items.len < 1) {
        try printErr(io, "usage: nulya ext deactivate [--user] <id>\n");
        return 1;
    }
    const id = positional.items[0];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var ext_root = (try openTargetRoot(alloc, io, try cwdRealPath(io, &cwd_buf), id, null, user)) orelse {
        try printOut(alloc, io, "no store root holds extension '{s}'\n", .{id});
        return 1;
    };
    defer ext_root.close(io);
    try store.Store.init(io, ext_root).deactivate(alloc, id);
    try printOut(alloc, io, "{s}: deactivated\n", .{id});
    return 0;
}

/// Every extension in every root, in search order, with the root it came from.
/// An id that a later root also has is marked `(shadowed by …)`: only the first
/// one is ever used, and silently hiding the duplicate is how a stale user-level
/// copy becomes a mystery.
fn extList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var search = try RootSearch.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer search.deinit(alloc);

    var seen: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen.items) |s| alloc.free(s);
        seen.deinit(alloc);
    }

    var printed: usize = 0;
    for (search.roots.entries) |entry| {
        var it = entry.dir.iterate();
        while (try it.next(io)) |dir_entry| {
            if (dir_entry.kind != .directory) continue;
            const active = (store.Store.init(io, entry.dir).activeVersion(alloc, dir_entry.name) catch |err| switch (err) {
                error.InvalidId => continue,
                else => return err,
            });
            defer if (active) |a| alloc.free(a);
            const shadowed = sliceHasString(seen.items, dir_entry.name);
            if (!shadowed) try seen.append(alloc, try alloc.dupe(u8, dir_entry.name));
            printed += 1;
            try printOut(alloc, io, "{s}\t{s}\t{s}{s}\n", .{
                dir_entry.name,
                active orelse "(inactive)",
                entry.spec,
                if (shadowed) "\t(shadowed)" else "",
            });
        }
    }
    if (printed == 0) try printOut(alloc, io, "no extensions\n", .{});
    return 0;
}

fn sliceHasString(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn extInspect(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext inspect <id>\n");
        return 1;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var search = try RootSearch.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer search.deinit(alloc);

    const manifest_rel = try std.fs.path.join(alloc, &.{ args[0], "extension.json" });
    defer alloc.free(manifest_rel);
    for (search.roots.entries) |entry| {
        const bytes = entry.dir.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch continue;
        defer alloc.free(bytes);
        try printOut(alloc, io, "{s}\n", .{bytes});
        return 0;
    }
    try printOut(alloc, io, "no such extension '{s}'\n", .{args[0]});
    return 1;
}

/// `ext api` is a curated `nulya src` (PLAN §3.10): the wire-protocol topic prints
/// the REAL `extension/protocol.zig`, so the ABI the model reads can never drift
/// from the code that implements it. `permissions` and `examples` stay short notes
/// (policy and CLI usage — not source that drifts).
fn extApi(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const topic = if (args.len >= 1) args[0] else "protocol";
    if (std.mem.eql(u8, topic, "permissions")) {
        try printRaw(io,
            \\Authority (DESIGN §9, v0.1 honest version):
            \\  extension and shell share one session_authority (~ current user).
            \\  host secrets (API keys, SSH agent, cloud creds) are stripped from the
            \\  child environment. manifest.permissions is declarative until the
            \\  sandbox backend enforces it.
            \\
        );
        return 0;
    }
    if (std.mem.eql(u8, topic, "examples")) {
        try printRaw(io,
            \\  nulya ext init web-search greet
            \\  nulya ext build .nulya/extensions/web-search
            \\  nulya ext activate web-search <version>
            \\  nulya ext run web-search '{"query":"zig"}'
            \\
        );
        return 0;
    }
    return printSource(alloc, io, "extension/protocol.zig", false);
}

// ── `nulya src` (PLAN §3.10) ─────────────────────────────────────────────────
//
// Print this binary's own embedded source. No path lists the tree; a path prints
// one file with its `test` blocks stripped (the agent usually wants structure, not
// test tokens), or verbatim with `--tests` / `--raw` (Zig-style reference).

fn dispatchSrc(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var include_tests = false;
    var path: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--tests") or std.mem.eql(u8, a, "--raw")) {
            include_tests = true;
        } else if (path == null) {
            path = a;
        } else {
            try printErr(io, "usage: nulya src [path] [--tests]\n");
            return 1;
        }
    }
    if (path == null) return srcList(alloc, io);
    return printSource(alloc, io, path.?, include_tests);
}

fn srcList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    for (source.files) |f| try printOut(alloc, io, "{s}\n", .{f.path});
    return 0;
}

fn printSource(alloc: std.mem.Allocator, io: std.Io, path: []const u8, include_tests: bool) !u8 {
    const bytes = source.find(path) orelse {
        try printOut(alloc, io, "no embedded source '{s}' (try `nulya src` for the list)\n", .{path});
        return 1;
    };
    if (include_tests) {
        try printRaw(io, bytes);
        return 0;
    }
    const stripped = try source.stripTests(alloc, bytes);
    defer alloc.free(stripped);
    try printRaw(io, stripped);
    return 0;
}

fn dispatchToolchain(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1 or !std.mem.eql(u8, args[0], "zig")) {
        try printErr(io, "usage: nulya toolchain zig <args...>\n");
        return 1;
    }
    const zig_exe = resolveZig(alloc, io) catch |err| {
        try printOut(alloc, io, "no zig toolchain: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer alloc.free(zig_exe);

    var argv = try alloc.alloc([]const u8, args.len);
    defer alloc.free(argv);
    argv[0] = zig_exe;
    for (args[1..], 1..) |a, i| argv[i] = a;

    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

// ── `nulya session *` (DESIGN §14, PLAN §3.2) ───────────────────────────────
//
// The one session driver surface. There is deliberately no setTools / setModel /
// replaceHistory: changing composition means a new session. Each subcommand is a
// separate process over the durable session file, and only `step` ever WRITES
// that file: `append` and `cancel` deposit into the session's siblings
// (`<id>.inbox/`, `<id>.cancel`) for `step` to consume at its next step
// boundary, and `events` tails the file read-only. `step` streams the events it
// appends as JSONL; its `--max-steps` budget is enforced by the kernel.

fn dispatchSession(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return sessionUsage(io);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "new")) return sessionNew(alloc, io, rest);
    if (std.mem.eql(u8, sub, "append")) return sessionAppend(alloc, io, rest);
    if (std.mem.eql(u8, sub, "step")) return sessionStep(alloc, io, rest);
    if (std.mem.eql(u8, sub, "events")) return sessionEvents(alloc, io, rest);
    if (std.mem.eql(u8, sub, "cancel")) return sessionCancel(alloc, io, rest);
    if (std.mem.eql(u8, sub, "outcome")) return sessionOutcome(alloc, io, rest);
    try printErr(io, "unknown `session` subcommand; try new|append|step|events|cancel|outcome\n");
    return 1;
}

/// `nulya session outcome <id> <verdict> [--note <text>]` — record how a session
/// turned out (DESIGN §3.3). The verdict is a judgment ABOUT the session, not a
/// turn IN it, so this writes only the outcome journal: it never opens the
/// session file and never takes its writer lease, which is what lets a session
/// still running (or being stepped by another process) be judged right now.
fn sessionOutcome(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try printErr(io, "usage: nulya session outcome <id> <success|partial|failure> [--note <text>]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const verdict = outcome.Verdict.parse(args[1]) orelse {
        try printOut(alloc, io, "invalid verdict '{s}' (want success|partial|failure)\n", .{args[1]});
        return 1;
    };
    const note = flagValue(args[2..], "--note");

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const at = try launch.rfc3339Now(alloc, io);
    defer alloc.free(at);
    try outcome.append(alloc, io, cwd_path, id, verdict, note, at);

    try printOut(alloc, io, "{s}: {s}\n", .{ id, @tagName(verdict) });
    return 0;
}

/// Find `--flag <value>` in args; returns the value or null.
fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

fn cwdRealPath(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ![]u8 {
    const len = try std.Io.Dir.cwd().realPath(io, buf);
    return buf[0..len];
}

fn sessionNew(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();
    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    // `--parent <id>:<seq>` names the lineage this session continues — a fork,
    // or the new file a compaction opens (DESIGN §3.4, §11). The parent must
    // exist: a lineage pointer into nothing is not provenance. Its header is
    // also where an unnamed model comes from, below.
    var parent: ?ledger.ParentRef = null;
    var parent_header: ?ledger.OwnedHeader = null;
    defer if (parent_header) |*h| h.deinit();
    if (flagValue(args, "--parent")) |p| {
        const ref = parseParent(p) orelse {
            try printErr(io, "invalid --parent (want <session>:<seq>)\n");
            return 1;
        };
        if (!launch.isValidSessionId(ref.session)) {
            try printErr(io, "invalid --parent session id\n");
            return 1;
        }
        const ppath = try launch.sessionPath(alloc, ref.session);
        defer alloc.free(ppath);
        parent_header = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), ppath) catch |err| {
            try printOut(alloc, io, "cannot read parent session '{s}': {s}\n", .{ ref.session, @errorName(err) });
            return 1;
        };
        parent = ref;
    }

    // `--profile` names HOW to reach a provider, `--model` WHICH of its ids to
    // run (default: the profile's own default). A typo'd profile is refused
    // rather than silently frozen as scripted; a real profile whose credential
    // is missing still resolves scripted (the offline stand-in) but says so.
    const named_profile = flagValue(args, "--profile");
    const model_id = flagValue(args, "--model");

    // A fork continues its parent's model unless told otherwise: a compaction
    // opens a new file for the same conversation, and who that conversation is
    // with must not change because `active_profile` moved meanwhile (physics §2
    // in spirit — the identity was frozen once, at the root). Composition
    // deliberately does NOT come along: a new session is exactly where promotion
    // and newly activated versions are meant to take hold (DESIGN §5.5, §7.5),
    // and a fork is a session boundary like any other.
    //
    // Two levels of continuing, because the two flags mean different things:
    // `--profile` names a different way to reach a provider, so it replaces the
    // parent's; `--model` only picks another id WITHIN a profile, so the
    // parent's profile still carries. Naming either re-resolves the identity
    // against today's config; naming neither takes the parent's frozen
    // descriptor verbatim, which is the compaction case.
    // An empty one is a legacy header that never recorded a profile: absent, not
    // a profile named "".
    const parent_profile: ?[]const u8 = if (parent_header) |h|
        (if (h.value.model.len != 0) h.value.model else null)
    else
        null;
    const inherited: ?ledger.ModelDescriptor = if (parent_header) |h| blk: {
        if (named_profile != null or model_id != null) break :blk null;
        break :blk if (h.value.model_identity.provider.len != 0) h.value.model_identity else null;
    } else null;

    const profile = named_profile orelse parent_profile orelse
        (if (cfg.provider.active_profile.len != 0) cfg.provider.active_profile else "scripted");

    // An inherited identity needs no resolution — and no credential warning: it
    // never degrades to scripted, so there is nothing to explain here. A missing
    // credential is reported, loudly and once, by the `step` that needs it.
    var identity: ledger.ModelDescriptor = undefined;
    if (inherited) |d| {
        identity = d;
    } else {
        const profile_cfg = cfg.provider.findProfile(profile) orelse {
            try printOut(alloc, io, "no such profile '{s}' (see `nulya config show`)\n", .{profile});
            return 1;
        };
        if (!launch.credentialAvailable(alloc, io, profile_cfg, &host)) {
            var paths = try config.ConfigPaths.init(alloc, &host);
            defer paths.deinit(alloc);
            const warn = if (profile_cfg.kind == .codex)
                try std.fmt.allocPrint(alloc, "warning: profile '{s}' has no credential (run `codex login`); session frozen as scripted\n", .{profile})
            else
                try std.fmt.allocPrint(alloc, "warning: profile '{s}' has no credential (put api_key in {s}, or set {s}); session frozen as scripted\n", .{ profile, paths.user, profile_cfg.api_key_env });
            defer alloc.free(warn);
            try printErr(io, warn);
        }
        // Freeze the RESOLVED model identity now: config chooses the model at
        // creation, and a later config edit can never change this session's
        // model (DESIGN §3).
        identity = launch.resolveDescriptor(alloc, io, cfg.provider, &host, profile, model_id);
    }

    const id = try launch.genSessionId(alloc, io);
    defer alloc.free(id);
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    try std.Io.Dir.cwd().createDirPath(io, launch.sessions_dir);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    const ranked = try promotion.rankExtensionTools(alloc, io, cwd_path, .{
        .uses_recent = cfg.registry.weights.uses_recent,
        .uses_total = cfg.registry.weights.uses_total,
        .last_used = cfg.registry.weights.last_used,
        .success_rate = cfg.registry.weights.success_rate,
    });
    defer promotion.freeRankedIds(alloc, ranked);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .dialect = cfg.environment.shell.toLocalOption() });
    defer lenv.deinit();

    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);

    // A placeholder handle is enough since `new` never steps.
    var holder: launch.ModelHolder = .{ .scripted = .{} };
    var sess = session.AgentSession.createDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = launch.scratch_dir,
        },
        .extension_roots = ext_roots,
        .registry = .{
            .pinned_native_tools = cfg.registry.pinned_native_tools,
            .ranked_native_tools = ranked,
            .max_tools = cfg.registry.max_tools,
        },
    }, .{
        .workspace = std.Io.Dir.cwd(),
        .session_path = spath,
        .session_id = id,
        .model_profile = profile,
        .model_identity = identity,
        .parent = parent,
    }) catch |err| {
        try printOut(alloc, io, "session new failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    sess.deinit();

    try printOut(alloc, io, "{s}\n", .{id});
    return 0;
}

fn sessionAppend(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session append <id> <text> | --file <path>\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }

    const text = if (flagValue(args[1..], "--file")) |path|
        std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20)) catch {
            try printOut(alloc, io, "cannot read --file '{s}'\n", .{path});
            return 1;
        }
    else if (args.len >= 2)
        try alloc.dupe(u8, args[1])
    else {
        try printErr(io, "usage: nulya session append <id> <text> | --file <path>\n");
        return 1;
    };
    defer alloc.free(text);

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    // `append` never writes the session file (its one writer is `step`): the
    // user turn is deposited into the session inbox under a fresh name and
    // appended at the next step boundary — including mid-run, if a step
    // process is going right now.
    var nonce: [4]u8 = undefined;
    io.random(&nonce);
    const name = try std.fmt.allocPrint(alloc, "msg-{d}-{x}", .{
        std.Io.Timestamp.now(io, .real).toNanoseconds(),
        std.mem.readInt(u32, &nonce, .little),
    });
    defer alloc.free(name);
    try ledger.depositEvent(alloc, io, std.Io.Dir.cwd(), spath, name, .{ .user_text = text });
    return 0;
}

/// The `session step --stream` line protocol (tui.md §2.2): one JSON object per
/// line on stdout, written AS the step runs instead of once it is over. Lines
/// carrying a `stream` field are transient observations; lines without one are
/// ledger events in exactly the `session events` shape. Under `--stream` stdout
/// carries nothing else — diagnostics become `{"stream":"run","event":"error"}`.
///
/// This is the whole protocol in one place: `loop.StepObserver` hands it facts,
/// it turns them into lines. It never touches the session, so it stays pure
/// observation (physics: model-visible state changes only by `append`).
const StepStream = struct {
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    /// Ledger index of the first event not yet flushed as a line.
    printed: usize = 0,
    /// How the most recent step ended, for the `run done` line's `stopped`.
    last_status: loop.StepStatus = .completed,
    /// First write failure, if any. An observer must not fail the step, so the
    /// error is parked here and reported by the caller as a non-zero exit.
    err: ?anyerror = null,

    fn note(self: *StepStream, e: anyerror) void {
        if (self.err == null) self.err = e;
    }

    fn observer(self: *StepStream) loop.StepObserver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: loop.StepObserver.VTable = .{
        .modelEvent = onModelEvent,
        .toolBegin = onToolBegin,
        .toolEnd = onToolEnd,
        .stepEnd = onStepEnd,
    };

    fn onModelEvent(ptr: *anyopaque, event: provider.StreamEvent) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        // A complete reasoning item is opaque provider bytes kept for replay, not
        // something to render; `thinking_delta` is the display channel (§2.2).
        if (event == .reasoning_item) return;
        self.modelLine(event) catch |e| self.note(e);
    }

    fn onToolBegin(ptr: *anyopaque, call: ledger.ToolCall) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.toolBeginLine(call) catch |e| self.note(e);
    }

    fn onToolEnd(ptr: *anyopaque, call: ledger.ToolCall, ok: bool) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.toolEndLine(call, ok) catch |e| self.note(e);
    }

    fn onStepEnd(ptr: *anyopaque, events: []const ledger.Event, status: loop.StepStatus) void {
        const self: *StepStream = @ptrCast(@alignCast(ptr));
        self.last_status = status;
        // Ledger lines first, then the boundary marker: a reader that has seen
        // `step end` knows it has every event of that step.
        self.flushEvents(events) catch |e| self.note(e);
        self.stepEndLine(status) catch |e| self.note(e);
    }

    /// Emit every ledger event not yet reported, in `session events` shape. The
    /// seq of view index i is i+1 — the same numbering the session file uses.
    fn flushEvents(self: *StepStream, events: []const ledger.Event) !void {
        while (self.printed < events.len) : (self.printed += 1) {
            const line = try ledger.encodeEventLine(self.alloc, events[self.printed], self.printed + 1);
            defer self.alloc.free(line);
            try self.out.writeAll(line);
        }
        try self.out.flush();
    }

    fn modelLine(self: *StepStream, event: provider.StreamEvent) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("model");
        try jw.objectField("event");
        switch (event) {
            .started => try jw.write("started"),
            .text_delta => |t| {
                try jw.write("text_delta");
                try jw.objectField("text");
                try jw.write(t);
            },
            .thinking_delta => |t| {
                try jw.write("thinking_delta");
                try jw.objectField("text");
                try jw.write(t);
            },
            .reasoning_item => unreachable, // filtered in onModelEvent
            .tool_use_start => |s| {
                try jw.write("tool_use_start");
                try jw.objectField("index");
                try jw.write(s.index);
                try jw.objectField("id");
                try jw.write(s.id);
                try jw.objectField("name");
                try jw.write(s.name);
            },
            .tool_use_input_delta => |d| {
                try jw.write("tool_use_input_delta");
                try jw.objectField("index");
                try jw.write(d.index);
                try jw.objectField("fragment");
                try jw.write(d.fragment);
            },
            .usage => |u| {
                try jw.write("usage");
                try jw.objectField("input_tokens");
                try jw.write(u.input_tokens);
                try jw.objectField("output_tokens");
                try jw.write(u.output_tokens);
                try jw.objectField("cache_read_tokens");
                try jw.write(u.cache_read_tokens);
                try jw.objectField("cache_write_tokens");
                try jw.write(u.cache_write_tokens);
            },
            .done => |stop| {
                try jw.write("done");
                try jw.objectField("stop");
                try jw.write(@tagName(stop));
            },
        }
        try jw.endObject();
        try self.endLine();
    }

    fn toolBeginLine(self: *StepStream, call: ledger.ToolCall) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("tool");
        try jw.objectField("event");
        try jw.write("begin");
        try jw.objectField("call_id");
        try jw.write(call.id);
        try jw.objectField("tool");
        try jw.write(call.tool);
        try jw.endObject();
        try self.endLine();
    }

    /// `call_id` alone identifies the call — the reader already learned its tool
    /// from the matching `begin` (and from `tool_use_start` before that).
    fn toolEndLine(self: *StepStream, call: ledger.ToolCall, ok: bool) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("tool");
        try jw.objectField("event");
        try jw.write("end");
        try jw.objectField("call_id");
        try jw.write(call.id);
        try jw.objectField("ok");
        try jw.write(ok);
        try jw.endObject();
        try self.endLine();
    }

    fn stepEndLine(self: *StepStream, status: loop.StepStatus) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("step");
        try jw.objectField("event");
        try jw.write("end");
        try jw.objectField("status");
        try jw.write(@tagName(status));
        try jw.endObject();
        try self.endLine();
    }

    fn runDone(self: *StepStream, steps: usize, stopped: []const u8) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("run");
        try jw.objectField("event");
        try jw.write("done");
        try jw.objectField("steps");
        try jw.write(steps);
        try jw.objectField("stopped");
        try jw.write(stopped);
        try jw.endObject();
        try self.endLine();
    }

    fn runError(self: *StepStream, message: []const u8) !void {
        var jw: std.json.Stringify = .{ .writer = self.out };
        try jw.beginObject();
        try jw.objectField("stream");
        try jw.write("run");
        try jw.objectField("event");
        try jw.write("error");
        try jw.objectField("message");
        try jw.write(message);
        try jw.endObject();
        try self.endLine();
    }

    /// One line, flushed: the reader consumes stdout line by line as it arrives.
    fn endLine(self: *StepStream) !void {
        try self.out.writeByte('\n');
        try self.out.flush();
    }
};

/// Why the run stopped, from facts the kernel already reports: a canceled step
/// short-circuits `run`, an assistant turn with no calls ends the turn, and
/// anything else means the step budget ran out.
fn stoppedReason(last_status: loop.StepStatus, turn_done: bool) []const u8 {
    if (last_status == .canceled) return "canceled";
    return if (turn_done) "end_turn" else "budget";
}

/// A `session step` diagnostic. Plain text without `--stream` (byte-identical to
/// what it has always printed); a `run error` line with it.
fn stepFail(
    alloc: std.mem.Allocator,
    io: std.Io,
    stream: ?*StepStream,
    comptime fmt: []const u8,
    args: anytype,
) !u8 {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(msg);
    if (stream) |s| {
        try s.runError(msg);
    } else {
        try printOut(alloc, io, "{s}\n", .{msg});
    }
    return 1;
}

fn sessionStep(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session step <id> [--max-steps N] [--effort E] [--stream]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const streaming = sliceHasFlag(args[1..], "--stream");
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var stream_state: StepStream = .{ .alloc = alloc, .out = &stdout.interface };
    const stream: ?*StepStream = if (streaming) &stream_state else null;
    // The kernel clamps this to `session.max_steps_ceiling`: a driver can lower
    // the budget, never raise it.
    var max_steps: usize = session.max_steps_ceiling;
    if (flagValue(args[1..], "--max-steps")) |v| {
        max_steps = std.fmt.parseInt(usize, v, 10) catch 0;
        if (max_steps == 0) {
            try printErr(io, "--max-steps must be a positive integer\n");
            return 1;
        }
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();

    var hdr = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), spath) catch |err| {
        return stepFail(alloc, io, stream, "no such session '{s}': {s}", .{ id, @errorName(err) });
    };
    defer hdr.deinit();

    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .dialect = cfg.environment.shell.toLocalOption() });
    defer lenv.deinit();
    // Let shell children (e.g. `nulya ext activate`) find the live session so
    // they can deposit capability notes into its inbox (DESIGN §5.3).
    try lenv.env.put("NULYA_SESSION", spath);

    // Reconstruct the model frozen at creation, re-resolving only the credential.
    // No silent fallback: a real session whose key is gone fails loudly rather
    // than quietly becoming a scripted session (DESIGN §3). The session id is
    // also the prompt-cache scope, so a provider that keys its cache explicitly
    // keeps hitting it across separate `step` processes.
    // The credential is re-resolved every step: the profile's own `api_key`
    // (user config, found by the header's profile name), else the env var the
    // header names, else the Codex auth file.
    const inline_key = if (cfg.provider.findProfile(hdr.value.model)) |p| p.api_key else null;
    var holder = launch.buildFromDescriptor(alloc, io, hdr.value.model_identity, &host, .{ .cache_key = id, .inline_key = inline_key }) catch |err| switch (err) {
        error.MissingCredential => {
            const credential = if (hdr.value.model_identity.api_key_env.len != 0) hdr.value.model_identity.api_key_env else "codex login";
            return stepFail(alloc, io, stream, "session '{s}' is a '{s}' session but its credential (profile '{s}' api_key, or {s}) is not available; refusing to run (no silent fallback)", .{ id, hdr.value.model_identity.provider, hdr.value.model, credential });
        },
        error.ProviderUnavailable => {
            return stepFail(alloc, io, stream, "session '{s}' was created with provider '{s}', which this build cannot construct", .{ id, hdr.value.model_identity.provider });
        },
        else => return err,
    };
    defer holder.deinit();

    // Effort is a generation option, not identity (DESIGN §3): the driver may
    // set it per step; otherwise the profile / catalog default applies.
    const effort = flagValue(args[1..], "--effort") orelse
        cfg.defaultEffort(hdr.value.model, hdr.value.model_identity.model);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    const ext_roots = try launch.extensionRoots(alloc, &host, &cfg);
    defer launch.freeExtensionRoots(alloc, ext_roots);

    var sess = session.AgentSession.openDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = launch.scratch_dir,
            .observer = if (stream) |s| s.observer() else null,
        },
        .model_options = .{ .effort = effort },
        .extension_roots = ext_roots,
    }, .{ .workspace = std.Io.Dir.cwd(), .session_path = spath }) catch |err| {
        return stepFail(alloc, io, stream, "session open failed: {s}", .{@errorName(err)});
    };
    defer sess.deinit();

    const before = sess.l.len();
    if (stream) |s| s.printed = before;
    const steps = sess.run(max_steps) catch |err| {
        // Whatever this run did append before it faulted is still fact; report
        // those lines, then the error.
        if (stream) |s| s.flushEvents(sess.l.view()) catch {};
        return stepFail(alloc, io, stream, "session step failed: {s}", .{@errorName(err)});
    };

    if (stream) |s| {
        // Every event was already flushed at its step boundary; only the run
        // verdict is left.
        try s.runDone(steps, stoppedReason(s.last_status, sess.lastAssistantDone()));
        // A dropped observation is not a broken step, but the reader's picture is
        // incomplete — say so on stderr (stdout stays pure JSON) and exit non-zero.
        if (s.err) |e| {
            try printErr(io, "stream write failed: ");
            try printErr(io, @errorName(e));
            try printErr(io, "\n");
            return 1;
        }
        return 0;
    }

    // stdout is the events this invocation appended, as one JSONL line each.
    for (sess.l.view()[before..], before..) |ev, i| {
        const line = try ledger.encodeEventLine(alloc, ev, i + 1);
        defer alloc.free(line);
        try printRaw(io, line);
    }
    return 0;
}

fn sessionEvents(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session events <id> [--since N] [--follow]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    var since: u64 = 0;
    if (flagValue(args[1..], "--since")) |v| since = std.fmt.parseInt(u64, v, 10) catch 0;
    const follow = sliceHasFlag(args[1..], "--follow");

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var tail: EventTail = .{ .since = since };
    try tail.dump(alloc, io, std.Io.Dir.cwd(), spath, &stdout.interface);
    try stdout.interface.flush();
    if (!follow) return 0;

    // Poll for newly appended events (DESIGN §14 / PLAN §3.2: polling is enough).
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        try tail.dump(alloc, io, std.Io.Dir.cwd(), spath, &stdout.interface);
        try stdout.interface.flush();
    }
}

/// A read-only tail over a session file's raw lines. `events` never opens the
/// file for writing and never parses or re-encodes events: the file IS the wire
/// format, and its writer already validated that event line k carries seq k, so
/// selecting by seq is counting complete lines past the header.
const EventTail = struct {
    since: u64,
    /// Byte offset of the first unread line.
    offset: usize = 0,
    /// Event lines consumed so far (== the seq of the last one).
    seq: u64 = 0,
    header_seen: bool = false,

    /// Write every complete, not-yet-seen event line with seq > `since` to `out`.
    fn dump(self: *EventTail, alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, spath: []const u8, out: *std.Io.Writer) !void {
        const bytes = try dir.readFileAlloc(io, spath, alloc, .unlimited);
        defer alloc.free(bytes);
        const clean_end: usize = @intCast(ledger.lastCompleteLineEnd(bytes));
        if (clean_end < self.offset) return error.SessionFileShrank;
        var pos = self.offset;
        while (pos < clean_end) {
            // `clean_end` sits just past a newline, so one exists at or after `pos`.
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n').?;
            const line = bytes[pos .. nl + 1];
            pos = nl + 1;
            if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
            if (!self.header_seen) {
                self.header_seen = true;
                continue;
            }
            self.seq += 1;
            if (self.seq > self.since) try out.writeAll(line);
        }
        self.offset = pos;
    }
};

fn sessionCancel(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session cancel <id>\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    if (!sessionExists(io, spath)) {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    }
    // The kernel consumes the marker at the session's next step boundary —
    // between steps of a run already going, or at the start of the next `step`.
    try session.requestCancel(alloc, io, std.Io.Dir.cwd(), spath);
    try printOut(alloc, io, "cancel requested for {s}\n", .{id});
    return 0;
}

fn sessionExists(io: std.Io, spath: []const u8) bool {
    std.Io.Dir.cwd().access(io, spath, .{}) catch return false;
    return true;
}

fn parseParent(s: []const u8) ?ledger.ParentRef {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const session_id = s[0..colon];
    if (session_id.len == 0) return null;
    const seq = std.fmt.parseInt(u64, s[colon + 1 ..], 10) catch return null;
    return .{ .session = session_id, .seq = seq };
}

fn sliceHasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn sessionUsage(io: std.Io) !u8 {
    try printRaw(io,
        \\usage:
        \\  nulya session new [--profile P] [--model ID] [--parent <id>:<seq>]
        \\                                                             freeze composition + model, print a new session id
        \\                                                             (P: a config profile, default active_profile; ID: one of its
        \\                                                             models, default the profile's — see `nulya config show`)
        \\  nulya session append <id> <text> | --file <path>           queue a user turn (appended at the next step boundary)
        \\  nulya session step <id> [--max-steps N] [--effort E] [--stream]
        \\                                                             run to turn end (or the budget); stdout = event JSONL
        \\                                                             --effort overrides the profile/catalog default for this run
        \\                                                             --stream also emits transient model/tool lines as they happen
        \\  nulya session events <id> [--since N] [--follow]           print events as JSONL (read-only tail)
        \\  nulya session cancel <id>                                  request cancel at the next step boundary
        \\  nulya session outcome <id> <success|partial|failure> [--note <text>]
        \\                                                             record how the session turned out (journal only — never
        \\                                                             touches the session file, so a running one can be judged)
        \\
    );
    return 0;
}

/// Resolve a zig executable: `NULYA_ZIG` override (dev), else the embedded
/// managed toolchain (DESIGN §10). Caller owns the returned path.
fn resolveZig(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();

    if (host.get("NULYA_ZIG")) |p| {
        if (p.len != 0) return alloc.dupe(u8, p);
    }

    const data_path = try dataDir(alloc, &host);
    defer alloc.free(data_path);
    std.Io.Dir.cwd().createDirPath(io, data_path) catch {};
    var data = try std.Io.Dir.openDirAbsolute(io, data_path, .{ .iterate = true });
    defer data.close(io);
    return toolchain.ensureExtracted(alloc, io, data);
}

fn dataDir(alloc: std.mem.Allocator, host: *const std.process.Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = host.get("LOCALAPPDATA") orelse ".";
        return std.fs.path.join(alloc, &.{ base, "nulya" });
    }
    if (host.get("XDG_DATA_HOME")) |x| return std.fs.path.join(alloc, &.{ x, "nulya" });
    const home = host.get("HOME") orelse ".";
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "nulya" });
}

fn writeInto(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(alloc, &.{ sub_dir, name });
    defer alloc.free(path);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn usage(io: std.Io) !u8 {
    try printRaw(io,
        \\nulya — minimal self-evolving agent harness
        \\
        \\  nulya ext init <id> <tool>        scaffold a new extension
        \\  nulya ext build <path>            compile into an immutable version
        \\  nulya ext activate <id> <ver>     point `current` at a version
        \\  nulya ext rollback <id> <ver>     repoint `current` at an older version
        \\  nulya ext run <id> [tool] <json>  invoke the active version
        \\  nulya ext list                    list extensions and active versions
        \\  nulya ext inspect <id>            print an extension's manifest
        \\  nulya ext api [protocol|permissions|examples]
        \\  nulya session new|append|step|events|cancel   drive a durable session
        \\  nulya config show [--json]        effective provider profiles + model catalog
        \\  nulya src [path] [--tests]        print this binary's own source
        \\  nulya skill list                 list active extension skills
        \\  nulya skill load <pinned-ref>    print a frozen SKILL.md
        \\  nulya toolchain zig <args...>     run the managed zig (scratch)
        \\
    );
    return 0;
}

fn printOut(alloc: std.mem.Allocator, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try printRaw(io, s);
}

fn printRaw(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn printErr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

test "buildArgsJson types values by the tool input schema" {
    const alloc = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"count":{"type":"integer"},"ratio":{"type":"number"},"on":{"type":"boolean"},"q":{"type":"string"}}}
    ;
    const pairs = [_][]const u8{ "count=3", "ratio=1.5", "on=true", "q=zig" };
    const out = try buildArgsJson(alloc, &pairs, schema);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"count\":3,\"ratio\":1.5,\"on\":true,\"q\":\"zig\"}", out);
}

test "buildArgsJson falls back to string without a schema or for unparseable scalars" {
    const alloc = std.testing.allocator;
    const pairs = [_][]const u8{ "a=1", "b=hi" };
    const out = try buildArgsJson(alloc, &pairs, "not a schema");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("{\"a\":\"1\",\"b\":\"hi\"}", out);

    // An integer-typed field with a non-integer value stays a string.
    const schema = "{\"properties\":{\"n\":{\"type\":\"integer\"}}}";
    const bad = [_][]const u8{"n=notanumber"};
    const out2 = try buildArgsJson(alloc, &bad, schema);
    defer alloc.free(out2);
    try std.testing.expectEqualStrings("{\"n\":\"notanumber\"}", out2);
}

test "EventTail prints raw event lines past --since, skips the header and a torn tail, and resumes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = try ledger.encodeHeaderLine(alloc, .{ .session = "s" });
    defer alloc.free(header);
    const e1 = try ledger.encodeEventLine(alloc, .{ .user_text = "one" }, 1);
    defer alloc.free(e1);
    const e2 = try ledger.encodeEventLine(alloc, .{ .user_text = "two" }, 2);
    defer alloc.free(e2);
    const e3 = try ledger.encodeEventLine(alloc, .{ .user_text = "three" }, 3);
    defer alloc.free(e3);

    // Header, two complete events, and a torn third being written right now.
    const first = try std.mem.concat(alloc, u8, &.{ header, e1, e2, e3[0 .. e3.len / 2] });
    defer alloc.free(first);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = first });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var tail: EventTail = .{ .since = 1 };
    try tail.dump(alloc, io, tmp.dir, "s.jsonl", &out.writer);
    try std.testing.expectEqualStrings(e2, out.written()); // seq 1 filtered, torn 3 withheld

    // The writer finishes the line; a follow-up dump prints only what is new,
    // and the file was never modified by the reader.
    const whole = try std.mem.concat(alloc, u8, &.{ header, e1, e2, e3 });
    defer alloc.free(whole);
    try tmp.dir.writeFile(io, .{ .sub_path = "s.jsonl", .data = whole });
    out.clearRetainingCapacity();
    try tail.dump(alloc, io, tmp.dir, "s.jsonl", &out.writer);
    try std.testing.expectEqualStrings(e3, out.written());
    const on_disk = try tmp.dir.readFileAlloc(io, "s.jsonl", alloc, .unlimited);
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings(whole, on_disk);
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

    // The plain-text form mentions each profile and the model line.
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    try writeConfigText(&text.writer, view);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "ds ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "no key") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "effort off|low|high|max (default auto)") != null);
}

test "parseParent parses <session>:<seq> and rejects malformed input" {
    const p = parseParent("s-123:41").?;
    try std.testing.expectEqualStrings("s-123", p.session);
    try std.testing.expectEqual(@as(u64, 41), p.seq);
    try std.testing.expect(parseParent("no-seq") == null);
    try std.testing.expect(parseParent(":41") == null);
    try std.testing.expect(parseParent("s:notnum") == null);
}

test "session step --stream emits the tui.md §2.2 line protocol in order" {
    const tool = @import("tool.zig");
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = cwd_buf[0..try tmp.dir.realPath(io, &cwd_buf)];

    // A stand-in for `shell` so the protocol test never spawns a subprocess; the
    // scripted provider (the same one `NULYA_SCRIPTED_MODE` selects) drives it.
    const FakeShell = struct {
        fn call(ptr: ?*anyopaque, a: std.mem.Allocator, req: tool.ToolRequest) anyerror!tool.RawToolResult {
            _ = ptr;
            _ = req;
            return .{ .ok = true, .output = try a.dupe(u8, "ok") };
        }
    };
    const tools_arr = [_]tool.Tool{
        .{
            .definition = .{ .id = "nulya.shell", .name = "shell", .description = "shell", .input_schema = "{}" },
            .executor = .{ .ptr = null, .callFn = FakeShell.call },
        },
    };

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    var scripted: launch.ScriptedProvider = .{ .mode = .finish };
    var sess: session.AgentSession = .{
        .alloc = alloc,
        .l = ledger.Ledger.init(alloc),
        .composition = .{
            .pinned_extensions = &.{},
            .extension_tool_bindings = &.{},
            .tools = .{ .tools = &tools_arr },
            .skills = .{ .skills = &.{} },
            .system_prompts = .{ .blocks = &.{} },
        },
        .model = scripted.handle(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = "/tmp",
            .observer = stream.observer(),
        },
        .model_options = .{},
        .extension_roots = &.{"nulya-absent-extensions-root"},
    };
    defer sess.l.deinit();

    try sess.appendUser("go");
    stream.printed = sess.l.len(); // as `session step` does: only this run's events
    const steps = try sess.run(5);
    try stream.runDone(steps, stoppedReason(stream.last_status, sess.lastAssistantDone()));
    try std.testing.expect(stream.err == null);

    // Step 1 calls a tool, step 2 addresses the user. Per step: model deltas →
    // tool begin/end → the ledger events that step appended → the step boundary.
    // Then one run verdict for the whole invocation.
    const expected =
        \\{"stream":"model","event":"started"}
        \\{"stream":"model","event":"text_delta","text":"Let me probe the environment."}
        \\{"stream":"model","event":"tool_use_start","index":0,"id":"c1","name":"shell"}
        \\{"stream":"model","event":"tool_use_input_delta","index":0,"fragment":"{\"command\":\"echo hello-from-nulya\"}"}
        \\{"stream":"model","event":"done","stop":"tool_use"}
        \\{"stream":"tool","event":"begin","call_id":"c1","tool":"shell"}
        \\{"stream":"tool","event":"end","call_id":"c1","ok":true}
        \\{"seq":2,"kind":"assistant","text":"Let me probe the environment.","calls":[{"id":"c1","tool":"shell","args":"{\"command\":\"echo hello-from-nulya\"}"}]}
        \\{"seq":3,"kind":"tool_results","results":[{"call_id":"c1","ok":true,"output":"ok","spill_path":null}]}
        \\{"stream":"step","event":"end","status":"completed"}
        \\{"stream":"model","event":"started"}
        \\{"stream":"model","event":"text_delta","text":"done"}
        \\{"stream":"model","event":"done","stop":"end_turn"}
        \\{"seq":4,"kind":"assistant","text":"done","calls":[]}
        \\{"stream":"step","event":"end","status":"completed"}
        \\{"stream":"run","event":"done","steps":2,"stopped":"end_turn"}
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.written());
}

test "a run stopped by the step budget reports stopped=budget, a canceled step reports canceled" {
    try std.testing.expectEqualStrings("end_turn", stoppedReason(.completed, true));
    try std.testing.expectEqualStrings("budget", stoppedReason(.completed, false));
    try std.testing.expectEqualStrings("canceled", stoppedReason(.canceled, false));
    // A cancel at the boundary wins even when the last assistant turn was clean.
    try std.testing.expectEqualStrings("canceled", stoppedReason(.canceled, true));
}

test "under --stream a diagnostic is a run error line, never a bare text line" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var stream: StepStream = .{ .alloc = alloc, .out = &out.writer };

    const code = try stepFail(alloc, io, &stream, "session open failed: {s}", .{"SessionBusy"});
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings(
        "{\"stream\":\"run\",\"event\":\"error\",\"message\":\"session open failed: SessionBusy\"}\n",
        out.written(),
    );
}
