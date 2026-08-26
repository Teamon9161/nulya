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
    //    same path a live agent uses: stdin is the arguments object, stdout is
    //    the result verbatim, so there is no envelope to decode (DESIGN §7.1).
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
    const v1 = try buildAndActivate(alloc, io, ws, zig_exe, "web.search", "web_search", support.plain_main_zig);
    defer alloc.free(v1);

    // A real `nulya ext run` invocation against v1.
    const run1 = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "web.search", "web_search", "{}" });
    defer alloc.free(run1.stdout);
    try std.testing.expectEqual(@as(u8, 0), run1.code);
    try std.testing.expect(std.mem.indexOf(u8, run1.stdout, "hello from a Nulya-built extension") != null);

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
    const v2_src = "// v2 implementation\n" ++ support.plain_main_zig;
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

    // A real extension that fails the way the wire says to — its message on
    // stderr, a non-zero exit: a normal failed invocation, never a host fault.
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
        \\    // Drain the arguments so the host's stdin write never blocks.
        \\    var in_buf: [4096]u8 = undefined;
        \\    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
        \\    const args_json = try reader.interface.allocRemaining(alloc, .limited(1 << 20));
        \\    defer alloc.free(args_json);
        \\
        \\    try std.Io.File.stderr().writeStreamingAll(io, "boom");
        \\    std.process.exit(1);
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
    const version = try buildAndActivate(alloc, io, ws, zig_exe, "demo", "greet", support.plain_main_zig);
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

