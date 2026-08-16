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
//!
//! And the `nulya session *` CLI (PLAN §3.2): a shell-script driver runs a goal
//! loop to completion, and `--max-steps` is enforced by the kernel even when the
//! loop-mode model would run forever.
//!
//! And script extensions (DESIGN §7.1): a script extension goes init(--script) →
//! build (no toolchain) → activate → run → pinned native and executes through
//! its interpreter; its version excludes compiler identity and is rebuild-stable.
//!
//! And the slow loop's substrate (M5): a verdict recorded while another process
//! holds the session lease (DESIGN §3.3); per-step usage on the assistant event,
//! not projected (§3.1); extensions discovered across workspace and user store
//! roots with first-root-wins shadowing, and a frozen version resolved from
//! whichever root holds it (§7.2); `ext build` landing under the store root by
//! manifest id; `session new --with` composing a built-but-inactive version into
//! one session; `session list --json`; and the repo's own `extensions/evolution`
//! going through exactly that path with no special casing.

const std = @import("std");
const support = @import("support");

const build_ext = support.build_ext;
const composition = support.composition;
const environment = support.environment;
const integrity = support.integrity;
const ledger = support.ledger;
const outcome = support.outcome;
const prompt = support.prompt;
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

    var dest = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer dest.close(io);
    var result = try build_ext.buildExtension(alloc, io, ws, ext_dir, dest, zig_exe);
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

test "self-manufacture closed loop: a shell/edit-only session builds its own extension; usage alone never promotes it; a pin — from config or --pin — makes it native in the next session" {
    // The milestone's first sentence, proven with no harness-built extension:
    //
    //   Session A exposes ONLY shell + edit. A deterministic model, through those
    //   builtins alone (real ToolExecutor -> LocalEnvironment shell spawns), runs
    //   `nulya ext init/build/activate/run` to manufacture a brand-new capability
    //   and records its usage. The tool never becomes native mid-session.
    //     -> Session B, opened with no pin, STILL sees only shell + edit: the
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
        try std.testing.expectEqual(@as(usize, 2), comp_plain.tools.tools.len);
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
    // quietly missing the tool it was asked for.
    {
        const bad = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--pin", "ext:demo/absent" });
        defer alloc.free(bad.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad.code);
        try std.testing.expect(std.mem.indexOf(u8, bad.stdout, "ext:demo/absent") != null);
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
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    }, .{ .workspace = ws, .session_path = spath });
    defer resumed.deinit();

    try std.testing.expectEqual(@as(usize, 3), resumed.composition.tools.tools.len);
    const greet = resumed.composition.tools.lookup("greet") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ext:demo/greet", greet.definition.id);
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

