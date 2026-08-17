//! The durable session end to end (DESIGN §3, §11, §14): a ledger that survives
//! the process that wrote it, the `nulya session *` driver surface, forks and
//! their inherited identity, the `--stream` line protocol, per-step usage, and
//! the outcome journal.

const std = @import("std");
const support = @import("support.zig");

const composition = support.composition;
const environment = support.environment;
const ledger = support.ledger;
const outcome = support.outcome;
const prompt = support.prompt;
const protocol = support.protocol;
const provider = support.provider;
const session = support.session;
const store = support.store;
const templates = support.templates;
const tool = support.tool;

const EndTurnModel = support.EndTurnModel;
const EnvPair = support.EnvPair;
const SelfBuildModel = support.SelfBuildModel;
const extractVersion = support.extractVersion;
const flattenIR = support.flattenIR;
const readSessionFile = support.readSessionFile;
const runCli = support.runCli;
const runCliEnv = support.runCliEnv;
const runCliEnvs = support.runCliEnvs;
const runCliStderr = support.runCliStderr;
const scaffoldAndBuild = support.scaffoldAndBuild;
const shellCallArgs = support.shellCallArgs;

// ── M1: durable ledger (DESIGN §3) ──────────────────────────────────────────

const sessions_dir_rel = ".nulya" ++ std.fs.path.sep_str ++ "sessions";
const session_file_rel = sessions_dir_rel ++ std.fs.path.sep_str ++ "s.jsonl";

test "durable ledger: process A steps twice and exits; process B resumes and projects a turn-identical PromptIR" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    try ws.createDirPath(io, sessions_dir_rel);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();

    // Step 0 issues one shell call; step 1 ends the turn.
    var args = [_][]const u8{ try shellCallArgs(alloc, "echo hi"), "" };
    defer alloc.free(args[0]);
    var model = SelfBuildModel{ .args_per_step = &args };
    const opts: session.AgentSession.Options = .{
        .model = .{ .ptr = &model, .vtable = &SelfBuildModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    };

    // Process A: two real steps, capture its final projection, then exit.
    var flat_a: []u8 = undefined;
    {
        var a = try session.AgentSession.createDurable(alloc, opts, .{
            .workspace = ws,
            .session_path = session_file_rel,
            .session_id = "s",
        });
        defer a.deinit();
        try a.appendUser("go");
        _ = try a.step(); // shell echo -> assistant(call) + tool_results
        _ = try a.step(); // end turn -> assistant
        const ir = try prompt.projectWithSystem(alloc, a.composition.system_prompts.blocks, a.l.view());
        defer ir.deinit(alloc);
        flat_a = try flattenIR(alloc, ir);
    }
    defer alloc.free(flat_a);

    // Process B: resume from the file and project — block-for-block identical.
    var b = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
    defer b.deinit();
    const ir_b = try prompt.projectWithSystem(alloc, b.composition.system_prompts.blocks, b.l.view());
    defer ir_b.deinit(alloc);
    const flat_b = try flattenIR(alloc, ir_b);
    defer alloc.free(flat_b);

    try std.testing.expectEqualStrings(flat_a, flat_b);
    // A real multi-turn conversation: user, assistant(call), tool_results, assistant.
    try std.testing.expect(ir_b.turns.len >= 4);
}

test "durable ledger: an assistant-with-calls tail left on disk by a crash is repaired on resume" {
    const alloc = std.testing.allocator;
    const io = std.testing.io; // EndTurnModel issues no tool calls, so no async shell.

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    try ws.createDirPath(io, sessions_dir_rel);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = EndTurnModel{};
    const opts: session.AgentSession.Options = .{
        .model = .{ .ptr = &model, .vtable = &EndTurnModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    };

    // Process A "crashes" right after appending an assistant-with-calls: the tail
    // has no matching tool_results, an illegal batch left on disk.
    {
        var a = try session.AgentSession.createDurable(alloc, opts, .{
            .workspace = ws,
            .session_path = session_file_rel,
            .session_id = "s",
        });
        defer a.deinit();
        try a.appendUser("go");
        try a.l.append(.{ .assistant = .{
            .text = "running",
            .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"echo hi\"}" }},
        } });
    }

    // Process B: on resume the interrupted batch is completed before the next
    // turn. Close it before process C opens — the writer lease is exclusive.
    {
        var b = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
        defer b.deinit();
        try std.testing.expectEqual(@as(usize, 2), b.l.len()); // user, assistant(call) — not yet repaired
        _ = try b.step();
        // user, assistant(call), tool_results(interrupted), assistant(end)
        try std.testing.expectEqual(@as(usize, 4), b.l.len());
        try std.testing.expect(b.l.view()[2] == .tool_results);
        try std.testing.expect(!b.l.view()[2].tool_results[0].ok);
        try std.testing.expect(std.mem.indexOf(u8, b.l.view()[2].tool_results[0].output, "state is unknown") != null);
    }

    // The repair persisted: a third process sees the completed batch on disk.
    var c = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 4), c.l.len());
}