test "cli: a system prompt's declared position orders the extension band, and a resume rebuilds the same bytes from the frozen manifests" {
    // DESIGN §5.6. `position` is package-authored metadata frozen with the rest
    // of the manifest, so the two paths that build system blocks — fresh
    // composition at `session new` and frozen composition at resume — have to
    // agree without either of them recording an order anywhere. Deliberately
    // adversarial to the old rule (member id order): the package that must come
    // FIRST is the one that sorts LAST.
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

    // `a.tail` sorts first and asks to be LAST; `z.head` sorts last and asks to
    // be FIRST; `m.body` never mentions position at all.
    const Pkg = struct { id: []const u8, manifest: []const u8, body: []const u8 };
    const pkgs = [_]Pkg{
        .{
            .id = "a.tail",
            .manifest =
            \\{"schema":"nulya.extension/v2","id":"a.tail","contributes":{"system_prompts":[{"path":"p.md","position":"late"}]}}
            ,
            .body = "TAIL\n",
        },
        .{
            .id = "m.body",
            .manifest =
            \\{"schema":"nulya.extension/v2","id":"m.body","contributes":{"system_prompts":["p.md"]}}
            ,
            .body = "BODY\n",
        },
        .{
            .id = "z.head",
            .manifest =
            \\{"schema":"nulya.extension/v2","id":"z.head","contributes":{"system_prompts":[{"path":"p.md","position":"early"}]}}
            ,
            .body = "HEAD\n",
        },
    };

    var with_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (with_args.items) |s| alloc.free(s);
        with_args.deinit(alloc);
    }
    for (pkgs) |p| {
        const draft = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", p.id });
        defer alloc.free(draft);
        try ws.createDirPath(io, draft);
        const manifest_rel = try std.fs.path.join(alloc, &.{ draft, "extension.json" });
        defer alloc.free(manifest_rel);
        try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = p.manifest });
        const body_rel = try std.fs.path.join(alloc, &.{ draft, "p.md" });
        defer alloc.free(body_rel);
        try ws.writeFile(io, .{ .sub_path = body_rel, .data = p.body });

        const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
        defer alloc.free(built.stdout);
        try std.testing.expectEqual(@as(u8, 0), built.code);
        const version = try extractVersion(alloc, built.stdout);
        defer alloc.free(version);
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", p.id, version });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
        try with_args.append(alloc, try alloc.dupe(u8, p.id));
    }

    // Fresh path, named in yet another order so nothing can be reading argv.
    const named: []const composition.WithRef = &.{
        .{ .id = "m.body" },
        .{ .id = "z.head" },
        .{ .id = "a.tail" },
    };
    var fresh = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{ .with = named });
    defer fresh.deinit(alloc);

    const expected = [_][]const u8{ "HEAD\n", "BODY\n", "TAIL\n" };
    try std.testing.expectEqual(@as(usize, 1 + expected.len), fresh.system_prompts.blocks.len);
    try std.testing.expectEqualStrings("kernel", fresh.system_prompts.blocks[0].source);
    for (expected, fresh.system_prompts.blocks[1..]) |want, block| {
        try std.testing.expectEqualStrings(want, block.bytes);
    }

    // …and the frozen path, from a session the real binary created and a second
    // process reopened: byte-identical blocks, sources included.
    const args = [_][]const u8{ exe_abs, "session", "new", "--profile", "scripted", "--with", "m.body", "--with", "z.head", "--with", "a.tail" };
    const created = try runCli(alloc, io, ws, &args);
    defer alloc.free(created.stdout);
    try std.testing.expectEqual(@as(u8, 0), created.code);
    const sid = std.mem.trim(u8, created.stdout, " \r\n");

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = EndTurnModel{};
    const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{sid});
    defer alloc.free(spath);
    var resumed = try session.AgentSession.openDurable(alloc, .{
        .model = .{ .ptr = &model, .vtable = &EndTurnModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    }, .{ .workspace = ws, .session_path = spath });
    defer resumed.deinit();

    const rebuilt = resumed.composition.system_prompts.blocks;
    try std.testing.expectEqual(fresh.system_prompts.blocks.len, rebuilt.len);
    for (fresh.system_prompts.blocks, rebuilt) |a_block, b_block| {
        try std.testing.expectEqualStrings(a_block.source, b_block.source);
        try std.testing.expectEqualStrings(a_block.bytes, b_block.bytes);
    }
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
    // words carried out as the failed call's text.
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

    // Built, never activated: `--with` makes it a member of THIS session, and
    // its one tool is `surface: auto`, so membership alone is what puts it on
    // the model's face (DESIGN §5.1). No pin — a pin would be refused, because
    // only `manual` tools take one.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", ref });
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

/// The version `current` names for `id` in a store root under `ws` — the file's
/// first field; the rest of the line is what activation recorded about `apply`
/// (`store.Active`). Caller owns it.
fn readActive(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, root_rel: []const u8, id: []const u8) ![]u8 {
    const rel = try std.fs.path.join(alloc, &.{ root_rel, id, "current" });
    defer alloc.free(rel);
    const raw = try ws.readFileAlloc(io, rel, alloc, .limited(256));
    defer alloc.free(raw);
    var fields = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    return alloc.dupe(u8, fields.next() orelse "");
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

/// A script entry, PowerShell and POSIX sh: drain stdin, print one line. Its
/// stdout IS the result, so the tests below assert on that exact sentence.
/// Kept here rather than as a template, because `ext init` generates its own
/// (`templates.scriptSh` / `scriptPs1`) and a fixture that moved whenever the
/// scaffold's wording did would be a test of the wording.
const greeter_script_ps1 =
    \\$ErrorActionPreference = 'Stop'
    \\$in = [Console]::In.ReadToEnd()
    \\[Console]::Out.Write('hello from a Nulya script extension')
    \\
;

const greeter_script_sh =
    \\#!/bin/sh
    \\cat >/dev/null
    \\printf 'hello from a Nulya script extension'
    \\
;

/// Scaffold a host-appropriate script extension (PowerShell on Windows, POSIX
/// sh elsewhere) and build it into an immutable version WITHOUT a toolchain.
/// Returns the built version id; caller frees.
fn scaffoldAndBuildScript(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8, tool_name: []const u8) ![]u8 {
    const windows = @import("builtin").os.tag == .windows;
    const script_name = if (windows) "run.ps1" else "run.sh";
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const interpreter = if (windows) "powershell" else "sh";
    const body = if (windows) greeter_script_ps1 else greeter_script_sh;

    const ext_dir = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(ext_dir);
    const src_dir = try std.fs.path.join(alloc, &.{ ext_dir, "src" });
    defer alloc.free(src_dir);
    try ws.createDirPath(io, src_dir);

    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{ "entry": "{s}", "interpreter": "{s}" }},
        \\  "contributes": {{
        \\    "tools": [{{ "name": "{s}", "surface": "manual", "description": "A script tool.", "input": {{ "type": "object", "properties": {{}} }} }}]
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

test "manifest surface: the frozen version keeps what the draft declared, and an unknown word is refused before anything is built" {
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
    const script_body = if (windows) greeter_script_ps1 else greeter_script_sh;

    // A script package, so this costs no toolchain: four tools, one for each
    // thing a package can say about where a tool belongs, plus the silence.
    const draft_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "faces";
    const src_rel = draft_rel ++ std.fs.path.sep_str ++ "src";
    try ws.createDirPath(io, src_rel);
    const script_rel = try std.fs.path.join(alloc, &.{ src_rel, script_name });
    defer alloc.free(script_rel);
    try ws.writeFile(io, .{ .sub_path = script_rel, .data = script_body });

    const good = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"faces","runtime":{{"entry":"{s}","interpreter":"{s}"}},"contributes":{{"tools":[
        \\{{"name":"ask","input":{{}},"surface":"auto"}},
        \\{{"name":"pinny","input":{{}},"surface":"manual"}},
        \\{{"name":"drive","input":{{}},"surface":"internal"}},
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
    try std.testing.expectEqual(@as(usize, 4), frozen.tools.len);
    try std.testing.expectEqual(manifest_mod.Surface.auto, frozen.tools[0].surfaceOf());
    try std.testing.expectEqual(manifest_mod.Surface.manual, frozen.tools[1].surfaceOf());
    try std.testing.expectEqual(manifest_mod.Surface.internal, frozen.tools[2].surfaceOf());
    // Silence survives as silence in the FILE — the kernel writes nothing in —
    // while the reading of it is `auto` (DESIGN §7.2.1).
    try std.testing.expect(frozen.tools[3].surface == null);
    try std.testing.expectEqual(manifest_mod.Surface.auto, frozen.tools[3].surfaceOf());
    // And the kernel acts on it: only the `manual` tool takes a pin, while
    // membership alone puts the `auto` one on the face and leaves the rest off.
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    {
        var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer ext_root.close(io);
        try store.Store.init(io, ext_root).activate(alloc, "faces", version);
    }
    const pins = [_][]const u8{"ext:faces/pinny"};
    var comp = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{
        .pinned_native_tools = &pins,
        .with = &.{.{ .id = "faces" }},
    });
    defer comp.deinit(alloc);
    try std.testing.expect(comp.tools.lookup("pinny") != null);
    try std.testing.expect(comp.tools.lookup("ask") != null);
    try std.testing.expect(comp.tools.lookup("quiet") != null);
    try std.testing.expect(comp.tools.lookup("drive") == null);
    try std.testing.expectError(error.PinToolNotPinnable, composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{
        .pinned_native_tools = &[_][]const u8{"ext:faces/drive"},
    }));

    // A word outside the three is a manifest fault: `ext build` names it and
    // writes no version at all. The three words this vocabulary used to be
    // spelled with are outside it too.
    const bad_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "typo";
    try ws.createDirPath(io, bad_rel ++ std.fs.path.sep_str ++ "src");
    const bad_script_rel = try std.fs.path.join(alloc, &.{ bad_rel, "src", script_name });
    defer alloc.free(bad_script_rel);
    try ws.writeFile(io, .{ .sub_path = bad_script_rel, .data = script_body });
    const bad = try std.fmt.allocPrint(alloc,
        \\{{"schema":"nulya.extension/v2","id":"typo","runtime":{{"entry":"{s}","interpreter":"{s}"}},"contributes":{{"tools":[{{"name":"t","input":{{}},"surface":"driver"}}]}}}}
    , .{ entry, interpreter });
    defer alloc.free(bad);
    try ws.writeFile(io, .{ .sub_path = bad_rel ++ std.fs.path.sep_str ++ "extension.json", .data = bad });

    const refused = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", bad_rel });
    defer alloc.free(refused.stdout);
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    const said = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "build", bad_rel }, &.{});
    defer alloc.free(said);
    try std.testing.expect(std.mem.indexOf(u8, said, "InvalidSurface") != null);
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

test "bundled agent: a delegation is a d-id of its own — another turn goes into the same conversation, its exchange budget is counted from the delegation's record rather than the child's ledger, and a session id is refused with the word that replaced it" {
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
        .data = "---\ndescription: plain worker\nmax_exchanges: 2\n---\nDo the work.\n",
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

    // ① The first delegation. The receipt names the DELEGATION — what the model
    //    says back to this tool — and, because the abstraction does not hide
    //    anything (D2), the remote conversation behind it as well.
    const first = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"first\"}" }, in_parent);
    defer alloc.free(first.stdout);
    try std.testing.expectEqual(@as(u8, 0), first.code);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "call agent again with session=d-") != null);
    const d = try delegationOf(alloc, first.stdout);
    defer alloc.free(d);
    const child = try remoteOf(alloc, first.stdout);
    defer alloc.free(child);

    // The record is this package's own journal of it: one opening row naming the
    // runner and what it opened, then one row per message.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"kind\":\"created\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"nulya\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, child) != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }
    // Read the first report, as a model would before following up — and as this
    // test must, since `task wait --any` counts a done task whose result nobody
    // has drained yet.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        // The frame names the delegation, and the sentence under it still points
        // at the remote transcript.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, d) != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "session events") != null);
    }

    // ② The exchange budget is the RECORD's turn count, not the child ledger's
    //    user turns — the only count an external runner could ever answer too.
    //    Two turns appended to the child directly, behind this tool's back, are
    //    three user turns in that session and still one message in the
    //    delegation: the budget must not move.
    {
        for ([_][]const u8{ "sideband one", "sideband two" }) |text| {
            const said = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", child, text });
            defer alloc.free(said.stdout);
            try std.testing.expectEqual(@as(u8, 0), said.code);
        }
    }

    const before = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(before.stdout);
    const follow_request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"second, be specific\"}}", .{d});
    defer alloc.free(follow_request);
    const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", follow_request }, in_parent);
    defer alloc.free(again.stdout);
    try std.testing.expectEqual(@as(u8, 0), again.code);
    try std.testing.expect(std.mem.indexOf(u8, again.stdout, d) != null);
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }
    // Nothing new was created: another turn goes into the conversation that
    // already holds everything it found (DESIGN §1).
    const after = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(after.stdout);
    try std.testing.expectEqual(std.mem.count(u8, before.stdout, "\n"), std.mem.count(u8, after.stdout, "\n"));
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "second, be specific") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "sideband two") != null);
    }
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
    }

    // ③ The budget itself. Two turns have been sent into the delegation and it
    //    allows two follow-ups on top of the first, so a third goes through —
    //    which the child's four user turns would already have refused — and the
    //    fourth is named, with the number.
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"third\"}}", .{d});
        defer alloc.free(request);
        const within = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(within.stdout);
        try std.testing.expectEqual(@as(u8, 0), within.code);
    }
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"fourth\"}}", .{d});
        defer alloc.free(request);
        const over = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(over.stdout);
        try std.testing.expectEqual(@as(u8, 1), over.code);
        try std.testing.expect(std.mem.indexOf(u8, over.stdout, "follow-up turn") != null);
    }

    // ④ The vocabulary. A SESSION id is what this took before delegations had
    //    ids of their own; it is refused with the word that replaced it rather
    //    than with a missing directory (D11), and an id of the right shape that
    //    names nothing is a different answer again.
    {
        const old_shape = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"x\"}}", .{child});
        defer alloc.free(old_shape);
        const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", old_shape }, in_parent);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "d-") != null);

        const unknown = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"session\":\"d-000000000000\",\"task\":\"x\"}" }, in_parent);
        defer alloc.free(unknown.stdout);
        try std.testing.expectEqual(@as(u8, 1), unknown.code);
        try std.testing.expect(std.mem.indexOf(u8, unknown.stdout, "no delegation") != null);
    }

    // ⑤ Neither / both / interrupt without something to interrupt.
    {
        const neither = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"task\":\"x\"}" }, in_parent);
        defer alloc.free(neither.stdout);
        try std.testing.expect(std.mem.indexOf(u8, neither.stdout, "EITHER name") != null);
        const both = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"session\":\"d-000000000000\",\"task\":\"x\"}" }, in_parent);
        defer alloc.free(both.stdout);
        try std.testing.expect(std.mem.indexOf(u8, both.stdout, "not both") != null);
        const early = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"x\",\"interrupt\":true}" }, in_parent);
        defer alloc.free(early.stdout);
        try std.testing.expectEqual(@as(u8, 1), early.code);
        try std.testing.expect(std.mem.indexOf(u8, early.stdout, "interrupt applies") != null);
    }

    // Let the last runner finish before the workspace goes away.
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        alloc.free(waited.stdout);
    }
}

