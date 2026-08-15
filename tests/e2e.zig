//! End-to-end proof of the milestone (DESIGN §16): "Nulya v0.1 ships two tools.
//! The third is created by Nulya itself."
//!
//! This scaffolds a real extension, builds it with the HOST's zig (injected via
//! NULYA_TEST_ZIG by build.zig so the ~90MB embed is not needed), activates the
//! immutable version, then invokes it through the same Environment seam a live
//! agent would use — and checks the wire response round-trips. Run with
//! `zig build e2e`.
//!
//! It also covers the durable ledger (DESIGN §3.4): a session created with
//! `createDurable` persists to a JSONL file, a second process `openDurable`
//! resumes it and projects a block-identical PromptIR, a separate CLI process's
//! `capability_note` deposit is drained on the next step, and a crash-left
//! assistant-with-calls tail is repaired on resume.

const std = @import("std");
const support = @import("support");

const build_ext = support.build_ext;
const composition = support.composition;
const environment = support.environment;
const integrity = support.integrity;
const ledger = support.ledger;
const notes = support.notes;
const prompt = support.prompt;
const promotion = support.promotion;
const protocol = support.protocol;
const provider = support.provider;
const session = support.session;
const store = support.store;
const templates = support.templates;
const tool = support.tool;
const tool_stats = support.tool_stats;

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
    const version = try scaffoldAndBuild(alloc, io, ws, zig_exe, id, tool_name, main_src);
    errdefer alloc.free(version);
    var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer ext_root.close(io);
    try store.Store.init(io, ext_root).activate(alloc, id, version);
    return version;
}

/// Scaffold a real single-file extension and build it into an immutable version
/// WITHOUT activating it. Returns the built version id; caller frees.
fn scaffoldAndBuild(
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

test "closed loop: usage-driven promotion executes the frozen version through the tool executor (harness-built extension)" {
    // The promotion + freeze half of the kernel loop, proven end to end with a
    // real built binary — not a stub, not a FakeEnv. The extension here is built
    // by the test harness (`buildAndActivate`); the separate self-manufacture test
    // below proves a shell/edit-only session can build it itself.
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

/// Deterministic model that drives a session through a fixed sequence of `shell`
/// tool calls — one per step — then ends the turn. `args_per_step[n]` is the JSON
/// argument for step n's shell call (`{"command":"..."}`); an empty entry means
/// "address the user and end". The slice is read live each step, so the harness
/// can fill in a later step (the activate command) once an earlier step's real
/// output reveals the built version id.
const SelfBuildModel = struct {
    args_per_step: []const []const u8,
    step_no: usize = 0,

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "self-build";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "self-build";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = alloc;
        _ = request;
        const self: *SelfBuildModel = @ptrCast(@alignCast(ptr));
        const n = self.step_no;
        self.step_no += 1;
        try sink.emit(.started);
        if (n >= self.args_per_step.len or self.args_per_step[n].len == 0) {
            try sink.emit(.{ .text_delta = "greet is ready." });
            try sink.emit(.{ .done = .end_turn });
            return;
        }
        try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "call", .name = "shell" } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = self.args_per_step[n] } });
        try sink.emit(.{ .done = .tool_use });
    }
    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

/// Encode a `shell` builtin argument object `{"command":"..."}`, escaping the
/// command exactly as a real model's tool call would arrive. Caller owns it.
fn shellCallArgs(alloc: std.mem.Allocator, command: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("command");
    try jw.write(command);
    try jw.endObject();
    return out.toOwnedSlice();
}

/// A copy of `s` with `\` turned into `/`, so an absolute Windows exe path is
/// safe to pass through both Git Bash and PowerShell (both accept `/`). Caller
/// owns it.
fn forwardSlashes(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try alloc.dupe(u8, s);
    for (buf) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buf;
}

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

