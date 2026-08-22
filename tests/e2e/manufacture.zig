//! The milestone's first sentence (DESIGN §16): "Nulya ships one tool. The
//! second is created by Nulya itself." A shell-only session manufactures a real
//! extension through the real CLI, usage alone never promotes it, and a pin —
//! from config or `--pin` — puts it on the next session's tool face.

const std = @import("std");
const support = @import("support.zig");

const composition = support.composition;
const environment = support.environment;
const ledger = support.ledger;
const provider = support.provider;
const session = support.session;
const tool_stats = support.tool_stats;

const EndTurnModel = support.EndTurnModel;
const SelfBuildModel = support.SelfBuildModel;
const callNative = support.callNative;
const extractVersion = support.extractVersion;
const forwardSlashes = support.forwardSlashes;
const readSessionFile = support.readSessionFile;
const runCli = support.runCli;
const runCliStderr = support.runCliStderr;
const shellCallArgs = support.shellCallArgs;

/// The most recent tool-result output in the ledger, or null if none — used to
/// read the version id the real `nulya ext build` printed into the transcript.
fn latestToolOutput(l: *const ledger.Ledger) ?[]const u8 {
    const v = l.view();
    var i = v.len;
    while (i > 0) {
        i -= 1;
        switch (v[i]) {
            .tool_results => |rs| if (rs.len > 0) return rs[0].output,
            else => {},
        }
    }
    return null;
}