test "bundled agent: the wake invariant — a turn sent while a runner holds the delegation's lease is queued rather than refused and starts nothing, a runner that loses the race for that lease reports nothing at all, and a turn sent once the lease is free starts a fresh runner that finds everything waiting" {
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
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/worker.md",
        .data = "---\ndescription: plain worker\n---\nDo the work.\n",
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

    const first = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"first\"}" }, in_parent);
    defer alloc.free(first.stdout);
    try std.testing.expectEqual(@as(u8, 0), first.code);
    const d = try delegationOf(alloc, first.stdout);
    defer alloc.free(d);
    const child = try remoteOf(alloc, first.stdout);
    defer alloc.free(child);
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
    }

    const lock_path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/.runner.lock", .{d});
    defer alloc.free(lock_path);

    // ① A runner is driving. Its lease is what says so — an OS lock, so nothing
    //    has to be believed about a process that may already be dead. A turn
    //    sent now is ACCEPTED (D3: it is what a person typing mid-answer does),
    //    queued into the conversation, and starts no second runner: the holder
    //    will find it.
    var held = try ws.createFile(io, lock_path, .{ .truncate = false, .read = true, .lock = .exclusive });
    const tasks_before = try countTasks(alloc, io, ws, exe_abs, parent);
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"queued one\"}}", .{d});
        defer alloc.free(request);
        const queued = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(queued.stdout);
        try std.testing.expectEqual(@as(u8, 0), queued.code);
        try std.testing.expect(std.mem.indexOf(u8, queued.stdout, "working right now") != null);
    }
    try std.testing.expectEqual(tasks_before, try countTasks(alloc, io, ws, exe_abs, parent));

    // ② A redundant runner — two senders probing at the same moment is the race
    //    the lease exists for — loses it and says NOTHING. A report frame from a
    //    runner that drove nothing would be a sub-agent's findings that no
    //    sub-agent produced, arriving in the parent as an ordinary message.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"delegation\":\"{s}\",\"session\":\"{s}\",\"agent\":\"worker\"}}", .{ d, child });
        defer alloc.free(args);
        const lost = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "run", args }, in_parent);
        defer alloc.free(lost.stdout);
        try std.testing.expectEqual(@as(u8, 0), lost.code);
        try std.testing.expect(std.mem.indexOf(u8, lost.stdout, "<agent-report") == null);
    }

    // ③ The lease is free again — the runner left, or was killed, and the OS
    //    released it either way. The next turn starts a fresh runner, and that
    //    runner finds BOTH messages: the one queued while the lease was held has
    //    been waiting in the conversation all along.
    held.close(io);
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"queued two\"}}", .{d});
        defer alloc.free(request);
        const sent = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(sent.stdout);
        try std.testing.expectEqual(@as(u8, 0), sent.code);
        try std.testing.expect(std.mem.indexOf(u8, sent.stdout, "background task") != null);
    }
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "60000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "queued one") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "queued two") != null);
    }
}