test "durable ledger: a capability_note appended by a separate CLI process is read on the next step" {
    const alloc = std.testing.allocator;
    const io = std.testing.io; // EndTurnModel issues no tool calls, so no async shell.

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
    try ws.createDirPath(io, sessions_dir_rel);

    // Build (but do NOT activate) a real extension: activation happens via the CLI
    // inside the live session, which is what deposits the capability note.
    const version = try scaffoldAndBuild(alloc, io, ws, zig_exe, "demo", "greet", templates.main_zig);
    defer alloc.free(version);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = EndTurnModel{};
    const opts: session.AgentSession.Options = .{
        .model = .{ .ptr = &model, .vtable = &EndTurnModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    };

    // Close this writer before the durable-resume check below — the lease is
    // exclusive, so only one writer holds the session file at a time.
    {
        var sess = try session.AgentSession.createDurable(alloc, opts, .{
            .workspace = ws,
            .session_path = session_file_rel,
            .session_id = "s",
        });
        defer sess.deinit();
        try sess.appendUser("please make a greet tool");

        // No note yet.
        try std.testing.expect(!sess.l.containsNote("demo", version));

        // A separate CLI process activates the extension with NULYA_SESSION set. It
        // deposits a capability note into the session inbox (never touching the
        // single-writer session file).
        {
            const run = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "activate", "demo", version }, "NULYA_SESSION", session_file_rel);
            defer alloc.free(run.stdout);
            try std.testing.expectEqual(@as(u8, 0), run.code);
        }

        // The next step drains the inbox at its boundary: the note is now in the
        // ledger and in the projected prompt, before the assistant turn.
        _ = try sess.step();
        try std.testing.expect(sess.l.containsNote("demo", version));

        const ir = try prompt.projectWithSystem(alloc, sess.composition.system_prompts.blocks, sess.l.view());
        defer ir.deinit(alloc);
        var saw_note_turn = false;
        for (ir.turns) |turn| switch (turn) {
            .capability_note => |text| {
                if (std.mem.indexOf(u8, text, "greet") != null) saw_note_turn = true;
            },
            else => {},
        };
        try std.testing.expect(saw_note_turn);
    }

    // And it is durable: a fresh process resuming the session still sees the note.
    var reopened = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
    defer reopened.deinit();
    try std.testing.expect(reopened.l.containsNote("demo", version));
}

// ── M2a: `nulya session *` CLI (PLAN §3.2) ──────────────────────────────────

test "session cli: --max-steps is enforced by the kernel even when the driver asks for more" {
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

    // `new` and `append` never invoke the model; only `step` does, so only it
    // needs the loop-mode env. The loop model never ends its turn.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = std.mem.trim(u8, new.stdout, " \r\n");

    {
        const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", id, "go forever" });
        defer alloc.free(ap.stdout);
        try std.testing.expectEqual(@as(u8, 0), ap.code);
    }

    // The driver would happily run forever, but --max-steps 3 caps this one
    // invocation at exactly three kernel steps.
    const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", id, "--max-steps", "3" }, "NULYA_SCRIPTED_MODE", "loop");
    defer alloc.free(step.stdout);
    try std.testing.expectEqual(@as(u8, 0), step.code);

    const dup_id = try alloc.dupe(u8, id);
    defer alloc.free(dup_id);
    const bytes = try readSessionFile(alloc, io, ws, dup_id);
    defer alloc.free(bytes);

    // Exactly three assistant turns ran — the cap held even though the model
    // wanted to keep going, and the last event is an unfinished (with-calls) batch.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\"kind\":\"assistant\""));
    try std.testing.expect(std.mem.count(u8, bytes, "\"kind\":\"tool_results\"") == 3);
    // The turn never ended: the loop model always emits a tool call, so there is
    // no assistant with an empty calls array.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"calls\":[]") == null);
}

/// A hermetic user-config layer: `NULYA_HOME` relocates `~/.nulya`, so the CLI
/// under test reads these profiles instead of whatever the machine running the
/// suite happens to have configured. Both profiles carry an inline `api_key`,
/// which is a credential in its own right — no environment variable needed for
/// `resolveDescriptor` to freeze a real (non-scripted) identity.
const fork_config =
    \\[provider]
    \\active_profile = "beta"
    \\
    \\[[provider.profiles]]
    \\name = "alpha"
    \\kind = "openai"
    \\model = "alpha-1"
    \\base_url = "https://alpha.example/v1"
    \\api_key = "sk-alpha"
    \\
    \\[[provider.profiles]]
    \\name = "beta"
    \\kind = "openai"
    \\model = "beta-1"
    \\base_url = "https://beta.example/v1"
    \\api_key = "sk-beta"
    \\
;

test "session cli: a fork continues its parent's frozen model identity, and names one to change it" {
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

    try ws.createDirPath(io, "home");
    try ws.writeFile(io, .{ .sub_path = "home/config.toml", .data = fork_config });
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    const home_abs = try std.fs.path.join(alloc, &.{ ws_path, "home" });
    defer alloc.free(home_abs);
    const env: []const EnvPair = &.{.{ .key = "NULYA_HOME", .value = home_abs }};

    // The parent runs on `alpha`, which is NOT the config's active profile.
    const new = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "alpha" }, env);
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const parent_id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent_id);

    const parent_ref = try std.fmt.allocPrint(alloc, "{s}:0", .{parent_id});
    defer alloc.free(parent_ref);

    // A fork naming no model continues the parent's identity: `alpha-1`, even
    // though creating a root session right now would resolve `beta-1`. This is
    // the property compaction depends on — the conversation does not change who
    // it is talking to because it moved to a new file.
    {
        const fork = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "new", "--parent", parent_ref }, env);
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 0), fork.code);
        const id = try alloc.dupe(u8, std.mem.trim(u8, fork.stdout, " \r\n"));
        defer alloc.free(id);

        const bytes = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model\":\"alpha\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model\":\"alpha-1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "beta") == null);
        // The lineage pointer is recorded verbatim.
        const lineage = try std.fmt.allocPrint(alloc, "\"parent\":{{\"session\":\"{s}\",\"seq\":0}}", .{parent_id});
        defer alloc.free(lineage);
        try std.testing.expect(std.mem.indexOf(u8, bytes, lineage) != null);
    }

    // Naming a profile forks onto that provider instead — inheritance is the
    // default, not a lock.
    {
        const fork = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "new", "--parent", parent_ref, "--profile", "beta" }, env);
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 0), fork.code);
        const id = try alloc.dupe(u8, std.mem.trim(u8, fork.stdout, " \r\n"));
        defer alloc.free(id);

        const bytes = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model\":\"beta-1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "alpha") == null);
    }

    // `--model` picks another id WITHIN a profile, so the parent's profile still
    // carries — a fork onto `alpha-2` stays on `alpha`, it does not fall back to
    // the config's active `beta`.
    {
        const fork = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "new", "--parent", parent_ref, "--model", "alpha-2" }, env);
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 0), fork.code);
        const id = try alloc.dupe(u8, std.mem.trim(u8, fork.stdout, " \r\n"));
        defer alloc.free(id);

        const bytes = try readSessionFile(alloc, io, ws, id);
        defer alloc.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model\":\"alpha\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model\":\"alpha-2\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "alpha.example") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "beta") == null);
    }

    // A lineage pointer into nothing is not provenance: refused, and no session
    // file is left behind.
    {
        const argv = [_][]const u8{ exe_abs, "session", "new", "--parent", "s-nope:0" };
        const fork = try runCliEnvs(alloc, io, ws, &argv, env);
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 1), fork.code);
        // Nothing on stdout: no id was printed, and the refusal is a diagnostic.
        try std.testing.expectEqualStrings("", std.mem.trim(u8, fork.stdout, " \r\n"));
        const said = try runCliStderr(alloc, io, ws, &argv, env);
        defer alloc.free(said);
        try std.testing.expect(std.mem.indexOf(u8, said, "cannot read parent") != null);
    }
}