fn isHexLower(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// Extract the `v-<24 hex>` version id from `nulya ext build` output. Caller owns it.
fn extractVersion(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const idx = std.mem.indexOf(u8, text, integrity.version_prefix) orelse return error.TestUnexpectedResult;
    var end = idx + integrity.version_prefix.len;
    while (end < text.len and isHexLower(text[end])) end += 1;
    return alloc.dupe(u8, text[idx..end]);
}

test "self-manufacture closed loop: a shell/edit-only session builds its own extension, a later session promotes it to native" {
    // The milestone's first sentence, proven with no harness-built extension:
    //
    //   Session A exposes ONLY shell + edit. A deterministic model, through those
    //   builtins alone (real ToolExecutor -> LocalEnvironment shell spawns), runs
    //   `nulya ext init/build/activate/run` to manufacture a brand-new capability
    //   and records its usage. The tool never becomes native mid-session.
    //     -> Session B ranks that usage, auto-promotes the tool to a native tool,
    //        and its executor spawns the frozen binary the model just built.
    //
    // No real LLM: a scripted provider issues the exact shell commands a model
    // would. `NULYA_ZIG` is injected into the (non-secret) sanitized child env so
    // the model's `nulya ext build` finds a toolchain without an embedded one.
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    // NULYA_ZIG is not secret-shaped, so it survives sanitization and reaches the
    // model's `nulya ext build` grandchild (test -> shell -> nulya -> zig).
    try lenv.env.put("NULYA_ZIG", zig_exe);

    const exe_fwd = try forwardSlashes(alloc, exe_abs);
    defer alloc.free(exe_fwd);
    const call_prefix = if (lenv.dialect_val == .powershell) "& " else "";

    // The model's scripted shell commands. args[2] (activate) is filled after the
    // real build step reveals the version. args[4] == "" ends the turn.
    var args: [5][]const u8 = .{ "", "", "", "", "" };
    defer for (args) |a| if (a.len != 0) alloc.free(a);
    {
        const c = try std.fmt.allocPrint(alloc, "{s}'{s}' ext init demo greet", .{ call_prefix, exe_fwd });
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
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    });
    defer sess.deinit();

    // Session A's model face is exactly the two builtins — no extension exists yet.
    try std.testing.expectEqual(@as(usize, 2), sess.composition.tools.tools.len);
    try std.testing.expect(sess.composition.tools.lookup("shell") != null);
    try std.testing.expect(sess.composition.tools.lookup("edit") != null);
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

    // Session A never promoted the tool: its face is frozen at shell + edit.
    try std.testing.expectEqual(@as(usize, 2), sess.composition.tools.tools.len);
    try std.testing.expect(sess.composition.tools.lookup("greet") == null);

    // The model's own `nulya ext run` recorded the durable usage fact.
    {
        const events = try tool_stats.readAll(alloc, io, ws_path);
        defer tool_stats.freeEvents(alloc, events);
        var saw = false;
        for (events) |e| {
            if (std.mem.eql(u8, e.tool_id, "ext:demo/greet")) saw = true;
        }
        try std.testing.expect(saw);
    }

    // --- Session B: the manufactured tool is now auto-promoted to native. ---
    const ranked = try promotion.rankExtensionTools(alloc, io, ws_path, .{});
    defer promotion.freeRankedIds(alloc, ranked);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqualStrings("ext:demo/greet", ranked[0]);

    var comp_b = try composition.SessionComposition.init(alloc, io, ws_path, ".nulya/extensions", .{ .ranked_native_tools = ranked });
    defer comp_b.deinit(alloc);
    const greet = comp_b.tools.lookup("greet") orelse return error.TestUnexpectedResult;
    const result = try callNative(alloc, io, greet, ws_path);
    defer alloc.free(result.output);
    try std.testing.expect(result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello from a Nulya-built extension") != null);
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

// ── M1: durable ledger (DESIGN §3) ──────────────────────────────────────────

/// A model that always addresses the user and ends the turn (no tool calls).
const EndTurnModel = struct {
    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "end-turn";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "end-turn";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = ptr;
        _ = alloc;
        _ = request;
        try sink.emit(.started);
        try sink.emit(.{ .text_delta = "done" });
        try sink.emit(.{ .done = .end_turn });
    }
    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

/// Flatten a PromptIR into a comparable byte string (one line per block, prefixed
/// with `S|` for a system block or the stable block's kind tag). Two block-level
/// prefixes are identical iff their flattenings are.
fn flattenIR(alloc: std.mem.Allocator, ir: prompt.PromptIR) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (ir.system_blocks) |b| try out.writer.print("S|{s}\n", .{b.bytes});
    for (ir.stable_blocks) |b| try out.writer.print("{d}|{s}\n", .{ @intFromEnum(b.kind), b.bytes });
    return out.toOwnedSlice();
}

/// One CLI invocation with an extra environment variable set (plus the inherited
/// host env, so PATH etc. survive). Caller owns `stdout`.
fn runCliEnv(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
    key: []const u8,
    value: []const u8,
) !CliRun {
    var env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer env.deinit();
    try env.put(key, value);
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
    return .{ .code = code, .stdout = try alloc.dupe(u8, result.stdout) };
}

const sessions_dir_rel = ".nulya" ++ std.fs.path.sep_str ++ "sessions";
const session_file_rel = sessions_dir_rel ++ std.fs.path.sep_str ++ "s.jsonl";

test "durable ledger: process A steps twice and exits; process B resumes and projects a block-identical PromptIR" {
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
    // A real multi-block conversation: user, assistant(call), tool_result, assistant.
    try std.testing.expect(ir_b.stable_blocks.len >= 4);
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

    // Process B: on resume the interrupted batch is completed before the next turn.
    var b = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 2), b.l.len()); // user, assistant(call) — not yet repaired
    _ = try b.step();
    // user, assistant(call), tool_results(interrupted), assistant(end)
    try std.testing.expectEqual(@as(usize, 4), b.l.len());
    try std.testing.expect(b.l.view()[2] == .tool_results);
    try std.testing.expect(!b.l.view()[2].tool_results[0].ok);
    try std.testing.expect(std.mem.indexOf(u8, b.l.view()[2].tool_results[0].output, "state is unknown") != null);

    // The repair persisted: a third process sees the completed batch on disk.
    var c = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 4), c.l.len());
}

