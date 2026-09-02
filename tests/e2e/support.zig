//! Shared fixtures for the e2e tests: the real-`nulya`-process runners, the
//! extension scaffolds, the deterministic models, and the small readers the
//! grouped test files below all reach for.
//!
//! It also re-exports `src/root.zig` — the public `nulya` library module,
//! imported here under the build name `support` — so every test file has ONE
//! import: core modules and test helpers arrive under the same name, and the
//! suite exercises exactly the surface a dependent package gets.

const std = @import("std");
const support = @import("support");

pub const build_ext = support.build_ext;
pub const composition = support.composition;
pub const config = support.config;
pub const emit = support.emit;
pub const environment = support.environment;
pub const integrity = support.integrity;
pub const launch = support.launch;
pub const ledger = support.ledger;
pub const manifest = support.manifest;
pub const outcome = support.outcome;
pub const prompt = support.prompt;
pub const provider = support.provider;
pub const remote = support.remote;
pub const remote_protocol = support.remote_protocol;
pub const session = support.session;
pub const site = support.site;
pub const store = support.store;
pub const target = support.target;
pub const templates = support.templates;
pub const tool = support.tool;
pub const tool_stats = support.tool_stats;

/// A single-file compiled extension, as small as the wire allows: drain stdin
/// (so the host's write never blocks), print one line, exit 0. Its stdout IS
/// what the caller reads back, so a test can assert on the greeting directly.
///
/// Deliberately not `templates.main_zig`, which is the real `ext init --zig`
/// scaffold: `greetSource` rewrites the greeting to tell two builds apart, and
/// pinning the assertions of a dozen tests to the text of a scaffold would make
/// every wording change there a test change here.
pub const plain_main_zig =
    \\const std = @import("std");
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    const alloc = init.gpa;
    \\    const io = init.io;
    \\
    \\    var in_buf: [4096]u8 = undefined;
    \\    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    \\    const args_json = try reader.interface.allocRemaining(alloc, .limited(1 << 20));
    \\    defer alloc.free(args_json);
    \\
    \\    try std.Io.File.stdout().writeStreamingAll(io, "hello from a Nulya-built extension");
    \\}
    \\
;

/// `extension.json` for `plain_main_zig` and every hand-written `main_src`
/// these tests hand to `scaffoldAndBuild` / `buildAndActivate`. Deliberately
/// minimal — one tool, an empty input schema — rather than
/// `templates.manifestJson`, so the fixtures do not move when the scaffold's
/// wording does.
///
/// `"surface": "manual"` because these fixtures exist for the PIN tests: only
/// a `manual` tool can be pinned, and the default is `auto` —
/// membership alone would put it on the face, which is a different test.
fn fixtureManifestJson(alloc: std.mem.Allocator, id: []const u8, tool_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{ "entry": "bin/{s}" }},
        \\  "contributes": {{
        \\    "tools": [{{
        \\      "name": "{s}",
        \\      "surface": "manual",
        \\      "description": "A generated Nulya extension tool.",
        \\      "input": {{ "type": "object", "properties": {{}} }}
        \\    }}],
        \\    "skills": []
        \\  }}
        \\}}
        \\
    , .{ id, id, tool_name });
}

/// Scaffold a real, buildable extension (`id`/`tool`, single-file entry source),
/// put its immutable built version in the workspace store, and activate it.
/// Returns the activated version id; caller frees.
pub fn buildAndActivate(
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
    try activateInStore(alloc, io, ws, id, version);
    return version;
}

/// Scaffold a real single-file extension into the workspace and put its built,
/// immutable version in the workspace store WITHOUT activating it. Returns the
/// built version id; caller frees.
///
/// The compile itself is shared through the prebuilt cache below — the draft is
/// written here exactly as before, but the frozen version is copied in rather
/// than compiled again for every test that needs one to exist.
pub fn scaffoldAndBuild(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    zig_exe: []const u8,
    id: []const u8,
    tool_name: []const u8,
    main_src: []const u8,
) ![]u8 {
    const manifest_bytes = try fixtureManifestJson(alloc, id, tool_name);
    defer alloc.free(manifest_bytes);
    try writeSingleFileDraft(alloc, io, ws, workspace_rel, id, manifest_bytes, main_src);
    return installPrebuilt(alloc, io, ws, zig_exe, id, manifest_bytes, main_src);
}

