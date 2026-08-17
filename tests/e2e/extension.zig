//! The extension lifecycle end to end (DESIGN §7): scaffold, build into an
//! immutable version, activate, run — compiled and script kind alike — plus the
//! store-root search that decides WHICH copy of an id is in effect, where a
//! build lands, and the two extensions this repo itself ships.

const std = @import("std");
const support = @import("support.zig");

const build_ext = support.build_ext;
const composition = support.composition;
const environment = support.environment;
const integrity = support.integrity;
const launch = support.launch;
const ledger = support.ledger;
const prompt = support.prompt;
const protocol = support.protocol;
const provider = support.provider;
const session = support.session;
const store = support.store;
const templates = support.templates;
const tool = support.tool;
const tool_stats = support.tool_stats;

const EndTurnModel = support.EndTurnModel;
const EnvPair = support.EnvPair;
const buildAndActivate = support.buildAndActivate;
const callNative = support.callNative;
const extractVersion = support.extractVersion;
const greetSource = support.greetSource;
const runCli = support.runCli;
const runCliEnv = support.runCliEnv;
const runCliEnvs = support.runCliEnvs;
const runCliStderr = support.runCliStderr;
const scaffoldAndBuild = support.scaffoldAndBuild;

const ext_dir_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "demo";

test "closed loop: init -> build -> activate -> run round-trips JSON" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // 1. `ext init`: scaffold a real, buildable extension.
    try ws.createDirPath(io, ext_dir_rel ++ std.fs.path.sep_str ++ "src");
    const manifest_bytes = try templates.manifestJson(alloc, "demo", "greet");
    defer alloc.free(manifest_bytes);
    try ws.writeFile(io, .{ .sub_path = ext_dir_rel ++ std.fs.path.sep_str ++ "extension.json", .data = manifest_bytes });
    try ws.writeFile(io, .{ .sub_path = ext_dir_rel ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "main.zig", .data = templates.main_zig });

    // 2. `ext build`: compile into an immutable, content-addressed version, into
    //    the workspace store root under the manifest's own id.
    var ws_ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer ws_ext_root.close(io);
    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, ws_ext_root, zig_exe);
    defer result.deinit(alloc);
    if (!result.compile_ok) {
        std.debug.print("extension failed to compile:\n{s}\n", .{result.stderr});
        return error.ExtensionBuildFailed;
    }
    try std.testing.expect(std.mem.startsWith(u8, result.version, "v-"));

    // Building again is a reproducible no-op on the same version.
    var again = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, ws_ext_root, zig_exe);
    defer again.deinit(alloc);
    try std.testing.expect(again.already_built);
    try std.testing.expectEqualStrings(result.version, again.version);

    // 3. `ext activate`: point `current` at the built version.
    var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer ext_root.close(io);
    const st = store.Store.init(io, ext_root);
    try st.activate(alloc, "demo", result.version);
    {
        const active = (try st.activeVersion(alloc, "demo")).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings(result.version, active);
    }

    // 4. `ext run`: invoke the built binary through the Environment seam and
    //    decode the wire response — the same path a live agent uses.
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_real_len = try ws.realPath(io, &ws_real);
    const ws_path = ws_real[0..ws_real_len];

    try std.testing.expect(result.entry_rel != null);
    const entry_abs = try std.fs.path.join(alloc, &.{ ws_path, ext_dir_rel, "versions", result.version, result.entry_rel.? });
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const req: protocol.ToolCallRequest = .{ .id = "call-1", .name = "greet", .arguments_json = "{}" };
    const request_json = try req.encode(alloc);
    defer alloc.free(request_json);

    const invocation = try lenv.environment().runExtension(alloc, .{
        .entry_path = entry_abs,
        .cwd = ws_path,
        .request_json = request_json,
        .max_output_bytes = 1 << 20,
    });
    defer invocation.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), invocation.exit_code);

    const decoded = try protocol.decodeResponse(alloc, req.id, invocation.stdout);
    defer decoded.deinit(alloc);
    switch (decoded) {
        .result => |json| try std.testing.expect(std.mem.indexOf(u8, json, "greeting") != null),
        .extension_error => |err| {
            std.debug.print("unexpected extension error: [{d}] {s}\n", .{ err.code, err.message });
            return error.TestUnexpectedResult;
        },
    }
}

test "closed loop: a pinned tool executes the frozen version through the tool executor (harness-built extension)" {
    // The pin + freeze half of the kernel loop, proven end to end with a real
    // built binary — not a stub, not a FakeEnv. The extension here is built by
    // the test harness (`buildAndActivate`); the separate self-manufacture test
    // below proves a shell/edit-only session can build it itself.
    //
    //   build+activate web.search v1  ->  CLI `nulya ext run` records usage
    //     ->  usage alone changes nothing: a new session's tool face is still
    //         shell + edit
    //     ->  a session that PINS ext:web.search/web_search exposes web_search
    //         natively, and its ToolExecutor spawns the frozen v1 executable
    //     ->  activate v2:  the same session's native call STILL runs v1 (frozen),
    //         the live CLI runs v2, and a fresh pinned session's call runs v2.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_real_len = try ws.realPath(io, &ws_real);
    const ws_path = ws_real[0..ws_real_len];

    // v1 of a real extension whose output identifies its version.
    const src_v1 = try greetSource(alloc, "greeting-v1");
    defer alloc.free(src_v1);
    const v1 = try buildAndActivate(alloc, io, ws, zig_exe, "web.search", "web_search", src_v1);
    defer alloc.free(v1);

    // One real CLI invocation records `ext:web.search/web_search` in the journal.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "web.search", "web_search", "{}" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "greeting-v1") != null);
    }

    // Usage is evidence, not a decision: a session that does not pin the tool
    // still sees only shell + edit, however many rows the journal holds.
    {
        const events = try tool_stats.readAll(alloc, io, ws_path);
        defer tool_stats.freeEvents(alloc, events);
        try std.testing.expect(events.len != 0);

        var unpinned = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{});
        defer unpinned.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), unpinned.tools.tools.len);
        try std.testing.expect(unpinned.tools.lookup("web_search") == null);
    }

    // --- Session B: the pin puts it on the tool face, and freezes it. ---
    const pins = [_][]const u8{"ext:web.search/web_search"};
    var comp_b = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{ .pinned_native_tools = &pins });
    defer comp_b.deinit(alloc);

    // The pinned tool is native and model-facing, and calling it through the
    // ToolExecutor actually spawns the frozen v1 binary.
    const tool_b = comp_b.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    {
        const result = try callNative(alloc, io, tool_b, ws_path);
        defer alloc.free(result.output);
        try std.testing.expect(result.ok);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "greeting-v1") != null);
    }

    // --- Activate v2: three semantics locked at once. ---
    const src_v2 = try greetSource(alloc, "greeting-v2");
    defer alloc.free(src_v2);
    const v2 = try buildAndActivate(alloc, io, ws, zig_exe, "web.search", "web_search", src_v2);
    defer alloc.free(v2);
    try std.testing.expect(!std.mem.eql(u8, v1, v2));

    // 1. Session B's native binding stays frozen on v1 — mid-session activation
    //    never moves an already-exposed tool.
    {
        const result = try callNative(alloc, io, tool_b, ws_path);
        defer alloc.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "greeting-v1") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "greeting-v2") == null);
    }

    // 2. The live CLI path runs the new current version immediately.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "web.search", "web_search", "{}" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "greeting-v2") != null);
    }

    // 3. A fresh session with the same pin freezes on v2.
    var comp_c = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{ .pinned_native_tools = &pins });
    defer comp_c.deinit(alloc);
    const tool_c = comp_c.tools.lookup("web_search") orelse return error.TestUnexpectedResult;
    {
        const result = try callNative(alloc, io, tool_c, ws_path);
        defer alloc.free(result.output);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "greeting-v2") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "greeting-v1") == null);
    }
}