test "session cli: a shell-script driver runs a goal loop to completion" {
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

    // A real driver script: create a session, then loop step/append until the
    // model ends its turn (an assistant with an empty calls array). This is the
    // /goal pattern from PLAN §3.2, expressed as ~10 lines of shell.
    const ps1_driver =
        \\$ErrorActionPreference = 'Stop'
        \\$n = $args[0]
        \\$id = (& $n session new --profile scripted).Trim()
        \\& $n session append $id 'do the thing' | Out-Null
        \\for ($i = 0; $i -lt 10; $i++) {
        \\    $out = & $n session step $id --max-steps 1
        \\    if ($out -match '"calls":\[\]') { exit 0 }
        \\    & $n session append $id 'continue' | Out-Null
        \\}
        \\exit 3
        \\
    ;
    const sh_driver =
        \\#!/bin/sh
        \\set -e
        \\n="$1"
        \\id=$("$n" session new --profile scripted)
        \\"$n" session append "$id" 'do the thing' >/dev/null
        \\i=0
        \\while [ $i -lt 10 ]; do
        \\  out=$("$n" session step "$id" --max-steps 1)
        \\  if printf '%s' "$out" | grep -q '"calls":\[\]'; then exit 0; fi
        \\  "$n" session append "$id" 'continue' >/dev/null
        \\  i=$((i+1))
        \\done
        \\exit 3
        \\
    ;

    const is_windows = @import("builtin").os.tag == .windows;
    const script_name = if (is_windows) "driver.ps1" else "driver.sh";
    try ws.writeFile(io, .{ .sub_path = script_name, .data = if (is_windows) ps1_driver else sh_driver });

    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    const script_abs = try std.fs.path.join(alloc, &.{ ws_path, script_name });
    defer alloc.free(script_abs);

    const argv: []const []const u8 = if (is_windows)
        &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_abs, exe_abs }
    else
        &.{ "sh", script_abs, exe_abs };

    // The same isolated user layer every other CLI call in this file gets: without
    // it the spawned driver inherits the developer's real `~/.nulya`, so their own
    // user config would be merged into a session this test is asserting about.
    var env = try std.testing.environ.createMap(alloc);
    defer env.deinit();
    const home = try support.testHome(alloc, io, ws);
    defer alloc.free(home);
    try env.put("NULYA_HOME", home);

    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = .{ .dir = ws },
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const code = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) std.debug.print("driver failed ({d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
    try std.testing.expectEqual(@as(u8, 0), code); // the driver reached its goal and exited 0
}

/// The first line of `text` that starts with `prefix`, minus the prefix. The
/// driver's stdout is its contract with whoever ran it — three lines, each one a
/// verb and the session it happened to — so the test reads it exactly that way.
fn lineAfter(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    }
    return null;
}

