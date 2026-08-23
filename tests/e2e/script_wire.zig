//! The wire and per-platform entries (DESIGN §7.1, §7.3).
//!
//! The claim under test is that a script extension is a real one: what `nulya
//! ext init` scaffolds — no compiler, no JSON to parse, no id to echo — goes the
//! whole way to the model's tool face, and what the script printed is what the
//! model reads, byte for byte. Then the two facts that make one version serve
//! every platform: the host picks its own entry, and a version that names none
//! for this host fails LOUDLY (naming the package) instead of running something
//! else or vanishing from the session.
//!
//! There is one wire, and nothing in a manifest selects it — so what a package
//! declares is only where its entry is, and these tests never say a word about
//! how it will be spoken to.

const std = @import("std");
const support = @import("support.zig");

const composition = support.composition;
const environment = support.environment;
const ledger = support.ledger;
const provider = support.provider;
const session = support.session;
const store = support.store;
const tool = support.tool;

const extractVersion = support.extractVersion;
const runCli = support.runCli;
const runCliEnv = support.runCliEnv;
const runCliStderr = support.runCliStderr;

const windows = @import("builtin").os.tag == .windows;

/// A model that calls one named extension tool once with fixed arguments, then
/// ends the turn on the next step. Deliberately not `SelfBuildModel`: that one
/// only ever calls `shell`, and the whole point here is the pinned extension
/// tool's own executor chain.
const OneToolModel = struct {
    tool_name: []const u8,
    args: []const u8,
    step_no: usize = 0,

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "one-tool";
    }
    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "one-tool";
    }
    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{};
    }
    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = alloc;
        _ = request;
        const self: *OneToolModel = @ptrCast(@alignCast(ptr));
        const n = self.step_no;
        self.step_no += 1;
        try sink.emit(.started);
        if (n != 0) {
            try sink.emit(.{ .text_delta = "done." });
            try sink.emit(.{ .done = .end_turn });
            return;
        }
        try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "call", .name = self.tool_name } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = self.args } });
        try sink.emit(.{ .done = .tool_use });
    }
    pub const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

/// Write a draft at `.nulya/extensions/<id>` from an exact manifest plus files.
fn writeDraft(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    id: []const u8,
    manifest_bytes: []const u8,
    files: []const struct { rel: []const u8, bytes: []const u8 },
) !void {
    const ext_dir = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    defer alloc.free(ext_dir);
    const src_dir = try std.fs.path.join(alloc, &.{ ext_dir, "src" });
    defer alloc.free(src_dir);
    try ws.createDirPath(io, src_dir);

    const manifest_rel = try std.fs.path.join(alloc, &.{ ext_dir, "extension.json" });
    defer alloc.free(manifest_rel);
    try ws.writeFile(io, .{ .sub_path = manifest_rel, .data = manifest_bytes });

    for (files) |f| {
        const rel = try std.fs.path.join(alloc, &.{ ext_dir, f.rel });
        defer alloc.free(rel);
        try ws.writeFile(io, .{ .sub_path = rel, .data = f.bytes });
    }
}

fn nulyaExe(alloc: std.mem.Allocator, host_env: *const std.process.Environ.Map) ![]u8 {
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    return std.fs.path.resolve(alloc, &.{exe_rel});
}

