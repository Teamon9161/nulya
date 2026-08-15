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

const extensions_root = ".nulya" ++ std.fs.path.sep_str ++ "extensions";

/// Dispatch `args` (everything after the program name). Returns a process exit
/// code. Errors are printed and turned into a non-zero code by `main`.
pub fn dispatch(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return usage(io);
    if (std.mem.eql(u8, args[0], "ext")) return dispatchExt(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "skill")) return dispatchSkill(alloc, io, args[1..]);
    if (std.mem.eql(u8, args[0], "toolchain")) return dispatchToolchain(alloc, io, args[1..]);
    try printErr(io, "unknown command; try `nulya ext`, `nulya skill`, or `nulya toolchain`\n");
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

    const entry_rel = try std.fmt.allocPrint(alloc, "{s}{s}", .{ rt.entry, build_ext.exe_suffix });
    defer alloc.free(entry_rel);

    var cwd_real: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try cwd.realPath(io, &cwd_real);
    const cwd_path = cwd_real[0..cwd_len];
    const entry_abs = try std.fs.path.join(alloc, &.{ cwd_path, extensions_root, id, "versions", active, entry_rel });
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // Resolution (active version, integrity, frozen manifest, tool declaration,
    // exact entry path) is the CLI's job; from here on the helper owns encode,
    // run, decode, and diagnostics.
    const invocation = try invoke.invokeTool(alloc, lenv.environment(), entry_abs, cwd_path, tool, args_json, .{
        .request_id = "cli",
        .timeout_ms = 30_000,
        .max_output_bytes = 1 << 20,
    });
    defer invocation.deinit(alloc);

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
    try printOut(alloc, io, "{s}: current -> {s}\n", .{ id, version });
    return 0;
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