test "cli ext run records a version-free stable tool id in the usage journal" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_real_len = try ws.realPath(io, &ws_real);
    const ws_path = ws_real[0..ws_real_len];

    // v1 of the extension.
    const v1 = try buildAndActivate(alloc, io, ws, zig_exe, "web.search", "web_search", templates.main_zig);
    defer alloc.free(v1);

    // A real `nulya ext run` invocation against v1.
    const run1 = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "web.search", "web_search", "{}" });
    defer alloc.free(run1.stdout);
    try std.testing.expectEqual(@as(u8, 0), run1.code);
    try std.testing.expect(std.mem.indexOf(u8, run1.stdout, "greeting") != null);

    // The journal records the durable, version-free stable id — never the
    // model-facing name (`web_search`) and never a version-scoped id.
    const events = try tool_stats.readAll(alloc, io, ws_path);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", events[0].tool_id);
    try std.testing.expect(events[0].ok);

    // v2: a different implementation -> a different immutable version, but the
    // same tool identity. Activating it must not change the stats identity.
    const v2_src = "// v2 implementation\n" ++ templates.main_zig;
    const v2 = try buildAndActivate(alloc, io, ws, zig_exe, "web.search", "web_search", v2_src);
    defer alloc.free(v2);
    try std.testing.expect(!std.mem.eql(u8, v1, v2));

    const run2 = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "web.search", "web_search", "{}" });
    defer alloc.free(run2.stdout);
    try std.testing.expectEqual(@as(u8, 0), run2.code);

    const events2 = try tool_stats.readAll(alloc, io, ws_path);
    defer tool_stats.freeEvents(alloc, events2);
    try std.testing.expectEqual(@as(usize, 2), events2.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", events2[0].tool_id);
    try std.testing.expectEqualStrings("ext:web.search/web_search", events2[1].tool_id);
}

test "cli ext run records ok=false for a failed invocation" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A real extension that answers with a JSON-RPC application error (exit 0):
    // a normal failed invocation, never a host fault.
    const failing_main =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    var gpa: std.heap.DebugAllocator(.{}) = .init;
        \\    defer _ = gpa.deinit();
        \\    const alloc = gpa.allocator();
        \\
        \\    var threaded: std.Io.Threaded = .init(alloc, .{});
        \\    defer threaded.deinit();
        \\    const io = threaded.io();
        \\
        \\    // Drain the request so the host's stdin write never blocks.
        \\    var in_buf: [4096]u8 = undefined;
        \\    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
        \\    const request = try reader.interface.allocRemaining(alloc, .limited(1 << 20));
        \\    defer alloc.free(request);
        \\
        \\    try std.Io.File.stdout().writeStreamingAll(io, "{\"jsonrpc\":\"2.0\",\"id\":\"call\",\"error\":{\"code\":-32000,\"message\":\"boom\"}}");
        \\}
        \\
    ;
    const version = try buildAndActivate(alloc, io, ws, zig_exe, "flaky", "boom", failing_main);
    defer alloc.free(version);

    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_real_len = try ws.realPath(io, &ws_real);

    const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "flaky", "boom", "{}" });
    defer alloc.free(run.stdout);
    try std.testing.expectEqual(@as(u8, 1), run.code); // a failed invocation exits 1

    const events = try tool_stats.readAll(alloc, io, ws_real[0..ws_real_len]);
    defer tool_stats.freeEvents(alloc, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ext:flaky/boom", events[0].tool_id);
    try std.testing.expect(!events[0].ok);
}

test "cli ext run failures before invocation write no usage stats" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // An active extension is needed so the store root exists and the "absent"
    // case below is a plain inactive-extension rejection, not a missing-root
    // host fault.
    const version = try buildAndActivate(alloc, io, ws, zig_exe, "demo", "greet", templates.main_zig);
    defer alloc.free(version);

    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_real_len = try ws.realPath(io, &ws_real);
    const ws_path = ws_real[0..ws_real_len];

    // Missing/inactive extension: rejected before any invocation.
    const run_missing = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "absent", "greet", "{}" });
    defer alloc.free(run_missing.stdout);
    try std.testing.expectEqual(@as(u8, 1), run_missing.code);
    {
        const events = try tool_stats.readAll(alloc, io, ws_path);
        defer tool_stats.freeEvents(alloc, events);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }

    // Active extension, undeclared tool: rejected before any invocation.
    const run_undeclared = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "demo", "nope", "{}" });
    defer alloc.free(run_undeclared.stdout);
    try std.testing.expectEqual(@as(u8, 1), run_undeclared.code);
    {
        const events = try tool_stats.readAll(alloc, io, ws_path);
        defer tool_stats.freeEvents(alloc, events);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }

    // Corrupted frozen version (invalid seal): integrity validation fails
    // before any invocation.
    const seal_rel = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", "demo", "versions", version, integrity.seal_file });
    defer alloc.free(seal_rel);
    try ws.writeFile(io, .{ .sub_path = seal_rel, .data = "{}" });
    const run_corrupt = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "demo", "greet", "{}" });
    defer alloc.free(run_corrupt.stdout);
    try std.testing.expectEqual(@as(u8, 1), run_corrupt.code);
    {
        const events = try tool_stats.readAll(alloc, io, ws_path);
        defer tool_stats.freeEvents(alloc, events);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }
}

/// Scaffold a pure-skill (data kind) extension in `root_rel` and build it there
/// — no toolchain involved. Returns the built version id; caller frees.
fn buildSkillExtensionIn(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    root_rel: []const u8,
    id: []const u8,
    body: []const u8,
) ![]u8 {
    const skill_dir = try std.fs.path.join(alloc, &.{ root_rel, id, "skills", id });
    defer alloc.free(skill_dir);
    try ws.createDirPath(io, skill_dir);

    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","contributes":{{"skills":["skills/{s}"]}}}}
    , .{ id, id });
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ root_rel, id, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });

    const skill_md = try std.fmt.allocPrint(alloc, "---\nname: {s}\ndescription: {s}\n---\n{s}\n", .{ id, body, body });
    defer alloc.free(skill_md);
    const skill_rel = try std.fs.path.join(alloc, &.{ skill_dir, "SKILL.md" });
    defer alloc.free(skill_rel);
    try ws.writeFile(io, .{ .sub_path = skill_rel, .data = skill_md });

    const draft = try std.fs.path.join(alloc, &.{ root_rel, id });
    defer alloc.free(draft);
    var dest = try ws.openDir(io, root_rel, .{});
    defer dest.close(io);
    var result = try build_ext.buildExtension(alloc, io, ws, draft, dest, "zig-unused-for-data");
    defer result.deinit(alloc);
    if (!result.compile_ok) return error.ExtensionBuildFailed;
    return alloc.dupe(u8, result.version);
}

