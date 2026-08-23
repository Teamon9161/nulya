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
const manifest_mod = support.manifest;
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
const buildBundled = support.buildBundled;
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
    var zig = build_ext.Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, ws_ext_root, &zig);
    defer result.deinit(alloc);
    if (!result.compile_ok) {
        std.debug.print("extension failed to compile:\n{s}\n", .{result.stderr});
        return error.ExtensionBuildFailed;
    }
    try std.testing.expect(std.mem.startsWith(u8, result.version, "v-"));

    // Building again is a reproducible no-op on the same version.
    var again = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, ws_ext_root, &zig);
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

    // 4. `ext run`: invoke the built binary through the Environment seam — the
    //    same path a live agent uses. The `--zig` scaffold speaks the `plain`
    //    wire (DESIGN §7.1, ext-review-2 C1): stdin is the arguments object,
    //    stdout is the result verbatim, so there is no envelope to decode.
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_real_len = try ws.realPath(io, &ws_real);
    const ws_path = ws_real[0..ws_real_len];

    try std.testing.expect(result.entry_rel != null);
    const entry_abs = try std.fs.path.join(alloc, &.{ ws_path, ext_dir_rel, "versions", result.version, result.entry_rel.? });
    defer alloc.free(entry_abs);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    const invocation = try lenv.environment().runExtension(alloc, .{
        .entry_path = entry_abs,
        .cwd = ws_path,
        .request_json = "{\"name\":\"zig\"}",
        .max_output_bytes = 1 << 20,
    });
    defer invocation.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), invocation.exit_code);
    try std.testing.expectEqualStrings("hello from a Nulya-built extension, name=zig\n", invocation.stdout);
}

test "closed loop: a pinned tool executes the frozen version through the tool executor (harness-built extension)" {
    // The pin + freeze half of the kernel loop, proven end to end with a real
    // built binary — not a stub, not a FakeEnv. The extension here is built by
    // the test harness (`buildAndActivate`); the separate self-manufacture test
    // below proves a shell-only session can build it itself.
    //
    //   build+activate web.search v1  ->  CLI `nulya ext run` records usage
    //     ->  usage alone changes nothing: a new session's tool face is still
    //         shell alone
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
    // still sees only shell, however many rows the journal holds.
    {
        const events = try tool_stats.readAll(alloc, io, ws_path);
        defer tool_stats.freeEvents(alloc, events);
        try std.testing.expect(events.len != 0);

        var unpinned = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{});
        defer unpinned.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), unpinned.tools.tools.len);
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

test "cli ext run records a version-free stable tool id in the usage journal, with the version that served the call beside it" {
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
    const v1 = try buildAndActivate(alloc, io, ws, zig_exe, "web.search", "web_search", support.jsonrpc_main_zig);
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
    // …and beside it, the frozen version that actually answered: the one the
    // command resolved, so evidence can be read per implementation later.
    try std.testing.expectEqualStrings(v1, events[0].version.?);

    // v2: a different implementation -> a different immutable version, but the
    // same tool identity. Activating it must not change the stats identity.
    const v2_src = "// v2 implementation\n" ++ support.jsonrpc_main_zig;
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
    // The two identities in one journal, doing their separate jobs: one id
    // across both rows (a tool's history is one history), two versions across
    // them (and that history can also be read per implementation).
    try std.testing.expectEqualStrings(v1, events2[0].version.?);
    try std.testing.expectEqualStrings(v2, events2[1].version.?);
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
    // A failure names its implementation too — that pairing is the whole point
    // of recording the version: "which one of them was failing" is a question
    // only an evidence trail can answer later.
    try std.testing.expectEqualStrings(version, events[0].version.?);
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
    const version = try buildAndActivate(alloc, io, ws, zig_exe, "demo", "greet", support.jsonrpc_main_zig);
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
    var zig = build_ext.Zig.init("zig-unused-for-data");
    defer zig.deinit(alloc);
    var result = try build_ext.buildExtension(alloc, io, ws, draft, dest, &zig);
    defer result.deinit(alloc);
    if (!result.compile_ok) return error.ExtensionBuildFailed;
    return alloc.dupe(u8, result.version);
}

test "extension store: a member named by a workspace session resolves in root order — a workspace copy shadows a user-root one of the same id, and a frozen version resolves from whichever root holds it" {
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

    // A session that NAMES both gets both (the store's contents reach nobody on
    // their own, DESIGN §5.1): the user-wide extension's skill is in the
    // catalog, and `shared` resolves to the workspace copy — first root wins, so
    // a workspace version shadows a user-wide one of the same id.
    const named: []const composition.WithRef = &.{ .{ .id = "user-wide" }, .{ .id = "shared" } };
    var comp = try composition.SessionComposition.init(alloc, io, ws_path, roots, .{ .with = named });
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

    // Without the user root in the search order, only the workspace copy exists —
    // and naming the user-only id there is a refusal, not a silent absence.
    try std.testing.expectError(error.WithVersionNotFound, composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{ .with = named }));
    var workspace_only = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{ .with = &.{.{ .id = "shared" }} });
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
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "(no current)") != null);

        const skills = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "skill", "list" }, env);
        defer alloc.free(skills.stdout);
        try std.testing.expect(std.mem.indexOf(u8, skills.stdout, user_shared) != null);
        try std.testing.expect(std.mem.indexOf(u8, skills.stdout, ws_shared) == null);
    }
}

test "cli: activating into the user store from inside a session says so on stderr — what it changes is what the id MEANS, machine-wide" {
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
        const expected = try std.fmt.allocPrint(alloc, "note: activating prompts.demo@{s} in the user store from inside session s-probe: prompts.demo now means this version for every workspace on this machine", .{version});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, stderr, expected) != null);
        // What it does NOT say any more, because it is no longer true: activating
        // composes nothing (DESIGN §5.1). Only `[extensions] with` and `--with`
        // put a package's prompt in front of a session.
        try std.testing.expect(std.mem.indexOf(u8, stderr, "every future session") == null);
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
        var zig = build_ext.Zig.init("");
        defer zig.deinit(alloc);
        var result = try build_ext.buildExtension(alloc, io, ws, draft, dest, &zig);
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

    // And now sessions start again. The gate is about the STORE — whether this
    // root may supply versions at all — so it is what stood between the checkout
    // and every session here, named or not. Composing the package is still a
    // second, separate decision (DESIGN §5.1): a plain session has no member…
    {
        const ok = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(ok.stdout);
        try std.testing.expectEqual(@as(u8, 0), ok.code);
        const id = std.mem.trim(u8, ok.stdout, " \r\n");
        const header = try support.readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "prompts.demo") == null);
    }
    // …and naming it now works, at the version the trusted store holds.
    {
        const ok = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "prompts.demo" });
        defer alloc.free(ok.stdout);
        try std.testing.expectEqual(@as(u8, 0), ok.code);
        const id = std.mem.trim(u8, ok.stdout, " \r\n");
        const header = try support.readSessionFile(alloc, io, ws, id);
        defer alloc.free(header);
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
    try std.testing.expect(std.mem.indexOf(u8, list2.stdout, "(no current)") != null);
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
            .tool_context = .{ .environment = lenv.environment(), .cwd = ws_path },
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
    try std.testing.expectEqual(@as(usize, 1), sess.composition.tools.tools.len);

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
    // The compile is shared (support.stageBundled), so this is a real `ext build`
    // that finds the version already there.
    alloc.free(try support.stageBundled(alloc, io, ws, "compact"));
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