test "session cli: drivers/goal runs the bundled driver — the model hands off, the driver forks through compact, and the goal completes in the child" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // The real script, from the repo, with the real binary: the driver still runs
    // its own `ext build` for both bundled extensions, but the compiles are shared
    // with the rest of the suite, so those builds answer "already built". Staging
    // them fills the workspace store, which is exactly the case `ext build` does
    // NOT auto-trust — so `stageBundled` records the trust itself (DESIGN §9).
    alloc.free(try support.stageBundled(alloc, io, ws, "handoff"));
    alloc.free(try support.stageBundled(alloc, io, ws, "compact"));

    const is_windows = @import("builtin").os.tag == .windows;
    const script = try std.fs.path.join(alloc, &.{ repo, "drivers", if (is_windows) "goal.ps1" else "goal.sh" });
    defer alloc.free(script);
    const argv: []const []const u8 = if (is_windows)
        &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "--profile", "scripted", "summarise the map" }
    else
        &.{ "sh", script, "--profile", "scripted", "summarise the map" };

    var env = try std.testing.environ.createMap(alloc);
    defer env.deinit();
    // The same user layer every other CLI call in this file uses, so the trust
    // record the driver's first `ext build` writes lands in the test's home and
    // never in the developer's.
    const home = try support.testHome(alloc, io, ws);
    defer alloc.free(home);
    try env.put("NULYA_HOME", home);
    try env.put("NULYA", exe_abs);
    try env.put("NULYA_ZIG", zig_exe);
    try env.put("NULYA_SCRIPTED_MODE", "handoff");

    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = .{ .dir = ws },
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const code = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) std.debug.print("goal driver failed ({d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
    try std.testing.expectEqual(@as(u8, 0), code);

    // Two streams, two audiences. stdout is control and only control — a front
    // end reads it to open and switch tabs, so a single protocol line leaking
    // into it would be a line it has to learn to ignore.
    {
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            try std.testing.expect(line[0] != '{');
        }
    }
    // stderr is the kernel's own `--stream` protocol, passed through verbatim:
    // the model's deltas AND the run verdict, which is what makes a spawned
    // driver renderable without a sidecar file or a kernel change.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\"stream\":\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\"stream\":\"run\"") != null);

    // Three lines, in order: the session it opened, the fork it performed, the
    // session the goal finished in.
    const parent_id = lineAfter(result.stdout, "session ") orelse return error.TestUnexpectedResult;
    const handed = lineAfter(result.stdout, "handoff ") orelse return error.TestUnexpectedResult;
    const arrow = std.mem.indexOf(u8, handed, " -> ") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(parent_id, handed[0..arrow]);
    const child_id = handed[arrow + 4 ..];
    try std.testing.expectEqualStrings(child_id, lineAfter(result.stdout, "done ") orelse return error.TestUnexpectedResult);

    // The parent stopped growing at the fork: its last event is the seq the
    // child's lineage points at. The handoff path never writes to the parent.
    const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", parent_id });
    defer alloc.free(events.stdout);
    const tail_seq = std.mem.count(u8, events.stdout, "\n");
    const lineage = try std.fmt.allocPrint(alloc, "\"parent\":{{\"session\":\"{s}\",\"seq\":{d}}}", .{ parent_id, tail_seq });
    defer alloc.free(lineage);
    const child_file = try readSessionFile(alloc, io, ws, child_id);
    defer alloc.free(child_file);
    try std.testing.expect(std.mem.indexOf(u8, child_file, lineage) != null);

    // The child opened on the carried brief: the fold marker, the sentinel the
    // scripted model put in its handoff, and the way back to the whole transcript.
    const first_event = blk: {
        var lines = std.mem.splitScalar(u8, child_file, '\n');
        _ = lines.next(); // header
        break :blk lines.next() orelse return error.TestUnexpectedResult;
    };
    const pointer = try std.fmt.allocPrint(alloc, "nulya session events {s}", .{parent_id});
    defer alloc.free(pointer);
    for ([_][]const u8{ "\"kind\":\"user_text\"", "<nulya:context-summary>", support.launch.ScriptedProvider.handoff_sentinel, pointer }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, first_event, needle) != null);
    }

    // The proposal itself is still on disk, filed under the session that made it.
    const proposal = try std.fmt.allocPrint(alloc, ".nulya/handoffs/{s}-1.md", .{parent_id});
    defer alloc.free(proposal);
    const written = try ws.readFileAlloc(io, proposal, alloc, .unlimited);
    defer alloc.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, support.launch.ScriptedProvider.handoff_sentinel) != null);

    // Two files, one conversation — the kernel's own projection agrees.
    const listed = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list", "--json" });
    defer alloc.free(listed.stdout);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, listed.stdout, .{});
    defer parsed.deinit();
    var seen = false;
    for (parsed.value.object.get("sessions").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("id").?.string, child_id)) continue;
        try std.testing.expectEqualStrings(parent_id, entry.object.get("root").?.string);
        seen = true;
    }
    try std.testing.expect(seen);
}

test "session cli: --stream emits the transient line protocol and leaves the ledger identical" {
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

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    {
        const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", id, "probe the box" });
        defer alloc.free(ap.stdout);
        try std.testing.expectEqual(@as(u8, 0), ap.code);
    }

    const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", id, "--stream" }, "NULYA_SCRIPTED_MODE", "finish");
    defer alloc.free(step.stdout);
    try std.testing.expectEqual(@as(u8, 0), step.code);

    // Every stdout line is one JSON object — a driver can parse the stream
    // without ever meeting a bare diagnostic line (tui.md §2.2).
    var lines = std.mem.tokenizeAny(u8, step.stdout, "\r\n");
    var first: ?[]const u8 = null;
    var last: []const u8 = "";
    var saw_tool_begin = false;
    var saw_tool_end = false;
    var saw_ledger_event = false;
    var step_ends: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        if (first == null) first = line;
        last = line;
        const obj = parsed.value.object;
        if (obj.get("stream")) |s| {
            const kind = s.string;
            const ev = obj.get("event").?.string;
            if (std.mem.eql(u8, kind, "tool") and std.mem.eql(u8, ev, "begin")) saw_tool_begin = true;
            if (std.mem.eql(u8, kind, "tool") and std.mem.eql(u8, ev, "end")) {
                saw_tool_end = true;
                try std.testing.expect(obj.get("ok").? == .bool);
            }
            if (std.mem.eql(u8, kind, "step") and std.mem.eql(u8, ev, "end")) step_ends += 1;
        } else {
            // A line without `stream` is a ledger event, in `session events` shape.
            try std.testing.expect(obj.get("seq") != null);
            try std.testing.expect(obj.get("kind") != null);
            saw_ledger_event = true;
        }
    }
    try std.testing.expectEqualStrings("{\"stream\":\"model\",\"event\":\"started\"}", first.?);
    try std.testing.expect(saw_tool_begin and saw_tool_end and saw_ledger_event);
    try std.testing.expectEqual(@as(usize, 2), step_ends); // one tool step, one closing step
    try std.testing.expectEqualStrings(
        "{\"stream\":\"run\",\"event\":\"done\",\"steps\":2,\"stopped\":\"end_turn\"}",
        last,
    );

    // The ledger a streamed run writes is exactly the ledger a plain run writes:
    // the observer is pure observation, so the file is the same history.
    const streamed = try readSessionFile(alloc, io, ws, id);
    defer alloc.free(streamed);

    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const ws2 = tmp2.dir;
    const new2 = try runCli(alloc, io, ws2, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new2.stdout);
    const id2 = try alloc.dupe(u8, std.mem.trim(u8, new2.stdout, " \r\n"));
    defer alloc.free(id2);
    {
        const ap = try runCli(alloc, io, ws2, &.{ exe_abs, "session", "append", id2, "probe the box" });
        defer alloc.free(ap.stdout);
        try std.testing.expectEqual(@as(u8, 0), ap.code);
    }
    const plain = try runCliEnv(alloc, io, ws2, &.{ exe_abs, "session", "step", id2 }, "NULYA_SCRIPTED_MODE", "finish");
    defer alloc.free(plain.stdout);
    try std.testing.expectEqual(@as(u8, 0), plain.code);
    const unstreamed = try readSessionFile(alloc, io, ws2, id2);
    defer alloc.free(unstreamed);

    // Compare from the assistant turn on: the header differs by session id and
    // creation time, and seq 1 carries the inbox delivery name it was drained
    // from. Everything the model and the tools produced must be identical.
    const streamed_turns = streamed[std.mem.indexOf(u8, streamed, "{\"seq\":2,").?..];
    const unstreamed_turns = unstreamed[std.mem.indexOf(u8, unstreamed, "{\"seq\":2,").?..];
    try std.testing.expectEqualStrings(unstreamed_turns, streamed_turns);

    // And a plain `step` still prints exactly its own event lines: the streamed
    // run's ledger lines appear verbatim in the streamed stdout too.
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "\"kind\":\"tool_results\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.stdout, "\"stream\":") == null);
}