/// Write the draft `scaffoldAndBuild` builds: `<root_rel>/<id>/extension.json`
/// plus `<root_rel>/<id>/src/main.zig`.
fn writeSingleFileDraft(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    root_rel: []const u8,
    id: []const u8,
    manifest_bytes: []const u8,
    main_src: []const u8,
) !void {
    const ext_dir = try std.fs.path.join(alloc, &.{ root_rel, id });
    defer alloc.free(ext_dir);
    const src_dir = try std.fs.path.join(alloc, &.{ ext_dir, "src" });
    defer alloc.free(src_dir);
    try root.createDirPath(io, src_dir);

    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir, "extension.json" });
    defer alloc.free(manifest_rel);
    try root.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });
    const main_rel = try std.fs.path.join(alloc, &.{ src_dir, "main.zig" });
    defer alloc.free(main_rel);
    try root.writeFile(io, .{ .sub_path = main_rel, .data = main_src });
}

/// One real `nulya` CLI invocation against the workspace. The test binary's own
/// stdout is the test-runner protocol, so the CLI is spawned as a child with
/// the workspace as cwd and its output captured on pipes. Caller owns `stdout`.
pub const CliRun = struct { code: u8, stdout: []u8 };

pub fn runCli(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
) !CliRun {
    return runCliEnvs(alloc, io, ws, argv, &.{});
}

/// The `greet` fixture with its greeting text swapped, so two builds differ by
/// observable output (and therefore by content-addressed version). The source
/// stays a real, compilable single-file extension. Caller owns the bytes.
pub fn greetSource(alloc: std.mem.Allocator, greeting: []const u8) ![]u8 {
    const needle = "hello from a Nulya-built extension";
    const size = std.mem.replacementSize(u8, plain_main_zig, needle, greeting);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    _ = std.mem.replace(u8, plain_main_zig, needle, greeting, buf);
    return buf;
}

/// The workspace's drafts and its own pointer layer, relative to the workspace.
pub const workspace_rel = ".nulya" ++ std.fs.path.sep_str ++ "extensions";

/// The one store every e2e workspace uses, under the isolated test home.
/// Caller owns the result.
pub fn storePath(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir) ![]u8 {
    const home = try defaultHome(alloc, io, ws);
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, "store" });
}

/// Open (creating if needed) that store. Caller closes it.
pub fn openStore(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir) !std.Io.Dir {
    const path = try storePath(alloc, io, ws);
    defer alloc.free(path);
    return store.openOrCreateRoot(io, ".", path);
}

/// The absolute path of a directory inside `ws` — what an environment's store
/// path has to be, since nothing there resolves against a workspace. Caller
/// owns the result.
pub fn absIn(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, rel: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = buf[0..try ws.realPath(io, &buf)];
    return std.fs.path.join(alloc, &.{ ws_path, rel });
}

/// Point the store's own `current` at a version, the way `ext activate --user`
/// would.
pub fn activateInStore(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8, version: []const u8) !void {
    var dir = try openStore(alloc, io, ws);
    defer dir.close(io);
    try store.Store.init(io, dir).activate(alloc, id, version);
}

/// One native tool invocation through the real executor chain: a fresh
/// `LocalEnvironment` resolves the frozen version against this workspace's
/// store, spawns it, and returns its output. Caller owns `result.output`.
pub fn callNative(alloc: std.mem.Allocator, io: std.Io, t: tool.Tool, ws_path: []const u8, store_path: []const u8) !tool.RawToolResult {
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .extension_store = store_path });
    defer lenv.deinit();
    return t.executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = lenv.environment(), .cwd = ws_path },
    });
}