test "cli ext build: a compiled version another store root already holds is copied in rather than compiled — byte for byte, with no toolchain on this machine at all" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;
    const draft = try std.fs.path.join(alloc, &.{ repo, "extensions", "compact" });
    defer alloc.free(draft);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    const home_abs = try std.fs.path.join(alloc, &.{ ws_path, "home" });
    defer alloc.free(home_abs);

    // The user store already carries a built `compact` — the ordinary case after
    // `ext build --user` once, or after another workspace built it.
    const user_root = "home" ++ std.fs.path.sep_str ++ "extensions";
    const version = try support.stageBundledIn(alloc, io, ws, user_root, "compact");
    defer alloc.free(version);

    // Now build the same draft here, with NULYA_ZIG naming something that is not
    // a compiler: `compact` is a COMPILED extension, so this build can only
    // succeed by adopting the copy the user root holds.
    const built = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "build", draft }, &.{
        .{ .key = "NULYA_HOME", .value = home_abs },
        .{ .key = "NULYA_ZIG", .value = "definitely-not-a-compiler" },
    });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    try std.testing.expect(std.mem.indexOf(u8, built.stdout, "copied from") != null);
    const copied_version = try extractVersion(alloc, built.stdout);
    defer alloc.free(copied_version);
    try std.testing.expectEqualStrings(version, copied_version);

    // Same version id, same bytes: the copy IS the version, so everything that
    // validates a frozen version — activate, `--with`, a pinned tool — accepts it.
    {
        const rel = try std.fs.path.join(alloc, &.{ "compact", "versions", version });
        defer alloc.free(rel);
        const user_version_rel = try std.fs.path.join(alloc, &.{ user_root, rel });
        defer alloc.free(user_version_rel);
        const ws_version_rel = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", rel });
        defer alloc.free(ws_version_rel);
        var from_user = try ws.openDir(io, user_version_rel, .{ .iterate = true });
        defer from_user.close(io);
        var in_workspace = try ws.openDir(io, ws_version_rel, .{ .iterate = true });
        defer in_workspace.close(io);
        try support.expectSameTree(alloc, io, from_user, in_workspace);
    }

    // A second build finds it in the destination root and says so — the copy did
    // not invent a version that only half exists.
    const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "build", draft }, &.{
        .{ .key = "NULYA_HOME", .value = home_abs },
        .{ .key = "NULYA_ZIG", .value = "definitely-not-a-compiler" },
    });
    defer alloc.free(again.stdout);
    try std.testing.expectEqual(@as(u8, 0), again.code);
    try std.testing.expect(std.mem.indexOf(u8, again.stdout, "already built") != null);

    // And the adopted version really runs: activate it and call its tool with no
    // arguments, which the frozen binary refuses by protocol rather than by
    // failing to start.
    {
        const activated = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "activate", "compact", version }, "NULYA_HOME", home_abs);
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
        const ran = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "run", "compact", "compact", "{}" }, "NULYA_HOME", home_abs);
        defer alloc.free(ran.stdout);
        try std.testing.expect(ran.stdout.len != 0);
    }
}

test "cli ext sync: every draft in a root is built in one pass — data, script and a compiled one adopted from the user store — a broken manifest fails alone, and --dry-run writes nothing" {
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
    // No toolchain at all for the whole test: the compiled draft below can only
    // be installed by adopting the copy the user store carries.
    const env: []const EnvPair = &.{
        .{ .key = "NULYA_HOME", .value = home_abs },
        .{ .key = "NULYA_ZIG", .value = "definitely-not-a-compiler" },
    };
    const ws_store = ".nulya" ++ std.fs.path.sep_str ++ "extensions";

    // Four drafts dropped into the workspace store, which is all "installing an
    // extension" is meant to take.
    try writeSkillDraft(alloc, io, ws, ws_store ++ std.fs.path.sep_str ++ "data.mode", "data.mode", "a mode kept as source");
    try writeScriptDraft(alloc, io, ws, ws_store, "my.helper");
    try support.copyBundledDraft(alloc, io, ws, ws_store, "compact");
    try ws.createDirPath(io, ws_store ++ std.fs.path.sep_str ++ "bad");
    try ws.writeFile(io, .{ .sub_path = ws_store ++ std.fs.path.sep_str ++ "bad" ++ std.fs.path.sep_str ++ "extension.json", .data = "{not json" });

    const staged = try support.stageBundledIn(alloc, io, ws, "home" ++ std.fs.path.sep_str ++ "extensions", "compact");
    defer alloc.free(staged);

    // A plan first: it says what each draft is and what would happen, and leaves
    // the store exactly as it found it.
    {
        const dry = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync", "--dry-run" }, env);
        defer alloc.free(dry.stdout);
        try std.testing.expectEqual(@as(u8, 1), dry.code); // the broken manifest
        try std.testing.expect(std.mem.indexOf(u8, dry.stdout, "not built") != null);
        try std.testing.expect(std.mem.indexOf(u8, dry.stdout, "bad: failed") != null);
        try std.testing.expect(std.mem.indexOf(u8, dry.stdout, "3 not built, 0 already built, 1 failed") != null);
        // The compiled one is not "would build" — it is available for the taking.
        try std.testing.expect(std.mem.indexOf(u8, dry.stdout, "available from") != null);
        const versions_rel = ws_store ++ std.fs.path.sep_str ++ "data.mode" ++ std.fs.path.sep_str ++ "versions";
        try std.testing.expectError(error.FileNotFound, ws.access(io, versions_rel, .{}));
    }

    const first = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync" }, env);
    defer alloc.free(first.stdout);
    try std.testing.expectEqual(@as(u8, 1), first.code);
    for ([_][]const u8{ "data.mode", "my.helper", "compact", "copied from", "bad: failed", "3 built, 0 already built, 1 failed" }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, first.stdout, needle) != null) catch |err| {
            std.debug.print("`ext sync` never said '{s}':\n{s}\n", .{ needle, first.stdout });
            return err;
        };
    }

    // Nothing was activated: building is mechanical, pointing `current` is a
    // decision.
    {
        const listed = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "list" }, env);
        defer alloc.free(listed.stdout);
        try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "(no current)") != null);
    }

    // Idempotent: a second pass finds every version already there.
    {
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync" }, env);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 1), again.code);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, "0 built, 3 already built, 1 failed") != null);
    }

    // --activate, case 1: an id with no `current` gets one.
    const data_version = blk: {
        const activated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync", "--activate" }, env);
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, activated.stdout, "-> current"));
        break :blk try readActive(alloc, io, ws, ws_store, "data.mode");
    };
    defer alloc.free(data_version);

    // --activate, case 2: a draft edited since — the new version becomes current.
    try writeSkillDraft(alloc, io, ws, ws_store ++ std.fs.path.sep_str ++ "data.mode", "data.mode", "edited since");
    const second_version = blk: {
        const activated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync", "--activate" }, env);
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 1), activated.code);
        try std.testing.expect(std.mem.indexOf(u8, activated.stdout, "built") != null);
        const now = try readActive(alloc, io, ws, ws_store, "data.mode");
        try std.testing.expect(!std.mem.eql(u8, now, data_version));
        break :blk now;
    };
    defer alloc.free(second_version);

    // --activate, case 3: someone activated an older version, and the draft's
    // version is already built — that decision outlives the next sync.
    {
        const rolled = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "activate", "data.mode", data_version }, env);
        defer alloc.free(rolled.stdout);
        try std.testing.expectEqual(@as(u8, 0), rolled.code);

        const activated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync", "--activate" }, env);
        defer alloc.free(activated.stdout);
        const stays = try std.fmt.allocPrint(alloc, "(current stays {s})", .{data_version});
        defer alloc.free(stays);
        try std.testing.expect(std.mem.indexOf(u8, activated.stdout, stays) != null);
        const now = try readActive(alloc, io, ws, ws_store, "data.mode");
        defer alloc.free(now);
        try std.testing.expectEqualStrings(data_version, now);
    }

    // What sync produced is an ordinary version: composable by name.
    {
        const with_arg = try std.fmt.allocPrint(alloc, "data.mode@{s}", .{second_version});
        defer alloc.free(with_arg);
        const new = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", with_arg }, env);
        defer alloc.free(new.stdout);
        try std.testing.expectEqual(@as(u8, 0), new.code);
    }
}

