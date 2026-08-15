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
const config = @import("config.zig");
const ledger = @import("ledger.zig");
const session = @import("session.zig");
const promotion = @import("promotion.zig");
const launch = @import("launch.zig");

const extensions_root = ".nulya" ++ std.fs.path.sep_str ++ "extensions";

/// Dispatch `args` (everything after the program name). Returns a process exit
/// code. Errors are printed and turned into a non-zero code by `main`.
pub fn dispatch(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return usage(io);
    if (std.mem.eql(u8, args[0], "ext")) return dispatchExt(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "skill")) return dispatchSkill(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "toolchain")) return dispatchToolchain(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "session")) return dispatchSession(alloc, io, args[1..]);
    try printErr(io, "unknown command; try `nulya ext`, `nulya skill`, `nulya session`, or `nulya toolchain`\n");
    return 1;
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
    if (std.mem.eql(u8, sub, "api")) return extApi(io, rest);

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
    var ext_root = std.Io.Dir.cwd().openDir(io, extensions_root, .{ .iterate = true }) catch {
        try printOut(alloc, io, "no skills\n", .{});
        return 0;
    };
    defer ext_root.close(io);

    const skills = try ext_skills.listActive(alloc, io, ext_root);
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
    var ext_root = std.Io.Dir.cwd().openDir(io, extensions_root, .{}) catch {
        try printOut(alloc, io, "no extensions\n", .{});
        return 1;
    };
    defer ext_root.close(io);
    const body = ext_skills.loadPinned(alloc, io, ext_root, args[0]) catch |err| {
        try printOut(alloc, io, "skill load failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer alloc.free(body);
    try printOut(alloc, io, "{s}\n", .{body});
    return 0;
}

fn extInit(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext init <id>\n");
        return 1;
    }
    const id = args[0];
    const tool = if (args.len >= 2) args[1] else id;

    const cwd = std.Io.Dir.cwd();
    const dir = try std.fs.path.join(alloc, &.{ extensions_root, id });
    defer alloc.free(dir);
    const src_dir = try std.fs.path.join(alloc, &.{ dir, "src" });
    defer alloc.free(src_dir);
    const tests_dir = try std.fs.path.join(alloc, &.{ dir, "tests" });
    defer alloc.free(tests_dir);
    try cwd.createDirPath(io, src_dir);
    try cwd.createDirPath(io, tests_dir);

    const manifest_bytes = try templates.manifestJson(alloc, id, tool);
    defer alloc.free(manifest_bytes);
    try writeInto(alloc, io, cwd, dir, "extension.json", manifest_bytes);
    try writeInto(alloc, io, cwd, src_dir, "main.zig", templates.main_zig);
    try writeInto(alloc, io, cwd, tests_dir, "example.json", templates.example_test_json);

    try printOut(alloc, io, "initialized extension '{s}' at {s}\n", .{ id, dir });
    return 0;
}

fn extBuild(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext build <path>\n");
        return 1;
    }
    const ext_dir = args[0];

    const zig_exe = resolveZig(alloc, io) catch |err| {
        try printOut(alloc, io, "no zig toolchain: {s}\n(set NULYA_ZIG, or build nulya with -Dembed-toolchain)\n", .{@errorName(err)});
        return 1;
    };
    defer alloc.free(zig_exe);

    var result = try build_ext.buildExtension(alloc, io, std.Io.Dir.cwd(), ext_dir, zig_exe);
    defer result.deinit(alloc);

    if (!result.compile_ok) {
        try printOut(alloc, io, "build FAILED for {s}:\n{s}\n", .{ ext_dir, result.stderr });
        return 1;
    }
    const state = if (result.already_built) "already built" else "built";
    try printOut(alloc, io, "{s}: {s} ({s})\n", .{ ext_dir, result.version, state });
    return 0;
}