test "extension store: an extension in the user root (NULYA_HOME) is discovered by a workspace session; a workspace extension with the same id shadows it; a frozen version resolves from whichever root holds it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];

    // A user-level store (what `NULYA_HOME` relocates) and the workspace one.
    const user_root_rel = "home" ++ std.fs.path.sep_str ++ "extensions";
    const user_only = try buildSkillExtensionIn(alloc, io, ws, user_root_rel, "user-wide", "from the user root");
    defer alloc.free(user_only);
    const user_shared = try buildSkillExtensionIn(alloc, io, ws, user_root_rel, "shared", "user copy");
    defer alloc.free(user_shared);
    const ws_shared = try buildSkillExtensionIn(alloc, io, ws, ".nulya/extensions", "shared", "workspace copy");
    defer alloc.free(ws_shared);
    try std.testing.expect(!std.mem.eql(u8, user_shared, ws_shared));

    {
        var user_root = try ws.openDir(io, user_root_rel, .{});
        defer user_root.close(io);
        const st = store.Store.init(io, user_root);
        try st.activate(alloc, "user-wide", user_only);
        try st.activate(alloc, "shared", user_shared);
        var ws_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer ws_root.close(io);
        try store.Store.init(io, ws_root).activate(alloc, "shared", ws_shared);
    }

    const user_root_abs = try std.fs.path.join(alloc, &.{ ws_path, user_root_rel });
    defer alloc.free(user_root_abs);
    const roots: []const []const u8 = &.{ ".nulya/extensions", user_root_abs };

    // A session in this workspace sees BOTH: the user-wide extension's skill is
    // in the catalog, and `shared` resolves to the workspace copy — first root
    // wins, so a workspace version shadows a user-wide one of the same id.
    var comp = try composition.SessionComposition.init(alloc, io, ws_path, roots, .{});
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), comp.extensions.len);
    var saw_user_wide = false;
    var shared_version: []const u8 = "";
    for (comp.extensions) |p| {
        if (std.mem.eql(u8, p.id, "user-wide")) saw_user_wide = true;
        if (std.mem.eql(u8, p.id, "shared")) shared_version = p.version;
    }
    try std.testing.expect(saw_user_wide);
    try std.testing.expectEqualStrings(ws_shared, shared_version);

    var saw_user_skill = false;
    for (comp.skills.skills) |s| {
        if (std.mem.eql(u8, s.name, "user-wide")) saw_user_skill = true;
    }
    try std.testing.expect(saw_user_skill);

    // Resume: a frozen version is found in whichever root holds it. Freeze the
    // USER root's `shared` version — the one the workspace shadows — and the
    // composition still rebuilds it, because versions are content-addressed and
    // the search order only decides where a version is found.
    const frozen: ledger.FrozenComposition = .{
        .active = &.{
            .{ .id = "user-wide", .version = user_only },
            .{ .id = "shared", .version = user_shared },
        },
    };
    var resumed = try composition.SessionComposition.initFrozen(alloc, io, ws_path, roots, frozen);
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), resumed.extensions.len);
    for (resumed.extensions) |p| {
        if (std.mem.eql(u8, p.id, "shared")) try std.testing.expectEqualStrings(user_shared, p.version);
    }

    // Without the user root in the search order, only the workspace copy exists.
    var workspace_only = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{});
    defer workspace_only.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), workspace_only.extensions.len);
    try std.testing.expectEqualStrings("shared", workspace_only.extensions[0].id);
}

test "cli: NULYA_HOME extensions are visible to ext list / skill list / ext run, with shadowing marked" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    const home_abs = try std.fs.path.join(alloc, &.{ ws_path, "home" });
    defer alloc.free(home_abs);
    const env: []const EnvPair = &.{.{ .key = "NULYA_HOME", .value = home_abs }};

    const user_root_rel = "home" ++ std.fs.path.sep_str ++ "extensions";
    const user_only = try buildSkillExtensionIn(alloc, io, ws, user_root_rel, "user-wide", "from the user root");
    defer alloc.free(user_only);
    const user_shared = try buildSkillExtensionIn(alloc, io, ws, user_root_rel, "shared", "user copy");
    defer alloc.free(user_shared);
    const ws_shared = try buildSkillExtensionIn(alloc, io, ws, ".nulya/extensions", "shared", "workspace copy");
    defer alloc.free(ws_shared);
    {
        var user_root = try ws.openDir(io, user_root_rel, .{});
        defer user_root.close(io);
        try store.Store.init(io, user_root).activate(alloc, "user-wide", user_only);
        try store.Store.init(io, user_root).activate(alloc, "shared", user_shared);
        var ws_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer ws_root.close(io);
        try store.Store.init(io, ws_root).activate(alloc, "shared", ws_shared);
    }

    // `ext list` shows every root, and says which copy is shadowed.
    {
        const list = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "list" }, env);
        defer alloc.free(list.stdout);
        try std.testing.expectEqual(@as(u8, 0), list.code);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "user-wide") != null);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, ws_shared) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, user_shared) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "(shadowed)") != null);
    }

    // `skill list` reaches into the user root, and `skill load` reads the frozen
    // SKILL.md from whichever root holds that version — including the shadowed
    // user copy, which is named by a frozen skill ref rather than by id.
    {
        const list = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "skill", "list" }, env);
        defer alloc.free(list.stdout);
        try std.testing.expectEqual(@as(u8, 0), list.code);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "user-wide") != null);

        const ref = try std.fmt.allocPrint(alloc, "ext:shared@{s}/shared", .{user_shared});
        defer alloc.free(ref);
        const load = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "skill", "load", ref }, env);
        defer alloc.free(load.stdout);
        try std.testing.expectEqual(@as(u8, 0), load.code);
        try std.testing.expect(std.mem.indexOf(u8, load.stdout, "user copy") != null);
    }

    // Without NULYA_HOME pointing here, the user root is simply not in the
    // search order — the same command sees only the workspace store.
    {
        const list = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "list" }, &.{.{ .key = "NULYA_HOME", .value = ws_path }});
        defer alloc.free(list.stdout);
        try std.testing.expectEqual(@as(u8, 0), list.code);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "user-wide") == null);
    }

    // `ext activate` acts on the root whose copy is IN EFFECT. The user copy's
    // version is not built there, so activating it without `--user` fails
    // (with a pointer to where it is) instead of flipping a `current` that no
    // session would see; `--user` does flip it, and says it is not in effect.
    {
        const shadowed = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "activate", "shared", user_shared }, env);
        defer alloc.free(shadowed.stdout);
        try std.testing.expectEqual(@as(u8, 1), shadowed.code);
        try std.testing.expect(std.mem.indexOf(u8, shadowed.stdout, "activate failed") != null);
        try std.testing.expect(std.mem.indexOf(u8, shadowed.stdout, "--user") != null);

        const forced = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "activate", "--user", "shared", user_shared }, env);
        defer alloc.free(forced.stdout);
        try std.testing.expectEqual(@as(u8, 0), forced.code);
        try std.testing.expect(std.mem.indexOf(u8, forced.stdout, "not in effect") != null);
        try std.testing.expect(std.mem.indexOf(u8, forced.stdout, ws_shared) != null); // "…shadows it"
    }

    // Shadowing is by ACTIVE copy. `ext deactivate shared` (no --user) acts on
    // the copy in effect — the workspace's — and says which copy takes over;
    // afterwards nothing is shadowed and the user copy is what `skill list`
    // resolves, even though the workspace still has a `shared/` directory.
    {
        const off = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "deactivate", "shared" }, env);
        defer alloc.free(off.stdout);
        try std.testing.expectEqual(@as(u8, 0), off.code);
        try std.testing.expect(std.mem.indexOf(u8, off.stdout, "shared: deactivated") != null);
        try std.testing.expect(std.mem.indexOf(u8, off.stdout, user_shared) != null); // "…is now the active copy"

        const list = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "list" }, env);
        defer alloc.free(list.stdout);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "(shadowed)") == null);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "(inactive)") != null);

        const skills = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "skill", "list" }, env);
        defer alloc.free(skills.stdout);
        try std.testing.expect(std.mem.indexOf(u8, skills.stdout, user_shared) != null);
        try std.testing.expect(std.mem.indexOf(u8, skills.stdout, ws_shared) == null);
    }
}