test "cli ext sync: a compiled draft with no toolchain and nowhere to copy from says it needs zig, alone, and writes no version" {
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
    const ws_store = ".nulya" ++ std.fs.path.sep_str ++ "extensions";
    const env: []const EnvPair = &.{.{ .key = "NULYA_ZIG", .value = "definitely-not-a-compiler" }};

    try support.copyBundledDraft(alloc, io, ws, ws_store, "compact");
    try writeScriptDraft(alloc, io, ws, ws_store, "my.helper");

    const synced = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync" }, env);
    defer alloc.free(synced.stdout);
    try std.testing.expectEqual(@as(u8, 1), synced.code);
    try std.testing.expect(std.mem.indexOf(u8, synced.stdout, "compact: needs zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, synced.stdout, "NULYA_ZIG") != null);
    // The script draft beside it is unaffected: one draft's problem is its own.
    try std.testing.expect(std.mem.indexOf(u8, synced.stdout, "1 built, 0 already built, 1 failed") != null);
    const compact_versions = ws_store ++ std.fs.path.sep_str ++ "compact" ++ std.fs.path.sep_str ++ "versions";
    try std.testing.expectError(error.FileNotFound, ws.access(io, compact_versions, .{}));
}

test "cli ext prune: every version but `current` goes, an id without one keeps all of them, and --dry-run only says what it would do" {
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
    const ws_store = ".nulya" ++ std.fs.path.sep_str ++ "extensions";
    const draft = ws_store ++ std.fs.path.sep_str ++ "data.mode";

    // Three versions of one id, `current` on the middle one; and a second id with
    // versions but no `current` at all.
    var versions: [3][]u8 = undefined;
    for ([_][]const u8{ "one", "two", "three" }, 0..) |body, i| {
        try writeSkillDraft(alloc, io, ws, draft, "data.mode", body);
        const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
        defer alloc.free(built.stdout);
        try std.testing.expectEqual(@as(u8, 0), built.code);
        versions[i] = try extractVersion(alloc, built.stdout);
    }
    defer for (versions) |v| alloc.free(v);

    try writeSkillDraft(alloc, io, ws, ws_store ++ std.fs.path.sep_str ++ "loose.mode", "loose.mode", "never activated");
    {
        const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", ws_store ++ std.fs.path.sep_str ++ "loose.mode" });
        defer alloc.free(built.stdout);
        try std.testing.expectEqual(@as(u8, 0), built.code);
    }
    {
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "data.mode", versions[1] });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
    }

    // A plan removes nothing.
    {
        const dry = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "prune", "--dry-run" });
        defer alloc.free(dry.stdout);
        try std.testing.expectEqual(@as(u8, 0), dry.code);
        try std.testing.expect(std.mem.indexOf(u8, dry.stdout, "would be removed") != null);
        for (versions) |v| {
            const rel = try std.fs.path.join(alloc, &.{ draft, "versions", v });
            defer alloc.free(rel);
            try ws.access(io, rel, .{});
        }
    }

    const pruned = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "prune" });
    defer alloc.free(pruned.stdout);
    try std.testing.expectEqual(@as(u8, 0), pruned.code);
    // The cost of the deletion is stated where the deletion is reported.
    try std.testing.expect(std.mem.indexOf(u8, pruned.stdout, "can no longer resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned.stdout, "loose.mode: no current") != null);

    for (versions, 0..) |v, i| {
        const rel = try std.fs.path.join(alloc, &.{ ws_store, "data.mode", "versions", v });
        defer alloc.free(rel);
        if (i == 1) {
            try ws.access(io, rel, .{}); // current survives
        } else {
            try std.testing.expectError(error.FileNotFound, ws.access(io, rel, .{}));
        }
    }
    // An id with no `current` is untouched: nothing there says which one to keep.
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "list" });
        defer alloc.free(listed.stdout);
        try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "loose.mode") != null);
        try std.testing.expect(std.mem.indexOf(u8, listed.stdout, versions[1]) != null);
    }

    // Rebuilding the draft that is still there restores the pruned version id —
    // the recovery path the note points at.
    try writeSkillDraft(alloc, io, ws, draft, "data.mode", "three");
    {
        const rebuilt = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
        defer alloc.free(rebuilt.stdout);
        const v = try extractVersion(alloc, rebuilt.stdout);
        defer alloc.free(v);
        try std.testing.expectEqualStrings(versions[2], v);
    }
}

/// The `current` pointer of `id` in a store root under `ws`. Caller owns it.
fn readActive(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, root_rel: []const u8, id: []const u8) ![]u8 {
    const rel = try std.fs.path.join(alloc, &.{ root_rel, id, "current" });
    defer alloc.free(rel);
    const raw = try ws.readFileAlloc(io, rel, alloc, .limited(256));
    defer alloc.free(raw);
    return alloc.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

/// Write a script extension DRAFT under `root_rel`; no build. Exactly what
/// `ext init` scaffolds — one manifest naming an entry per OS, and both scripts,
/// because a build checks that EVERY declared variant is in the snapshot.
fn writeScriptDraft(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, root_rel: []const u8, id: []const u8) !void {
    const ext_dir = try std.fs.path.join(alloc, &.{ root_rel, id });
    defer alloc.free(ext_dir);
    const src_dir = try std.fs.path.join(alloc, &.{ ext_dir, "src" });
    defer alloc.free(src_dir);
    try ws.createDirPath(io, src_dir);

    const manifest_bytes = try templates.scriptManifestJson(alloc, id, "do_thing");
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });

    const sh = try templates.scriptSh(alloc, id);
    defer alloc.free(sh);
    const sh_rel = try std.fs.path.join(alloc, &.{ src_dir, "run.sh" });
    defer alloc.free(sh_rel);
    try ws.writeFile(io, .{ .sub_path = sh_rel, .data = sh });

    const ps1 = try templates.scriptPs1(alloc, id);
    defer alloc.free(ps1);
    const ps1_rel = try std.fs.path.join(alloc, &.{ src_dir, "run.ps1" });
    defer alloc.free(ps1_rel);
    try ws.writeFile(io, .{ .sub_path = ps1_rel, .data = ps1 });
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

/// A JSON-RPC script entry, PowerShell and POSIX sh. `ext init` no longer
/// scaffolds these — its default is the `plain` wire (DESIGN §7.1) — but the
/// JSON-RPC wire is still what a script MAY declare, and the test below is the
/// standing proof that a script speaking it goes the whole way. So the fixture
/// lives here, where its consumer is, rather than as a template nothing
/// generates.
const jsonrpc_script_ps1 =
    \\$ErrorActionPreference = 'Stop'
    \\$in = [Console]::In.ReadToEnd()
    \\$id = 'call'
    \\try { $req = $in | ConvertFrom-Json; if ($req.id) { $id = [string]$req.id } } catch {}
    \\$resp = [ordered]@{ jsonrpc = '2.0'; id = $id; result = [ordered]@{ greeting = 'hello from a Nulya script extension' } }
    \\[Console]::Out.Write(($resp | ConvertTo-Json -Compress))
    \\
;

const jsonrpc_script_sh =
    \\#!/bin/sh
    \\req=$(cat)
    \\id=$(printf '%s' "$req" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    \\[ -z "$id" ] && id=call
    \\printf '{"jsonrpc":"2.0","id":"%s","result":{"greeting":"hello from a Nulya script extension"}}' "$id"
    \\
;

/// Scaffold a host-appropriate JSON-RPC script extension (PowerShell on Windows,
/// POSIX sh elsewhere) and build it into an immutable version WITHOUT a
/// toolchain. Returns the built version id; caller frees.
fn scaffoldAndBuildScript(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8, tool_name: []const u8) ![]u8 {
    const windows = @import("builtin").os.tag == .windows;
    const script_name = if (windows) "run.ps1" else "run.sh";
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const interpreter = if (windows) "powershell" else "sh";
    const body = if (windows) jsonrpc_script_ps1 else jsonrpc_script_sh;

    const ext_dir = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(ext_dir);
    const src_dir = try std.fs.path.join(alloc, &.{ ext_dir, "src" });
    defer alloc.free(src_dir);
    try ws.createDirPath(io, src_dir);

    // The wire is left unwritten on purpose: absent means JSON-RPC, which is
    // what every manifest predating `runtime.wire` says.
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{ "entry": "{s}", "interpreter": "{s}" }},
        \\  "contributes": {{
        \\    "tools": [{{ "name": "{s}", "description": "A script tool.", "input": {{ "type": "object", "properties": {{}} }} }}]
        \\  }}
        \\}}
        \\
    , .{ id, entry, interpreter, tool_name });
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });
    const script_rel = try std.fs.path.join(alloc, &.{ src_dir, script_name });
    defer alloc.free(script_rel);
    try ws.writeFile(io, .{ .sub_path = script_rel, .data = body });

    var dest = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer dest.close(io);
    var zig = build_ext.Zig.init("zig-unused-for-scripts");
    defer zig.deinit(alloc);
    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir, dest, &zig);
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