fn extRun(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try printErr(io, "usage: nulya ext run <id> [tool] <json-args>\n");
        return 1;
    }
    const id = args[0];
    const args_json = args[args.len - 1];
    const cwd = std.Io.Dir.cwd();

    var ext_root = try cwd.openDir(io, extensions_root, .{});
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);
    const active = (try st.activeVersion(alloc, id)) orelse {
        try printOut(alloc, io, "extension '{s}' has no active version; run `nulya ext build` then `nulya ext activate`\n", .{id});
        return 1;
    };
    defer alloc.free(active);

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
    const tool = if (args.len >= 3) args[1] else blk: {
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
    var declared = false;
    for (m.tools) |declared_tool| {
        if (std.mem.eql(u8, declared_tool.name, tool)) {
            declared = true;
            break;
        }
    }
    if (!declared) {
        try printOut(alloc, io, "extension '{s}' does not declare tool '{s}'\n", .{ id, tool });
        return 1;
    }

    // Reuse the store's exact entry-path construction (identity check + exe
    // suffix) so this CLI path and the session composition can never drift on how
    // a frozen executable is located.
    const entry_rel = try st.versionEntryPath(alloc, id, active, rt.entry);
    defer alloc.free(entry_rel);

    var cwd_real: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try cwd.realPath(io, &cwd_real);
    const cwd_path = cwd_real[0..cwd_len];
    const entry_abs = try std.fs.path.join(alloc, &.{ cwd_path, extensions_root, entry_rel });
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // Resolution (active version, integrity, frozen manifest, tool declaration,
    // exact entry path) is the CLI's job; from here on the helper owns encode,
    // run, decode, and diagnostics.
    const invocation = try invoke.invokeTool(alloc, lenv.environment(), entry_abs, cwd_path, tool, args_json, .{
        .timeout_ms = 30_000,
        .max_output_bytes = 1 << 20,
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

const ActivateMode = enum { activate, rollback };

fn extActivate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8, mode: ActivateMode) !u8 {
    if (args.len < 2) {
        try printErr(io, "usage: nulya ext activate|rollback <id> <version>\n");
        return 1;
    }
    const id = args[0];
    const version = args[1];

    var ext_root = try std.Io.Dir.cwd().openDir(io, extensions_root, .{});
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

fn extDeactivate(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext deactivate <id>\n");
        return 1;
    }
    var ext_root = try std.Io.Dir.cwd().openDir(io, extensions_root, .{});
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);
    try st.deactivate(alloc, args[0]);
    try printOut(alloc, io, "{s}: deactivated\n", .{args[0]});
    return 0;
}

fn extList(alloc: std.mem.Allocator, io: std.Io) !u8 {
    var ext_root = std.Io.Dir.cwd().openDir(io, extensions_root, .{ .iterate = true }) catch {
        try printOut(alloc, io, "no extensions\n", .{});
        return 0;
    };
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);

    var it = ext_root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const active = try st.activeVersion(alloc, entry.name);
        defer if (active) |a| alloc.free(a);
        try printOut(alloc, io, "{s}\t{s}\n", .{ entry.name, active orelse "(inactive)" });
    }
    return 0;
}

fn extInspect(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya ext inspect <id>\n");
        return 1;
    }
    const manifest_rel = try std.fs.path.join(alloc, &.{ extensions_root, args[0], "extension.json" });
    defer alloc.free(manifest_rel);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20)) catch {
        try printOut(alloc, io, "no such extension '{s}'\n", .{args[0]});
        return 1;
    };
    defer alloc.free(bytes);
    try printOut(alloc, io, "{s}\n", .{bytes});
    return 0;
}