test "the wire: `ext init` scaffolds it, `ext run --arg` runs it, and a pinned session reads its stdout byte for byte" {
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

    // The default scaffold IS the script one: no `--script`, no compiler.
    const init = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "init", "greeter", "greet" });
    defer alloc.free(init.stdout);
    try std.testing.expectEqual(@as(u8, 0), init.code);
    try std.testing.expect(std.mem.indexOf(u8, init.stdout, "script extension") != null);

    // Both platforms' entries are written, because one version has to serve both.
    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "greeter";
    try ws.access(io, draft ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "run.sh", .{});
    try ws.access(io, draft ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "run.ps1", .{});
    // And the scaffold declares neither `permissions` nor `wire`: neither key is
    // in the schema any more, and a template is copied far more often than it is
    // read, so it must not propagate the ceremony (DESIGN §9, §7.1).
    const manifest_bytes = try ws.readFileAlloc(io, draft ++ std.fs.path.sep_str ++ "extension.json", alloc, .limited(1 << 16));
    defer alloc.free(manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "permissions") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "wire") == null);

    // A script build needs no toolchain at all.
    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);

    // `--arg name=world` becomes NULYA_ARG_name for the script, and whatever the
    // script printed is the whole of the answer — no envelope, no decode.
    const expected = "hello from greeter, name=world\n";
    {
        const ref = try std.fmt.allocPrint(alloc, "greeter@{s}", .{version});
        defer alloc.free(ref);
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "greet", "--arg", "name=world" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.startsWith(u8, run.stdout, expected));
    }
    // No argument at all: the script sees `{}` on stdin and falls back itself.
    {
        const ref = try std.fmt.allocPrint(alloc, "greeter@{s}", .{version});
        defer alloc.free(ref);
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "greet", "{}" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.startsWith(u8, run.stdout, "hello from greeter, name=world\n") or
            std.mem.startsWith(u8, run.stdout, "hello from greeter, name="));
    }

    {
        var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer ext_root.close(io);
        try store.Store.init(io, ext_root).activate(alloc, "greeter", version);
    }

    // On the model's tool face: a real session, a real step, and the tool result
    // the model reads is the script's stdout, byte for byte.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted", "--pin", "ext:greeter/greet" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(id);

    var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
    defer lenv.deinit();
    var model = OneToolModel{ .tool_name = "greet", .args = "{\"name\":\"world\"}" };
    const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
    defer alloc.free(spath);
    var sess = try session.AgentSession.openDurable(alloc, .{
        .model = .{ .ptr = &model, .vtable = &OneToolModel.vtable },
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .cwd = ws_path },
            .scratch_dir = ".nulya/scratch",
        },
    }, .{ .workspace = ws, .session_path = spath });
    defer sess.deinit();

    // The binding carries the frozen script and this host's interpreter.
    const binding = sess.composition.extension_tool_bindings[0];
    try std.testing.expect(std.mem.indexOf(u8, binding.entry_path, "package") != null);
    try std.testing.expect(binding.interpreter != null);
    try std.testing.expect(std.mem.indexOf(u8, binding.entry_path, if (windows) "run.ps1" else "run.sh") != null);

    _ = try sess.step();

    var found: ?[]const u8 = null;
    for (sess.l.view()) |ev| switch (ev) {
        .tool_results => |batch| for (batch) |r| {
            try std.testing.expect(r.ok);
            found = r.output;
        },
        else => {},
    };
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(expected, found.?);
}

test "a non-zero exit is a failed call carrying the code, stderr and stdout" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    try writeDraft(alloc, io, ws, "boom",
        \\{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "boom",
        \\  "runtime": {
        \\    "entry": { "windows": "src/run.ps1", "default": "src/run.sh" },
        \\    "interpreter": { "windows": "powershell", "default": "sh" }
        \\  },
        \\  "contributes": { "tools": [{ "name": "t", "input": { "type": "object" } }] }
        \\}
    , &.{
        .{ .rel = "src/run.sh", .bytes = "#!/bin/sh\nprintf 'partial work\\n'\nprintf 'went wrong\\n' >&2\nexit 3\n" },
        .{ .rel = "src/run.ps1", .bytes = "[Console]::Out.Write('partial work')\n[Console]::Error.Write('went wrong')\nexit 3\n" },
    });

    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "boom";
    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", draft });
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    const ref = try std.fmt.allocPrint(alloc, "boom@{s}", .{version});
    defer alloc.free(ref);

    const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "t", "{}" });
    defer alloc.free(run.stdout);
    // A failed CALL, not a host fault: `ext run` reports it as the tool's own
    // failure (exit 1) and hands the model-facing text over.
    try std.testing.expectEqual(@as(u8, 1), run.code);
    // `powershell <script>` is the `-Command` form, which collapses any failure
    // to 1 — a property of that interpreter, not of the wire. What the wire
    // guarantees is that the code the host observed is IN the text.
    const expected_code = if (windows) "exit 1" else "exit 3";
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, expected_code) != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "partial work") != null);
}