test "manifest audience: the frozen version keeps what the draft declared, and an unknown word is refused before anything is built" {
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

    const windows = @import("builtin").os.tag == .windows;
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const interpreter = if (windows) "powershell" else "sh";
    const script_name = if (windows) "run.ps1" else "run.sh";
    const script_body = if (windows) jsonrpc_script_ps1 else jsonrpc_script_sh;

    // A script package, so this costs no toolchain: three tools, one for each
    // thing a package can say about who a tool is for.
    const draft_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "faces";
    const src_rel = draft_rel ++ std.fs.path.sep_str ++ "src";
    try ws.createDirPath(io, src_rel);
    const script_rel = try std.fs.path.join(alloc, &.{ src_rel, script_name });
    defer alloc.free(script_rel);
    try ws.writeFile(io, .{ .sub_path = script_rel, .data = script_body });

    const good = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"faces","runtime":{{"entry":"{s}","interpreter":"{s}"}},"contributes":{{"tools":[
        \\{{"name":"ask","input":{{}},"audience":"model"}},
        \\{{"name":"drive","input":{{}},"audience":"driver"}},
        \\{{"name":"quiet","input":{{}}}}
        \\]}}}}
    , .{ entry, interpreter });
    defer alloc.free(good);
    const manifest_rel = draft_rel ++ std.fs.path.sep_str ++ "extension.json";
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = good });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft_rel });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);

    // The version's own manifest — the bytes a session freezes and every reader
    // (a driver's pin policy, `ext inspect`) sees — carries the declaration.
    const frozen_rel = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", "faces", "versions", version, "extension.json" });
    defer alloc.free(frozen_rel);
    const frozen_bytes = try ws.readFileAlloc(io, frozen_rel, alloc, .limited(1 << 20));
    defer alloc.free(frozen_bytes);
    var frozen = try manifest_mod.parse(alloc, frozen_bytes);
    defer frozen.deinit();
    try frozen.validate();
    try std.testing.expectEqual(@as(usize, 3), frozen.tools.len);
    try std.testing.expectEqual(@as(?manifest_mod.Audience, .model), frozen.tools[0].audienceOf());
    try std.testing.expectEqual(@as(?manifest_mod.Audience, .driver), frozen.tools[1].audienceOf());
    // Silence survives as silence: the kernel never writes `model` in for a
    // package that said nothing (DESIGN §7.2.1).
    try std.testing.expect(frozen.tools[2].audience == null);

    // The declaration changes NOTHING the kernel does: a session may still pin
    // the driver-audience tool, and it executes like any other.
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    {
        var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer ext_root.close(io);
        try store.Store.init(io, ext_root).activate(alloc, "faces", version);
    }
    const pins = [_][]const u8{"ext:faces/drive"};
    var comp = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{ .pinned_native_tools = &pins });
    defer comp.deinit(alloc);
    try std.testing.expect(comp.tools.lookup("drive") != null);

    // A word outside the two is a manifest fault: `ext build` names it and
    // writes no version at all.
    const bad_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "typo";
    try ws.createDirPath(io, bad_rel ++ std.fs.path.sep_str ++ "src");
    const bad_script_rel = try std.fs.path.join(alloc, &.{ bad_rel, "src", script_name });
    defer alloc.free(bad_script_rel);
    try ws.writeFile(io, .{ .sub_path = bad_script_rel, .data = script_body });
    const bad = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"typo","runtime":{{"entry":"{s}","interpreter":"{s}"}},"contributes":{{"tools":[{{"name":"t","input":{{}},"audience":"drivers"}}]}}}}
    , .{ entry, interpreter });
    defer alloc.free(bad);
    try ws.writeFile(io, .{ .sub_path = bad_rel ++ std.fs.path.sep_str ++ "extension.json", .data = bad });

    const refused = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", bad_rel });
    defer alloc.free(refused.stdout);
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    const said = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "build", bad_rel }, &.{});
    defer alloc.free(said);
    try std.testing.expect(std.mem.indexOf(u8, said, "InvalidAudience") != null);
    try std.testing.expectError(error.FileNotFound, ws.access(io, bad_rel ++ std.fs.path.sep_str ++ "versions", .{}));
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
    var zig = build_ext.Zig.init("a-completely-different-zig");
    defer zig.deinit(alloc);
    var rebuilt = try build_ext.buildExtension(alloc, io, ws, ext_dir, dest, &zig);
    defer rebuilt.deinit(alloc);
    try std.testing.expect(rebuilt.compile_ok);
    try std.testing.expect(rebuilt.already_built);
    try std.testing.expectEqualStrings(v1, rebuilt.version);
}