fn extApi(io: std.Io, args: []const []const u8) !u8 {
    const topic = if (args.len >= 1) args[0] else "protocol";
    const text = if (std.mem.eql(u8, topic, "permissions"))
        \\Authority (DESIGN §9, v0.1 honest version):
        \\  extension and shell share one session_authority (~ current user).
        \\  host secrets (API keys, SSH agent, cloud creds) are stripped from the
        \\  child environment. manifest.permissions is declarative until the
        \\  sandbox backend enforces it.
        \\
    else if (std.mem.eql(u8, topic, "examples"))
        \\  nulya ext init web-search greet
        \\  nulya ext build .nulya/extensions/web-search
        \\  nulya ext activate web-search <version>
        \\  nulya ext run web-search '{"query":"zig"}'
        \\
    else
        \\Wire protocol (JSON-RPC 2.0, oneshot: spawn -> stdin request -> stdout response -> exit):
        \\  request  {"jsonrpc":"2.0","id":"..","method":"tool/call","params":{"name":"..","arguments":{..}}}
        \\  success  {"jsonrpc":"2.0","id":"..","result":{..}}
        \\  error    {"jsonrpc":"2.0","id":"..","error":{"code":-32000,"message":"..","data":{"retryable":false}}}
        \\
    ;
    try printRaw(io, text);
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
// separate process over the durable session file; `step` streams the events it
// appends as JSONL, and its `--max-steps` cap is enforced by the kernel.

fn dispatchSession(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return sessionUsage(io);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "new")) return sessionNew(alloc, io, rest);
    if (std.mem.eql(u8, sub, "append")) return sessionAppend(alloc, io, rest);
    if (std.mem.eql(u8, sub, "step")) return sessionStep(alloc, io, rest);
    if (std.mem.eql(u8, sub, "events")) return sessionEvents(alloc, io, rest);
    if (std.mem.eql(u8, sub, "cancel")) return sessionCancel(alloc, io, rest);
    if (std.mem.eql(u8, sub, "close")) return sessionClose(alloc, io, rest);
    try printErr(io, "unknown `session` subcommand; try new|append|step|events|cancel|close\n");
    return 1;
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

    const profile = flagValue(args, "--model") orelse
        (if (cfg.provider.active_profile.len != 0) cfg.provider.active_profile else "scripted");

    var parent: ?ledger.ParentRef = null;
    if (flagValue(args, "--parent")) |p| parent = parseParent(p) orelse {
        try printErr(io, "invalid --parent (want <session>:<seq>)\n");
        return 1;
    };

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

    // The model is only recorded (by profile name) at creation; a placeholder
    // handle is enough since `new` never steps.
    var holder = launch.ModelHolder{};
    var sess = session.AgentSession.createDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = launch.scratch_dir,
        },
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

    var l = ledger.openDurable(alloc, io, std.Io.Dir.cwd(), spath) catch |err| {
        try printOut(alloc, io, "session append failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer l.deinit();
    try l.append(.{ .user_text = text });
    return 0;
}

fn sessionStep(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session step <id> [--max-steps N]\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    // Kernel ceiling: a driver can lower it with --max-steps but never raise it.
    const kernel_ceiling: usize = 50;
    var max_steps: usize = kernel_ceiling;
    if (flagValue(args[1..], "--max-steps")) |v| {
        max_steps = @min(std.fmt.parseInt(usize, v, 10) catch kernel_ceiling, kernel_ceiling);
    }

    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    // A pending cancel request is honored at this step boundary: consume it and
    // do nothing this invocation.
    if (try consumeCancel(alloc, io, id)) {
        try printErr(io, "session step canceled by request\n");
        return 0;
    }

    var host = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host.deinit();

    var hdr = ledger.readHeader(alloc, io, std.Io.Dir.cwd(), spath) catch |err| {
        try printOut(alloc, io, "no such session '{s}': {s}\n", .{ id, @errorName(err) });
        return 1;
    };
    defer hdr.deinit();

    var cfg = try config.load(alloc, io, &host);
    defer cfg.deinit();

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .dialect = cfg.environment.shell.toLocalOption() });
    defer lenv.deinit();
    // Let shell children (e.g. `nulya ext activate`) find the live session so
    // they can deposit capability notes into its inbox (DESIGN §5.3).
    try lenv.env.put("NULYA_SESSION", spath);

    var holder = launch.ModelHolder{};
    try launch.buildModel(alloc, io, cfg.provider, &host, hdr.value.model, &holder);
    defer holder.deinit();

    const effort = if (cfg.provider.findProfile(hdr.value.model)) |p| p.effort else null;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = try cwdRealPath(io, &cwd_buf);

    var sess = session.AgentSession.openDurable(alloc, .{
        .model = holder.model(),
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = cwd_path },
            .scratch_dir = launch.scratch_dir,
        },
        .model_options = .{ .effort = effort },
    }, .{ .workspace = std.Io.Dir.cwd(), .session_path = spath }) catch |err| {
        try printOut(alloc, io, "session open failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer sess.deinit();

    const before = sess.l.len();
    _ = sess.run(max_steps) catch |err| {
        try printOut(alloc, io, "session step failed: {s}\n", .{@errorName(err)});
        return 1;
    };

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

    var printed = try dumpEventsSince(alloc, io, spath, since);
    if (!follow) return 0;

    // Poll for newly appended events (DESIGN §14 / PLAN §3.2: polling is enough).
    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        printed = try dumpEventsSince(alloc, io, spath, printed);
    }
}