test "bundled agent: an interrupt stops the run in flight — the step is killed where it stands, the kernel repairs the batch it left, and the message the interrupt carried is taken up in the next round" {
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

    // `loop` never ends its turn, so this delegation keeps stepping until its
    // budget runs out — a run that is genuinely in flight to interrupt.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/slow.md",
        .data = "---\ndescription: never finishes on its own\nmax_steps: 30\n---\nKeep going.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const looping: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "loop" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"slow\",\"task\":\"go on for a while\"}" }, looping);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const child = try remoteOf(alloc, started.stdout);
    defer alloc.free(child);

    // Wait until the run is actually under way: the first tool result in the
    // child's ledger says a step is executing, which is what an interrupt is for.
    try waitForEvent(alloc, io, ws, exe_abs, child, "\"kind\":\"tool_results\"");

    const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"INTERRUPT-SENTINEL\",\"interrupt\":true}}", .{d});
    defer alloc.free(request);
    const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, looping);
    defer alloc.free(interrupted.stdout);
    try std.testing.expectEqual(@as(u8, 0), interrupted.code);

    // An interrupt is a DELIVERY, not a kind of message (D3): the record holds
    // one ordinary turn row, marked with how it was sent.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"interrupt\":true") != null);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        // The step that was running died where it stood, leaving a call batch
        // with no results; the kernel closes it at the next step boundary, which
        // is the next round of the very same runner (DESIGN §4).
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "interrupted before Nulya recorded results") != null);
        // …and the message the interrupt carried is in the conversation.
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "INTERRUPT-SENTINEL") != null);
    }
    // The marker is consumed, never left behind to cut short a later round.
    {
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        try std.testing.expectError(error.FileNotFound, ws.access(io, marker, .{}));
    }
}

/// The delegation id out of a receipt (`… — delegation d-…, session s-…`).
fn delegationOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "delegation d-").? + "delegation ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

/// The remote conversation out of the same receipt — named on purpose: the
/// abstraction gives the facts one name, it does not hide them (D2).
fn remoteOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "session s-").? + "session ".len;
    var end = at;
    while (end < text.len and text[end] != ',' and text[end] != ' ') end += 1;
    return alloc.dupe(u8, text[at..end]);
}

fn readRecord(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, d: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/record.jsonl", .{d});
    defer alloc.free(path);
    return ws.readFileAlloc(io, path, alloc, .limited(1 << 20));
}

fn countTasks(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    parent: []const u8,
) !usize {
    const listed = try runCli(alloc, io, ws, &.{ exe_abs, "task", "list", "--session", parent, "--json" });
    defer alloc.free(listed.stdout);
    return std.mem.count(u8, listed.stdout, "\"full\"");
}