test "cli ext seed: the binary's own drafts land in a store root, move forward when the binary does, never over somebody's edit without --force, --dry-run writes nothing, and sync builds what was seeded" {
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
    // No toolchain anywhere in this test: seeding writes source, and the two
    // ids synced below are data kind, which build without a compiler.
    const env: []const EnvPair = &.{.{ .key = "NULYA_ZIG", .value = "definitely-not-a-compiler" }};
    const ws_store = ".nulya" ++ std.fs.path.sep_str ++ "extensions";

    // An id the binary does not ship is refused by name, with the real list.
    {
        const err = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "seed", "nope" }, env);
        defer alloc.free(err);
        try std.testing.expect(std.mem.indexOf(u8, err, "ships no draft 'nope'") != null);
        try std.testing.expect(std.mem.indexOf(u8, err, "std") != null);
    }

    // A plan writes nothing — not even the store root directory.
    {
        const dry = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "seed", "--dry-run" }, env);
        defer alloc.free(dry.stdout);
        try std.testing.expectEqual(@as(u8, 0), dry.code);
        try std.testing.expect(std.mem.indexOf(u8, dry.stdout, "std: would seed") != null);
        try std.testing.expect(std.mem.indexOf(u8, dry.stdout, "8 seeded, 0 updated, 0 up to date, 0 left alone") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ws_store, .{}));
    }

    // A named subset into the user store, and the ordinary sync path builds it:
    // seeding is only how the source arrives.
    {
        const seeded = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "seed", "--user", "guide", "evolution" }, env);
        defer alloc.free(seeded.stdout);
        try std.testing.expectEqual(@as(u8, 0), seeded.code);
        try std.testing.expect(std.mem.indexOf(u8, seeded.stdout, "2 seeded, 0 updated, 0 up to date, 0 left alone") != null);
        try std.testing.expect(std.mem.indexOf(u8, seeded.stdout, "`nulya ext sync --user` builds them") != null);
        try std.testing.expect(std.mem.indexOf(u8, seeded.stdout, "compact") == null);

        const synced = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "sync", "--user" }, env);
        defer alloc.free(synced.stdout);
        try std.testing.expectEqual(@as(u8, 0), synced.code);
        try std.testing.expect(std.mem.indexOf(u8, synced.stdout, "2 built, 0 already built, 0 failed") != null);

        // Seeding the same ids again is a no-op that says so — and the build
        // beside the draft is not a change to it.
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "seed", "--user", "guide", "evolution" }, env);
        defer alloc.free(again.stdout);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, "guide: up to date in") != null);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, "0 seeded, 0 updated, 2 up to date, 0 left alone") != null);
    }

    // The default root is the workspace store, and an id that already holds a
    // draft NOBODY here wrote keeps it byte for byte: an edit is somebody's
    // work, and only `--force` names it out loud.
    {
        const guide_dir = ws_store ++ std.fs.path.sep_str ++ "guide";
        const guide_manifest = guide_dir ++ std.fs.path.sep_str ++ "extension.json";
        try ws.createDirPath(io, guide_dir);
        const mine = "{\"mine\": true}";
        try ws.writeFile(io, .{ .sub_path = guide_manifest, .data = mine });

        const seeded = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "seed" }, env);
        defer alloc.free(seeded.stdout);
        try std.testing.expectEqual(@as(u8, 0), seeded.code);
        try std.testing.expect(std.mem.indexOf(u8, seeded.stdout, "guide: differs from this build, left alone") != null);
        try std.testing.expect(std.mem.indexOf(u8, seeded.stdout, "--force guide") != null);
        try std.testing.expect(std.mem.indexOf(u8, seeded.stdout, "7 seeded, 0 updated, 0 up to date, 1 left alone") != null);

        const kept = try ws.readFileAlloc(io, guide_manifest, alloc, .limited(1 << 16));
        defer alloc.free(kept);
        try std.testing.expectEqualStrings(mine, kept);
        // The others really arrived, manifest and all.
        try ws.access(io, ws_store ++ std.fs.path.sep_str ++ "std" ++ std.fs.path.sep_str ++ "extension.json", .{});
        try ws.access(io, ws_store ++ std.fs.path.sep_str ++ "std" ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "vendor" ++ std.fs.path.sep_str ++ "mvzr.zig", .{});

        // …and `--force` is the one way past it.
        const forced = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "seed", "--force", "guide" }, env);
        defer alloc.free(forced.stdout);
        try std.testing.expectEqual(@as(u8, 0), forced.code);
        try std.testing.expect(std.mem.indexOf(u8, forced.stdout, "guide: replaced") != null);
        const replaced = try ws.readFileAlloc(io, guide_manifest, alloc, .limited(1 << 16));
        defer alloc.free(replaced);
        try std.testing.expect(std.mem.indexOf(u8, replaced, "\"id\": \"guide\"") != null);
    }

    // What the update channel rests on: every draft this binary wrote carries a
    // record of the tree it wrote, and an edit to the draft is measured against
    // it. (The refresh itself needs two different binaries to observe, so it is
    // tested where both sides can be constructed — `cli/ext_seed.zig`.)
    {
        const std_dir = ws_store ++ std.fs.path.sep_str ++ "std";
        try ws.access(io, std_dir ++ std.fs.path.sep_str ++ ".seed", .{});

        const std_manifest = std_dir ++ std.fs.path.sep_str ++ "extension.json";
        const shipped = try ws.readFileAlloc(io, std_manifest, alloc, .limited(1 << 20));
        defer alloc.free(shipped);
        const edited = try std.fmt.allocPrint(alloc, "{s}\n", .{shipped});
        defer alloc.free(edited);
        try ws.writeFile(io, .{ .sub_path = std_manifest, .data = edited });

        const held = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "seed", "std" }, env);
        defer alloc.free(held.stdout);
        try std.testing.expect(std.mem.indexOf(u8, held.stdout, "std: differs from this build, left alone") != null);
        const kept = try ws.readFileAlloc(io, std_manifest, alloc, .limited(1 << 20));
        defer alloc.free(kept);
        try std.testing.expectEqualStrings(edited, kept);
    }
}

// ── The bundled agent extension: delegation over the task substrate ─────────

test "bundled agent: render writes a persona nothing installs; a delegation opens a child session wearing its bytes, runs it as a background task of the parent, holds a read-only agent to the gate, and reports back through the parent's inbox" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // Two definitions: one read-only, one ordinary. Front matter is a set of
    // `session new` arguments; the body is the system prompt.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data =
        \\---
        \\description: a read-only prober
        \\readonly: true
        \\max_steps: 2
        \\pins: [nonsense]
        \\---
        \\You only read. Report what you found.
        \\
        ,
    });

    // ① `render` is the ONE implementation of that rendering: it writes the body
    // where `session new --prompt` can read it and answers with the whole set of
    // arguments the definition asks for. Content-determined, so running it twice
    // is the same file.
    var prompt_rel: []u8 = undefined;
    {
        const first = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"prober\"}" });
        defer alloc.free(first.stdout);
        try std.testing.expectEqual(@as(u8, 0), first.code);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, first.stdout, " \r\n"), .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("agent-prober", obj.get("label").?.string);
        try std.testing.expectEqual(true, obj.get("readonly").?.bool);
        try std.testing.expectEqual(@as(i64, 2), obj.get("max_steps").?.integer);
        // A pin the kernel could not resolve refuses the whole `session new`, so
        // a malformed one is dropped here — and said out loud.
        try std.testing.expectEqual(@as(usize, 0), obj.get("pins").?.array.items.len);
        try std.testing.expect(std.mem.indexOf(u8, obj.get("warnings").?.array.items[0].string, "nonsense") != null);
        prompt_rel = try alloc.dupe(u8, obj.get("prompt").?.string);

        const again = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"prober\"}" });
        defer alloc.free(again.stdout);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, prompt_rel) != null);
    }
    defer alloc.free(prompt_rel);

    // The persona is a FILE, and nothing installed it: no `agent-*` package
    // appears in the store, so `/ext` has nothing new in it and `ext prune`
    // cannot break the resume of a session wearing one.
    {
        const body = try ws.readFileAlloc(io, prompt_rel, alloc, .limited(1 << 16));
        defer alloc.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "You only read.") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/extensions/agent-prober", .{}));
    }

    // ② An unknown name lists the ones there are, and creates nothing.
    {
        const unknown = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"nope\"}" });
        defer alloc.free(unknown.stdout);
        try std.testing.expectEqual(@as(u8, 1), unknown.code);
        try std.testing.expect(std.mem.indexOf(u8, unknown.stdout, "no agent 'nope'") != null);
        try std.testing.expect(std.mem.indexOf(u8, unknown.stdout, "prober") != null);
    }

    // ③ Outside a session there is nobody to report back to, so a complete
    // delegation is refused and nothing is created.
    {
        const nowhere = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" });
        defer alloc.free(nowhere.stdout);
        try std.testing.expectEqual(@as(u8, 1), nowhere.code);
        try std.testing.expect(std.mem.indexOf(u8, nowhere.stdout, "inside a session") != null);
    }

    // ④ The whole circle. A parent session delegates; the child is created,
    // driven by a background task OF THE PARENT, and its report comes back the
    // way every other late answer does — `task_finished` in the parent's inbox.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    const delegated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"find the parser\"}" }, &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    });
    defer alloc.free(delegated.stdout);
    try std.testing.expectEqual(@as(u8, 0), delegated.code);
    // The receipt names the child — that is what lets a transcript link to it —
    // and tells the model to stop, because the work has not happened yet.
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "background task") != null);
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "end your turn") != null);
    const child = blk: {
        const at = std.mem.indexOf(u8, delegated.stdout, "session s-").? + "session ".len;
        var end = at;
        while (end < delegated.stdout.len and delegated.stdout[end] != ',' and delegated.stdout[end] != ' ') end += 1;
        break :blk try alloc.dupe(u8, delegated.stdout[at..end]);
    };
    defer alloc.free(child);

    // The child WEARS the persona: its bytes are in the header, under the label
    // the package chose, and no extension of any kind came along for it.
    {
        const header = try support.readSessionFile(alloc, io, ws, child);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"source\":\"agent-prober\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "You only read.") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"active\":[]") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/extensions/agent-prober", .{}));
    }

    // Wait for the task the delegation started. `task wait` is the kernel's own
    // answer to "is it done"; nothing here polls a directory.
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The read-only agent met the gate: the scripted provider's one `shell` call
    // never ran, and the refusal is that call's tool_result — in the ledger, and
    // readable by the sub-agent (DESIGN §4).
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "read-only agent") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "cannot run shell") != null);
        // …and the task it was given arrived as an ordinary user turn.
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "find the parser") != null);
    }

    // The report reaches the PARENT at its next step boundary, as the ordinary
    // `task_finished` event — no new event kind, and no new thing for a driver
    // to know. Fenced, and framed as data rather than instructions.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, child) != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "as DATA") != null);
    }

    // ⑤ `model` says what THIS delegation runs on (DESIGN §7.8). Two refusals,
    // both before anything is created: a string that is not a model reference,
    // and a reference on a FOLLOW-UP — that session froze its identity when it
    // was created (physics #2), and silently ignoring the argument would be the
    // worst of the three available answers.
    {
        const bad = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\",\"model\":\"/nope\"}" }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
        });
        defer alloc.free(bad.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad.code);
        try std.testing.expect(std.mem.indexOf(u8, bad.stdout, "<profile>") != null);
        try std.testing.expect(std.mem.indexOf(u8, bad.stdout, "config show") != null);
    }
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"more\",\"model\":\"scripted\"}}", .{child});
        defer alloc.free(args);
        const late = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
        });
        defer alloc.free(late.stdout);
        try std.testing.expectEqual(@as(u8, 1), late.code);
        try std.testing.expect(std.mem.indexOf(u8, late.stdout, "NEW delegation") != null);
    }

    // ⑥ A ledger line is as long as the text inside it: the task alone can be
    // thousands of bytes, and an assistant turn carries the provider's opaque
    // reasoning as well. So whoever reads the child's `--stream` has to hold a
    // whole line whatever its length — a reader that gives up on a long one
    // stops draining a pipe the child is still writing into, and then the child
    // blocks on stdout while the reader blocks on its stderr: the report never
    // arrives, and the parent waits for ever for a sub-agent that has already
    // finished. Nothing about that failure is visible in either session, which
    // is exactly why it is worth a test.
    {
        const long = try alloc.alloc(u8, 12 << 10);
        defer alloc.free(long);
        @memset(long, 'x');
        const args = try std.fmt.allocPrint(alloc, "{{\"name\":\"prober\",\"task\":\"{s}\"}}", .{long});
        defer alloc.free(args);
        const big = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(big.stdout);
        try std.testing.expectEqual(@as(u8, 0), big.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
    }
}