test "self-manufacture closed loop: a shell-only session builds its own extension; usage alone never promotes it; a pin — from config or --pin — makes it native in the next session" {
    // The milestone's first sentence, proven with no harness-built extension:
    //
    //   Session A exposes ONLY shell. A deterministic model, through that one
    //   builtin (real ToolExecutor -> LocalEnvironment shell spawns), runs
    //   `nulya ext init/build/activate/run` to manufacture a brand-new capability
    //   and records its usage. The tool never becomes native mid-session.
    //     -> Session B, opened with no pin, STILL sees only shell: the
    //        usage journal is evidence, never a decision (DESIGN §5.1, §5.5).
    //     -> Promotion is someone writing a pin. Both spellings are exercised
    //        through the real CLI: `[registry] pinned_native_tools` in the
    //        project layer's `.nulya/config.toml`, and `session new --pin`.
    //        Either way the header records it and the executor spawns the frozen
    //        binary the model just built.
    //
    // No real LLM: a scripted provider issues the exact shell commands a model
    // would. `NULYA_ZIG` is injected into the (non-secret) sanitized child env so
    // the model's `nulya ext build` finds a toolchain without an embedded one.
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    // NULYA_ZIG is not secret-shaped, so it survives sanitization and reaches the
    // model's `nulya ext build` grandchild (test -> shell -> nulya -> zig).
    try lenv.env.put("NULYA_ZIG", zig_exe);
    // The model's `ext build` records this workspace store as trusted (DESIGN §9)
    // in the USER layer, so it must see the same isolated home `runCli` gives the
    // `session new` below — otherwise the store the model just built is trusted in
    // one home and refused from the other, which is the developer's real `~`.
    const test_home = try support.testHome(alloc, io, ws);
    defer alloc.free(test_home);
    try lenv.env.put("NULYA_HOME", test_home);

    const exe_fwd = try forwardSlashes(alloc, exe_abs);
    defer alloc.free(exe_fwd);
    const call_prefix = if (lenv.dialect_val == .powershell) "& " else "";

    // The model's scripted shell commands. args[2] (activate) is filled after the
    // real build step reveals the version. args[4] == "" ends the turn.
    var args: [5][]const u8 = .{ "", "", "", "", "" };
    defer for (args) |a| if (a.len != 0) alloc.free(a);
    {
        // `--zig`: this test's subject is the COMPILED path — a real
        // `zig build-exe` reached through shell -> nulya -> zig, with NULYA_ZIG
        // surviving sanitization. `ext init` without it scaffolds a script,
        // which is the default precisely because it needs none of that.
        const c = try std.fmt.allocPrint(alloc, "{s}'{s}' ext init --zig demo greet", .{ call_prefix, exe_fwd });
        defer alloc.free(c);
        args[0] = try shellCallArgs(alloc, c);
    }
    {
        const c = try std.fmt.allocPrint(alloc, "{s}'{s}' ext build .nulya/extensions/demo", .{ call_prefix, exe_fwd });
        defer alloc.free(c);
        args[1] = try shellCallArgs(alloc, c);
    }
    {
        const c = try std.fmt.allocPrint(alloc, "{s}'{s}' ext run demo greet '{{}}'", .{ call_prefix, exe_fwd });
        defer alloc.free(c);
        args[3] = try shellCallArgs(alloc, c);
    }

    var model_impl = SelfBuildModel{ .args_per_step = &args };
    var sess = try session.AgentSession.init(alloc, .{
        .model = .{ .ptr = &model_impl, .vtable = &SelfBuildModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    });
    defer sess.deinit();

    // Session A's model face is exactly the one builtin — no extension exists yet.
    try std.testing.expectEqual(@as(usize, 1), sess.composition.tools.tools.len);
    try std.testing.expect(sess.composition.tools.lookup("shell") != null);
    try std.testing.expect(sess.composition.tools.lookup("greet") == null);

    try sess.appendUser("I need a greet capability.");
    _ = try sess.step(); // init:  scaffold the extension
    _ = try sess.step(); // build: compile into an immutable version

    // Read the version the real build printed, then script the activate call.
    const build_out = latestToolOutput(&sess.l) orelse return error.TestUnexpectedResult;
    const ver = try extractVersion(alloc, build_out);
    defer alloc.free(ver);
    {
        const c = try std.fmt.allocPrint(alloc, "{s}'{s}' ext activate demo {s}", .{ call_prefix, exe_fwd, ver });
        defer alloc.free(c);
        args[2] = try shellCallArgs(alloc, c);
    }
    _ = try sess.step(); // activate: point current at the built version
    _ = try sess.step(); // run:      `nulya ext run` proves CLI works AND records usage
    _ = try sess.step(); // end turn
    try std.testing.expect(sess.lastAssistantDone());

    // Session A never promoted the tool: its face is frozen at shell alone.
    try std.testing.expectEqual(@as(usize, 1), sess.composition.tools.tools.len);
    try std.testing.expect(sess.composition.tools.lookup("greet") == null);

    // The model's own `nulya ext run` recorded the durable usage fact — written
    // by a SEPARATE process (the CLI in the model's shell) into the same journal
    // this session's own `shell` rows go to.
    {
        const events = try tool_stats.readAll(alloc, io, ws_path);
        defer tool_stats.freeEvents(alloc, events);
        var saw_ext = false;
        var saw_measured_shell = false;
        for (events) |e| {
            // Every writer stamps every line, whichever process it came from.
            try std.testing.expect(e.at != null);
            if (std.mem.eql(u8, e.tool_id, "ext:demo/greet")) {
                // The version the model itself just built and activated: the id
                // stays version-free, the column beside it names the frozen
                // implementation that answered.
                try std.testing.expectEqualStrings(ver, e.version.?);
                saw_ext = true;
            }
            // The kernel measures the calls it dispatches itself. This session is
            // in-memory, so no row names a session — there is no id to name.
            if (std.mem.eql(u8, e.tool_id, "builtin.shell")) {
                try std.testing.expect(e.duration_ms != null);
                try std.testing.expect(e.session == null);
                // The builtin IS the kernel: no implementation version exists to
                // record, so the column is absent rather than invented.
                try std.testing.expect(e.version == null);
                saw_measured_shell = true;
            }
        }
        try std.testing.expect(saw_ext);
        try std.testing.expect(saw_measured_shell);
    }

    // --- Session B: usage rows exist, and change nothing. ---
    {
        const plain = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(plain.stdout);
        try std.testing.expectEqual(@as(u8, 0), plain.code);
        const plain_id = try alloc.dupe(u8, std.mem.trim(u8, plain.stdout, " \r\n"));
        defer alloc.free(plain_id);
        const plain_header = try readSessionFile(alloc, io, ws, plain_id);
        defer alloc.free(plain_header);
        // The extension is active (so the header pins its version), but nothing
        // put its tool on the model's face.
        try std.testing.expect(std.mem.indexOf(u8, plain_header, "\"native_tools\":[]") != null);

        var comp_plain = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{});
        defer comp_plain.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), comp_plain.tools.tools.len);
        try std.testing.expect(comp_plain.tools.lookup("greet") == null);
    }

    // --- Promotion = a pin. Spelling one: the project layer's config file. ---
    try ws.writeFile(io, .{ .sub_path = ".nulya/config.toml", .data =
        \\[registry]
        \\pinned_native_tools = ["ext:demo/greet"]
        \\
    });
    {
        const pinned = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(pinned.stdout);
        try std.testing.expectEqual(@as(u8, 0), pinned.code);
        const pinned_id = try alloc.dupe(u8, std.mem.trim(u8, pinned.stdout, " \r\n"));
        defer alloc.free(pinned_id);
        const pinned_header = try readSessionFile(alloc, io, ws, pinned_id);
        defer alloc.free(pinned_header);
        try std.testing.expect(std.mem.indexOf(u8, pinned_header, "\"native_tools\":[\"ext:demo/greet\"]") != null);

        // What a `session step` process rebuilds from that header: the tool is
        // on the face, at the frozen version, and really runs.
        try assertGreetRunsFromHeader(alloc, io, ws, ws_path, pinned_id);
    }

    // --- Spelling two: `session new --pin`, with no config file at all. ---
    try ws.deleteFile(io, ".nulya/config.toml");
    {
        const pinned = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--pin", "ext:demo/greet" });
        defer alloc.free(pinned.stdout);
        try std.testing.expectEqual(@as(u8, 0), pinned.code);
        const pinned_id = try alloc.dupe(u8, std.mem.trim(u8, pinned.stdout, " \r\n"));
        defer alloc.free(pinned_id);
        const pinned_header = try readSessionFile(alloc, io, ws, pinned_id);
        defer alloc.free(pinned_header);
        try std.testing.expect(std.mem.indexOf(u8, pinned_header, "\"native_tools\":[\"ext:demo/greet\"]") != null);
        try assertGreetRunsFromHeader(alloc, io, ws, ws_path, pinned_id);
    }

    // A pin that resolves to nothing fails the session rather than starting one
    // quietly missing the tool it was asked for. The refusal names the pin — on
    // stderr, because `session new`'s stdout is the id and nothing else.
    {
        const argv = [_][]const u8{ exe_abs, "session", "new", "--profile", "scripted", "--pin", "ext:demo/absent" };
        const bad = try runCli(alloc, io, ws, &argv);
        defer alloc.free(bad.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad.code);
        try std.testing.expectEqualStrings("", std.mem.trim(u8, bad.stdout, " \r\n"));
        const said = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(said);
        try std.testing.expect(std.mem.indexOf(u8, said, "ext:demo/absent") != null);
    }
}

/// Resume the session `id` the way `session step` does — composition rebuilt
/// from the frozen header — and prove its pinned `greet` really executes.
fn assertGreetRunsFromHeader(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    ws_path: []const u8,
    id: []const u8,
) !void {
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = EndTurnModel{};
    const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
    defer alloc.free(spath);
    var resumed = try session.AgentSession.openDurable(alloc, .{
        .model = .{ .ptr = &model, .vtable = &EndTurnModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    }, .{ .workspace = ws, .session_path = spath });
    defer resumed.deinit();

    try std.testing.expectEqual(@as(usize, 2), resumed.composition.tools.tools.len);
    const greet = resumed.composition.tools.lookup("greet") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ext:demo/greet", greet.definition.id);
    const result = try callNative(alloc, io, greet, ws_path);
    defer alloc.free(result.output);
    try std.testing.expect(result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello from a Nulya-built extension") != null);
}