/// Poll a session's ledger until `needle` shows up. Bounded, because a test that
/// hangs says less than one that fails.
fn waitForEvent(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    session_id: []const u8,
    needle: []const u8,
) !void {
    var tries: usize = 0;
    while (tries < 600) : (tries += 1) {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", session_id });
        defer alloc.free(events.stdout);
        if (std.mem.indexOf(u8, events.stdout, needle) != null) return;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
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
    //
    // MEMBERSHIP is the whole of that decision. `agent` is `surface: "auto"`
    // (§5.1), so the one `--with` the delegation adds for a coordinator both
    // freezes the package into `active` and puts its entry tool in the native
    // face; no pin is passed, and one naming it would be refused. The three
    // `internal` tools stay off that face — `--bare` means nothing else can put
    // them there either, so the list is exactly one long.
    const boss_file = try delegateTo(alloc, io, ws, exe_abs, ref, in_parent, parent, "boss", "coordinate");
    defer alloc.free(boss_file);
    const worker_file = try delegateTo(alloc, io, ws, exe_abs, ref, in_parent, parent, "worker", "work");
    defer alloc.free(worker_file);
    {
        const boss_header = try support.readSessionFile(alloc, io, ws, std.fs.path.stem(boss_file));
        defer alloc.free(boss_header);
        try std.testing.expect(std.mem.indexOf(u8, boss_header, "\"native_tools\":[\"ext:agent/agent\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, boss_header, "\"id\":\"agent\"") != null);
        // A leaf is not a member at all, so the tool is nowhere in its header —
        // neither as a frozen member nor as a native slot.
        const worker_header = try support.readSessionFile(alloc, io, ws, std.fs.path.stem(worker_file));
        defer alloc.free(worker_header);
        try std.testing.expect(std.mem.indexOf(u8, worker_header, "ext:agent/agent") == null);
        try std.testing.expect(std.mem.indexOf(u8, worker_header, "\"id\":\"agent\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, worker_header, "\"native_tools\":[]") != null);
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
        try std.testing.expect(std.mem.startsWith(u8, empty.stdout, "exit 1\nstderr:\n"));
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
        try std.testing.expect(std.mem.startsWith(u8, empty.stdout, "exit 1\nstderr:\n"));
        try std.testing.expect(std.mem.indexOf(u8, empty.stdout, "non-empty question") != null);
    }

    // ③ A session wearing `plan`: the prompt is a frozen system block, the
    //    narrowing it asks for is frozen with the version (so "what this
    //    session's permission stance was" stays answerable afterwards), and
    //    `propose` / `todo` are on the model's face because they are
    //    `surface: auto` and this session is a member — while `approve`, which
    //    is `internal`, is not (DESIGN §5.1).
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", plan_ref });
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

        // `shell` plus the two `surface: auto` tools. `approve` is `internal`
        // and stays off the face however the package is composed — that is the
        // whole of the second axis (DESIGN §5.1).
        try std.testing.expectEqual(@as(usize, 3), sess.composition.tools.tools.len);
        try std.testing.expect(sess.composition.tools.lookup("propose") != null);
        try std.testing.expect(sess.composition.tools.lookup("todo") != null);
        try std.testing.expect(sess.composition.tools.lookup("approve") == null);
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

// ── the Codex runner (contract ar-d) ────────────────────────────────────────
//
// A delegation whose definition says `runner: codex` is held by a Codex thread
// instead of a nulya session. These run against `tests/fake_codex.zig` — an
// app-server that answers the protocol and never leaves this machine — because
// everything worth pinning down is on THIS side of that conversation: which
// requests the runner sends, when it sends them, and what it refuses to open.

/// The offline app-server, built by `build.zig` for exactly this. Absent means
/// the suite was not launched through `zig build e2e`.
fn fakeCodex(alloc: std.mem.Allocator) !?[]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const named = host_env.get("NULYA_FAKE_CODEX") orelse return null;
    if (named.len == 0) return null;
    return try std.fs.path.resolve(alloc, &.{named});
}

/// The remote out of a codex receipt (`… — delegation d-…, codex thread t-…`).
/// Named on purpose, like the nulya one: the abstraction gives the facts one
/// name, it does not hide them (D2).
fn codexThreadOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "codex thread ").? + "codex thread ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

/// Poll a file in the workspace until it holds `needle`. Bounded, because a test
/// that hangs says less than one that fails.
fn waitForText(
    io: std.Io,
    alloc: std.mem.Allocator,
    ws: std.Io.Dir,
    path: []const u8,
    needle: []const u8,
) !void {
    var tries: usize = 0;
    while (tries < 600) : (tries += 1) {
        if (ws.readFileAlloc(io, path, alloc, .limited(1 << 20))) |body| {
            defer alloc.free(body);
            if (std.mem.indexOf(u8, body, needle) != null) return;
        } else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

/// Poll until a path is gone. Used on the runner's own on-disk state — an empty
/// `<d>/inbox/` means the runner took the message, a missing `<d>/interrupt`
/// means it took the marker — so a test waits on a FACT rather than on a guess
/// about how fast a background task runs.
fn waitForGone(io: std.Io, ws: std.Io.Dir, path: []const u8) !void {
    var tries: usize = 0;
    while (tries < 600) : (tries += 1) {
        ws.access(io, path, .{}) catch return;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn inboxEmpty(io: std.Io, alloc: std.mem.Allocator, ws: std.Io.Dir, d: []const u8) !bool {
    const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/inbox", .{d});
    defer alloc.free(path);
    var dir = ws.openDir(io, path, .{ .iterate = true }) catch return true;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) return false;
    }
    return true;
}

fn waitForInboxDrained(io: std.Io, alloc: std.mem.Allocator, ws: std.Io.Dir, d: []const u8) !void {
    var tries: usize = 0;
    while (tries < 600) : (tries += 1) {
        if (try inboxEmpty(io, alloc, ws, d)) return;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "bundled agent: a codex delegation is a thread, not a session — the record freezes the runner and its opaque model, the report comes back through the parent's inbox, and a turn sent while it is idle waits in the delegation's own inbox until the next round takes it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const codex_exe = (try fakeCodex(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(codex_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // A definition whose only nulya-shaped field is the body. `runner_model` is
    // the other harness's vocabulary (D9) — never parsed here.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: reads the codebase through codex\nrunner: codex\nrunner_model: some-codex-model\n---\nYou are a scout. Report what you found.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const with_codex: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // ① The call's `model` beats the definition's, and for an external runner it
    // is passed through WHOLE. `/nope` is the string a nulya delegation refuses
    // outright as a malformed profile reference — one string, two runners, two
    // right answers, because the grammar belongs to the harness (D9).
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"find the parser\",\"model\":\"/nope\"}" }, with_codex);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    // The receipt names the delegation AND what is behind it — a thread here,
    // never a session id that does not exist.
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "codex thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "session events") == null);

    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const thread = try codexThreadOf(alloc, started.stdout);
    defer alloc.free(thread);

    // ② The record froze which harness holds this delegation and what it was
    // asked to run on — in its own column, so nothing has to be interpreted to
    // be read (D2).
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"codex\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_model\":\"/nope\"") != null);
        const remote = try std.fmt.allocPrint(alloc, "\"remote\":\"{s}\"", .{thread});
        defer alloc.free(remote);
        try std.testing.expect(std.mem.indexOf(u8, rows, remote) != null);
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // ③ The report reaches the parent exactly the way a nulya delegation's does:
    // the ordinary `task_finished` event, drained at the next step boundary. The
    // runner contract earned that for free — no new event kind, and no driver
    // had to learn anything (D8).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        // The fake echoes what it was given, so this is the task travelling the
        // whole way: inbox file -> drain -> `turn/start` input -> agent message.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: find the parser") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "as DATA") != null);
    }

    // ④ Another turn into the same delegation, sent while nothing is running.
    // The channel is the delegation's own inbox (D5) — Codex has no inbox for us
    // to append to — and the proof that it was used is both the directory being
    // there and the second report quoting a message that could only have come
    // through it.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"and the lexer\"}}", .{d});
        defer alloc.free(args);
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, with_codex);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);

        const inbox = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/inbox", .{d});
        defer alloc.free(inbox);
        try ws.access(io, inbox, .{});

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: and the lexer") != null);
        // Drained, so the wake invariant's `pending` goes false and nobody
        // starts a runner for a message that has already been answered.
        try std.testing.expect(try inboxEmpty(io, alloc, ws, d));
    }

    // ⑤ Exchanges are counted from the record, whatever runner is behind it.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
}

