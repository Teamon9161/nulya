//! End-to-end proof of the milestone (DESIGN §16): "Nulya v0.1 ships two tools.
//! The third is created by Nulya itself."
//!
//! This scaffolds a real extension, builds it with the HOST's zig (injected via
//! NULYA_TEST_ZIG by build.zig so the ~90MB embed is not needed), activates the
//! immutable version, then invokes it through the same Environment seam a live
//! agent would use — and checks the wire response round-trips. Run with
//! `zig build e2e`.

const std = @import("std");
const extension = @import("extension");

const build_ext = extension.build_ext;
const composition = extension.composition;
const environment = extension.environment;
const integrity = extension.integrity;
const promotion = extension.promotion;
const protocol = extension.protocol;
const store = extension.store;
const templates = extension.templates;
const tool = extension.tool;
const tool_stats = extension.tool_stats;

const ext_dir_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "demo";

test "closed loop: init -> build -> activate -> run round-trips JSON" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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

    // 2. `ext build`: compile into an immutable, content-addressed version.
    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, zig_exe);
    defer result.deinit(alloc);
    if (!result.compile_ok) {
        std.debug.print("extension failed to compile:\n{s}\n", .{result.stderr});
        return error.ExtensionBuildFailed;
    }
    try std.testing.expect(std.mem.startsWith(u8, result.version, "v-"));

    // Building again is a reproducible no-op on the same version.
    var again = try build_ext.buildExtension(alloc, io, ws, ext_dir_rel, zig_exe);
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

    const outcome = try lenv.environment().runExtension(alloc, .{
        .entry_path = entry_abs,
        .cwd = ws_path,
        .request_json = request_json,
        .max_output_bytes = 1 << 20,
    });
    defer outcome.deinit(alloc);
    try std.testing.expectEqual(@as(u8, 0), outcome.exit_code);

    const decoded = try protocol.decodeResponse(alloc, req.id, outcome.stdout);
    defer decoded.deinit(alloc);
    switch (decoded) {
        .result => |json| try std.testing.expect(std.mem.indexOf(u8, json, "greeting") != null),
        .extension_error => |err| {
            std.debug.print("unexpected extension error: [{d}] {s}\n", .{ err.code, err.message });
            return error.TestUnexpectedResult;
        },
    }
}

/// Scaffold a real, buildable extension (`id`/`tool`, single-file entry source),
/// compile it with the host zig into an immutable version, and activate it.
/// Returns the activated version id; caller frees.
fn buildAndActivate(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    zig_exe: []const u8,
    id: []const u8,
    tool_name: []const u8,
    main_src: []const u8,
) ![]u8 {
    const ext_dir = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(ext_dir);
    const src_dir = try std.fs.path.join(alloc, &.{ ext_dir, "src" });
    defer alloc.free(src_dir);
    try ws.createDirPath(io, src_dir);

    const manifest_bytes = try templates.manifestJson(alloc, id, tool_name);
    defer alloc.free(manifest_bytes);
    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });
    const main_rel = try std.fs.path.join(alloc, &.{ src_dir, "main.zig" });
    defer alloc.free(main_rel);
    try ws.writeFile(io, .{ .sub_path = main_rel, .data = main_src });

    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir, zig_exe);
    defer result.deinit(alloc);
    if (!result.compile_ok) {
        std.debug.print("extension failed to compile:\n{s}\n", .{result.stderr});
        return error.ExtensionBuildFailed;
    }
    var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer ext_root.close(io);
    try store.Store.init(io, ext_root).activate(alloc, id, result.version);
    return try alloc.dupe(u8, result.version);
}

/// One real `nulya` CLI invocation against the workspace. The test binary's own
/// stdout is the test-runner protocol, so the CLI is spawned as a child with
/// the workspace as cwd and its output captured on pipes. Caller owns `stdout`.
const CliRun = struct { code: u8, stdout: []u8 };

fn runCli(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
) !CliRun {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = .{ .dir = ws },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const code = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = try alloc.dupe(u8, result.stdout) };
}

/// The generated `greet` extension with its greeting text swapped, so two builds
/// differ by observable output (and therefore by content-addressed version). The
/// source stays a real, compilable single-file extension. Caller owns the bytes.
fn greetSource(alloc: std.mem.Allocator, greeting: []const u8) ![]u8 {
    const needle = "hello from a Nulya-built extension";
    const size = std.mem.replacementSize(u8, templates.main_zig, needle, greeting);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    _ = std.mem.replace(u8, templates.main_zig, needle, greeting, buf);
    return buf;
}

/// One native tool invocation through the real executor chain: a fresh
/// `LocalEnvironment` spawns the frozen executable and returns its decoded output.
/// Caller owns `result.output`.
fn callNative(alloc: std.mem.Allocator, io: std.Io, t: tool.Tool, ws_path: []const u8) !tool.RawToolResult {
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    return t.executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
    });
}

test "self-evolution closed loop: CLI usage auto-promotes an extension whose native call executes the frozen version" {
    // The whole kernel loop the milestone promises, proven end to end with a real
    // built binary — not a stub, not a FakeEnv:
    //
    //   build+activate web.search v1  ->  CLI `nulya ext run` records usage
    //     ->  a new session ranks the journal, auto-promotes web_search to a
    //         native tool, and its ToolExecutor spawns the frozen v1 executable
    //     ->  activate v2:  the same session's native call STILL runs v1 (frozen),
    //         the live CLI runs v2, and a fresh session's native call runs v2.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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

    // One real CLI invocation records `ext:web.search/web_search` in the journal —
    // the only thing that makes the tool an eligible promotion candidate.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", "web.search", "web_search", "{}" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "greeting-v1") != null);
    }

    // --- Session B: rank the journal at the setup boundary, then freeze. ---
    const ranked_b = try promotion.rankExtensionTools(alloc, io, ws_path, .{});
    defer promotion.freeRankedIds(alloc, ranked_b);
    try std.testing.expectEqual(@as(usize, 1), ranked_b.len);
    try std.testing.expectEqualStrings("ext:web.search/web_search", ranked_b[0]);

    var comp_b = try composition.SessionComposition.init(alloc, io, ws_path, ".nulya/extensions", .{ .ranked_native_tools = ranked_b });
    defer comp_b.deinit(alloc);

    // The ranked candidate is now a native, model-facing tool, and calling it
    // through the ToolExecutor actually spawns the frozen v1 binary.
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

    // 3. A fresh session opened after the switch promotes and freezes on v2.
    const ranked_c = try promotion.rankExtensionTools(alloc, io, ws_path, .{});
    defer promotion.freeRankedIds(alloc, ranked_c);
    var comp_c = try composition.SessionComposition.init(alloc, io, ws_path, ".nulya/extensions", .{ .ranked_native_tools = ranked_c });
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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