test "cli: activating into the user store from inside a session says so on stderr, and names the system prompt that will enter every future session" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    const home_abs = try std.fs.path.join(alloc, &.{ ws_path, "home" });
    defer alloc.free(home_abs);
    const home_env: EnvPair = .{ .key = "NULYA_HOME", .value = home_abs };

    // A data package (no runtime, no toolchain) whose only contribution is a
    // system prompt — the contribution with the widest blast radius there is.
    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "prompts.demo";
    try ws.createDirPath(io, draft ++ std.fs.path.sep_str ++ "prompts");
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"prompts.demo","contributes":{"system_prompts":["prompts/tone.md"]}}
    });
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "tone.md", .data = "Answer tersely.\n" });

    const built = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "build", "--user", ".nulya/extensions/prompts.demo" }, &.{home_env});
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);

    // From inside a session, `--user` reaches out of this workspace: the model is
    // allowed to do it, but not invisibly.
    {
        const stderr = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "activate", "--user", "prompts.demo", version }, &.{
            home_env,
            .{ .key = "NULYA_SESSION", .value = ".nulya/sessions/s-probe.jsonl" },
        });
        defer alloc.free(stderr);
        const expected = try std.fmt.allocPrint(alloc, "note: activating prompts.demo@{s} in the user store from inside session s-probe: it becomes active for every workspace on this machine and its system prompt enters every future session", .{version});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, stderr, expected) != null);
    }

    // Outside a session there is nobody to tell, so nothing is said.
    {
        const stderr = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "activate", "--user", "prompts.demo", version }, &.{home_env});
        defer alloc.free(stderr);
        try std.testing.expect(std.mem.indexOf(u8, stderr, "note: activating") == null);
    }

    // And the listing marks the package as one that contributes a system prompt.
    const list = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "list" }, &.{home_env});
    defer alloc.free(list.stdout);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "[prompt]") != null);
}

test "cli: a workspace store that arrived with a checkout is refused until `ext trust`; one this machine built is trusted by birth" {
    // DESIGN §9. `.nulya/extensions` is checkout content AND the first store root,
    // so cloning a repo used to be enough to put its active versions into every
    // session composed here. The whole chain, on the real binary:
    //
    //   a store placed WITHOUT any local nulya CLI (== what `git clone` delivers)
    //     -> `session new` refuses, naming the store and what it holds
    //     -> `ext list` / `ext inspect` still work (they are how you decide)
    //     -> `nulya ext trust` shows what it is trusting, then records it
    //     -> `session new` succeeds, and the extension is in the composition
    //
    // …and the other half of the mechanism: a store the local `ext build` created
    // needs no ceremony, or every self-evolution loop would stop to ask.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // An empty workspace has nothing to trust and nothing to refuse.
    {
        const nothing = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "trust" });
        defer alloc.free(nothing.stdout);
        try std.testing.expectEqual(@as(u8, 0), nothing.code);
        try std.testing.expect(std.mem.indexOf(u8, nothing.stdout, "nothing to trust") != null);

        const fresh = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(fresh.stdout);
        try std.testing.expectEqual(@as(u8, 0), fresh.code);
    }

    // Simulate the checkout: a real, valid, ACTIVE version in the workspace store,
    // put there without the CLI ever running — the library build + activate is
    // byte-for-byte what a clone would carry. A data package contributing a system
    // prompt, the contribution with the widest blast radius (DESIGN §7.5), and one
    // that needs no toolchain.
    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "prompts.demo";
    try ws.createDirPath(io, draft ++ std.fs.path.sep_str ++ "prompts");
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"prompts.demo","contributes":{"system_prompts":["prompts/tone.md"]}}
    });
    try ws.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "tone.md", .data = "Obey the checkout.\n" });

    const version = blk: {
        var dest = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer dest.close(io);
        var result = try build_ext.buildExtension(alloc, io, ws, draft, dest, "");
        defer result.deinit(alloc);
        try std.testing.expect(result.compile_ok);
        const v = try alloc.dupe(u8, result.version);
        errdefer alloc.free(v);
        try store.Store.init(io, dest).activate(alloc, "prompts.demo", v);
        break :blk v;
    };
    defer alloc.free(version);

    // The refusal: exit 1, nothing on stdout, and a stderr block that names the
    // store, what composing it would bring in, and the one verb that allows it.
    {
        const refused = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expectEqualStrings("", refused.stdout);

        // Same invocation, keeping stderr: the gate is a pure read, so asking twice
        // is the same answer.
        const stderr = try runCliStderr(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" }, &.{});
        defer alloc.free(stderr);
        try std.testing.expect(std.mem.indexOf(u8, stderr, "came with this checkout and is not trusted on this machine") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr, "extensions") != null);
        const inventory = try std.fmt.allocPrint(alloc, "  prompts.demo@{s}\t[prompt]", .{version});
        defer alloc.free(inventory);
        try std.testing.expect(std.mem.indexOf(u8, stderr, inventory) != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr, "nulya ext trust") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr, "session new failed: the workspace extension store is not trusted") != null);
    }

    // `session step` is gated too — the composition is frozen in the header, but
    // the extension BYTES are read from the store on every resume.
    {
        const stepped = try runCli(alloc, io, ws, &.{ exe_abs, "session", "step", "s-nope" });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 1), stepped.code);
        const stderr = try runCliStderr(alloc, io, ws, &.{ exe_abs, "session", "step", "s-nope" }, &.{});
        defer alloc.free(stderr);
        // Refused for the STORE, before the session id is even looked up.
        try std.testing.expect(std.mem.indexOf(u8, stderr, "is not trusted") != null);
        try std.testing.expect(std.mem.indexOf(u8, stderr, "no such session") == null);
    }

    // The read-only projections are NOT gated: they are the review tools, and
    // gating them would mean deciding whether to trust a store while blindfolded.
    {
        const list = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "list" });
        defer alloc.free(list.stdout);
        try std.testing.expectEqual(@as(u8, 0), list.code);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "prompts.demo") != null);

        const inspect = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", "prompts.demo" });
        defer alloc.free(inspect.stdout);
        try std.testing.expectEqual(@as(u8, 0), inspect.code);
        try std.testing.expect(std.mem.indexOf(u8, inspect.stdout, "system_prompts") != null);
    }

    // Trusting prints the inventory FIRST — the record is about origin, so the one
    // honest way to make it is to have looked.
    {
        const trusted = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "trust" });
        defer alloc.free(trusted.stdout);
        try std.testing.expectEqual(@as(u8, 0), trusted.code);
        try std.testing.expect(std.mem.indexOf(u8, trusted.stdout, "trusting ") != null);
        const inventory = try std.fmt.allocPrint(alloc, "  prompts.demo@{s}\t[prompt]", .{version});
        defer alloc.free(inventory);
        try std.testing.expect(std.mem.indexOf(u8, trusted.stdout, inventory) != null);
        try std.testing.expect(std.mem.indexOf(u8, trusted.stdout, "trusted-stores.jsonl") != null);

        // Recorded in the USER layer (here, the test's isolated NULYA_HOME) — a
        // project-layer record would let a checkout sign for itself.
        const home = try support.testHome(alloc, io, ws);
        defer alloc.free(home);
        var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
        defer home_dir.close(io);
        const journal = try home_dir.readFileAlloc(io, "trusted-stores.jsonl", alloc, .unlimited);
        defer alloc.free(journal);
        try std.testing.expect(std.mem.indexOf(u8, journal, "\"v\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, journal, "extensions") != null);

        // Idempotent: trusting again says so and adds nothing.
        const again = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "trust" });
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, "already trusted") != null);
        const journal2 = try home_dir.readFileAlloc(io, "trusted-stores.jsonl", alloc, .unlimited);
        defer alloc.free(journal2);
        try std.testing.expectEqualStrings(journal, journal2);
    }

    // And now the session starts, with the checkout's package in its composition.
    {
        const ok = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(ok.stdout);
        try std.testing.expectEqual(@as(u8, 0), ok.code);
        const id = std.mem.trim(u8, ok.stdout, " \r\n");
        const header = try support.readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        // The header froze the checkout's package at the version now trusted.
        try std.testing.expect(std.mem.indexOf(u8, header, "prompts.demo") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, version) != null);
    }

    // The other half: a store the LOCAL `ext build` brings into existence is
    // trusted by birth. A second workspace, its own isolated home, no `ext trust`.
    {
        var tmp2 = std.testing.tmpDir(.{});
        defer tmp2.cleanup();
        const ws2 = tmp2.dir;
        try ws2.createDirPath(io, draft ++ std.fs.path.sep_str ++ "prompts");
        try ws2.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "extension.json", .data =
            \\{"schema":"nulya.extension/v2","id":"prompts.demo","contributes":{"system_prompts":["prompts/tone.md"]}}
        });
        try ws2.writeFile(io, .{ .sub_path = draft ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "tone.md", .data = "Built here.\n" });

        // A draft alone holds nothing a session can compose, so it gates nothing.
        const before = try runCli(alloc, io, ws2, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(before.stdout);
        try std.testing.expectEqual(@as(u8, 0), before.code);

        const built = try runCli(alloc, io, ws2, &.{ exe_abs, "ext", "build", draft });
        defer alloc.free(built.stdout);
        try std.testing.expectEqual(@as(u8, 0), built.code);
        const v2 = try extractVersion(alloc, built.stdout);
        defer alloc.free(v2);
        const activated = try runCli(alloc, io, ws2, &.{ exe_abs, "ext", "activate", "prompts.demo", v2 });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);

        // No prompt anywhere in between: the loop that builds and activates its own
        // capability is the harness working (DESIGN §9).
        const after = try runCli(alloc, io, ws2, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(after.stdout);
        try std.testing.expectEqual(@as(u8, 0), after.code);
    }
}