// ── M5c: multiple extension store roots (DESIGN §7.2) ───────────────────────

test "session cli: list --json reports parent, event count, summed usage and the latest outcome" {
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

    // An empty workspace lists nothing rather than failing.
    {
        const empty = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list", "--json" });
        defer alloc.free(empty.stdout);
        try std.testing.expectEqual(@as(u8, 0), empty.code);
        try std.testing.expect(std.mem.indexOf(u8, empty.stdout, "\"sessions\":[]") != null);
    }

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent_id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent_id);
    {
        const ap = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", parent_id, "probe the box" });
        defer alloc.free(ap.stdout);
        const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", parent_id }, "NULYA_SCRIPTED_MODE", "finish");
        defer alloc.free(step.stdout);
        try std.testing.expectEqual(@as(u8, 0), step.code);
        const verdict = try runCli(alloc, io, ws, &.{ exe_abs, "session", "outcome", parent_id, "partial", "--note", "first pass" });
        defer alloc.free(verdict.stdout);
        // A later verdict corrects it; the listing reports the one that stands.
        const revised = try runCli(alloc, io, ws, &.{ exe_abs, "session", "outcome", parent_id, "success" });
        defer alloc.free(revised.stdout);
        try std.testing.expectEqual(@as(u8, 0), revised.code);
    }

    const parent_ref = try std.fmt.allocPrint(alloc, "{s}:3", .{parent_id});
    defer alloc.free(parent_ref);
    const fork = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--parent", parent_ref });
    defer alloc.free(fork.stdout);
    try std.testing.expectEqual(@as(u8, 0), fork.code);
    const child_id = try alloc.dupe(u8, std.mem.trim(u8, fork.stdout, " \r\n"));
    defer alloc.free(child_id);

    // Give the fork a priced turn, so the episode total is something the parent's
    // own file cannot account for. (The scripted provider reports no cost, so the
    // line is written the way the kernel writes it — the real encoder, no mock.)
    {
        const line = try ledger.encodeEventLine(alloc, .{ .assistant = .{
            .text = "forked and priced",
            .calls = &.{},
            .usage = .{ .input_tokens = 900, .output_tokens = 40, .cache_read_tokens = 800 },
        } }, 1);
        defer alloc.free(line);
        const child_path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{child_id});
        defer alloc.free(child_path);
        const before = try ws.readFileAlloc(io, child_path, alloc, .unlimited);
        defer alloc.free(before);
        const after = try std.mem.concat(alloc, u8, &.{ before, line });
        defer alloc.free(after);
        try ws.writeFile(io, .{ .sub_path = child_path, .data = after });
    }

    const listed = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list", "--json" });
    defer alloc.free(listed.stdout);
    try std.testing.expectEqual(@as(u8, 0), listed.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, listed.stdout, .{});
    defer parsed.deinit();
    const sessions = parsed.value.object.get("sessions").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), sessions.len);

    // Newest first: the fork was created last.
    const child = sessions[0].object;
    try std.testing.expectEqualStrings(child_id, child.get("id").?.string);
    try std.testing.expectEqualStrings(parent_id, child.get("parent").?.object.get("session").?.string);
    try std.testing.expectEqual(@as(i64, 3), child.get("parent").?.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 1), child.get("events").?.integer);
    try std.testing.expect(child.get("outcome").? == .null); // unjudged is not failure
    try std.testing.expect(child.get("created").?.string.len == 20);

    const parent = sessions[1].object;
    try std.testing.expectEqualStrings(parent_id, parent.get("id").?.string);
    try std.testing.expect(parent.get("parent").? == .null);

    // One task, two files: both name the same episode root, and both report the
    // episode's total — the parent's own usage is 0, but the episode's is not.
    try std.testing.expectEqualStrings(parent_id, child.get("root").?.string);
    try std.testing.expectEqualStrings(parent_id, parent.get("root").?.string);
    try std.testing.expectEqual(@as(i64, 900), child.get("usage").?.object.get("input_tokens").?.integer);
    for ([_]std.json.ObjectMap{ parent, child }) |v| {
        const ep = v.get("episode_usage").?.object;
        try std.testing.expectEqual(@as(i64, 900), ep.get("input_tokens").?.integer);
        try std.testing.expectEqual(@as(i64, 40), ep.get("output_tokens").?.integer);
        try std.testing.expectEqual(@as(i64, 800), ep.get("cache_read_tokens").?.integer);
    }
    // user_text + assistant(call) + tool_results + assistant(end).
    try std.testing.expectEqual(@as(i64, 4), parent.get("events").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, parent.get("first_user_text").?.string, "probe the box") != null);
    try std.testing.expectEqualStrings("scripted", parent.get("model").?.string);
    try std.testing.expectEqualStrings("success", parent.get("outcome").?.object.get("verdict").?.string);
    try std.testing.expect(parent.get("outcome").?.object.get("note").? == .null); // the correcting line had none
    // The scripted provider prices nothing, so the sum is honestly zero.
    try std.testing.expectEqual(@as(i64, 0), parent.get("usage").?.object.get("input_tokens").?.integer);
    try std.testing.expect(parent.get("composition").?.object.get("active") != null);

    // The human form names both sessions, the verdict, and the fork's episode.
    const text = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(text.stdout);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, parent_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, child_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, "success") != null);
    const root_marker = try std.fmt.allocPrint(alloc, "root {s}", .{parent_id});
    defer alloc.free(root_marker);
    try std.testing.expect(std.mem.indexOf(u8, text.stdout, root_marker) != null);
}