/// Print every event whose seq is greater than `since` as a raw JSONL line.
/// Returns the highest seq printed (or `since` if none), for follow-mode paging.
fn dumpEventsSince(alloc: std.mem.Allocator, io: std.Io, spath: []const u8, since: u64) !u64 {
    var l = ledger.openDurable(alloc, io, std.Io.Dir.cwd(), spath) catch return since;
    defer l.deinit();
    var last = since;
    for (l.view(), 0..) |ev, i| {
        const seq: u64 = i + 1;
        if (seq <= since) continue;
        const line = try ledger.encodeEventLine(alloc, ev, seq);
        defer alloc.free(line);
        try printRaw(io, line);
        last = seq;
    }
    return last;
}

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
    const marker = try cancelMarkerPath(alloc, id);
    defer alloc.free(marker);
    try std.Io.Dir.cwd().createDirPath(io, launch.sessions_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "" });
    try printOut(alloc, io, "cancel requested for {s}\n", .{id});
    return 0;
}

fn sessionClose(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printErr(io, "usage: nulya session close <id>\n");
        return 1;
    }
    const id = args[0];
    if (!launch.isValidSessionId(id)) {
        try printErr(io, "invalid session id\n");
        return 1;
    }
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);
    std.Io.Dir.cwd().access(io, spath, .{}) catch {
        try printOut(alloc, io, "no such session '{s}'\n", .{id});
        return 1;
    };
    // A session IS its file; closing just clears any pending cancel request.
    _ = try consumeCancel(alloc, io, id);
    try printOut(alloc, io, "closed {s}\n", .{id});
    return 0;
}

fn cancelMarkerPath(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}.cancel", .{ launch.sessions_dir, id });
}

/// If a cancel marker exists for `id`, delete it and return true.
fn consumeCancel(alloc: std.mem.Allocator, io: std.Io, id: []const u8) !bool {
    const marker = try cancelMarkerPath(alloc, id);
    defer alloc.free(marker);
    std.Io.Dir.cwd().access(io, marker, .{}) catch return false;
    std.Io.Dir.cwd().deleteFile(io, marker) catch {};
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
        \\  nulya session new [--model profile] [--parent <id>:<seq>]   print a new session id
        \\  nulya session append <id> <text> | --file <path>           append a user turn
        \\  nulya session step <id> [--max-steps N]                    run to turn end (or the cap); stdout = event JSONL
        \\  nulya session events <id> [--since N] [--follow]           print events as JSONL
        \\  nulya session cancel <id>                                  request cancel at the next step boundary
        \\  nulya session close <id>                                   clear pending cancel; a session is its file
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
        \\  nulya session new|append|step|events|cancel|close   drive a durable session
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