test "durable ledger: a capability_note appended by a separate CLI process is read on the next step" {
    const alloc = std.testing.allocator;
    const io = std.testing.io; // EndTurnModel issues no tool calls, so no async shell.

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

    var sess = try session.AgentSession.createDurable(alloc, opts, .{
        .workspace = ws,
        .session_path = session_file_rel,
        .session_id = "s",
    });
    defer sess.deinit();
    try sess.appendUser("please make a greet tool");

    // No note yet.
    try std.testing.expect(!try notes.containsNoteFor(&sess.l, "demo", version));

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
    try std.testing.expect(try notes.containsNoteFor(&sess.l, "demo", version));

    const ir = try prompt.projectWithSystem(alloc, sess.composition.system_prompts.blocks, sess.l.view());
    defer ir.deinit(alloc);
    var saw_note_block = false;
    for (ir.stable_blocks) |blk| {
        if (blk.kind == .capability_note and std.mem.indexOf(u8, blk.bytes, "greet") != null) saw_note_block = true;
    }
    try std.testing.expect(saw_note_block);

    // And it is durable: a fresh process resuming the session still sees the note.
    var reopened = try session.AgentSession.openDurable(alloc, opts, .{ .workspace = ws, .session_path = session_file_rel });
    defer reopened.deinit();
    try std.testing.expect(try notes.containsNoteFor(&reopened.l, "demo", version));
}

// ── M2a: `nulya session *` CLI (PLAN §3.2) ──────────────────────────────────

/// Read a whole session file's bytes. Caller owns them.
fn readSessionFile(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
    defer alloc.free(path);
    return ws.readFileAlloc(io, path, alloc, .unlimited);
}

test "session cli: --max-steps is enforced by the kernel even when the driver asks for more" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // `new` and `append` never invoke the model; only `step` does, so only it
    // needs the loop-mode env. The loop model never ends its turn.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--model", "scripted" });
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

test "session cli: a shell-script driver runs a goal loop to completion" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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
        \\$id = (& $n session new --model scripted).Trim()
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
        \\id=$("$n" session new --model scripted)
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
    if (code != 0) std.debug.print("driver failed ({d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
    try std.testing.expectEqual(@as(u8, 0), code); // the driver reached its goal and exited 0
}