// ── M5e: `session new --with` (composition membership, not a native pin) ────

test "session cli: --with pins a built-but-not-activated version into one session (system prompt in system blocks, skill in the catalog); a later plain session does not see it; resume rebuilds the same composition" {
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

    // A mode package: one system prompt + one skill, built but NEVER activated.
    const mode_dir = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "mode.demo";
    try ws.createDirPath(io, mode_dir ++ std.fs.path.sep_str ++ "prompts");
    try ws.createDirPath(io, mode_dir ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "mode-recipes");
    try ws.writeFile(io, .{ .sub_path = mode_dir ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"mode.demo","contributes":{"system_prompts":["prompts/mode.md"],"skills":["skills/mode-recipes"]}}
    });
    try ws.writeFile(io, .{ .sub_path = mode_dir ++ std.fs.path.sep_str ++ "prompts" ++ std.fs.path.sep_str ++ "mode.md", .data = "You are running in demo mode.\n" });
    try ws.writeFile(io, .{ .sub_path = mode_dir ++ std.fs.path.sep_str ++ "skills" ++ std.fs.path.sep_str ++ "mode-recipes" ++ std.fs.path.sep_str ++ "SKILL.md", .data = "---\nname: mode-recipes\ndescription: recipes for demo mode\n---\nthe recipes\n" });

    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", ".nulya/extensions/mode.demo" });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);

    // Not activated: `ext list` shows it inactive, so no other session gets it.
    {
        const list = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "list" });
        defer alloc.free(list.stdout);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "(inactive)") != null);
    }

    // A session started `--with mode.demo@<version>` composes it in: the header
    // records the exact version, so this is ordinary frozen composition, not a
    // special case. Naming the version is what "not activated" means — there is
    // no `current` to fall back to, and the kernel does not guess one.
    const with_arg = try std.fmt.allocPrint(alloc, "mode.demo@{s}", .{version});
    defer alloc.free(with_arg);
    const with = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", with_arg });
    defer alloc.free(with.stdout);
    try std.testing.expectEqual(@as(u8, 0), with.code);
    const with_id = try alloc.dupe(u8, std.mem.trim(u8, with.stdout, " \r\n"));
    defer alloc.free(with_id);

    const header = try readSessionFile(alloc, io, ws, with_id);
    defer alloc.free(header);
    const active_ref = try std.fmt.allocPrint(alloc, "\"id\":\"mode.demo\",\"version\":\"{s}\"", .{version});
    defer alloc.free(active_ref);
    try std.testing.expect(std.mem.indexOf(u8, header, active_ref) != null);
    // Membership, not a native pin: the tool face is untouched.
    try std.testing.expect(std.mem.indexOf(u8, header, "\"native_tools\":[]") != null);

    // What the model actually sees: the mode's system prompt is a system block
    // and its skill is in the catalog — rebuilt from the header, the way every
    // `session step` process does it.
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = EndTurnModel{};
    const opts: session.AgentSession.Options = .{
        .model = .{ .ptr = &model, .vtable = &EndTurnModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    };
    const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{with_id});
    defer alloc.free(spath);
    {
        var resumed = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = spath });
        defer resumed.deinit();
        var saw_prompt = false;
        for (resumed.composition.system_prompts.blocks) |b| {
            if (std.mem.indexOf(u8, b.bytes, "demo mode") != null) saw_prompt = true;
        }
        try std.testing.expect(saw_prompt);
        try std.testing.expectEqual(@as(usize, 1), resumed.composition.skills.skills.len);
        try std.testing.expectEqualStrings("mode-recipes", resumed.composition.skills.skills[0].name);
        try std.testing.expectEqual(@as(usize, 2), resumed.composition.tools.tools.len); // shell + edit only
    }

    // The listing says which frozen package rewrites the system blocks of the
    // sessions that carry it — a package with that power should be readable
    // without opening a manifest by hand.
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list", "--json" });
        defer alloc.free(listed.stdout);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, listed.stdout, .{});
        defer parsed.deinit();
        const composed = parsed.value.object.get("sessions").?.array.items[0].object.get("composition").?.object;
        const prompts = composed.get("system_prompts").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), prompts.len);
        const expected = try std.fmt.allocPrint(alloc, "mode.demo@{s}/prompts/mode.md", .{version});
        defer alloc.free(expected);
        try std.testing.expectEqualStrings(expected, prompts[0].string);
    }

    // A later session that does NOT ask for it sees nothing of it: `--with` is
    // per-session membership, and it does not leak into the next session.
    {
        const plain = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
        defer alloc.free(plain.stdout);
        const plain_id = try alloc.dupe(u8, std.mem.trim(u8, plain.stdout, " \r\n"));
        defer alloc.free(plain_id);
        const plain_header = try readSessionFile(alloc, io, ws, plain_id);
        defer alloc.free(plain_header);
        try std.testing.expect(std.mem.indexOf(u8, plain_header, "mode.demo") == null);
    }

    // A fork does not inherit it either — composition is always resolved fresh.
    {
        const parent_ref = try std.fmt.allocPrint(alloc, "{s}:0", .{with_id});
        defer alloc.free(parent_ref);
        const fork = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--parent", parent_ref });
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 0), fork.code);
        const fork_id = try alloc.dupe(u8, std.mem.trim(u8, fork.stdout, " \r\n"));
        defer alloc.free(fork_id);
        const fork_header = try readSessionFile(alloc, io, ws, fork_id);
        defer alloc.free(fork_header);
        try std.testing.expect(std.mem.indexOf(u8, fork_header, "mode.demo") == null);
    }

    // Once activated, the bare id resolves to `current` — the same composition,
    // named the other way.
    {
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "mode.demo", version });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);

        // Now that it is active it enters EVERY future session's system blocks
        // (DESIGN §7.5), and the listing says so out loud.
        const list = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "list" });
        defer alloc.free(list.stdout);
        try std.testing.expect(std.mem.indexOf(u8, list.stdout, "[skills prompt]") != null);

        const bare = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "mode.demo" });
        defer alloc.free(bare.stdout);
        try std.testing.expectEqual(@as(u8, 0), bare.code);
        const bare_id = try alloc.dupe(u8, std.mem.trim(u8, bare.stdout, " \r\n"));
        defer alloc.free(bare_id);
        const bare_header = try readSessionFile(alloc, io, ws, bare_id);
        defer alloc.free(bare_header);
        try std.testing.expect(std.mem.indexOf(u8, bare_header, active_ref) != null);
        const deactivated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "deactivate", "mode.demo" });
        defer alloc.free(deactivated.stdout);
        try std.testing.expectEqual(@as(u8, 0), deactivated.code);
    }

    // An id with no built version — and a bare id with nothing activated — are
    // refused rather than silently dropped: the caller named them.
    {
        const bad = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "nope" });
        defer alloc.free(bad.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad.code);
        const bare_inactive = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "mode.demo" });
        defer alloc.free(bare_inactive.stdout);
        try std.testing.expectEqual(@as(u8, 1), bare_inactive.code);
        const bad_version = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--with", "mode.demo@v-000000000000000000000000" });
        defer alloc.free(bad_version.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad_version.code);
    }
}