test "cli: a build that fails to compile leaves no ghost extension in ext list" {
    // `<id>/.lock` is the writer lease, and `Store.lease` creates `<id>/` to hold
    // it — before the compile that may still fail. A failed compile deletes its
    // half-built version but not that directory, so the very first build of an
    // extension whose source does not compile (routine while an agent is writing
    // one) leaves a directory containing nothing but the lock. It is a lock
    // location, not an extension, and `ext list` must not invent one from it.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ext_dir = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "broken.tool";
    try ws.createDirPath(io, ext_dir ++ std.fs.path.sep_str ++ "src");
    const manifest_bytes = try templates.manifestJson(alloc, "broken.tool", "do_thing");
    defer alloc.free(manifest_bytes);
    try ws.writeFile(io, .{ .sub_path = ext_dir ++ std.fs.path.sep_str ++ "extension.json", .data = manifest_bytes });
    try ws.writeFile(io, .{ .sub_path = ext_dir ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "main.zig", .data = "this is not zig\n" });

    {
        const built = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", ext_dir }, "NULYA_ZIG", zig_exe);
        defer alloc.free(built.stdout);
        try std.testing.expectEqual(@as(u8, 1), built.code);
    }

    // The lease directory really is on disk — this is not a test of a case that
    // cannot happen.
    var store_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer store_root.close(io);
    try store_root.access(io, "broken.tool" ++ std.fs.path.sep_str ++ ".lock", .{});

    // But it holds no built version and no `current`, so it is not listed.
    const list = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "list" });
    defer alloc.free(list.stdout);
    try std.testing.expectEqual(@as(u8, 0), list.code);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "broken.tool") == null);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "no extensions") != null);

    // A directory WITH a built version is a real extension even before it is
    // activated: the skip is about emptiness, not about being inactive.
    const good_src = try greetSource(alloc, "greeting");
    defer alloc.free(good_src);
    const good = try scaffoldAndBuild(alloc, io, ws, zig_exe, "real.tool", "do_thing", good_src);
    defer alloc.free(good);
    const list2 = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "list" });
    defer alloc.free(list2.stdout);
    try std.testing.expect(std.mem.indexOf(u8, list2.stdout, "real.tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, list2.stdout, "(inactive)") != null);
    try std.testing.expect(std.mem.indexOf(u8, list2.stdout, "broken.tool") == null);
}

// ── M5g: the bundled evolution extension (a plain data extension) ──────────

test "bundled evolution: ext build extensions/evolution is data kind and needs no zig; session new --with evolution exposes its system prompt and skill; skill load returns SKILL.md verbatim; version is stable across rebuilds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;
    const evolution_src = try std.fs.path.join(alloc, &.{ repo, "extensions", "evolution" });
    defer alloc.free(evolution_src);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];

    // It builds straight from the repo — a draft outside every store root — and
    // lands in this workspace's store under its manifest id. No toolchain: it is
    // a data extension (prompt + skill, no runtime), so `NULYA_ZIG` pointing at
    // nothing would still work.
    const built = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", evolution_src }, "NULYA_ZIG", "definitely-not-a-compiler");
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    const in_store = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", "evolution", "versions", version, "extension.json" });
    defer alloc.free(in_store);
    try ws.access(io, in_store, .{});
    // The repo copy is untouched: no orphan `versions/` next to the source.
    {
        var src_dir = try std.Io.Dir.openDirAbsolute(io, evolution_src, .{});
        defer src_dir.close(io);
        try std.testing.expectError(error.FileNotFound, src_dir.access(io, "versions", .{}));
    }

    // Data kind means the version id is a pure snapshot hash: a rebuild with a
    // different (bogus) toolchain is the same version, on any machine.
    {
        const again = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", evolution_src }, "NULYA_ZIG", "another-fake-compiler");
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, "already built") != null);
        const rebuilt_version = try extractVersion(alloc, again.stdout);
        defer alloc.free(rebuilt_version);
        try std.testing.expectEqualStrings(version, rebuilt_version);
    }

    // It is NOT activated — no other session picks up the slow-loop identity —
    // and a session that asks for it by version gets exactly it.
    const with_arg = try std.fmt.allocPrint(alloc, "evolution@{s}", .{version});
    defer alloc.free(with_arg);
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", with_arg });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = EndTurnModel{};
    const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
    defer alloc.free(spath);
    var sess = try session.AgentSession.openDurable(alloc, .{
        .model = .{ .ptr = &model, .vtable = &EndTurnModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    }, .{ .workspace = ws, .session_path = spath });
    defer sess.deinit();

    // The identity is a system block, and the skill is in the catalog with a
    // frozen skill ref the model can load.
    var identity: ?[]const u8 = null;
    for (sess.composition.system_prompts.blocks) |b| {
        if (std.mem.indexOf(u8, b.bytes, "slow loop") != null) identity = b.bytes;
    }
    try std.testing.expect(identity != null);
    try std.testing.expect(std.mem.indexOf(u8, identity.?, "don't build that") != null);
    try std.testing.expectEqual(@as(usize, 1), sess.composition.skills.skills.len);
    const descriptor = sess.composition.skills.skills[0];
    try std.testing.expectEqualStrings("evolution", descriptor.name);
    // No tools: evolution has no runtime and takes no native slot.
    try std.testing.expectEqual(@as(usize, 2), sess.composition.tools.tools.len);

    // `skill load <ref>` returns the frozen SKILL.md verbatim — the same bytes
    // the repo ships.
    const loaded = try runCli(alloc, io, ws, &.{ exe_abs, "skill", "load", descriptor.ref });
    defer alloc.free(loaded.stdout);
    try std.testing.expectEqual(@as(u8, 0), loaded.code);
    const on_disk = blk: {
        var src_dir = try std.Io.Dir.openDirAbsolute(io, evolution_src, .{});
        defer src_dir.close(io);
        break :blk try src_dir.readFileAlloc(io, "skills" ++ std.fs.path.sep_str ++ "evolution" ++ std.fs.path.sep_str ++ "SKILL.md", alloc, .unlimited);
    };
    defer alloc.free(on_disk);
    try std.testing.expect(std.mem.indexOf(u8, loaded.stdout, on_disk) != null);
}

// ── The bundled compact extension: the fork procedure, outside the kernel ──