test "bundled agent: the personas the package ships need no files — list layers workspace over user over builtin and marks what it shadows, and a delegation to the builtin explore runs read-only with the pins its definition asks for" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // ① Nothing written anywhere: `explore`, `plan` and `general` are already
    // there. Distribution is the binary (DESIGN §7.8) — no install step, and no
    // directory to create.
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "list", "{}" });
        defer alloc.free(listed.stdout);
        try std.testing.expectEqual(@as(u8, 0), listed.code);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, listed.stdout, " \r\n"), .{});
        defer parsed.deinit();
        const rows = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 4), rows.len);
        for ([_][]const u8{ "explore", "general", "orchestrator", "plan" }) |want| {
            for (rows) |row| {
                if (!std.mem.eql(u8, row.object.get("name").?.string, want)) continue;
                try std.testing.expectEqualStrings("builtin", row.object.get("layer").?.string);
                try std.testing.expectEqual(false, row.object.get("shadowed").?.bool);
                try std.testing.expect(row.object.get("description").?.string.len != 0);
                // Every persona brings SOMETHING: tools to work with, or the
                // names it may pass work to (the coordinator's whole job).
                try std.testing.expect(row.object.get("pins").?.array.items.len != 0 or
                    row.object.get("agents").?.array.items.len != 0);
                break;
            } else return error.TestUnexpectedResult;
        }
        // The one that is read-only is the one that says so.
        for (rows) |row| {
            const ro = row.object.get("readonly").?.bool;
            try std.testing.expectEqual(std.mem.eql(u8, row.object.get("name").?.string, "explore"), ro);
        }
    }

    // ② A workspace definition of the same name WINS, and the builtin is still
    // listed, marked — the store roots' rule (§7.2), not a reserved name.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{ .sub_path = ".nulya/agents/explore.md", .data = "---\ndescription: mine\n---\nmy own explore\n" });
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "list", "{}" });
        defer alloc.free(listed.stdout);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, listed.stdout, " \r\n"), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 5), parsed.value.array.items.len);
        var winner_layer: []const u8 = "";
        var shadowed_builtin = false;
        for (parsed.value.array.items) |row| {
            if (!std.mem.eql(u8, row.object.get("name").?.string, "explore")) continue;
            if (row.object.get("shadowed").?.bool) {
                try std.testing.expectEqualStrings("builtin", row.object.get("layer").?.string);
                shadowed_builtin = true;
            } else winner_layer = row.object.get("layer").?.string;
        }
        try std.testing.expectEqualStrings("workspace", winner_layer);
        try std.testing.expect(shadowed_builtin);
        // …and the winner is what rendering that name writes.
        const m = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"explore\"}" });
        defer alloc.free(m.stdout);
        try std.testing.expect(std.mem.indexOf(u8, m.stdout, "\"layer\":\"workspace\"") != null);
    }
    try ws.deleteFile(io, ".nulya/agents/explore.md");

    // ③ The builtin `explore` pins `std`'s read-only tools. `render` hands those
    // pins on as written and has no opinion about whether they resolve: a pin
    // brings its own package into the session (DESIGN §5.1), so there is exactly
    // one judge of that, and it is the `session new` that would be refused.
    // Nothing is derived here, and no `members` list is answered any more.
    {
        const rendered = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"explore\"}" });
        defer alloc.free(rendered.stdout);
        try std.testing.expectEqual(@as(u8, 0), rendered.code);
        try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "\"ext:std/read\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "\"members\"") == null);
    }

    // ④ With `std` active, the builtin persona delegates for real: its pins
    // become the child's tool face, the membership they imply comes with them,
    // and `readonly` is held at the kernel's gate.
    const std_ref = try buildBundled(alloc, io, ws, exe_abs, "std");
    defer alloc.free(std_ref);
    const std_version = std_ref[std.mem.indexOfScalar(u8, std_ref, '@').? + 1 ..];
    {
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "std", std_version });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
    }

    // What "read-only" MEANS at the gate now travels on the gate request itself
    // (DESIGN §4), frozen from this very manifest at composition time. `ext
    // inspect <id>@<version>` still has to answer for it — it is how a person
    // checks the same claim — but nothing reads it to build an allow-list any
    // more, which is the derivation that once came back empty and made a
    // read-only delegation read-only in name only (BUGS #16).
    {
        const frozen = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", std_ref });
        defer alloc.free(frozen.stdout);
        try std.testing.expectEqual(@as(u8, 0), frozen.code);
        try std.testing.expect(std.mem.indexOf(u8, frozen.stdout, "\"readonly\": true") != null);
    }

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    const delegated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"explore\",\"task\":\"find the parser\"}" }, &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    });
    defer alloc.free(delegated.stdout);
    try std.testing.expectEqual(@as(u8, 0), delegated.code);
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "read-only") != null);
    const child = blk: {
        const at = std.mem.indexOf(u8, delegated.stdout, "session s-").? + "session ".len;
        var end = at;
        while (end < delegated.stdout.len and delegated.stdout[end] != ',' and delegated.stdout[end] != ' ') end += 1;
        break :blk try alloc.dupe(u8, delegated.stdout[at..end]);
    };
    defer alloc.free(child);

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The child's frozen composition: the persona as BYTES the header holds, the
    // `std` its pins brought in as the only member (nothing on the delegation's
    // command line named it — the kernel's own implication did, DESIGN §5.1),
    // and exactly the three read-only tools on its native face. The persona is
    // not an extension — the store gained nothing from this delegation.
    {
        const header = try support.readSessionFile(alloc, io, ws, child);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"source\":\"agent-explore\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"id\":\"agent-explore\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"id\":\"std\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"native_tools\":[\"ext:std/read\",\"ext:std/grep\",\"ext:std/glob\"]") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/extensions/agent-explore", .{}));
    }
    // …and the gate held it to them: the scripted provider's `shell` never ran.
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "cannot run shell") != null);
    }
}

