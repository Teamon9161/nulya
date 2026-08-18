//! The self-description entry points: `nulya help`, the `ext api` topics, the
//! kernel prompt's one bootstrap sentence, and the bundled `guide` skill.
//!
//! These four are what a session with nothing but `shell` and `edit` can find
//! out about the harness it is running in, so each is checked as the model
//! would meet it — a real process, its real output.

const std = @import("std");
const support = @import("support.zig");

const environment = support.environment;
const provider = support.provider;
const session = support.session;

const EndTurnModel = support.EndTurnModel;
const extractVersion = support.extractVersion;
const runCli = support.runCli;
const runCliEnv = support.runCliEnv;
const runCliStderr = support.runCliStderr;

/// The absolute path of the binary under test, or a skip.
fn nulyaExe(alloc: std.mem.Allocator, host_env: *const std.process.Environ.Map) ![]u8 {
    const rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    return std.fs.path.resolve(alloc, &.{rel});
}

test "cli help: help / --help / -h print the same usage covering every verb family, exit 0; an unknown command names itself and points at nulya help on stderr, exit 1" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const help = try runCli(alloc, io, ws, &.{ exe_abs, "help" });
    defer alloc.free(help.stdout);
    try std.testing.expectEqual(@as(u8, 0), help.code);

    // Every verb family, and the flags that carry real semantics — a usage that
    // omits them sends the model guessing at exactly the two decisions it has to
    // make (compose a version in, put a tool on the tool face).
    for ([_][]const u8{
        "ext init",     "--script",  "ext build",      "ext run",        "--arg",
        "ext activate", "--user",    "ext trust",      "ext api",        "ext sync",
        "ext seed",     "ext prune", "--dry-run",      "--activate",     "session new",
        "--with",       "--pin",     "--parent",       "session step",   "--max-steps",
        "--effort",     "--stream",  "session events", "session cancel", "outcome",
        "session list", "--image",   "config show",    "skill load",     "src",
        "toolchain",    "help",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, help.stdout, needle) != null) catch |err| {
            std.debug.print("`nulya help` never mentions '{s}'\n", .{needle});
            return err;
        };
    }

    // One screen: this is read by a model that pays for every line of it. The
    // budget moves only when a real capability arrives (`--image`, +2; `ext
    // seed`, +1).
    try std.testing.expect(std.mem.count(u8, help.stdout, "\n") <= 43);

    // The two flag spellings a terminal user reaches for reach the same text.
    for ([_][]const u8{ "--help", "-h" }) |flag| {
        const alt = try runCli(alloc, io, ws, &.{ exe_abs, flag });
        defer alloc.free(alt.stdout);
        try std.testing.expectEqual(@as(u8, 0), alt.code);
        try std.testing.expectEqualStrings(help.stdout, alt.stdout);
    }

    // A bare verb family prints its own block and nothing else — a subset of the
    // full screen, so the two can never describe the same verb differently.
    const ext_only = try runCli(alloc, io, ws, &.{ exe_abs, "ext" });
    defer alloc.free(ext_only.stdout);
    try std.testing.expectEqual(@as(u8, 0), ext_only.code);
    try std.testing.expect(ext_only.stdout.len < help.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, ext_only.stdout) != null);
    try std.testing.expect(std.mem.indexOf(u8, ext_only.stdout, "session new") == null);

    // An unknown command says which one, points at the one verb that explains
    // everything, and keeps stdout clean for whoever was parsing it.
    const bad = try runCli(alloc, io, ws, &.{ exe_abs, "wobble" });
    defer alloc.free(bad.stdout);
    try std.testing.expectEqual(@as(u8, 1), bad.code);
    try std.testing.expectEqualStrings("", bad.stdout);
    const bad_err = try runCliStderr(alloc, io, ws, &.{ exe_abs, "wobble" }, &.{});
    defer alloc.free(bad_err);
    try std.testing.expect(std.mem.indexOf(u8, bad_err, "wobble") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_err, "nulya help") != null);
}