test "per-platform entry: one version, this host's script — and a version with none for this host fails by name" {
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

    // Two entries, one per platform, distinguishable by what they print — so
    // "the host picked its own" is observable and not inferred from a path.
    try writeDraft(alloc, io, ws, "both",
        \\{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "both",
        \\  "runtime": {
        \\    "entry": { "windows": "src/run.ps1", "default": "src/run.sh" },
        \\    "interpreter": { "windows": "powershell", "default": "sh" }
        \\  },
        \\  "contributes": { "tools": [{ "name": "t", "input": { "type": "object" } }] }
        \\}
    , &.{
        .{ .rel = "src/run.sh", .bytes = "#!/bin/sh\nprintf 'from-sh'\n" },
        .{ .rel = "src/run.ps1", .bytes = "[Console]::Out.Write('from-ps1')\n" },
    });

    const both_draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "both";
    const both_built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", both_draft });
    defer alloc.free(both_built.stdout);
    try std.testing.expectEqual(@as(u8, 0), both_built.code);
    const both_version = try extractVersion(alloc, both_built.stdout);
    defer alloc.free(both_version);
    {
        const ref = try std.fmt.allocPrint(alloc, "both@{s}", .{both_version});
        defer alloc.free(ref);
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "t", "{}" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.startsWith(u8, run.stdout, if (windows) "from-ps1" else "from-sh"));
    }

    // A version that names ONLY the other platform. It builds and activates
    // fine — nothing about it is broken, it simply does not run here — and the
    // declared file has to be in the snapshot even though this host never runs
    // it.
    try writeDraft(alloc, io, ws, "elsewhere",
        \\{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "elsewhere",
        \\  "runtime": {
        \\    "entry": { "linux": "src/run.sh" },
        \\    "interpreter": { "linux": "sh" }
        \\  },
        \\  "contributes": { "tools": [{ "name": "t", "input": { "type": "object" } }] }
        \\}
    , &.{
        .{ .rel = "src/run.sh", .bytes = "#!/bin/sh\nprintf 'from-sh'\n" },
    });

    const away_draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "elsewhere";
    const away_built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", away_draft });
    defer alloc.free(away_built.stdout);
    try std.testing.expectEqual(@as(u8, 0), away_built.code);
    const away_version = try extractVersion(alloc, away_built.stdout);
    defer alloc.free(away_version);
    {
        var ext_root = try ws.openDir(io, ".nulya" ++ std.fs.path.sep_str ++ "extensions", .{});
        defer ext_root.close(io);
        try store.Store.init(io, ext_root).activate(alloc, "elsewhere", away_version);
    }

    // `ext run`: one line naming the package and this host, and exit 1.
    {
        const argv = [_][]const u8{ exe_abs, "ext", "run", "elsewhere", "t", "{}" };
        const run = try runCli(alloc, io, ws, &argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        try std.testing.expectEqualStrings("", run.stdout);
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "elsewhere") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, @tagName(@import("builtin").os.tag)) != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, err_text, "\n"));
    }

    // Pinning it: a HARD failure that names the package. A session quietly
    // missing a tool the operator pinned is not the session that was asked for
    // (the `PinNamesUnknownExtension` rule, for a different reason).
    {
        const argv = [_][]const u8{ exe_abs, "session", "new", "--profile", "scripted", "--pin", "ext:elsewhere/t" };
        const new = try runCli(alloc, io, ws, &argv);
        defer alloc.free(new.stdout);
        try std.testing.expectEqual(@as(u8, 1), new.code);
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "elsewhere") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "EntryUnsupportedOnHost") != null);
    }

    // The same refusal at the library seam, so it is the kernel's answer and not
    // the CLI's politeness.
    try std.testing.expectError(error.EntryUnsupportedOnHost, composition.SessionComposition.init(
        alloc,
        io,
        ws_path,
        &.{".nulya/extensions"},
        .{ .pinned_native_tools = &[_][]const u8{"ext:elsewhere/t"} },
    ));

    // A draft whose declared variant is NOT in the package never becomes a
    // version: the machine that builds it is the only one that can notice.
    try writeDraft(alloc, io, ws, "missing",
        \\{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "missing",
        \\  "runtime": {
        \\    "entry": { "windows": "src/run.ps1", "default": "src/run.sh" },
        \\    "interpreter": { "windows": "powershell", "default": "sh" }
        \\  },
        \\  "contributes": { "tools": [{ "name": "t", "input": { "type": "object" } }] }
        \\}
    , &.{
        .{ .rel = if (windows) "src/run.ps1" else "src/run.sh", .bytes = "#!/bin/sh\nprintf 'here'\n" },
    });
    const missing_draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "missing";
    const missing_built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", missing_draft });
    defer alloc.free(missing_built.stdout);
    try std.testing.expectEqual(@as(u8, 1), missing_built.code);
}

