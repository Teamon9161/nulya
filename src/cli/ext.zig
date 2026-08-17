//! `nulya ext …` (DESIGN §7, §14): the extension lifecycle as a CLI — scaffold,
//! build into an immutable version, point `current` at one, run one, and read
//! what the store roots hold. The model reaches all of it through `shell`; none
//! of it is a model-facing tool.

const std = @import("std");
const builtin = @import("builtin");
const environment = @import("../environment.zig");
const build_ext = @import("../extension/build/build_ext.zig");
const store = @import("../extension/store.zig");
const roots_mod = @import("../extension/roots.zig");
const invoke = @import("../extension/invoke.zig");
const manifest = @import("../extension/manifest.zig");
const templates = @import("../extension/build/templates.zig");
const notes = @import("../extension/notes.zig");
// `tool` is a common local name below (a tool NAME), so the module keeps a
// distinct one rather than forcing every call site to rename.
const tool_mod = @import("../tool.zig");
const tool_stats = @import("../tool_stats.zig");
const cli_src = @import("src.zig");
const cli_toolchain = @import("toolchain.zig");
const ZigExe = cli_toolchain.ZigExe;
const resolveZig = cli_toolchain.resolveZig;
const noteUnpinnedZig = cli_toolchain.noteUnpinnedZig;
const common = @import("common.zig");
const RootSearch = common.RootSearch;
const writeRootSpec = common.writeRootSpec;
const takeUserFlag = common.takeUserFlag;
const targetRootSpec = common.targetRootSpec;
const envSessionId = common.envSessionId;
const cwdRealPath = common.cwdRealPath;
const withRef = common.withRef;
const writeInto = common.writeInto;
const printOut = common.printOut;
const printRaw = common.printRaw;
const printErr = common.printErr;