test "cli ext api: permissions and examples carry no document citations and walk script init -> build -> run -> activate -> --with/--pin -> outcome" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const perms = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "api", "permissions" });
    defer alloc.free(perms.stdout);
    try std.testing.expectEqual(@as(u8, 0), perms.code);
    // Today's authority, not a version-stamped note: the same authority as
    // shell, the sanitized child environment, the two variables that ARE passed,
    // the declarative-only manifest field, the enforced clock, the store gate.
    for ([_][]const u8{
        "shell",      "NULYA_EXE", "NULYA_SESSION", "permissions",
        "timeout_ms", "600",       "ext trust",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, perms.stdout, needle) != null) catch |err| {
            std.debug.print("`ext api permissions` never mentions '{s}'\n", .{needle});
            return err;
        };
    }

    const examples = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "api", "examples" });
    defer alloc.free(examples.stdout);
    try std.testing.expectEqual(@as(u8, 0), examples.code);
    for ([_][]const u8{
        "ext init --script", "ext build",       "ext run",  "--arg",
        "ext activate",      "--pin",           "--with",   "--user",
        "ext trust",         "session outcome", "ext sync", "ext prune",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, examples.stdout, needle) != null) catch |err| {
            std.debug.print("`ext api examples` never shows '{s}'\n", .{needle});
            return err;
        };
    }

    // Model-facing text cites no document: the model cannot read one, and an
    // extension carrying this text may be installed anywhere.
    const help = try runCli(alloc, io, ws, &.{ exe_abs, "help" });
    defer alloc.free(help.stdout);
    for ([_][]const u8{ perms.stdout, examples.stdout, help.stdout }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, text, "DESIGN") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "PLAN") == null);
    }
}

test "kernel prompt: a fresh session's first system block names NULYA_EXE, nulya help and nulya src" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];

    // A session composed of nothing at all — no extension, no skill, no mode.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
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

    const blocks = sess.composition.system_prompts.blocks;
    try std.testing.expect(blocks.len >= 1);
    try std.testing.expectEqualStrings("kernel", blocks[0].source);
    // Even with nothing composed, the session knows where this binary is and
    // which two verbs describe it — the bootstrap the rest of the entry layer
    // hangs off.
    for ([_][]const u8{ "NULYA_EXE", "nulya help", "nulya src" }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, blocks[0].bytes, needle) != null) catch |err| {
            std.debug.print("the kernel system block never mentions '{s}'\n", .{needle});
            return err;
        };
    }
}

test "bundled guide: ext build extensions/guide is data kind and needs no zig; session new --with guide lists the skill and contributes no system prompt; skill load returns SKILL.md verbatim; version is stable across rebuilds" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);
    const repo = host_env.get("NULYA_REPO") orelse return error.SkipZigTest;
    const guide_src = try std.fs.path.join(alloc, &.{ repo, "extensions", "guide" });
    defer alloc.free(guide_src);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try ws.realPath(io, &ws_real)];

    // Skills and nothing else: no runtime, so no compiler is consulted and the
    // version id is a pure content hash — the same on every machine, and stable
    // across a rebuild with a different (here, nonexistent) toolchain.
    const built = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", guide_src }, "NULYA_ZIG", "definitely-not-a-compiler");
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    {
        const again = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", guide_src }, "NULYA_ZIG", "another-fake-compiler");
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, "already built") != null);
        const rebuilt = try extractVersion(alloc, again.stdout);
        defer alloc.free(rebuilt);
        try std.testing.expectEqualStrings(version, rebuilt);
    }

    const with_arg = try std.fmt.allocPrint(alloc, "guide@{s}", .{version});
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

    // One catalog line, no native slot, and — the point of shipping it as a
    // skill — not one byte of system prompt beyond the kernel's own block and
    // the catalog itself.
    try std.testing.expectEqual(@as(usize, 1), sess.composition.skills.skills.len);
    const descriptor = sess.composition.skills.skills[0];
    try std.testing.expectEqualStrings("guide", descriptor.name);
    try std.testing.expectEqual(@as(usize, 2), sess.composition.tools.tools.len);
    for (sess.composition.system_prompts.blocks) |b| {
        try std.testing.expect(!std.mem.startsWith(u8, b.source, "ext:"));
    }

    // `skill load <ref>` returns the frozen SKILL.md — the same bytes the repo
    // ships, so a reader of the skill and a reader of the repo see one text.
    const loaded = try runCli(alloc, io, ws, &.{ exe_abs, "skill", "load", descriptor.ref });
    defer alloc.free(loaded.stdout);
    try std.testing.expectEqual(@as(u8, 0), loaded.code);
    const on_disk = blk: {
        var src_dir = try std.Io.Dir.openDirAbsolute(io, guide_src, .{});
        defer src_dir.close(io);
        break :blk try src_dir.readFileAlloc(io, "skills" ++ std.fs.path.sep_str ++ "guide" ++ std.fs.path.sep_str ++ "SKILL.md", alloc, .unlimited);
    };
    defer alloc.free(on_disk);
    try std.testing.expect(std.mem.indexOf(u8, loaded.stdout, on_disk) != null);
}

