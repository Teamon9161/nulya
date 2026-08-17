//! Shared fixtures for the e2e tests: the real-`nulya`-process runners, the
//! extension scaffolds, the deterministic models, and the small readers the
//! grouped test files below all reach for.
//!
//! It also re-exports `src/e2e_support.zig` (the build module named `support`),
//! so every test file has ONE import: core modules and test helpers arrive
//! under the same name.

const std = @import("std");
const support = @import("support");

pub const build_ext = support.build_ext;
pub const composition = support.composition;
pub const config = support.config;
pub const environment = support.environment;
pub const integrity = support.integrity;
pub const launch = support.launch;
pub const ledger = support.ledger;
pub const manifest = support.manifest;
pub const outcome = support.outcome;
pub const prompt = support.prompt;
pub const protocol = support.protocol;
pub const provider = support.provider;
pub const session = support.session;
pub const store = support.store;
pub const templates = support.templates;
pub const tool = support.tool;
pub const tool_stats = support.tool_stats;
pub const trust = support.trust;

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
    var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer ext_root.close(io);
    try store.Store.init(io, ext_root).activate(alloc, id, version);
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
    const manifest_bytes = try templates.manifestJson(alloc, id, tool_name);
    defer alloc.free(manifest_bytes);
    try writeSingleFileDraft(alloc, io, ws, ".nulya" ++ std.fs.path.sep_str ++ "extensions", id, manifest_bytes, main_src);
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

/// The generated `greet` extension with its greeting text swapped, so two builds
/// differ by observable output (and therefore by content-addressed version). The
/// source stays a real, compilable single-file extension. Caller owns the bytes.
pub fn greetSource(alloc: std.mem.Allocator, greeting: []const u8) ![]u8 {
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
pub fn callNative(alloc: std.mem.Allocator, io: std.Io, t: tool.Tool, ws_path: []const u8) !tool.RawToolResult {
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    return t.executor.call(alloc, .{
        .args_json = "{}",
        .ctx = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = ws_path },
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
/// or writes the developer's real `~/.nulya`: the user store `--user` writes to,
/// the user config, and the trusted-stores journal `ext build` / `ext trust`
/// append to (DESIGN §9) all live under `NULYA_HOME`. A test that cares about the
/// user layer passes its own `NULYA_HOME` pair, which wins — the pairs are applied
/// after this.
const home_subdir = ".nulya-test-home";

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
// Building a COMPILED extension really runs `zig build-exe -O ReleaseSafe`, and
// DESIGN §7.4 fixes that invocation: no `--enable-cache`, and a fresh
// content-addressed store path every time. So it costs a full compile (~7s on a
// developer machine) that no zig cache can shorten — and this suite wants a
// built version of the same handful of packages in a dozen fresh workspaces.
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
    var result = try build_ext.buildExtension(alloc, io, draft_root, draft_rel, store_dir, zig_exe);
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

/// Copy the frozen `<id>/versions/<version>` out of the shared cache into `ws`'s
/// workspace store, byte for byte, and record that store as trusted.
///
/// The copy is what makes this cheap AND what makes it honest: a version is
/// content-addressed, so identical bytes are the same version. What a copy
/// cannot reproduce is the store's BIRTH — DESIGN §9 trusts a workspace store
/// because a local `ext build` filled it, and nothing local filled this one. So
/// the trust is recorded here explicitly: the harness standing in for the person
/// who would have run `nulya ext trust`, in the same isolated home `runCli` uses.
fn installVersion(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8, version: []const u8) !void {
    var cache_store = try openPrebuiltDir(alloc, io, "store");
    defer cache_store.close(io);

    const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", version });
    defer alloc.free(version_rel);
    var src = try cache_store.openDir(io, version_rel, .{ .iterate = true });
    defer src.close(io);

    const dest_rel = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id, "versions", version });
    defer alloc.free(dest_rel);
    try ws.createDirPath(io, dest_rel);
    var dest = try ws.openDir(io, dest_rel, .{});
    defer dest.close(io);
    try copyTree(alloc, io, src, dest);

    try trustWorkspaceStore(alloc, io, ws);
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

/// Record `ws`'s workspace extension store in the test home's trust journal, the
/// way `nulya ext trust` would (DESIGN §9). Idempotent.
fn trustWorkspaceStore(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir) !void {
    var store_dir = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
    defer store_dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = buf[0..try store_dir.realPath(io, &buf)];

    const home = try defaultHome(alloc, io, ws);
    defer alloc.free(home);
    if (try trust.isTrusted(alloc, io, home, store_path)) return;
    try trust.append(alloc, io, home, store_path);
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

/// Put a built version of the repo's OWN `extensions/<id>` in `ws`'s workspace
/// store, so the `nulya ext build` a test — or a driver script it spawns — is
/// about to run finds it and answers "already built" instead of compiling it
/// again. The CLI path under test is unchanged; only its cost is. Returns the
/// version id; caller frees.
pub fn stageBundled(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, id: []const u8) ![]u8 {
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
    try installVersion(alloc, io, ws, id, version);
    return alloc.dupe(u8, version);
}