test "a leftover runtime.wire builds and runs, and the build says the key is not read any more" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A package written against the wire that used to exist. It is not broken —
    // there is one wire and it was always going to be spoken this way — so the
    // build proceeds and the tool answers; what the author gets is a sentence
    // saying their word is no longer read.
    try writeDraft(alloc, io, ws, "leftover",
        \\{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "leftover",
        \\  "runtime": { "entry": "src/run.sh", "interpreter": "sh", "wire": "jsonrpc" },
        \\  "contributes": { "tools": [{ "name": "t", "input": { "type": "object" } }] }
        \\}
    , &.{
        .{ .rel = "src/run.sh", .bytes = "#!/bin/sh\ncat >/dev/null\nprintf 'still here'\n" },
    });

    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "leftover";
    const argv = [_][]const u8{ exe_abs, "ext", "build", draft };
    const built = try runCli(alloc, io, ws, &argv);
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);

    // The note names the package and the key, on stderr so stdout stays the
    // version id a caller parses.
    const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
    defer alloc.free(err_text);
    try std.testing.expect(std.mem.indexOf(u8, err_text, "leftover") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_text, "runtime.wire") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_text, ".zig:") == null);

    if (windows) return; // no `sh` to run the entry with
    const ref = try std.fmt.allocPrint(alloc, "leftover@{s}", .{version});
    defer alloc.free(ref);
    const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "t", "{}" });
    defer alloc.free(run.stdout);
    try std.testing.expectEqual(@as(u8, 0), run.code);
    try std.testing.expect(std.mem.startsWith(u8, run.stdout, "still here"));
}

test "`ext init --zig` scaffolds a runtime spoken to the same way: --arg, no json defaults to {}, and no tool is a usage error (C1/C2, ext-review-2 §2)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_abs = try nulyaExe(alloc, &host_env);
    defer alloc.free(exe_abs);
    const zig_exe = host_env.get("NULYA_TEST_ZIG") orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const init = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "init", "--zig", "compiled.greeter", "greet" });
    defer alloc.free(init.stdout);
    try std.testing.expectEqual(@as(u8, 0), init.code);

    const draft = ".nulya" ++ std.fs.path.sep_str ++ "extensions" ++ std.fs.path.sep_str ++ "compiled.greeter";
    // The compiled scaffold says nothing about a wire either: how a process is
    // talked to was never a property of what kind of process it is (DESIGN §7.1).
    const manifest_bytes = try ws.readFileAlloc(io, draft ++ std.fs.path.sep_str ++ "extension.json", alloc, .limited(1 << 16));
    defer alloc.free(manifest_bytes);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "wire") == null);

    const built = try runCliEnv(alloc, io, ws, &.{ exe_abs, "ext", "build", draft }, "NULYA_ZIG", zig_exe);
    defer alloc.free(built.stdout);
    try std.testing.expectEqual(@as(u8, 0), built.code);
    const version = try extractVersion(alloc, built.stdout);
    defer alloc.free(version);
    const ref = try std.fmt.allocPrint(alloc, "compiled.greeter@{s}", .{version});
    defer alloc.free(ref);

    // ① `--arg name=zig` becomes NULYA_ARG_name for the compiled binary too —
    // one wire, whichever kind of runtime is behind it.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "greet", "--arg", "name=zig" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "zig") != null);
    }

    // ② No JSON at all, and no --arg: the tool is named, so the call still
    // runs — its arguments default to `{}` (C2, ext-review-2 §2).
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "greet" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "name=world") != null);
    }

    // ③ No tool at all: usage on stderr, exit 1 — the tool is required, never
    // inferred from the manifest's own (possibly singular) tool list.
    {
        const argv = [_][]const u8{ exe_abs, "ext", "run", ref };
        const run = try runCli(alloc, io, ws, &argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        try std.testing.expectEqualStrings("", run.stdout);
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "usage: nulya ext run") != null);
    }
}