test "bundled agent: a codex delegation that is running takes a message as turn/steer and an interrupt as turn/interrupt" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const codex_exe = (try fakeCodex(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(codex_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: scouts\nrunner: codex\n---\nYou are a scout.\n",
    });

    // The fake holds its first turn open while this file exists, so the test
    // decides when the run in flight ends rather than racing it; every request
    // it receives lands in the log, which is how "the runner sent turn/steer"
    // becomes a fact rather than an inference from a report.
    try ws.writeFile(io, .{ .sub_path = "hold", .data = "" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const held: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "FAKE_CODEX_LOG", .value = "codex-log.txt" },
        .{ .key = "FAKE_CODEX_HOLD", .value = "hold" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"go on for a while\"}" }, held);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    // Wait until a turn is genuinely under way — that is what a steer and an
    // interrupt are for.
    try waitForText(io, alloc, ws, "codex-log.txt", "turn/start");

    // ① An ordinary message, delivered while the turn is running. The runner
    // drains `<d>/inbox/` between the lines it reads, and a message found there
    // mid-turn becomes `turn/steer` — the same act as typing while the main
    // conversation is answering (D3). An empty inbox is the runner saying it
    // took it.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"also check the lexer\"}}", .{d});
        defer alloc.free(args);
        const steered = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(steered.stdout);
        try std.testing.expectEqual(@as(u8, 0), steered.code);
        // It is working, so nothing new was started for it.
        try std.testing.expect(std.mem.indexOf(u8, steered.stdout, "queued") != null);
        try waitForInboxDrained(io, alloc, ws, d);
    }

    // ② An interrupt: the same message, then the marker (D6). The runner checks
    // the marker BEFORE it drains, so the message behind it stays where it is,
    // and the marker becomes this harness's own stop verb.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"STOP-SENTINEL\",\"interrupt\":true}}", .{d});
        defer alloc.free(args);
        const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(interrupted.stdout);
        try std.testing.expectEqual(@as(u8, 0), interrupted.code);
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        // Taken, never left behind to cut short a later round.
        try waitForGone(io, ws, marker);
    }

    // Let the held turn end, so the round that was interrupted can finish.
    try ws.deleteFile(io, "hold");

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // Both verbs really went down the wire. The fake reads what was sent mid-turn
    // once the turn is over, so the log is the record of it either way.
    {
        const log = try ws.readFileAlloc(io, "codex-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "turn/steer") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "turn/interrupt") != null);
    }
}

test "bundled agent: a read-only codex delegation is refused outright when the sandbox comes back wider than it asked for" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const codex_exe = (try fakeCodex(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(codex_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data = "---\ndescription: only reads\nreadonly: true\nrunner: codex\n---\nYou only read.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    // The lever is the sandbox the harness REPORTS applying — the one fact D10's
    // check reads. Everything else about this delegation is identical between
    // the two runs below, so the refusal can have no other cause.
    const wide: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "FAKE_CODEX_SANDBOX", .value = "workspaceWrite" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, wide);
    defer alloc.free(refused.stdout);
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "read-only") != null);
    // Fail CLOSED: nothing was opened, so there is no delegation to drive and
    // nothing to quietly run wider than it said.
    try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/delegations", .{}));

    // …and with a harness that confirms the ceiling, the same definition opens.
    const narrow: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const opened = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, narrow);
    defer alloc.free(opened.stdout);
    try std.testing.expectEqual(@as(u8, 0), opened.code);
    try std.testing.expect(std.mem.indexOf(u8, opened.stdout, "read-only") != null);

    const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
    defer alloc.free(waited.stdout);
    try std.testing.expectEqual(@as(u8, 0), waited.code);
}

// ── the Claude runner (contract ar-f) ───────────────────────────────────────
//
// A delegation whose definition says `runner: claude` is held by a Claude Code
// session instead of a nulya one. These run against `tests/fake_claude.zig` — a
// `claude -p` that answers the stream-json protocol and never leaves this
// machine — because everything worth pinning down is on THIS side of that
// conversation: which flags the runner passes, when it writes a message into
// stdin, and what it refuses to run.

/// The offline `claude`, built by `build.zig` for exactly this. Absent means the
/// suite was not launched through `zig build e2e`.
fn fakeClaude(alloc: std.mem.Allocator) !?[]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const named = host_env.get("NULYA_FAKE_CLAUDE") orelse return null;
    if (named.len == 0) return null;
    return try std.fs.path.resolve(alloc, &.{named});
}

/// The remote out of a claude receipt (`… — delegation d-…, claude session <uuid>`).
fn claudeSessionOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "claude session ").? + "claude session ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