pub fn dispatchExt(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return common.usage(io);
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

fn extInit(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    var is_script = false;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(alloc);
    for (flags.rest) |a| {
        if (std.mem.eql(u8, a, "--script")) is_script = true else try positional.append(alloc, a);
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
    const root_spec = (try writeRootSpec(alloc, flags.user)) orelse {
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
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    if (flags.rest.len < 1) {
        try printErr(io, "usage: nulya ext build <path> [--user]\n");
        return 1;
    }
    const ext_dir = flags.rest[0];

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const dest_spec = (try buildDestRoot(alloc, io, cwd_path, ext_dir, flags.user)) orelse {
        try printErr(io, "no home directory for --user (set NULYA_HOME or HOME)\n");
        return 1;
    };
    defer alloc.free(dest_spec);
    var dest_root = try store.openOrCreateRoot(io, cwd_path, dest_spec);
    defer dest_root.close(io);

    // A script extension needs no toolchain; only a compiled one does. Resolve
    // zig best-effort and let the build decide — it reports ZigVersionUnreadable
    // only if it actually has to compile.
    const zig_exe: ?ZigExe = resolveZig(alloc, io) catch null;
    defer if (zig_exe) |z| z.deinit(alloc);

    var result = build_ext.buildExtension(alloc, io, std.Io.Dir.cwd(), ext_dir, dest_root, if (zig_exe) |z| z.path else "") catch |err| switch (err) {
        // Either nothing answered, or what answered could not say its own
        // version — and that difference is the whole repair hint, so it is not
        // flattened into one sentence.
        error.ZigVersionUnreadable => {
            if (zig_exe) |z| {
                try printOut(alloc, io, "the zig at {s} could not report its version (`zig version` failed), and a compiled extension needs one; set NULYA_ZIG to a working toolchain, or build nulya with -Dembed-toolchain\n", .{z.path});
            } else {
                try printOut(alloc, io, "no zig toolchain (needed to compile this extension); set NULYA_ZIG, put zig on PATH, or build nulya with -Dembed-toolchain\n", .{});
            }
            return 1;
        },
        else => return err,
    };
    defer result.deinit(alloc);

    // `entry_rel` is set only for a COMPILED package, i.e. exactly when the
    // compiler above was used and its identity entered the version id.
    if (result.entry_rel != null) {
        if (zig_exe) |z| try noteUnpinnedZig(alloc, io, z);
    }

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
    if (user) return writeRootSpec(alloc, true);

    var draft = std.Io.Dir.cwd().openDir(io, ext_dir, .{}) catch
        return try alloc.dupe(u8, store.workspace_root_rel); // let the build report it
    defer draft.close(io);
    var draft_buf: [std.fs.max_path_bytes]u8 = undefined;
    const draft_real = draft_buf[0..try draft.realPath(io, &draft_buf)];

    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    for (search.roots.entries) |entry| {
        if (isInside(entry.real, draft_real)) return try alloc.dupe(u8, entry.spec);
    }
    return try alloc.dupe(u8, store.workspace_root_rel);
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
        try printErr(io, "usage: nulya ext run <id>[@<version>] [tool] <json-args> | --arg k=v ...\n");
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
        try printErr(io, "usage: nulya ext run <id>[@<version>] [tool] <json-args> | --arg k=v ...\n");
        return 1;
    }
    // `<id>` runs the version in effect; `<id>@<version>` runs exactly that
    // built version, active or not — how a session invokes a tool it composed
    // with `--with <id>@<version>` (DESIGN §14), and how anything else names a
    // frozen version without touching `current`.
    const with_ref = withRef(positional.items[0]);
    const id = with_ref.id;
    const use_args = pairs.items.len > 0;
    if (!use_args and positional.items.len < 2) {
        try printErr(io, "usage: nulya ext run <id>[@<version>] [tool] <json-args> | --arg k=v ...\n");
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

    // Whichever root holds the version — the first active copy of the id, or
    // the first copy of the pinned version (DESIGN §7.2). One shared lookup
    // (`Roots.Resolved`) does search order, integrity validation, and the
    // frozen manifest, so this path cannot drift from session composition.
    // That frozen manifest is the runtime truth: the source tree's may already
    // have changed while `current` still points at an older immutable version.
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const resolved: roots_mod.Roots.Resolved = if (with_ref.version) |v|
        search.roots.resolveVersion(alloc, id, v) catch |err| switch (err) {
            error.Canceled => return err,
            error.VersionNotFound => {
                try printOut(alloc, io, "no store root holds {s}@{s}; see `nulya ext list`\n", .{ id, v });
                return 1;
            },
            else => {
                try printOut(alloc, io, "version {s}@{s} failed integrity validation ({s})\n", .{ id, v, @errorName(err) });
                return 1;
            },
        }
    else
        (search.roots.resolveActive(alloc, id) catch |err| switch (err) {
            error.Canceled => return err,
            // `current` names a version this root cannot serve. Name the fault;
            // `nulya ext list` names the version it points at.
            else => {
                try printOut(alloc, io, "active version of '{s}' failed integrity validation ({s}); see `nulya ext list`\n", .{ id, @errorName(err) });
                return 1;
            },
        }) orelse {
            try printOut(alloc, io, "extension '{s}' has no active version; run `nulya ext build` then `nulya ext activate`, or name a built version as {s}@<version>\n", .{ id, id });
            return 1;
        };
    defer resolved.deinit(alloc);
    const m = resolved.manifest;

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

    // A compiled binary lives under `bin/`; a script under `package/`. The
    // resolution dispatches on runtime kind so this CLI path and session
    // composition never drift on how a frozen entry is located.
    const entry_abs = try resolved.entryPathAbs(alloc, &search.roots);
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // Resolution (active version, integrity, frozen manifest, tool declaration,
    // exact entry path) is the CLI's job; from here on the helper owns encode,
    // run, decode, and diagnostics.
    const invocation = try invoke.invokeTool(alloc, lenv.environment(), entry_abs, cwd_path, tool, args_json, .{
        // The frozen manifest may say this tool needs longer than the host
        // default (DESIGN §7.3) — the same declaration a natively pinned tool
        // carries into its binding, read from the same place.
        .timeout_ms = spec.?.timeout_ms orelse tool_mod.Timeouts.extension_ms,
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
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    if (flags.rest.len < 2) {
        try printErr(io, "usage: nulya ext activate|rollback [--user] <id> <version>\n");
        return 1;
    }
    const id = flags.rest[0];
    const version = flags.rest[1];

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const target = (try targetRootSpec(alloc, io, cwd_path, id, version, flags.user)) orelse {
        try printOut(alloc, io, "no store root holds {s}@{s} (or no home for --user); see `nulya ext list`\n", .{ id, version });
        return 1;
    };
    defer alloc.free(target);
    var ext_root = try store.openOrCreateRoot(io, cwd_path, target);
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);
    try warnUserScope(alloc, io, st, id, version, flags.user);
    (switch (mode) {
        .activate => st.activate(alloc, id, version),
        .rollback => st.rollback(alloc, id, version),
    }) catch |err| {
        try printOut(alloc, io, "{s} failed: {s} ({s}@{s} in {s})\n", .{ @tagName(mode), @errorName(err), id, version, target });
        if (err == error.VersionNotFound) {
            // The version exists, just not in the root whose copy is in effect
            // — say so, or "but I built it" is the next question.
            var search = try RootSearch.open(alloc, io, cwd_path);
            defer search.deinit(alloc);
            if (search.roots.firstWithVersion(alloc, id, version)) |i| {
                try printOut(alloc, io, "note: {s}@{s} is built in {s}, which {s} shadows; activate a version built in {s}, or `--user` to act on the user store\n", .{ id, version, search.roots.entries[i].spec, target, target });
            }
        }
        return 1;
    };

    // What is IN EFFECT now (`Roots.firstActive`, DESIGN §7.2) — not merely
    // what this root's `current` says: an earlier root's active copy still wins.
    // Only a version that is actually in effect gets announced to a live session
    // (NULYA_SESSION names its file) by depositing a capability note into its
    // inbox for the next step boundary (DESIGN §3, §5.3). Best-effort: a
    // note-deposit failure never fails the activation the model just performed.
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    const effective = try search.roots.firstActive(alloc, id);
    defer if (effective) |e| alloc.free(e.version);
    const shadowed_by: ?roots_mod.Roots.ActiveVersion = blk: {
        const e = effective orelse break :blk null;
        if (std.mem.eql(u8, e.version, version) and std.mem.eql(u8, search.roots.entries[e.root].spec, target)) break :blk null;
        break :blk e;
    };
    if (shadowed_by == null) depositSessionNote(alloc, io, ext_root, id, version) catch {};

    try printOut(alloc, io, "{s}: current -> {s} in {s}\n", .{ id, version, target });
    if (shadowed_by) |s| {
        try printOut(alloc, io, "note: not in effect — {s}@{s} in {s} shadows it\n", .{ id, s.version, search.roots.entries[s.root].spec });
    }
    return 0;
}

/// Say, on stderr, when a model running inside a session reaches OUT of that
/// session's workspace: `--user` puts the version in the user store, where it is
/// active for every workspace on this machine (DESIGN §7.2), and if it
/// contributes a system prompt that text joins the system blocks of every future
/// session (DESIGN §7.5). Neither is refused — the model is allowed to do this,
/// and a refusal here would be a policy in the kernel's shell. What is not
/// allowed is doing it INVISIBLY. Silent outside `--user`, and silent when no
/// session is running.
fn warnUserScope(
    alloc: std.mem.Allocator,
    io: std.Io,
    st: store.Store,
    id: []const u8,
    version: []const u8,
    user: bool,
) !void {
    if (!user) return;
    const sid = (try envSessionId(alloc)) orelse return;
    defer alloc.free(sid);

    // Best effort: an unreadable manifest only costs the extra clause.
    const prompts: bool = blk: {
        var m = st.readManifest(alloc, id, version) catch break :blk false;
        defer m.deinit();
        break :blk m.system_prompts.len != 0;
    };
    const line = try std.fmt.allocPrint(
        alloc,
        "note: activating {s}@{s} in the user store from inside session {s}: it becomes active for every workspace on this machine{s}\n",
        .{ id, version, sid, if (prompts) " and its system prompt enters every future session" else "" },
    );
    defer alloc.free(line);
    try printErr(io, line);
}

/// Deposit a capability note for `id@version` into the current session's inbox
/// when `NULYA_SESSION` is set. The variable holds the session file path relative
/// to the workspace cwd, so both the file and its `<stem>.inbox` sibling resolve
/// against `cwd()`.
fn depositSessionNote(alloc: std.mem.Allocator, io: std.Io, ext_root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    var host = try environment.hostEnvironMap(alloc);
    defer host.deinit();
    const session_path = host.get("NULYA_SESSION") orelse return;
    if (session_path.len == 0) return;
    try notes.depositActiveNote(alloc, io, std.Io.Dir.cwd(), session_path, ext_root, id, version);
}

fn extDeactivate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    const flags = try takeUserFlag(alloc, args);
    defer alloc.free(flags.rest);
    if (flags.rest.len < 1) {
        try printErr(io, "usage: nulya ext deactivate [--user] <id>\n");
        return 1;
    }
    const id = flags.rest[0];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);
    const target = (try targetRootSpec(alloc, io, cwd_path, id, null, flags.user)) orelse {
        try printOut(alloc, io, "extension '{s}' has no active version in any store root\n", .{id});
        return 1;
    };
    defer alloc.free(target);
    var ext_root = try store.openOrCreateRoot(io, cwd_path, target);
    defer ext_root.close(io);
    try store.Store.init(io, ext_root).deactivate(alloc, id);
    try printOut(alloc, io, "{s}: deactivated\n", .{id});

    // Deactivating the copy in effect can UNSHADOW one in a later root — say so,
    // or "I deactivated it, why is it still in my session?" is the next question.
    var search = try RootSearch.open(alloc, io, cwd_path);
    defer search.deinit(alloc);
    if (try search.roots.firstActive(alloc, id)) |still| {
        defer alloc.free(still.version);
        try printOut(alloc, io, "note: {s}@{s} in {s} is now the active copy\n", .{ id, still.version, search.roots.entries[still.root].spec });
    }
    return 0;
}

/// Every extension directory in every root, in search order, with the root it
/// came from. An ACTIVE id that an earlier root also has active is marked
/// `(shadowed)`: only the first active copy is ever used (`Roots.listActive`),
/// and silently hiding the duplicate is how a stale user-level copy becomes a
/// mystery. A directory without `current` shadows nothing and is listed as
/// `(inactive)` for its root alone — unless it holds no built version either, in
/// which case it is a bare writer lease, not an extension, and is skipped.
///
/// A listed version also says what it CONTRIBUTES (`[tools skills prompt]`, from
/// its frozen manifest). `prompt` is the one that earns the column: an activated
/// package's `system_prompts` enter the system blocks of every future session
/// (DESIGN §7.5) with no gate anywhere, and until now the only way to see that
/// was to read the manifest by hand. Unreadable manifest → no marker, never a
/// failed listing.
fn extList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var search = try RootSearch.open(alloc, io, try cwdRealPath(io, &cwd_buf));
    defer search.deinit(alloc);

    var seen_active: std.ArrayList([]const u8) = .empty;
    defer {
        for (seen_active.items) |s| alloc.free(s);
        seen_active.deinit(alloc);
    }

    var printed: usize = 0;
    for (search.roots.entries, 0..) |entry, root_index| {
        var it = entry.dir.iterate();
        while (try it.next(io)) |dir_entry| {
            if (dir_entry.kind != .directory) continue;
            const st = store.Store.init(io, entry.dir);
            const active = (st.activeVersion(alloc, dir_entry.name) catch |err| switch (err) {
                error.InvalidId => continue,
                else => return err,
            });
            defer if (active) |a| alloc.free(a);
            // A directory with neither an active pointer nor a built version is
            // not an extension — it is where `<id>/.lock` lives. Both `ext build`
            // and `ext activate` take that lease before they validate anything, so
            // a typo'd id or a manifest that failed to parse leaves an empty shell
            // behind; listing it invents an extension nobody made. A directory
            // holding versions is real whether or not one is active (a draft, a
            // deactivated copy), and so is one with a `current` pointer even if
            // its versions are gone — that one is broken, and saying so beats
            // hiding it.
            if (active == null) {
                const versions = try st.listVersions(alloc, dir_entry.name);
                defer {
                    for (versions) |v| alloc.free(v);
                    alloc.free(versions);
                }
                if (versions.len == 0) continue;
            }
            const shadowed = active != null and sliceHasString(seen_active.items, dir_entry.name);
            if (active != null and !shadowed) try seen_active.append(alloc, try alloc.dupe(u8, dir_entry.name));
            const contributes = if (active) |v|
                try contributionMarker(alloc, &search.roots, .{ .id = dir_entry.name, .root = root_index, .version = v })
            else
                try alloc.dupe(u8, "");
            defer alloc.free(contributes);
            printed += 1;
            try printOut(alloc, io, "{s}\t{s}\t{s}{s}{s}\n", .{
                dir_entry.name,
                active orelse "(inactive)",
                entry.spec,
                contributes,
                if (shadowed) "\t(shadowed)" else "",
            });
        }
    }
    if (printed == 0) try printOut(alloc, io, "no extensions\n", .{});
    return 0;
}

/// `\t[tools skills prompt]` for what this frozen version contributes, or an
/// empty string when it contributes nothing nameable or cannot be read. Caller
/// owns the result.
fn contributionMarker(alloc: std.mem.Allocator, roots: *const roots_mod.Roots, entry: roots_mod.Roots.ActiveEntry) ![]u8 {
    const resolved = roots.resolveEntry(alloc, entry) catch return alloc.dupe(u8, "");
    defer resolved.deinit(alloc);
    const m = resolved.manifest;
    if (m.tools.len == 0 and m.skills.len == 0 and m.system_prompts.len == 0) return alloc.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("\t[");
    var first = true;
    for ([_]struct { on: bool, word: []const u8 }{
        .{ .on = m.tools.len != 0, .word = "tools" },
        .{ .on = m.skills.len != 0, .word = "skills" },
        .{ .on = m.system_prompts.len != 0, .word = "prompt" },
    }) |part| {
        if (!part.on) continue;
        if (!first) try out.writer.writeByte(' ');
        try out.writer.writeAll(part.word);
        first = false;
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
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
    return cli_src.printSource(alloc, io, "extension/protocol.zig", false);
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