// ── M5d: `ext build` lands under the store root, by manifest id ─────────────

/// A model that prices every turn, so the ledger has a real cost to record.
const PricedModel = struct {
    step_no: usize = 0,

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "priced";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "priced";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = alloc;
        _ = request;
        const self: *PricedModel = @ptrCast(@alignCast(ptr));
        const n = self.step_no;
        self.step_no += 1;
        try sink.emit(.started);
        try sink.emit(.{ .text_delta = "priced turn" });
        try sink.emit(.{ .usage = .{
            .input_tokens = 1000 + n,
            .output_tokens = 10 + n,
            .cache_read_tokens = 900,
            .cache_write_tokens = 0,
        } });
        try sink.emit(.{ .done = .end_turn });
    }
    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

test "durable ledger: assistant events carry per-step usage, legacy lines read as absent, and PromptIR turns are unchanged" {
    const alloc = std.testing.allocator;
    const io = std.testing.io; // PricedModel issues no tool calls, so no async shell.

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];
    try ws.createDirPath(io, sessions_dir_rel);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = PricedModel{};
    const opts: session.AgentSession.Options = .{
        .model = .{ .ptr = &model, .vtable = &PricedModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    };

    var flat_priced: []u8 = undefined;
    {
        var sess = try session.AgentSession.createDurable(alloc, opts, .{
            .workspace = ws,
            .session_path = session_file_rel,
            .session_id = "s",
        });
        defer sess.deinit();
        try sess.appendUser("go");
        _ = try sess.step();

        const priced = sess.l.view()[1].assistant.usage.?;
        try std.testing.expectEqual(@as(u64, 1000), priced.input_tokens);
        try std.testing.expectEqual(@as(u64, 900), priced.cache_read_tokens);

        const ir = try prompt.projectWithSystem(alloc, sess.composition.system_prompts.blocks, sess.l.view());
        defer ir.deinit(alloc);
        flat_priced = try flattenIR(alloc, ir);
    }
    defer alloc.free(flat_priced);

    // It is on the line, and it survives a reopen by another process.
    const bytes = try readSessionFile(alloc, io, ws, "s");
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"usage\":{\"input_tokens\":1000,\"output_tokens\":10,\"cache_read_tokens\":900,\"cache_write_tokens\":0}") != null);

    var reopened = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 1000), reopened.l.view()[1].assistant.usage.?.input_tokens);

    // Cost is a fact about the turn, not model-visible text: the projected
    // turns are identical to those of the same conversation with no usage at
    // all — which is also how every pre-M5b line still reads back.
    var plain = ledger.Ledger.init(alloc);
    defer plain.deinit();
    for (reopened.l.view()) |e| switch (e) {
        .assistant => |as| try plain.append(.{ .assistant = .{ .reasoning = as.reasoning, .text = as.text, .calls = as.calls } }),
        else => try plain.append(e),
    };
    const ir_plain = try prompt.projectWithSystem(alloc, reopened.composition.system_prompts.blocks, plain.view());
    defer ir_plain.deinit(alloc);
    const flat_plain = try flattenIR(alloc, ir_plain);
    defer alloc.free(flat_plain);
    try std.testing.expectEqualStrings(flat_plain, flat_priced);
    try std.testing.expect(plain.view()[1].assistant.usage == null);
}