test "bundled agent: a claude delegation is a claude session — the record freezes runner, version and opaque model, the persona is frozen beside it, the report comes back through the parent's inbox, and the next round resumes the session it opened" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const claude_exe = (try fakeClaude(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(claude_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: reads the codebase through claude\nrunner: claude\nrunner_model: some-claude-model\n---\nYou are a scout. Report what you found.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const with_claude: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
        .{ .key = "FAKE_CLAUDE_LOG", .value = "claude-log.txt" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // ① The call's `model` beats the definition's, and for an external runner it
    // is passed through WHOLE — `/nope` is the string a nulya delegation refuses
    // outright as a malformed profile reference (D9).
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"find the parser\",\"model\":\"/nope\"}" }, with_claude);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    // The receipt names the delegation AND what is behind it — a claude session
    // here, never a nulya session id that does not exist.
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "claude session") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "nulya session events") == null);

    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const remote = try claudeSessionOf(alloc, started.stdout);
    defer alloc.free(remote);

    // ② The record froze which harness holds this delegation, at what version,
    // and what it was asked to run on — each in its own column, so nothing has to
    // be interpreted to be read (D2/D7).
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"claude\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_model\":\"/nope\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_version\":") != null);
        const named = try std.fmt.allocPrint(alloc, "\"remote\":\"{s}\"", .{remote});
        defer alloc.free(named);
        try std.testing.expect(std.mem.indexOf(u8, rows, named) != null);
    }

    // ③ The persona is frozen INTO the delegation, because claude rebuilds its
    // prompt from flags on every round: without this copy the delegation would
    // silently follow later edits to the definition file.
    {
        const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/persona.md", .{d});
        defer alloc.free(path);
        const frozen = try ws.readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(frozen);
        try std.testing.expect(std.mem.indexOf(u8, frozen, "You are a scout.") != null);
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // ④ The report reaches the parent exactly the way a nulya delegation's does:
    // the ordinary `task_finished` event, drained at the next step boundary. No
    // new event kind, and no driver had to learn anything (D8).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        // The fake echoes what it was given, so this is the task travelling the
        // whole way: inbox file -> take -> stdin user message -> assistant text.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: find the parser") != null);
    }

    // ⑤ The first round OPENED the session under the name we minted, carrying the
    // persona and the model straight through.
    {
        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        const opened = try std.fmt.allocPrint(alloc, "--session-id {s}", .{remote});
        defer alloc.free(opened);
        try std.testing.expect(std.mem.indexOf(u8, log, opened) != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--append-system-prompt") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--model /nope") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--resume") == null);
    }

    // ⑥ Another turn, sent while nothing is running. The channel is the
    // delegation's own inbox (D5), and the round that takes it RESUMES the
    // session rather than opening a second one — which is what makes a follow-up
    // cheap in the first place.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"and the lexer\"}}", .{d});
        defer alloc.free(args);
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, with_claude);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: and the lexer") != null);
        // Drained, so the wake invariant's `pending` goes false and nobody starts
        // a runner for a message that has already been answered.
        try std.testing.expect(try inboxEmpty(io, alloc, ws, d));

        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        const resumed = try std.fmt.allocPrint(alloc, "--resume {s}", .{remote});
        defer alloc.free(resumed);
        try std.testing.expect(std.mem.indexOf(u8, log, resumed) != null);
    }

    // ⑦ Exchanges are counted from the record, whatever runner is behind it.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
}

test "bundled agent: a claude delegation that is running takes an interrupt as a control request, and the message behind it is answered by the next round" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const claude_exe = (try fakeClaude(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(claude_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: scouts\nrunner: claude\n---\nYou are a scout.\n",
    });

    // The fake holds its first turn open while this file exists, so the test
    // decides when the run in flight ends rather than racing it; everything the
    // runner sent lands in the log, which is how "it sent the interrupt" becomes
    // a fact rather than an inference from a report.
    try ws.writeFile(io, .{ .sub_path = "hold", .data = "" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const held: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
        .{ .key = "FAKE_CLAUDE_LOG", .value = "claude-log.txt" },
        .{ .key = "FAKE_CLAUDE_HOLD", .value = "hold" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"go on for a while\"}" }, held);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    // Wait until a turn is genuinely under way — that is what an interrupt is for.
    try waitForText(io, alloc, ws, "claude-log.txt", "user ");

    // The interrupt: the message first, then the marker (D6). The runner checks
    // the marker between the lines it reads, so the message behind it stays in
    // the inbox rather than being fed to a turn that is about to be cut short.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"STOP-SENTINEL\",\"interrupt\":true}}", .{d});
        defer alloc.free(args);
        const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(interrupted.stdout);
        try std.testing.expectEqual(@as(u8, 0), interrupted.code);
        // It is working, so nothing new was started for it.
        try std.testing.expect(std.mem.indexOf(u8, interrupted.stdout, "queued") != null);
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        // Taken, never left behind to cut short a later round.
        try waitForGone(io, ws, marker);
    }

    // Let the held turn end, so the round that was interrupted can finish.
    try ws.deleteFile(io, "hold");

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The stop verb really went down the wire…
    {
        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "control_request interrupt") != null);
    }

    // …and the message behind it was answered rather than lost: the interrupt is
    // execution control, not a kind of message (D3).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: STOP-SENTINEL") != null);
    }
}

test "bundled agent: a read-only claude delegation asks for the narrow shape and refuses the round when the session it gets back is wider" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const claude_exe = (try fakeClaude(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(claude_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data = "---\ndescription: only reads\nreadonly: true\nrunner: claude\n---\nYou only read.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    // The lever is what the harness REPORTS its session having — the one fact
    // D10's check can read, because unlike a sandbox nothing else comes back.
    const wide: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
        .{ .key = "FAKE_CLAUDE_LOG", .value = "claude-log.txt" },
        .{ .key = "FAKE_CLAUDE_TOOLS", .value = "Read,Glob,Write" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, wide);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "read-only") != null);

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The round refused rather than ran: what comes back to the parent says the
    // ceiling could not be held, and nothing the sub-agent might have said.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "read-only") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") == null);
    }

    // …and the narrow shape really was asked for. The flags are the mechanism —
    // availability, a permission mode that never asks, and no MCP server to add
    // a tool nobody here has seen the name of — and the echo above is the check.
    {
        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "--tools Read,Glob,Grep") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--permission-mode dontAsk") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--strict-mcp-config") != null);
    }

    // With a session that comes back inside the ceiling, the same definition runs.
    {
        const narrow: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        };
        const opened = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, narrow);
        defer alloc.free(opened.stdout);
        try std.testing.expectEqual(@as(u8, 0), opened.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") != null);
    }
}