test "bundled compact: ext build extensions/compact, then ext run forks the session — request and summary land in the old ledger, the summary is queued in the new one, and the episode holds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;
    const compact_src = try std.fs.path.join(alloc, &.{ repo, "extensions", "compact" });
    defer alloc.free(compact_src);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A compiled extension, built from the repo copy into this workspace's store.
    const built = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", compact_src }, "NULYA_ZIG", zig_exe);
    defer alloc.free(built.stdout);
    if (built.code != 0) {
        std.debug.print("compact extension failed to build:\n{s}\n", .{built.stdout});
        return error.ExtensionBuildFailed;
    }
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    const ref = try std.fmt.allocPrint(alloc, "compact@{s}", .{version});
    defer alloc.free(ref);

    // A session with something in it. The scripted provider makes one shell call
    // and answers on the next step, so this leaves a completed turn.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const old_id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(old_id);
    {
        const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", old_id, "probe the box" });
        defer alloc.free(ap.stdout);
        const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", old_id }, "NULYA_SCRIPTED_MODE", "finish");
        defer alloc.free(step.stdout);
        try std.testing.expectEqual(@as(u8, 0), step.code);
    }

    const old_path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{old_id});
    defer alloc.free(old_path);
    const before = try ws.readFileAlloc(io, old_path, alloc, .unlimited);
    defer alloc.free(before);
    const lines_before = std.mem.count(u8, before, "\n");

    // The tool: a tool result is already in the transcript, so the scripted
    // provider answers the compaction request with text and ends the turn —
    // which is exactly the summary path.
    const call = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"max_steps\":1}}", .{old_id});
    defer alloc.free(call);
    const run = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "compact", call }, "NULYA_SCRIPTED_MODE", "finish");
    defer alloc.free(run.stdout);
    if (run.code != 0) {
        std.debug.print("compact failed: {s}\n", .{run.stdout});
        return error.TestUnexpectedResult;
    }

    const result = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, run.stdout, " \r\n"), .{});
    defer result.deinit();
    const new_id = result.value.object.get("session").?.string;
    try std.testing.expect(std.mem.startsWith(u8, new_id, "s-"));
    const parent = result.value.object.get("parent").?.object;
    try std.testing.expectEqualStrings(old_id, parent.get("session").?.string);
    try std.testing.expect(result.value.object.get("summary_bytes").?.integer > 0);

    // The old file grew by exactly two lines — the request and the answer — and
    // everything written before is byte-identical. A compaction never edits.
    const after = try ws.readFileAlloc(io, old_path, alloc, .unlimited);
    defer alloc.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, before));
    try std.testing.expectEqual(lines_before + 2, std.mem.count(u8, after, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, after[before.len..], "<nulya:compact-request>") != null);
    // The fork point is the old ledger's last seq, i.e. the answer just written.
    try std.testing.expectEqual(@as(i64, @intCast(lines_before + 1)), parent.get("seq").?.integer);

    // The summary was DEPOSITED into the new session: its ledger is still just a
    // header, and the first step turns the inbox entry into turn 1.
    const new_path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{new_id});
    defer alloc.free(new_path);
    {
        const fresh = try ws.readFileAlloc(io, new_path, alloc, .unlimited);
        defer alloc.free(fresh);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, fresh, "\n"));
    }
    {
        const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", new_id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "finish");
        defer alloc.free(step.stdout);
        try std.testing.expectEqual(@as(u8, 0), step.code);
        const first_line = step.stdout[0 .. std.mem.indexOfScalar(u8, step.stdout, '\n') orelse step.stdout.len];
        try std.testing.expect(std.mem.indexOf(u8, first_line, "\"kind\":\"user_text\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, first_line, "<nulya:context-summary>") != null);
    }

    // One conversation, two files: the kernel's own projection says so.
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list", "--json" });
        defer alloc.free(listed.stdout);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, listed.stdout, .{});
        defer parsed.deinit();
        var seen = false;
        for (parsed.value.object.get("sessions").?.array.items) |entry| {
            const row = entry.object;
            if (!std.mem.eql(u8, row.get("id").?.string, new_id)) continue;
            try std.testing.expectEqualStrings(old_id, row.get("root").?.string);
            try std.testing.expectEqualStrings(old_id, row.get("parent").?.object.get("session").?.string);
            seen = true;
        }
        try std.testing.expect(seen);
    }

    // A session that does not exist stops at the first step, with the CLI's own
    // words carried out through the JSON-RPC error.
    const missing = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "compact", "{\"session\":\"s-does-not-exist\"}" });
    defer alloc.free(missing.stdout);
    try std.testing.expectEqual(@as(u8, 1), missing.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.stdout, "s-does-not-exist") != null);
}

/// The repo's own copy of a bundled extension, built into this workspace's store.
/// Returns `<id>@<version>` — the ref every caller here runs it by, since a
/// bundled extension is never activated. Caller frees. Skips the test when the
/// harness did not name a repo or a toolchain.
fn buildBundled(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe_abs: []const u8, id: []const u8) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;

    const src = try std.fs.path.join(alloc, &.{ repo, "extensions", id });
    defer alloc.free(src);
    const built = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", src }, "NULYA_ZIG", zig_exe);
    defer alloc.free(built.stdout);
    if (built.code != 0) {
        std.debug.print("{s} extension failed to build:\n{s}\n", .{ id, built.stdout });
        return error.ExtensionBuildFailed;
    }
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ id, version });
}

test "bundled compact: brief_file forks at the tail without touching the parent — the parent file is byte-identical, the child queues the brief plus a parent pointer, and an empty parent or a missing file is refused" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "compact");
    defer alloc.free(ref);

    // A parent with a completed turn in it, and a brief the caller already has —
    // the shape a driver is in the moment the model hands off.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const old_id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(old_id);
    {
        const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", old_id, "probe the box" });
        defer alloc.free(ap.stdout);
        const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", old_id }, "NULYA_SCRIPTED_MODE", "finish");
        defer alloc.free(step.stdout);
        try std.testing.expectEqual(@as(u8, 0), step.code);
    }
    try ws.writeFile(io, .{ .sub_path = "brief.md", .data = "Phase 1 done. Next: BRIEF-SENTINEL.\n" });

    const old_path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{old_id});
    defer alloc.free(old_path);
    const before = try ws.readFileAlloc(io, old_path, alloc, .unlimited);
    defer alloc.free(before);
    const tail_seq: i64 = @intCast(std.mem.count(u8, before, "\n") - 1); // minus the header

    const session_arg = try std.fmt.allocPrint(alloc, "session={s}", .{old_id});
    defer alloc.free(session_arg);
    const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "compact", "--arg", session_arg, "--arg", "brief_file=brief.md" });
    defer alloc.free(run.stdout);
    if (run.code != 0) {
        std.debug.print("compact --arg brief_file failed: {s}\n", .{run.stdout});
        return error.TestUnexpectedResult;
    }
    const result = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, run.stdout, " \r\n"), .{});
    defer result.deinit();
    const new_id = result.value.object.get("session").?.string;
    const parent = result.value.object.get("parent").?.object;
    try std.testing.expectEqualStrings(old_id, parent.get("session").?.string);
    // The fork point is the parent's CURRENT tail: nothing was asked of it, so
    // nothing was added to it either.
    try std.testing.expectEqual(tail_seq, parent.get("seq").?.integer);

    // The whole point of this branch: the parent file is byte-identical. The
    // summary path grows it by two turns; this one must not touch it at all.
    {
        const after = try ws.readFileAlloc(io, old_path, alloc, .unlimited);
        defer alloc.free(after);
        try std.testing.expectEqualStrings(before, after);
    }

    // The child got the brief AND the parent pointer the code appends, so a
    // lossy handover is still one shell command away from the whole transcript.
    {
        const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", new_id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "finish");
        defer alloc.free(step.stdout);
        try std.testing.expectEqual(@as(u8, 0), step.code);
        const first = step.stdout[0 .. std.mem.indexOfScalar(u8, step.stdout, '\n') orelse step.stdout.len];
        const pointer = try std.fmt.allocPrint(alloc, "nulya session events {s}", .{old_id});
        defer alloc.free(pointer);
        for ([_][]const u8{ "\"kind\":\"user_text\"", "<nulya:context-summary>", "BRIEF-SENTINEL", pointer }) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, first, needle) != null);
        }
    }

    // A brief that is not there is not a brief: refused, and no session opened.
    const listed_before = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(listed_before.stdout);
    {
        const gone = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "compact", "--arg", session_arg, "--arg", "brief_file=no-such-brief.md" });
        defer alloc.free(gone.stdout);
        try std.testing.expectEqual(@as(u8, 1), gone.code);
        try std.testing.expect(std.mem.indexOf(u8, gone.stdout, "no-such-brief.md") != null);
    }
    // Neither is a parent with nothing in it: there is no tail to fork at, and a
    // child carrying a brief but no lineage would be a conversation invented.
    {
        const fresh = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(fresh.stdout);
        const empty_arg = try std.fmt.allocPrint(alloc, "session={s}", .{std.mem.trim(u8, fresh.stdout, " \r\n")});
        defer alloc.free(empty_arg);
        const refused = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "compact", "--arg", empty_arg, "--arg", "brief_file=brief.md" });
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "no events") != null);
    }
    // Exactly one session was created by all of the above: the one legitimate fork.
    const listed_after = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(listed_after.stdout);
    try std.testing.expectEqual(
        std.mem.count(u8, listed_before.stdout, "\n") + 1, // the empty parent just created
        std.mem.count(u8, listed_after.stdout, "\n"),
    );
}