/// Deterministic model that drives a session through a fixed sequence of `shell`
/// tool calls — one per step — then ends the turn. `args_per_step[n]` is the JSON
/// argument for step n's shell call (`{"command":"..."}`); an empty entry means
/// "address the user and end". The slice is read live each step, so the harness
/// can fill in a later step (the activate command) once an earlier step's real
/// output reveals the built version id.
pub const SelfBuildModel = struct {
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
    pub const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

/// Encode a `shell` builtin argument object `{"command":"..."}`, escaping the
/// command exactly as a real model's tool call would arrive. Caller owns it.
pub fn shellCallArgs(alloc: std.mem.Allocator, command: []const u8) ![]u8 {
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
pub fn forwardSlashes(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try alloc.dupe(u8, s);
    for (buf) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buf;
}

fn isHexLower(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// Extract the `v-<24 hex>` version id from `nulya ext build` output. Caller owns it.
pub fn extractVersion(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const idx = std.mem.indexOf(u8, text, integrity.version_prefix) orelse return error.TestUnexpectedResult;
    var end = idx + integrity.version_prefix.len;
    while (end < text.len and isHexLower(text[end])) end += 1;
    return alloc.dupe(u8, text[idx..end]);
}

/// A model that always addresses the user and ends the turn (no tool calls).
pub const EndTurnModel = struct {
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
    pub const vtable: provider.Model.VTable = .{
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
pub fn flattenIR(alloc: std.mem.Allocator, ir: prompt.PromptIR) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (ir.system_blocks) |b| try out.writer.print("S|{s}\n", .{b.bytes});
    for (ir.turns) |turn| switch (turn) {
        .user_text => |u| {
            try out.writer.print("U|{s}\n", .{u.text});
            // Images are model-visible, so two projections that differ only in
            // them are NOT turn-identical.
            for (u.images) |img| try out.writer.print("I|{s}|{s}\n", .{ img.media_type, img.data });
        },
        .assistant => |as| {
            try out.writer.print("R|{s}\nA|{s}\n", .{ as.reasoning, as.text });
            for (as.calls) |c| try out.writer.print("C|{s}|{s}|{s}\n", .{ c.id, c.tool, c.args_json });
        },
        .tool_results => |results| for (results) |r| {
            try out.writer.print("T|{s}|{}|{s}\n", .{ r.call_id, r.ok, r.output });
        },
        .note => |text| try out.writer.print("N|{s}\n", .{text}),
    };
    return out.toOwnedSlice();
}

/// One CLI invocation with an extra environment variable set (plus the inherited
/// host env, so PATH etc. survive). Caller owns `stdout`.
pub fn runCliEnv(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
    key: []const u8,
    value: []const u8,
) !CliRun {
    return runCliEnvs(alloc, io, ws, argv, &.{.{ .key = key, .value = value }});
}

pub const EnvPair = struct { key: []const u8, value: []const u8 };

/// The child's user layer, defaulted into the workspace so no e2e run ever reads
/// or writes the developer's real `~/.nulya`: the ONE extension store and the
/// user config both live under `NULYA_HOME`. A test that cares about the user
/// layer passes its own `NULYA_HOME` pair, which wins — the pairs are applied
/// after this.
pub const home_subdir = ".nulya-test-home";

/// The ONE store, relative to the workspace — where every version an e2e run
/// builds lands, since `NULYA_HOME` points into the workspace.
pub const store_rel = home_subdir ++ std.fs.path.sep_str ++ "store";

/// That same user layer, for a test that spawns `nulya` some other way than
/// `runCli` — an in-process session whose `shell` runs the CLI has to point its
/// own tool environment here, or the two halves of the test disagree about which
/// home they read. Caller owns the result.
pub fn testHome(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir) ![]u8 {
    return defaultHome(alloc, io, ws);
}

fn defaultHome(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = buf[0..try ws.realPath(io, &buf)];
    return std.fs.path.join(alloc, &.{ ws_path, home_subdir });
}

pub fn runCliEnvs(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
    pairs: []const EnvPair,
) !CliRun {
    var env = try std.testing.environ.createMap(alloc);
    defer env.deinit();
    // E2E children are outside any agent session unless a test says otherwise.
    // The runner itself may carry these identities when Nulya launched it.
    _ = env.orderedRemove("NULYA_SESSION");
    _ = env.orderedRemove("NULYA_SESSION_ID");
    const home = try defaultHome(alloc, io, ws);
    defer alloc.free(home);
    try env.put("NULYA_HOME", home);
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

/// One CLI invocation that is FED something on stdin — `session step --gate`,
/// whose approval verdicts arrive there. `std.process.run` always
/// hands the child an empty stdin, so this is the same shape with one pipe more.
///
/// The whole answer is written and stdin is closed before stdout is drained:
/// verdict lines are tiny (far under a pipe buffer) and so is everything the
/// step prints, so neither side can block on the other. Closing early is also
/// half the test — after the last written verdict the gate meets EOF, which is
/// exactly the fail-closed path.
pub fn runCliStdin(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
    stdin_bytes: []const u8,
    pairs: []const EnvPair,
) !CliRun {
    var env = try std.testing.environ.createMap(alloc);
    defer env.deinit();
    // E2E children are outside any agent session unless a test says otherwise.
    // The runner itself may carry these identities when Nulya launched it.
    _ = env.orderedRemove("NULYA_SESSION");
    _ = env.orderedRemove("NULYA_SESSION_ID");
    const home = try defaultHome(alloc, io, ws);
    defer alloc.free(home);
    try env.put("NULYA_HOME", home);
    for (pairs) |p| try env.put(p.key, p.value);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = ws },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    if (stdin_bytes.len > 0) try child.stdin.?.writeStreamingAll(io, stdin_bytes);
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const code = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = try alloc.dupe(u8, multi_reader.reader(0).buffered()) };
}

/// One CLI invocation, keeping STDERR instead of stdout: notes and warnings are
/// written there precisely so stdout stays the machine-readable surface. Caller
/// owns the result.
pub fn runCliStderr(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    argv: []const []const u8,
    pairs: []const EnvPair,
) ![]u8 {
    var env = try std.testing.environ.createMap(alloc);
    defer env.deinit();
    // E2E children are outside any agent session unless a test says otherwise.
    // The runner itself may carry these identities when Nulya launched it.
    _ = env.orderedRemove("NULYA_SESSION");
    _ = env.orderedRemove("NULYA_SESSION_ID");
    const home = try defaultHome(alloc, io, ws);
    defer alloc.free(home);
    try env.put("NULYA_HOME", home);
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

/// Read a whole session file's bytes. Caller owns them.
pub fn readSessionFile(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
    defer alloc.free(path);
    return ws.readFileAlloc(io, path, alloc, .unlimited);
}

// ── Compile once, install everywhere ────────────────────────────────────────
//
// Building a COMPILED extension really runs `zig build-exe -O ReleaseSafe`, with
// no `--enable-cache` and a fresh content-addressed store path every time. So it
// costs a full compile (~7s on a developer machine) that no zig cache can
// shorten — and this suite wants a built version of the same handful of
// packages in a dozen fresh workspaces.
//
// Most of those tests are not about building. They need a frozen version to
// EXIST in their store so they can activate it, pin it, run it, resume a header
// that names it. So each distinct package is built exactly once, into a store
// this file owns, and every other test receives a byte-identical copy of the
// version directory. A version is content-addressed, so the copy IS the same
// version and `integrity.validateVersionDir` accepts it unchanged.
//
// The tests where the BUILD is the subject still compile for real: the
// init→build→activate→run closed loop, the self-manufacture proof, the build
// that must fail to compile, and every version-id-stability check.
//
// The cache sits under `.zig-cache/` and deliberately outlives the process: a
// compiled version id includes the compiler identity, so a toolchain change
// invalidates it by construction, and deleting `.zig-cache` is the reset.

/// Cache root, relative to the repo `NULYA_REPO` names.
const prebuilt_rel = ".zig-cache" ++ std.fs.path.sep_str ++ "nulya-e2e-prebuilt";

/// Cache key -> built version id, for this process. Zig's test runner runs a
/// binary's tests one at a time, so no lock is needed here; two `zig build`
/// steps running at once are two processes, and the store's own `<id>/.lock`
/// serializes those.
var prebuilt_memo: std.StringHashMapUnmanaged([]const u8) = .empty;
var prebuilt_arena: ?std.heap.ArenaAllocator = null;

/// The cache's own allocator: never freed, and outlives every test's arena.
fn prebuiltAlloc() std.mem.Allocator {
    if (prebuilt_arena == null) prebuilt_arena = .init(std.heap.page_allocator);
    return prebuilt_arena.?.allocator();
}

/// `NULYA_REPO`, the repo root build.zig hands the test binary. Caller owns it.
fn repoRoot(alloc: std.mem.Allocator) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;
    return alloc.dupe(u8, repo);
}

/// Open `<repo>/.zig-cache/nulya-e2e-prebuilt/<sub>`, creating it when missing.
/// Caller closes it.
fn openPrebuiltDir(alloc: std.mem.Allocator, io: std.Io, sub: []const u8) !std.Io.Dir {
    const repo = try repoRoot(alloc);
    defer alloc.free(repo);
    const path = try std.fs.path.join(alloc, &.{ repo, prebuilt_rel, sub });
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
}

/// A filesystem-safe, collision-resistant name for one package's cache slot.
/// Caller owns it.
fn prebuiltKey(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var hasher: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (parts) |p| {
        hasher.update(p);
        hasher.update(&.{0});
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(alloc, "{x}", .{digest[0..8]});
}

/// Build `draft_rel` (relative to `draft_root`) into the shared cache store,
/// unless this process — or an earlier run — already has that version. Returns
/// the version id, owned by the cache.
fn prebuiltVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    key: []const u8,
    draft_root: std.Io.Dir,
    draft_rel: []const u8,
    zig_exe: []const u8,
) ![]const u8 {
    if (prebuilt_memo.get(key)) |version| return version;

    var store_dir = try openPrebuiltDir(alloc, io, "store");
    defer store_dir.close(io);
    var zig = build_ext.Zig.init(zig_exe);
    defer zig.deinit(alloc);
    var result = try build_ext.buildExtension(alloc, io, draft_root, draft_rel, store_dir, &zig);
    defer result.deinit(alloc);
    if (!result.compile_ok) {
        std.debug.print("prebuilt extension failed to compile:\n{s}\n", .{result.stderr});
        return error.ExtensionBuildFailed;
    }

    const cache = prebuiltAlloc();
    const version = try cache.dupe(u8, result.version);
    try prebuilt_memo.put(cache, try cache.dupe(u8, key), version);
    return version;
}

/// Copy the frozen `<id>/versions/<version>` out of the shared cache into this
/// workspace's store, byte for byte.
///
/// The copy is what makes this cheap AND what makes it honest: a version is
/// content-addressed, so identical bytes are the same version.
fn installVersion(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8, version: []const u8) !void {
    var dest_root = try openStore(alloc, io, ws);
    defer dest_root.close(io);
    try installVersionInto(alloc, io, dest_root, id, version);
}

/// The copy itself, into an already-open store directory.
fn installVersionInto(
    alloc: std.mem.Allocator,
    io: std.Io,
    dest_root: std.Io.Dir,
    id: []const u8,
    version: []const u8,
) !void {
    var cache_store = try openPrebuiltDir(alloc, io, "store");
    defer cache_store.close(io);

    const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", version });
    defer alloc.free(version_rel);
    var src = try cache_store.openDir(io, version_rel, .{ .iterate = true });
    defer src.close(io);

    try dest_root.createDirPath(io, version_rel);
    var dest = try dest_root.openDir(io, version_rel, .{});
    defer dest.close(io);
    try copyTree(alloc, io, src, dest);
}

fn copyTree(alloc: std.mem.Allocator, io: std.Io, src: std.Io.Dir, dest: std.Io.Dir) !void {
    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dest.createDirPath(io, entry.path),
        // Permissions come from the source, so a frozen binary stays executable.
        .file => try src.copyFile(entry.path, dest, entry.path, io, .{ .make_path = true }),
        else => {},
    };
}

/// Copy the repo's own `extensions/<id>` DRAFT (source only — the repo carries no
/// built versions) into a store root under `ws`. For a verb that acts on drafts
/// where they sit (`ext sync`), which needs a real compiled package in the root
/// rather than a path to build.
pub fn copyBundledDraft(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, root_rel: []const u8, id: []const u8) !void {
    const repo = try repoRoot(alloc);
    defer alloc.free(repo);
    const src_path = try std.fs.path.join(alloc, &.{ repo, "extensions", id });
    defer alloc.free(src_path);
    var src = try std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true });
    defer src.close(io);

    const dest_rel = try std.fs.path.join(alloc, &.{ root_rel, id });
    defer alloc.free(dest_rel);
    try ws.createDirPath(io, dest_rel);
    var dest = try ws.openDir(io, dest_rel, .{});
    defer dest.close(io);
    try copyTree(alloc, io, src, dest);
}