test "cli config show: both forms project the effective [registry], so today's pins are readable without opening a config file that may hold a key" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A project layer that only narrows (what that layer is allowed to do):
    // it lowers the tool budget and names one pin. Both are decisions a reader
    // has to be able to see before opening a session.
    try ws.createDirPath(io, ".nulya");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/config.toml",
        .data =
        \\[registry]
        \\max_tools = 5
        \\pinned_native_tools = ["ext:date.now/print_date"]
        \\
        ,
    });

    const json = try runCli(alloc, io, ws, &.{ exe_abs, "config", "show", "--json" });
    defer alloc.free(json.stdout);
    try std.testing.expectEqual(@as(u8, 0), json.code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json.stdout, .{});
    defer parsed.deinit();
    const registry = parsed.value.object.get("registry").?.object;
    try std.testing.expectEqual(@as(i64, 5), registry.get("max_tools").?.integer);
    const pins = registry.get("pinned_native_tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), pins.len);
    try std.testing.expectEqualStrings("ext:date.now/print_date", pins[0].string);

    // The text form answers the same question, under the keys a reader writes
    // back — this is the command that replaces reading the config files, one of
    // which may carry an inline api_key.
    const text = try runCli(alloc, io, ws, &.{ exe_abs, "config", "show" });
    defer alloc.free(text.stdout);
    try std.testing.expectEqual(@as(u8, 0), text.code);
    for ([_][]const u8{ "registry:", "max_tools", "pinned_native_tools", "ext:date.now/print_date" }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, text.stdout, needle) != null) catch |err| {
            std.debug.print("`config show` never mentions '{s}'\n", .{needle});
            return err;
        };
    }
}

test "cli ext run/build: missing or malformed JSON arguments and an unbuildable draft are one line on stderr and exit 1, never a Zig stack trace" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A script extension: no toolchain involved, so this test is about the CLI's
    // answers and nothing else.
    const init = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "init", "--script", "my.helper", "do_thing" });
    defer alloc.free(init.stdout);
    try std.testing.expectEqual(@as(u8, 0), init.code);
    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "my.helper";
    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    const ref = try std.fmt.allocPrint(alloc, "my.helper@{s}", .{version});
    defer alloc.free(ref);

    // The three shapes a caller actually arrives with: no JSON at all (the tool
    // name is then read as the arguments), JSON that does not parse, and JSON
    // that parses but is not an object.
    for ([_][]const []const u8{
        &.{ exe_abs, "ext", "run", ref, "do_thing" },
        &.{ exe_abs, "ext", "run", ref, "do_thing", "{bad" },
        &.{ exe_abs, "ext", "run", ref, "do_thing", "[]" },
    }) |argv| {
        const run = try runCli(alloc, io, ws, argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        // stdout is for data; a refusal leaves it empty for whoever was parsing.
        try std.testing.expectEqualStrings("", run.stdout);
        const err_text = try runCliStderr(alloc, io, ws, argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "JSON object") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "--arg") != null);
        // One line, and not a Zig error report: no `error: <Name>` banner and no
        // source-location frames.
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, err_text, "\n"));
        try std.testing.expect(std.mem.indexOf(u8, err_text, "error: InvalidArgumentsJson") == null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, ".zig:") == null);
    }

    // A valid invocation is untouched.
    const ok = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "do_thing", "{}" });
    defer alloc.free(ok.stdout);
    try std.testing.expectEqual(@as(u8, 0), ok.code);
    try std.testing.expect(ok.stdout.len != 0);

    // Same class, same treatment: a build pointed at a directory with no
    // manifest, and one whose manifest the author has just broken.
    const no_manifest = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "build", "no-such-draft" }, &.{});
    defer alloc.free(no_manifest);
    try std.testing.expect(std.mem.indexOf(u8, no_manifest, "extension.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_manifest, ".zig:") == null);

    try ws.createDirPath(io, "broken");
    try ws.writeFile(io, .{ .sub_path = "broken" ++ std.fs.path.sep_str ++ "extension.json", .data = "{not json" });
    const bad_build = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", "broken" });
    defer alloc.free(bad_build.stdout);
    try std.testing.expectEqual(@as(u8, 1), bad_build.code);
    try std.testing.expectEqualStrings("", bad_build.stdout);
    const bad_err = try runCliStderr(alloc, io, ws, &.{ exe_abs, "ext", "build", "broken" }, &.{});
    defer alloc.free(bad_err);
    try std.testing.expect(std.mem.indexOf(u8, bad_err, "InvalidJson") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_err, ".zig:") == null);
}