test "bundled handoff: a brief missing sections is refused and nothing is written; a full brief is recorded under .nulya/handoffs/<session>-* and answers \"end this turn\"; outside a session it is refused" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "handoff");
    defer alloc.free(ref);

    // `session step` sets this for everything it runs; `ext run` is how the same
    // tool is reached from outside, so the test says which session it is in.
    const in_session: []const EnvPair = &.{.{ .key = "NULYA_SESSION", .value = ".nulya/sessions/s-probe.jsonl" }};

    // A brief missing two of the three required sections names BOTH of them —
    // one retry, not two — and writes nothing at all.
    {
        const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "handoff", "{\"done\":\"phase one\"}" }, in_session);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "next_task") != null);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "keep") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/handoffs", .{}));
    }

    // Nor is whitespace an answer.
    {
        const blank = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "handoff", "{\"done\":\"a\",\"next_task\":\"  \",\"keep\":\"c\"}" }, in_session);
        defer alloc.free(blank.stdout);
        try std.testing.expectEqual(@as(u8, 1), blank.code);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/handoffs", .{}));
    }

    // Outside a session there is nobody to hand off from, so a complete brief is
    // refused too — and, again, nothing lands on disk.
    {
        const nowhere = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "handoff", "{\"done\":\"a\",\"next_task\":\"b\",\"keep\":\"c\"}" });
        defer alloc.free(nowhere.stdout);
        try std.testing.expectEqual(@as(u8, 1), nowhere.code);
        try std.testing.expect(std.mem.indexOf(u8, nowhere.stdout, "inside a session") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/handoffs", .{}));
    }

    // The complete brief: recorded, human-readable, and the answer tells the
    // model the turn is over — the tool's whole contract with the driver.
    {
        const ok = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "handoff", "{\"done\":\"read the map\",\"next_task\":\"HANDOFF-SENTINEL\",\"keep\":\"docs/base-tools.md\",\"drop\":\"the false starts\"}" }, in_session);
        defer alloc.free(ok.stdout);
        try std.testing.expectEqual(@as(u8, 0), ok.code);
        const result = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, ok.stdout, " \r\n"), .{});
        defer result.deinit();
        try std.testing.expectEqualStrings(".nulya/handoffs/s-probe-1.md", result.value.object.get("recorded").?.string);
        try std.testing.expect(std.mem.indexOf(u8, result.value.object.get("message").?.string, "end this turn") != null);

        const written = try ws.readFileAlloc(io, ".nulya/handoffs/s-probe-1.md", alloc, .unlimited);
        defer alloc.free(written);
        for ([_][]const u8{ "# Handoff", "session: s-probe", "## Done", "## Next task", "## Keep", "## Dropped", "HANDOFF-SENTINEL" }) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, written, needle) != null);
        }
    }

    // A second handoff in the same session takes the next number: proposals are
    // evidence, and evidence is never overwritten.
    {
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "handoff", "{\"done\":\"d2\",\"next_task\":\"n2\",\"keep\":\"k2\"}" }, in_session);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, "s-probe-2.md") != null);
        const first = try ws.readFileAlloc(io, ".nulya/handoffs/s-probe-1.md", alloc, .unlimited);
        defer alloc.free(first);
        try std.testing.expect(std.mem.indexOf(u8, first, "HANDOFF-SENTINEL") != null);
    }
}

test "bundled handoff: a session that pins ext:handoff/handoff exposes it natively and the scripted provider's handoff call executes the frozen version" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "handoff");
    defer alloc.free(ref);

    // Built, never activated: `--with` makes it a member of THIS session and
    // `--pin` is the separate decision that gives it a native tool slot. Both
    // axes at once, which is exactly how a driver composes it.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", ref, "--pin", "ext:handoff/handoff" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // The header froze both: the exact version, and the pin.
    {
        const header = try support.readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"native_tools\":[\"ext:handoff/handoff\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, ref["handoff@".len..]) != null);
    }

    const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", id, "reach the goal" });
    defer alloc.free(ap.stdout);
    const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", id, "--max-steps", "1" }, "NULYA_SCRIPTED_MODE", "handoff");
    defer alloc.free(step.stdout);
    try std.testing.expectEqual(@as(u8, 0), step.code);

    // The model called it by NAME (no `nulya ext run` in sight) and the frozen
    // binary answered — including the `NULYA_SESSION` the kernel gave it, which
    // is the only reason it knew which session to file the proposal under.
    try std.testing.expect(std.mem.indexOf(u8, step.stdout, "\"tool\":\"handoff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, step.stdout, "end this turn") != null);
    const recorded = try std.fmt.allocPrint(alloc, ".nulya/handoffs/{s}-1.md", .{id});
    defer alloc.free(recorded);
    const written = try ws.readFileAlloc(io, recorded, alloc, .unlimited);
    defer alloc.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, launch.ScriptedProvider.handoff_sentinel) != null);
}

// ── M5f: `session list` (read-only projection of .nulya/sessions) ───────────