/// Assert two directory trees hold the same files with the same bytes — the
/// checkable form of "a version is content-addressed, so a copy of it IS it".
pub fn expectSameTree(alloc: std.mem.Allocator, io: std.Io, a: std.Io.Dir, b: std.Io.Dir) !void {
    try expectTreeSubset(alloc, io, a, b);
    try expectTreeSubset(alloc, io, b, a);
}

fn expectTreeSubset(alloc: std.mem.Allocator, io: std.Io, from: std.Io.Dir, to: std.Io.Dir) !void {
    var walker = try from.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const mine = try from.readFileAlloc(io, entry.path, alloc, .unlimited);
        defer alloc.free(mine);
        const theirs = to.readFileAlloc(io, entry.path, alloc, .unlimited) catch |err| {
            std.debug.print("missing in the other tree: {s} ({s})\n", .{ entry.path, @errorName(err) });
            return error.TestUnexpectedResult;
        };
        defer alloc.free(theirs);
        std.testing.expectEqualSlices(u8, mine, theirs) catch |err| {
            std.debug.print("differs: {s}\n", .{entry.path});
            return err;
        };
    }
}

/// Put a built version of the single-file extension `<id>`/`<tool>` in `ws`'s
/// workspace store, compiling it at most once per repo checkout. Returns the
/// version id; caller frees.
pub fn installPrebuilt(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    zig_exe: []const u8,
    id: []const u8,
    manifest_bytes: []const u8,
    main_src: []const u8,
) ![]u8 {
    const key = try prebuiltKey(alloc, &.{ manifest_bytes, main_src });
    defer alloc.free(key);

    var drafts = try openPrebuiltDir(alloc, io, "drafts");
    defer drafts.close(io);
    try writeSingleFileDraft(alloc, io, drafts, key, id, manifest_bytes, main_src);
    const draft_rel = try std.fs.path.join(alloc, &.{ key, id });
    defer alloc.free(draft_rel);

    const version = try prebuiltVersion(alloc, io, key, drafts, draft_rel, zig_exe);
    try installVersion(alloc, io, ws, id, version);
    return alloc.dupe(u8, version);
}