// ── the Pi runner (contract ar-e) ───────────────────────────────────────────
//
// A delegation whose definition says `runner: pi` is held by a `pi --mode rpc`
// session. These run against `tests/fake_pi.zig` — a process that answers the
// documented RPC protocol offline — because everything worth pinning down is on
// THIS side of it.

/// The offline `pi`, built by `build.zig` for exactly this.
fn fakePi(alloc: std.mem.Allocator) !?[]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const named = host_env.get("NULYA_FAKE_PI") orelse return null;
    if (named.len == 0) return null;
    return try std.fs.path.resolve(alloc, &.{named});
}

/// The remote out of a pi receipt (`… — delegation d-…, pi session <uuid>`).
fn piSessionOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "pi session ").? + "pi session ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

test "bundled agent: a pi delegation is a pi session — one flag opens or resumes it, the persona is frozen beside the record, and the report comes back through the parent's inbox" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const pi_exe = (try fakePi(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(pi_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: reads the codebase through pi\nrunner: pi\nrunner_model: anthropic/some-model\n---\nYou are a scout. Report what you found.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const with_pi: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_PI_EXE", .value = pi_exe },
        .{ .key = "FAKE_PI_LOG", .value = "pi-log.txt" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"find the parser\"}" }, with_pi);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "pi session") != null);

    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const remote = try piSessionOf(alloc, started.stdout);
    defer alloc.free(remote);

    // The record froze which harness holds this delegation, at what version, and
    // what it was asked to run on — each in its own column (D2/D7).
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"pi\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_model\":\"anthropic/some-model\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_version\":") != null);
    }

    // The persona is frozen INTO the delegation, and handed over as a PATH — pi
    // reads the file when the argument is one, so nothing has to fit on a command
    // line.
    {
        const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/persona.md", .{d});
        defer alloc.free(path);
        const frozen = try ws.readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(frozen);
        try std.testing.expect(std.mem.indexOf(u8, frozen, "You are a scout.") != null);
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The report reaches the parent the way every other delegation's does.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: find the parser") != null);
    }

    // One flag opens or resumes: `--session-id` is passed on every round, and
    // there is no second form for this arm to choose between.
    {
        const log = try ws.readFileAlloc(io, "pi-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        const named = try std.fmt.allocPrint(alloc, "--session-id {s}", .{remote});
        defer alloc.free(named);
        try std.testing.expect(std.mem.indexOf(u8, log, named) != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--mode rpc") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--append-system-prompt") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--model anthropic/some-model") != null);
    }

    // Another turn, sent while nothing is running: the channel is the
    // delegation's own inbox (D5) and the next round takes it.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"and the lexer\"}}", .{d});
        defer alloc.free(args);
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, with_pi);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: and the lexer") != null);
        try std.testing.expect(try inboxEmpty(io, alloc, ws, d));
    }

    // Exchanges are counted from the record, whatever runner is behind it.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
}

test "bundled agent: a pi delegation that is running takes an interrupt as abort, and the message behind it is answered by the next round" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const pi_exe = (try fakePi(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(pi_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: scouts\nrunner: pi\n---\nYou are a scout.\n",
    });
    try ws.writeFile(io, .{ .sub_path = "hold", .data = "" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const held: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_PI_EXE", .value = pi_exe },
        .{ .key = "FAKE_PI_LOG", .value = "pi-log.txt" },
        .{ .key = "FAKE_PI_HOLD", .value = "hold" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"go on for a while\"}" }, held);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    try waitForText(io, alloc, ws, "pi-log.txt", "prompt");

    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"STOP-SENTINEL\",\"interrupt\":true}}", .{d});
        defer alloc.free(args);
        const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(interrupted.stdout);
        try std.testing.expectEqual(@as(u8, 0), interrupted.code);
        try std.testing.expect(std.mem.indexOf(u8, interrupted.stdout, "queued") != null);
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        try waitForGone(io, ws, marker);
    }

    try ws.deleteFile(io, "hold");

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The stop verb really went down the wire…
    {
        const log = try ws.readFileAlloc(io, "pi-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "abort") != null);
    }

    // …and the message behind it was answered rather than lost (D3).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: STOP-SENTINEL") != null);
    }
}

test "bundled agent: a read-only pi delegation asks for the allow-list and stops the run when a tool outside it begins" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const pi_exe = (try fakePi(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(pi_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data = "---\ndescription: only reads\nreadonly: true\nrunner: pi\n---\nYou only read.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    // Pi reports no tool list, so the lever is the one thing the protocol does
    // say: a tool BEGINNING. `write` is not in the ceiling, so the run stops.
    const wide: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_PI_EXE", .value = pi_exe },
        .{ .key = "FAKE_PI_LOG", .value = "pi-log.txt" },
        .{ .key = "FAKE_PI_TOOL", .value = "write" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, wide);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "read-only") != null);

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "read-only") != null);
        // Stopped rather than reported: whatever it was going on to say does not
        // come back as a sub-agent's findings.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") == null);
    }

    // The allow-list really was asked for. (That `abort` went down the wire is
    // pinned by the interrupt test above; here the process is closed right after
    // the refusal, so the fake never gets to read it back — which is fine: the
    // ceiling's job is that the round produces nothing, and that is asserted.)
    {
        const log = try ws.readFileAlloc(io, "pi-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "--tools read,grep,find,ls") != null);
    }

    // With a run that stays inside the ceiling, the same definition reports.
    {
        const narrow: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "NULYA_PI_EXE", .value = pi_exe },
            .{ .key = "FAKE_PI_TOOL", .value = "read" },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        };
        const opened = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, narrow);
        defer alloc.free(opened.stdout);
        try std.testing.expectEqual(@as(u8, 0), opened.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", "120000" });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") != null);
    }
}