test "bundled agent: a follow-up resumes the same delegated session rather than starting one; it is refused while the agent is still working, past max_exchanges, and outside a delegation" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // No pins: this test is about the conversation, not about a tool face.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/worker.md",
        .data = "---\ndescription: plain worker\nmax_exchanges: 1\n---\nDo the work.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const in_parent: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // ① The first delegation, and its report.
    const first = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"first\"}" }, in_parent);
    defer alloc.free(first.stdout);
    try std.testing.expectEqual(@as(u8, 0), first.code);
    // The receipt teaches the cheaper move for next time.
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "call agent again with session=") != null);
    const child = blk: {
        const at = std.mem.indexOf(u8, first.stdout, "session s-").? + "session ".len;
        var end = at;
        while (end < first.stdout.len and first.stdout[end] != ',' and first.stdout[end] != ' ') end += 1;
        break :blk try alloc.dupe(u8, first.stdout[at..end]);
    };
    defer alloc.free(child);
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // ② A follow-up goes into THAT session — append-only, so the sub-agent
    // resumes with everything it already found and hits its own prefix cache
    // (DESIGN §1). No new session is created.
    // Read the first report, as a model would before following up — and as this
    // test must, since `task wait --any` counts a done task whose result nobody
    // has drained yet.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
    }

    const before = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(before.stdout);
    const follow_request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"second, be specific\"}}", .{child});
    defer alloc.free(follow_request);
    const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", follow_request }, in_parent);
    defer alloc.free(again.stdout);
    try std.testing.expectEqual(@as(u8, 0), again.code);
    try std.testing.expect(std.mem.indexOf(u8, again.stdout, "follow-up sent to agent session") != null);
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }
    const after = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(after.stdout);
    try std.testing.expectEqual(std.mem.count(u8, before.stdout, "\n"), std.mem.count(u8, after.stdout, "\n"));

    // Two turns in the child's ledger, and two reports in the parent's inbox —
    // one background task each, the ordinary `task_finished` both times.
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, events.stdout, "\"kind\":\"user_text\""));
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "second, be specific") != null);
    }
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        // The second report, the same way as the first: an ordinary
        // `task_finished`, one background task per turn.
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
    }

    // ③ Past `max_exchanges`: named, with the number.
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"third\"}}", .{child});
        defer alloc.free(request);
        const over = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(over.stdout);
        try std.testing.expectEqual(@as(u8, 1), over.code);
        try std.testing.expect(std.mem.indexOf(u8, over.stdout, "allows 1 follow-up turn") != null);
    }

    // ④ Neither / both / a session that is not a delegation.
    {
        const neither = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"task\":\"x\"}" }, in_parent);
        defer alloc.free(neither.stdout);
        try std.testing.expect(std.mem.indexOf(u8, neither.stdout, "EITHER name") != null);
        const both = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"session\":\"s-x\",\"task\":\"x\"}" }, in_parent);
        defer alloc.free(both.stdout);
        try std.testing.expect(std.mem.indexOf(u8, both.stdout, "not both") != null);
        const plain_request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"x\"}}", .{parent});
        defer alloc.free(plain_request);
        const plain = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", plain_request }, in_parent);
        defer alloc.free(plain.stdout);
        try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "not a delegated agent session") != null);
    }

    // ⑤ While it is still working, a follow-up is refused rather than dropped
    // into the run that is producing the report. `loop` never ends its turn, so
    // the runner is still going when this is asked.
    {
        const busy_new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(busy_new.stdout);
        const busy_parent = try alloc.dupe(u8, std.mem.trim(u8, busy_new.stdout, " \r\n"));
        defer alloc.free(busy_parent);
        const busy_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{busy_parent});
        defer alloc.free(busy_file);
        const busy_env: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = busy_file },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "loop" },
        };
        const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"a long one\"}" }, busy_env);
        defer alloc.free(started.stdout);
        try std.testing.expectEqual(@as(u8, 0), started.code);
        const busy_child = blk: {
            const at = std.mem.indexOf(u8, started.stdout, "session s-").? + "session ".len;
            var end = at;
            while (end < started.stdout.len and started.stdout[end] != ',' and started.stdout[end] != ' ') end += 1;
            break :blk try alloc.dupe(u8, started.stdout[at..end]);
        };
        defer alloc.free(busy_child);

        const hurry = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"hurry\"}}", .{busy_child});
        defer alloc.free(hurry);
        const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", hurry }, busy_env);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "is still working") != null);

        const task_name = try std.fmt.allocPrint(alloc, "{s}/t1", .{busy_parent});
        defer alloc.free(task_name);
        const killed = try runCli(alloc, io, ws, &.{ exe_abs, "task", "kill", task_name });
        alloc.free(killed.stdout);
    }
}

test "bundled agent: only a persona with an agents whitelist carries the tool, it may reach only the names on that list, and the depth backstop stops an indirect cycle" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{ .sub_path = ".nulya/agents/worker.md", .data = "---\ndescription: a leaf\n---\nDo the work.\n" });
    try ws.writeFile(io, .{ .sub_path = ".nulya/agents/boss.md", .data = "---\ndescription: coordinates\nagents: [worker]\n---\nYou coordinate.\n" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const in_parent: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // A coordinator's session carries the tool; a leaf's does not — one field in
    // one place decides it, so a leaf has nothing to refuse later.
    const boss_file = try delegateTo(alloc, io, ws, exe_abs, ref, in_parent, parent, "boss", "coordinate");
    defer alloc.free(boss_file);
    const worker_file = try delegateTo(alloc, io, ws, exe_abs, ref, in_parent, parent, "worker", "work");
    defer alloc.free(worker_file);
    {
        const boss_header = try support.readSessionFile(alloc, io, ws, std.fs.path.stem(boss_file));
        defer alloc.free(boss_header);
        try std.testing.expect(std.mem.indexOf(u8, boss_header, "\"native_tools\":[\"ext:agent/agent\"]") != null);
        const worker_header = try support.readSessionFile(alloc, io, ws, std.fs.path.stem(worker_file));
        defer alloc.free(worker_header);
        try std.testing.expect(std.mem.indexOf(u8, worker_header, "ext:agent/agent") == null);
    }

    const in_boss: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = boss_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // The whitelist is read from the persona this session is WEARING (its frozen
    // header), and a name off the list comes back with the list.
    {
        const denied = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"explore\",\"task\":\"x\"}" }, in_boss);
        defer alloc.free(denied.stdout);
        try std.testing.expectEqual(@as(u8, 1), denied.code);
        try std.testing.expect(std.mem.indexOf(u8, denied.stdout, "may only delegate to: worker") != null);
    }

    // A leaf's session refuses every name, and says why rather than listing none.
    {
        const in_worker: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = worker_file },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        };
        const denied = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"x\"}" }, in_worker);
        defer alloc.free(denied.stdout);
        try std.testing.expectEqual(@as(u8, 1), denied.code);
        try std.testing.expect(std.mem.indexOf(u8, denied.stdout, "cannot delegate") != null);
    }

    // The depth backstop: a whitelist cannot see an INDIRECT cycle (`a` may
    // delegate to `b`, `b` to `a`), so the runner tells each step how deep it is
    // and this refuses at the bound. Not a security boundary — the variable is
    // absent when a person drives a delegated session — and it says so in DESIGN.
    {
        const deep: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = boss_file },
            .{ .key = "NULYA_AGENT_DEPTH", .value = "3" },
        };
        const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"x\"}" }, deep);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "levels deep") != null);
    }
}