test "cli src: --raw matches the on-disk source; default strips tests; ext api reads real source" {
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

    // The binary embeds the exact `src/**` it was built from, so `--raw` prints
    // that file byte-for-byte — regardless of the child's cwd (here a fresh tmp).
    // The test process cwd is the build root, so the on-disk source is readable.
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, "src" ++ std.fs.path.sep_str ++ "prompt.zig", alloc, .unlimited);
    defer alloc.free(on_disk);

    const raw = try runCli(alloc, io, ws, &.{ exe_abs, "src", "prompt.zig", "--raw" });
    defer alloc.free(raw.stdout);
    try std.testing.expectEqual(@as(u8, 0), raw.code);
    try std.testing.expectEqualStrings(on_disk, raw.stdout);

    // The default view strips top-level test blocks: shorter, and no test header
    // survives at column 0 (the raw view has them).
    const def = try runCli(alloc, io, ws, &.{ exe_abs, "src", "prompt.zig" });
    defer alloc.free(def.stdout);
    try std.testing.expectEqual(@as(u8, 0), def.code);
    try std.testing.expect(def.stdout.len < raw.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, raw.stdout, "\ntest ") != null);
    try std.testing.expect(std.mem.indexOf(u8, def.stdout, "\ntest ") == null);

    // No path lists the embedded tree.
    const list = try runCli(alloc, io, ws, &.{ exe_abs, "src" });
    defer alloc.free(list.stdout);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "prompt.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "extension/protocol.zig") != null);

    // `ext api` is now a curated `nulya src`: it prints the real protocol source.
    const api = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "api" });
    defer alloc.free(api.stdout);
    try std.testing.expectEqual(@as(u8, 0), api.code);
    try std.testing.expect(std.mem.indexOf(u8, api.stdout, "Extension wire protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, api.stdout, "tool/call") != null);

    // An unknown path fails cleanly.
    const miss = try runCli(alloc, io, ws, &.{ exe_abs, "src", "nope.zig" });
    defer alloc.free(miss.stdout);
    try std.testing.expectEqual(@as(u8, 1), miss.code);
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

/// Serialize a PromptIR into a comparable byte string: one line per system
/// block, then one line per part of every turn, tagged by kind. Two projections
/// are turn-for-turn identical iff their serializations are. A string rather
/// than a structural `prompt.isStablePrefix` comparison because the two sides
/// are never alive at once here — the exclusive session lease means process A's
/// ledger is closed before process B opens the same file.
fn flattenIR(alloc: std.mem.Allocator, ir: prompt.PromptIR) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (ir.system_blocks) |b| try out.writer.print("S|{s}\n", .{b.bytes});
    for (ir.turns) |turn| switch (turn) {
        .user_text => |text| try out.writer.print("U|{s}\n", .{text}),
        .assistant => |as| {
            try out.writer.print("R|{s}\nA|{s}\n", .{ as.reasoning, as.text });
            for (as.calls) |c| try out.writer.print("C|{s}|{s}|{s}\n", .{ c.id, c.tool, c.args_json });
        },
        .tool_results => |results| for (results) |r| {
            try out.writer.print("T|{s}|{}|{s}\n", .{ r.call_id, r.ok, r.output });
        },
        .capability_note => |text| try out.writer.print("N|{s}\n", .{text}),
    };
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
    return runCliEnvs(alloc, io, ws, argv, &.{.{ .key = key, .value = value }});
}

const EnvPair = struct { key: []const u8, value: []const u8 };

fn runCliEnvs(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
    pairs: []const EnvPair,
) !CliRun {
    var env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer env.deinit();
    for (pairs) |p| try env.put(p.key, p.value);
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

/// One CLI invocation, keeping STDERR instead of stdout: notes and warnings are
/// written there precisely so stdout stays the machine-readable surface. Caller
/// owns the result.
fn runCliStderr(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
    pairs: []const EnvPair,
) ![]u8 {
    var env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
    defer env.deinit();
    for (pairs) |p| try env.put(p.key, p.value);
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = .{ .dir = ws },
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return alloc.dupe(u8, result.stderr);
}

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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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
        const fork = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "new", "--parent", "s-nope:0" }, env);
        defer alloc.free(fork.stdout);
        try std.testing.expectEqual(@as(u8, 1), fork.code);
        try std.testing.expect(std.mem.indexOf(u8, fork.stdout, "s-") == null or
            std.mem.indexOf(u8, fork.stdout, "cannot read parent") != null);
    }
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

test "session cli: --stream emits the transient line protocol and leaves the ledger identical" {
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
    try std.testing.expectEqual(@as(usize, 2), comp.pinned_extensions.len);
    var saw_user_wide = false;
    var shared_version: []const u8 = "";
    for (comp.pinned_extensions) |p| {
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
    try std.testing.expectEqual(@as(usize, 2), resumed.pinned_extensions.len);
    for (resumed.pinned_extensions) |p| {
        if (std.mem.eql(u8, p.id, "shared")) try std.testing.expectEqualStrings(user_shared, p.version);
    }

    // Without the user root in the search order, only the workspace copy exists.
    var workspace_only = try composition.SessionComposition.init(alloc, io, ws_path, &.{".nulya/extensions"}, .{});
    defer workspace_only.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), workspace_only.pinned_extensions.len);
    try std.testing.expectEqualStrings("shared", workspace_only.pinned_extensions[0].id);
}

test "cli: NULYA_HOME extensions are visible to ext list / skill list / ext run, with shadowing marked" {
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
    // user copy, which is named by a pinned ref rather than by id.
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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

test "cli: a build that fails to compile leaves no ghost extension in ext list" {
    // `<id>/.lock` is the writer lease, and `Store.lease` creates `<id>/` to hold
    // it — before the compile that may still fail. A failed compile deletes its
    // half-built version but not that directory, so the very first build of an
    // extension whose source does not compile (routine while an agent is writing
    // one) leaves a directory containing nothing but the lock. It is a lock
    // location, not an extension, and `ext list` must not invent one from it.
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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
    // pinned ref the model can load.
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

// ── M5f: `session list` (read-only projection of .nulya/sessions) ───────────

test "session cli: list --json reports parent, event count, summed usage and the latest outcome" {
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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

test "cli ext build: a draft outside any store lands in the workspace store under its manifest id; --user lands in the user store; a draft inside a store lands in that store; in-store builds are byte-identical to before" {
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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

    var host_env = try std.process.Environ.createMap(.{ .block = .global }, alloc);
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