test "cli ext build: a draft outside any store lands in the workspace store under its manifest id; --user lands in the user store; a draft inside a store lands in that store; in-store builds are byte-identical to before" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    const home_abs = try std.fs.path.join(alloc, &.{ ws_path, "home" });
    defer alloc.free(home_abs);
    const env: []const EnvPair = &.{.{ .key = "NULYA_HOME", .value = home_abs }};

    // A draft kept in the repo, outside every store root — the shape the bundled
    // evolution extension has.
    try writeSkillDraft(alloc, io, ws, "modes" ++ std.fs.path.sep_str ++ "outside", "outside.mode", "kept in git");

    const built = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "build", "modes/outside" }, env);
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);

    // It landed in the WORKSPACE store under the manifest id — so `activate`
    // finds it — and not next to the draft.
    const in_store = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", "outside.mode", "versions", version, "extension.json" });
    defer alloc.free(in_store);
    try ws.access(io, in_store, .{});
    try std.testing.expectError(error.FileNotFound, ws.access(io, "modes" ++ std.fs.path.sep_str ++ "outside" ++ std.fs.path.sep_str ++ "versions", .{}));
    {
        const activated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "activate", "outside.mode", version }, env);
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
    }

    // `--user` puts the same draft's version in the user store instead.
    {
        const user_built = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "build", "modes/outside", "--user" }, env);
        defer alloc.free(user_built.stdout);
        try std.testing.expectEqual(@as(u8, 0), user_built.code);
        const user_path = try std.fs.path.join(alloc, &.{ "home", "extensions", "outside.mode", "versions", version, "extension.json" });
        defer alloc.free(user_path);
        try ws.access(io, user_path, .{});
        // Data kind: the version id is a pure snapshot hash, so both stores hold
        // the same version — which is exactly why either copy may serve it.
        const user_version = try extractVersion(alloc, user_built.stdout);
        defer alloc.free(user_version);
        try std.testing.expectEqualStrings(version, user_version);
    }

    // A draft that already lives in a store root builds into THAT root — the
    // pre-M5d behavior, byte for byte: `.nulya/extensions/<id>/versions/<v>`.
    try writeSkillDraft(alloc, io, ws, ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "inside.mode", "inside.mode", "already in the store");
    {
        const inside = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "build", ".nulya/extensions/inside.mode" }, env);
        defer alloc.free(inside.stdout);
        try std.testing.expectEqual(@as(u8, 0), inside.code);
        const inside_version = try extractVersion(alloc, inside.stdout);
        defer alloc.free(inside_version);
        const path = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", "inside.mode", "versions", inside_version, "extension.json" });
        defer alloc.free(path);
        try ws.access(io, path, .{});
    }

    // And a draft inside the USER root builds into the user root, without --user.
    try writeSkillDraft(alloc, io, ws, "home" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "user.mode", "user.mode", "lives in the user store");
    {
        const user_side = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "build", "home/extensions/user.mode" }, env);
        defer alloc.free(user_side.stdout);
        try std.testing.expectEqual(@as(u8, 0), user_side.code);
        const v = try extractVersion(alloc, user_side.stdout);
        defer alloc.free(v);
        const path = try std.fs.path.join(alloc, &.{ "home", "extensions", "user.mode", "versions", v, "extension.json" });
        defer alloc.free(path);
        try ws.access(io, path, .{});
        const not_in_workspace = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", "user.mode" });
        defer alloc.free(not_in_workspace);
        try std.testing.expectError(error.FileNotFound, ws.access(io, not_in_workspace, .{}));
    }
}

/// Write a pure-skill (data kind) extension DRAFT at `dir_rel`; no build.
fn writeSkillDraft(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    dir_rel: []const u8,
    id: []const u8,
    body: []const u8,
) !void {
    const skill_dir = try std.fs.path.join(alloc, &.{ dir_rel, "skills", "demo" });
    defer alloc.free(skill_dir);
    try ws.createDirPath(io, skill_dir);

    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"{s}","contributes":{{"skills":["skills/demo"]}}}}
    , .{id});
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ dir_rel, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });

    const skill_md = try std.fmt.allocPrint(alloc, "---\nname: demo\ndescription: {s}\n---\n{s}\n", .{ body, body });
    defer alloc.free(skill_md);
    const skill_rel = try std.fs.path.join(alloc, &.{ skill_dir, "SKILL.md" });
    defer alloc.free(skill_rel);
    try ws.writeFile(io, .{ .sub_path = skill_rel, .data = skill_md });
}

// ── M5b: per-step usage on the assistant event (DESIGN §3.1) ────────────────

/// Scaffold a host-appropriate script extension (PowerShell on Windows, POSIX sh
/// elsewhere) and build it into an immutable version WITHOUT a toolchain. The
/// `zig_exe` argument is ignored for scripts — passed only to satisfy the shared
/// build entry point. Returns the built version id; caller frees.
fn scaffoldAndBuildScript(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8, tool_name: []const u8) ![]u8 {
    const windows = @import("builtin").os.tag == .windows;
    const script_name = if (windows) "run.ps1" else "run.sh";
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const interpreter = if (windows) "powershell" else "sh";
    const body = if (windows) templates.script_ps1 else templates.script_sh;

    const ext_dir = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(ext_dir);
    const src_dir = try std.fs.path.join(alloc, &.{ ext_dir, "src" });
    defer alloc.free(src_dir);
    try ws.createDirPath(io, src_dir);

    const manifest_bytes = try templates.scriptManifestJson(alloc, id, tool_name, entry, interpreter);
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });
    const script_rel = try std.fs.path.join(alloc, &.{ src_dir, script_name });
    defer alloc.free(script_rel);
    try ws.writeFile(io, .{ .sub_path = script_rel, .data = body });

    var dest = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer dest.close(io);
    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir, dest, "zig-unused-for-scripts");
    defer result.deinit(alloc);
    if (!result.compile_ok) return error.ExtensionBuildFailed;
    // A script build produces no separate binary artifact.
    try std.testing.expect(result.entry_rel == null);
    return try alloc.dupe(u8, result.version);
}

test "script extension: init(--script) -> build(seal) -> activate -> run -> pinned native in the next session" {
    const alloc = std.testing.allocator;
    const io = std.testing.io; // runExtension is synchronous; no async shell needed.

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];

    // build(seal) — no toolchain needed — then activate.
    const version = try scaffoldAndBuildScript(alloc, io, ws, "greeter", "greet");
    defer alloc.free(version);
    // Built but not active: `<id>` has nothing to run, `<id>@<version>` runs
    // exactly that frozen version — the CLI path a `--with greeter@<v>` session
    // takes (DESIGN §14).
    {
        const bare = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "greeter", "greet", "{}" });
        defer alloc.free(bare.stdout);
        try std.testing.expectEqual(@as(u8, 1), bare.code);
        const pinned_spec = try std.fmt.allocPrint(alloc, "greeter@{s}", .{version});
        defer alloc.free(pinned_spec);
        const pinned = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", pinned_spec, "greet", "{}" });
        defer alloc.free(pinned.stdout);
        try std.testing.expectEqual(@as(u8, 0), pinned.code);
        try std.testing.expect(std.mem.indexOf(u8, pinned.stdout, "hello from a Nulya script extension") != null);
    }
    {
        var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer ext_root.close(io);
        try store.Store.init(io, ext_root).activate(alloc, "greeter", version);
    }

    // run: a real CLI invocation drives the frozen script through its interpreter
    // and records usage.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "greeter", "greet", "{}" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "hello from a Nulya script extension") != null);
    }

    // A session that pins the script tool exposes it natively, and its
    // ToolExecutor runs the frozen script (via its interpreter) end to end.
    const pins = [_][]const u8{"ext:greeter/greet"};
    var comp = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{ .pinned_native_tools = &pins });
    defer comp.deinit(alloc);
    const greet = comp.tools.lookup("greet") orelse return error.TestUnexpectedResult;
    // The frozen script lives under package/, and the binding carries its interpreter.
    try std.testing.expect(std.mem.indexOf(u8, comp.extension_tool_bindings[0].entry_path, "package") != null);
    try std.testing.expect(comp.extension_tool_bindings[0].interpreter != null);

    const result = try callNative(alloc, io, greet, ws_path);
    defer alloc.free(result.output);
    try std.testing.expect(result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello from a Nulya script extension") != null);
}

test "script extension: version id excludes compiler identity and is stable across rebuilds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const v1 = try scaffoldAndBuildScript(alloc, io, ws, "greeter", "greet");
    defer alloc.free(v1);

    // Rebuild with a *different* (bogus) toolchain argument: because a script
    // build never consults the compiler, the version is unchanged. This is
    // exactly "compiler identity is not in the version hash".
    const windows = @import("builtin").os.tag == .windows;
    const ext_dir = if (windows) ".nulya\\extensions\\greeter" else ".nulya/extensions/greeter";
    var dest = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer dest.close(io);
    var rebuilt = try build_ext.buildExtension(alloc, io, ws, ext_dir, dest, "a-completely-different-zig");
    defer rebuilt.deinit(alloc);
    try std.testing.expect(rebuilt.compile_ok);
    try std.testing.expect(rebuilt.already_built);
    try std.testing.expectEqualStrings(v1, rebuilt.version);
}