/// Delegate to `name` from `parent` and wait for the report; returns the child's
/// session FILE path (what `NULYA_SESSION` takes). Caller frees.
fn delegateTo(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    ref: []const u8,
    env: []const EnvPair,
    parent: []const u8,
    name: []const u8,
    task: []const u8,
) ![]u8 {
    const request = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"task\":\"{s}\"}}", .{ name, task });
    defer alloc.free(request);
    const out = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, env);
    defer alloc.free(out.stdout);
    try std.testing.expectEqual(@as(u8, 0), out.code);
    const at = std.mem.indexOf(u8, out.stdout, "session s-").? + "session ".len;
    var end = at;
    while (end < out.stdout.len and out.stdout[end] != ',' and out.stdout[end] != ' ') end += 1;
    const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
    alloc.free(waited.stdout);
    return std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{out.stdout[at..end]});
}

// ── The bundled plan / ask extensions: the front end's two consumers ────────

test "bundled plan and ask: propose, todo and ask record without writing anything; approve renders the brief compact forks on, and the session that continues does not wear the planning persona" {
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

    const plan_ref = try buildBundled(alloc, io, ws, exe_abs, "plan");
    defer alloc.free(plan_ref);
    const ask_ref = try buildBundled(alloc, io, ws, exe_abs, "ask");
    defer alloc.free(ask_ref);

    // ① `propose` and `todo` answer and write NOTHING. The call itself, with the
    //    plan in its arguments, is already in the ledger — a second copy on disk
    //    would be a second truth (physics #3).
    {
        const ok = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", plan_ref, "propose", "{\"plan_md\":\"# Plan\\n\\nphase one\"}" });
        defer alloc.free(ok.stdout);
        try std.testing.expectEqual(@as(u8, 0), ok.code);
        try std.testing.expect(std.mem.indexOf(u8, ok.stdout, "end this turn now") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/handoffs", .{}));

        // A missing section names the field and still writes nothing — the
        // `handoff` discipline, so the retry is an informed one.
        const empty = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", plan_ref, "propose", "{}" });
        defer alloc.free(empty.stdout);
        try std.testing.expect(std.mem.indexOf(u8, empty.stdout, "-32602") != null);
        try std.testing.expect(std.mem.indexOf(u8, empty.stdout, "non-empty plan_md") != null);

        const list = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", plan_ref, "todo", "{\"items\":[{\"text\":\"read\",\"state\":\"done\"},{\"text\":\"plan\"}]}" });
        defer alloc.free(list.stdout);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "1 of 2 done") != null);

        const bad = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", plan_ref, "todo", "{\"items\":[{\"text\":\"x\",\"state\":\"nope\"}]}" });
        defer alloc.free(bad.stdout);
        try std.testing.expect(std.mem.indexOf(u8, bad.stdout, "not a state") != null);
    }

    // ② `ask` is the same shape: recorded, end the turn, nothing on disk. The
    //    question is answerable because it is in the conversation, not because
    //    anything here waited for an answer.
    {
        const ok = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ask_ref, "ask", "{\"question\":\"which one?\",\"options\":[\"a\",\"b\"]}" });
        defer alloc.free(ok.stdout);
        try std.testing.expectEqual(@as(u8, 0), ok.code);
        try std.testing.expect(std.mem.indexOf(u8, ok.stdout, "end this turn now") != null);

        const empty = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ask_ref, "ask", "{\"options\":[\"a\"]}" });
        defer alloc.free(empty.stdout);
        try std.testing.expect(std.mem.indexOf(u8, empty.stdout, "-32602") != null);
        try std.testing.expect(std.mem.indexOf(u8, empty.stdout, "non-empty question") != null);
    }

    // ③ A session wearing `plan`: the prompt is a frozen system block, the
    //    narrowing it asks for is frozen with the version (so "what this
    //    session's permission stance was" stays answerable afterwards), and the
    //    tools are on the model's face only because this session pinned them —
    //    membership and pin are two axes (DESIGN §7.5).
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", plan_ref, "--pin", "ext:plan/propose" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    {
        var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
        defer lenv.deinit();
        var model = EndTurnModel{};
        const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
        defer alloc.free(spath);
        var ws_real: [std.fs.max_path_bytes]u8 = undefined;
        const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
        var sess = try session.AgentSession.openDurable(alloc, .{
            .model = .{ .ptr = &model, .vtable = &EndTurnModel.vtable },
            .step_ctx = .{
                .tool_context = .{ .environment = lenv.environment(), .cwd = ws_path },
                .scratch_dir = ".nulya/scratch",
            },
        }, .{ .workspace = ws, .session_path = spath });
        defer sess.deinit();

        // `shell` plus the one pinned tool: `todo` and `approve` are declared
        // and not pinned, which is the whole of the second axis.
        try std.testing.expectEqual(@as(usize, 2), sess.composition.tools.tools.len);
        var saw_prompt = false;
        for (sess.composition.system_prompts.blocks) |b| {
            if (std.mem.indexOf(u8, b.source, "plan") != null) saw_prompt = true;
        }
        try std.testing.expect(saw_prompt);

        var checked_policy = false;
        for (sess.composition.extensions) |member| {
            if (!std.mem.eql(u8, member.id, "plan")) continue;
            const rel = try std.fmt.allocPrint(
                alloc,
                ".nulya/extensions/{s}/versions/{s}/extension.json",
                .{ member.id, member.version },
            );
            defer alloc.free(rel);
            const bytes = try ws.readFileAlloc(io, rel, alloc, .limited(1 << 20));
            defer alloc.free(bytes);
            var frozen = try manifest_mod.parse(alloc, bytes);
            defer frozen.deinit();
            try std.testing.expectEqual(@as(?bool, true), frozen.policy.?.readonly);
            checked_policy = true;
        }
        try std.testing.expect(checked_policy);
    }

    // One real turn, so there is a conversation to fork FROM: `compact` refuses
    // a session with no events, which is the honest answer to "continue from
    // where?" when there is no where.
    {
        const appended = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", id, "draft a plan" });
        alloc.free(appended.stdout);
        const stepped = try runCli(alloc, io, ws, &.{ exe_abs, "session", "step", id, "--max-steps", "1" });
        alloc.free(stepped.stdout);
    }

    // ④ `approve` is the one tool here that touches the disk, and what it writes
    //    is a brief in `handoff`'s own shape — so `compact --arg brief_file=`
    //    forks on it with no special case at all.
    const approve_args = try std.fmt.allocPrint(
        alloc,
        "{{\"session\":\"{s}\",\"plan_md\":\"# Plan\\n\\nphase one: touch src/main.zig\"}}",
        .{id},
    );
    defer alloc.free(approve_args);
    const approved = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", plan_ref, "approve", approve_args });
    defer alloc.free(approved.stdout);
    try std.testing.expectEqual(@as(u8, 0), approved.code);
    const brief_rel = try std.fmt.allocPrint(alloc, ".nulya/handoffs/{s}-1.md", .{id});
    defer alloc.free(brief_rel);
    try std.testing.expect(std.mem.indexOf(u8, approved.stdout, brief_rel) != null);

    const written = try ws.readFileAlloc(io, brief_rel, alloc, .limited(1 << 16));
    defer alloc.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "# Approved plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "touch src/main.zig") != null);

    const compact_ref = try buildBundled(alloc, io, ws, exe_abs, "compact");
    defer alloc.free(compact_ref);
    const fork_args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"brief_file\":\"{s}\"}}", .{ id, brief_rel });
    defer alloc.free(fork_args);
    const forked = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", compact_ref, "compact", fork_args });
    defer alloc.free(forked.stdout);
    try std.testing.expectEqual(@as(u8, 0), forked.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, forked.stdout, " \r\n"), .{});
    defer parsed.deinit();
    const child = parsed.value.object.get("session").?.string;
    const child_path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{child});
    defer alloc.free(child_path);
    const child_file = try ws.readFileAlloc(io, child_path, alloc, .limited(1 << 20));
    defer alloc.free(child_file);
    const header_line = child_file[0 .. std.mem.indexOfScalar(u8, child_file, '\n') orelse child_file.len];
    // The plan travelled; the persona that wrote it did not. `session new
    // --parent` takes no `--with`, and `plan` declares `on_request` so nothing
    // puts it back — which is the whole point of continuing in a fresh session.
    try std.testing.expect(std.mem.indexOf(u8, header_line, "\"plan\"") == null);
}