/// Put a built version of the repo's OWN `extensions/<id>` in this workspace's
/// store, so the `nulya ext build` a test — or a driver script it spawns — is
/// about to run finds it and answers "already built" instead of compiling it
/// again. The CLI path under test is unchanged; only its cost is. Returns the
/// version id; caller frees.
pub fn stageBundled(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8) ![]u8 {
    var dest_root = try openStore(alloc, io, ws);
    defer dest_root.close(io);
    return stageBundledIn(alloc, io, dest_root, id);
}

/// `stageBundled` into an already-open store — for a test that stands up a
/// SECOND machine's store (a far side's `NULYA_HOME`, say). Returns the version
/// id; caller frees.
pub fn stageBundledIn(alloc: std.mem.Allocator, io: std.Io, dest_root: std.Io.Dir, id: []const u8) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;

    const repo = try repoRoot(alloc);
    defer alloc.free(repo);
    var repo_dir = try std.Io.Dir.openDirAbsolute(io, repo, .{});
    defer repo_dir.close(io);

    const key = try std.fmt.allocPrint(alloc, "bundled-{s}", .{id});
    defer alloc.free(key);
    const draft_rel = try std.fs.path.join(alloc, &.{ "extensions", id });
    defer alloc.free(draft_rel);

    const version = try prebuiltVersion(alloc, io, key, repo_dir, draft_rel, zig_exe);
    try installVersionInto(alloc, io, dest_root, id, version);
    return alloc.dupe(u8, version);
}

/// The repo's own copy of a bundled extension, built into this workspace's store.
/// Returns `<id>@<version>` — the ref every caller here runs it by, since a
/// bundled extension is never activated. Caller frees. Skips the test when the
/// harness did not name a repo or a toolchain.
pub fn buildBundled(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe_abs: []const u8, id: []const u8) ![]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;

    // The compile is shared with every other test that wants this package
    // (`stageBundled`); the real `ext build` below then answers "already built" —
    // the same CLI path, without a second seven-second compile.
    alloc.free(try stageBundled(alloc, io, ws, id));

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