// ── M5a: the session-outcome journal (DESIGN §3.3) ──────────────────────────

test "session cli: outcome appends a verdict to the outcomes journal, rejects a bad verdict and an unknown session, and works while another process holds the session lock" {
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

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    // A verdict is a judgment about the session, not a turn in it: recording one
    // takes no writer lease, so it works even while another process holds the
    // session file open as its writer.
    {
        const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
        defer alloc.free(spath);
        var held = try ledger.openDurable(alloc, io, ws, spath);
        defer held.deinit();
        // The lease really is held: a second writer is refused right now.
        try std.testing.expectError(error.SessionBusy, ledger.openDurable(alloc, io, ws, spath));

        const rec = try runCli(alloc, io, ws, &.{ exe_abs, "session", "outcome", id, "partial", "--note", "tool loop was slow" });
        defer alloc.free(rec.stdout);
        try std.testing.expectEqual(@as(u8, 0), rec.code);
    }

    // A later judgment corrects an earlier one; both lines stay.
    {
        const rec = try runCli(alloc, io, ws, &.{ exe_abs, "session", "outcome", id, "success" });
        defer alloc.free(rec.stdout);
        try std.testing.expectEqual(@as(u8, 0), rec.code);
    }

    // A bad verdict and an unknown session are refused without writing anything.
    {
        const bad = try runCli(alloc, io, ws, &.{ exe_abs, "session", "outcome", id, "great" });
        defer alloc.free(bad.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad.code);
        const missing = try runCli(alloc, io, ws, &.{ exe_abs, "session", "outcome", "s-nope", "success" });
        defer alloc.free(missing.stdout);
        try std.testing.expectEqual(@as(u8, 1), missing.code);
    }

    const outcomes = try outcome.readAll(alloc, io, ws_path);
    defer outcome.freeAll(alloc, outcomes);
    try std.testing.expectEqual(@as(usize, 2), outcomes.len);
    try std.testing.expectEqualStrings(id, outcomes[0].session);
    try std.testing.expectEqual(outcome.Verdict.partial, outcomes[0].verdict);
    try std.testing.expectEqualStrings("tool loop was slow", outcomes[0].note.?);
    try std.testing.expect(outcomes[1].note == null);
    // The verdict that stands is the last one, and it is timestamped.
    const latest = outcome.latestFor(outcomes, id).?;
    try std.testing.expectEqual(outcome.Verdict.success, latest.verdict);
    try std.testing.expectEqual(@as(usize, 20), latest.at.len);
    // Nothing said about the writer means a person judged it.
    try std.testing.expectEqual(outcome.Source.human, latest.source);
    try std.testing.expect(latest.by == null);

    // The model reaches this command through `shell`, whose env names the live
    // session (NULYA_SESSION) — so the journal can record that the session graded
    // ITSELF instead of leaving the slow loop unable to tell.
    {
        const spath_rel = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
        defer alloc.free(spath_rel);
        const self_graded = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "outcome", id, "success", "--note", "went great, if I say so myself" }, "NULYA_SESSION", spath_rel);
        defer alloc.free(self_graded.stdout);
        try std.testing.expectEqual(@as(u8, 0), self_graded.code);

        // `--seq` judges ONE assistant turn; it is evidence, never the session's
        // verdict. The number is validated but not bounds-checked: this command
        // stays a journal append and never opens the session file.
        const turn = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "outcome", id, "failure", "--seq", "2", "--note", "wrong file" }, "NULYA_SESSION", spath_rel);
        defer alloc.free(turn.stdout);
        try std.testing.expectEqual(@as(u8, 0), turn.code);

        const bad_seq = try runCli(alloc, io, ws, &.{ exe_abs, "session", "outcome", id, "success", "--seq", "0" });
        defer alloc.free(bad_seq.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad_seq.code);
    }

    const judged = try outcome.readAll(alloc, io, ws_path);
    defer outcome.freeAll(alloc, judged);
    try std.testing.expectEqual(@as(usize, 4), judged.len);
    try std.testing.expectEqual(outcome.Source.agent, judged[2].source);
    try std.testing.expectEqualStrings(id, judged[2].by.?); // by == session: a self-grade
    try std.testing.expect(judged[2].seq == null);
    try std.testing.expectEqual(@as(u64, 2), judged[3].seq.?);
    try std.testing.expectEqual(outcome.Verdict.failure, judged[3].verdict);

    // The verdict that stands is the last WHOLE-SESSION line — the self-grade —
    // and the turn-level failure never becomes the session's grade.
    const stands = outcome.latestFor(judged, id).?;
    try std.testing.expectEqual(outcome.Verdict.success, stands.verdict);
    try std.testing.expectEqual(outcome.Source.agent, stands.source);

    // `session list` carries who judged, so a self-grade is visible at a glance.
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list", "--json" });
        defer alloc.free(listed.stdout);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, listed.stdout, .{});
        defer parsed.deinit();
        const view = parsed.value.object.get("sessions").?.array.items[0].object.get("outcome").?.object;
        try std.testing.expectEqualStrings("agent", view.get("source").?.string);
        try std.testing.expectEqualStrings(id, view.get("by").?.string);

        const text = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
        defer alloc.free(text.stdout);
        try std.testing.expect(std.mem.indexOf(u8, text.stdout, "(self)") != null);
    }

    // The session file itself was never touched by any of this.
    const bytes = try readSessionFile(alloc, io, ws, id);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "outcome") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "partial") == null);
}

// ── M2b: script extensions (DESIGN §7.1) ────────────────────────────────────
