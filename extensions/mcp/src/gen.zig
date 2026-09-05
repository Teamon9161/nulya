//! `mcp_add` and `mcp_list`: turning one MCP server into one extension package,
//! and saying which ones this machine already holds.
//!
//! The generator connects ONCE, at generation time, and writes the tool list it
//! is told into `contributes.tools[]`. That list is then the package's frozen
//! manifest — the kernel never starts a binary to ask what it offers — so a
//! server that grows a tool is a REGENERATION: a new content-addressed version,
//! activated when somebody decides to, never mid-session.
//!
//! Nothing here activates anything, and nothing here writes a secret: the draft
//! carries the shape of the transport, its values stay in the two directories
//! `server.zig` reads.

const std = @import("std");
const client = @import("client.zig");
const embed = @import("embed.zig");
const rpc = @import("rpc.zig");
const spec_mod = @import("server.zig");

/// The bound one generated tool call gets on the model's face.
pub const tool_timeout_ms: u32 = 60_000;

/// The client's own bound, comfortably inside it, so a server that stalls is
/// answered by this package's message rather than by the host's kill.
pub const client_timeout_ms: u32 = tool_timeout_ms - 5_000;

/// How many tools one server may contribute. A manifest is frozen forever and is
/// read on every composition; a server offering more than this is asking for a
/// decision (which half do you want?) that belongs to a person.
const max_tools: usize = 256;

const max_child_output: usize = 4 << 20;

pub const Ctx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// The nulya that spawned this process — the one whose store this package's
    /// version must land in, rather than whichever copy is on PATH.
    exe: []const u8,
};

/// `mcp_add{name, command, args?, env?}` — connect, read the tool face, write a
/// draft, build it.
pub fn add(ctx: Ctx, arguments: std.json.ObjectMap) !rpc.Outcome {
    const alloc = ctx.alloc;
    const name = rpc.trimmedField(arguments, "name");
    if (!isPlainName(name)) {
        return rpc.refuse(
            alloc,
            "mcp_add needs a short name for the server (letters, digits, '-' and '_'; it becomes the package id mcp.<name> and the prefix on every tool)",
            .{},
        );
    }
    if (rpc.trimmedField(arguments, "url").len != 0) {
        return rpc.refuse(
            alloc,
            "mcp_add speaks the stdio transport only: give the command that starts the server, not a url",
            .{},
        );
    }
    const command = rpc.trimmedField(arguments, "command");
    if (command.len == 0) {
        return rpc.refuse(alloc, "mcp_add needs {{\"name\":\"…\",\"command\":\"…\"}} (optional: \"args\", \"env\")", .{});
    }
    const args = try rpc.stringListField(alloc, arguments, "args");
    const needs = try rpc.stringListField(alloc, arguments, "env");

    // Generation runs the server with whatever it needs already in place, so a
    // server that refuses to list its tools without a token can still be added.
    const config = spec_mod.load(alloc, ctx.io, ctx.env, name) catch null;
    var values: std.ArrayList(client.Pair) = .empty;
    for (needs) |key| {
        const value = if (config) |c| c.get(key) else null;
        if (value) |v| try values.append(alloc, .{ .key = key, .value = v });
    }

    var server: client.Server = .{ .alloc = alloc, .io = ctx.io };
    defer server.stop();
    server.start(ctx.env, .{
        .command = command,
        .args = args,
        .env = values.items,
        .timeout_ms = client_timeout_ms,
    }) catch return rpc.refuse(
        alloc,
        "mcp_add could not start '{s}': the command did not run (check it is installed and on PATH)",
        .{command},
    );

    server.initialize() catch |err| return connectionRefusal(alloc, &server, command, "the handshake", err);
    const listed = server.listTools(max_tools) catch |err|
        return connectionRefusal(alloc, &server, command, "tools/list", err);
    if (listed.len == 0) {
        return rpc.refuse(alloc, "'{s}' started and answered, but declares no tools; nothing to generate", .{command});
    }

    const mapped = try mapTools(alloc, name, listed);
    const id = try std.fmt.allocPrint(alloc, "mcp.{s}", .{name});
    const spec: spec_mod.Spec = .{
        .name = name,
        .command = command,
        .args = args,
        .env = needs,
        .tools = try toolMaps(alloc, mapped),
    };

    const draft = try std.fs.path.join(alloc, &.{ ".nulya", "extensions", id });
    try writeDraft(ctx, draft, id, spec, mapped);

    const built = try run(alloc, ctx.io, &.{ ctx.exe, "ext", "build", draft });
    if (built.code != 0) {
        return rpc.refuse(alloc, "the draft is written to {s}, but `nulya ext build` refused it: {s}", .{ draft, detail(built) });
    }
    const version = versionOf(built.stdout) orelse {
        return rpc.refuse(alloc, "`nulya ext build {s}` printed no version: {s}", .{ draft, detail(built) });
    };

    return .{ .text = try report(ctx, id, version, draft, spec, mapped) };
}

/// `mcp_list` — the generated packages this machine holds, and whether each one
/// has what it needs to run.
pub fn list(ctx: Ctx) !rpc.Outcome {
    const alloc = ctx.alloc;
    const listed = try run(alloc, ctx.io, &.{ ctx.exe, "ext", "list" });
    if (listed.code != 0) return rpc.refuse(alloc, "`nulya ext list` failed: {s}", .{detail(listed)});

    var out: std.Io.Writer.Allocating = .init(alloc);
    var found: usize = 0;
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse continue;
        if (!std.mem.startsWith(u8, id, "mcp.")) continue;
        found += 1;
        const version = fields.next() orelse "";
        const layer = fields.next() orelse "";
        try out.writer.print("{s} {s} ({s})\n", .{ id, version, layer });
        try describe(ctx, &out.writer, id);
    }
    if (found == 0) {
        return .{ .text = "no MCP servers on this machine. `nulya ext run mcp mcp_add '{\"name\":\"…\",\"command\":\"…\"}'` generates one." };
    }
    return .{ .text = out.written() };
}

/// The rest of one listing entry, from the draft this workspace holds. A package
/// generated somewhere else has no draft here, and that costs the detail rather
/// than the line: the store holds the version, and this workspace is not the
/// only place it could have come from.
fn describe(ctx: Ctx, w: *std.Io.Writer, id: []const u8) !void {
    const path = try std.fs.path.join(ctx.alloc, &.{ ".nulya", "extensions", id, "src", spec_mod.spec_file });
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.alloc, .limited(1 << 20)) catch return;
    const spec = spec_mod.decode(ctx.alloc, bytes) catch return;

    try w.print("  command  {s}", .{spec.command});
    for (spec.args) |a| try w.print(" {s}", .{a});
    try w.writeByte('\n');
    try w.writeAll("  tools   ");
    for (spec.tools) |t| try w.print(" {s}", .{t.name});
    try w.writeByte('\n');
    if (spec.env.len == 0) return;

    const config = spec_mod.load(ctx.alloc, ctx.io, ctx.env, spec.name) catch null;
    const absent = try spec_mod.missing(ctx.alloc, spec, config);
    try w.writeAll("  needs   ");
    for (spec.env) |key| try w.print(" {s}", .{key});
    if (absent.len == 0) {
        try w.print(" — from {s}\n", .{if (config) |c| c.path else "?"});
    } else {
        try w.writeAll(" — NOT configured; the tools will refuse until it is\n");
    }
}

// ── generation ──────────────────────────────────────────────────────────────

pub const Mapped = struct {
    exposed: spec_mod.ToolMap,
    description: []const u8,
    input_schema: []const u8,
};

/// Every server tool under a name a session can hold: `<server>_<tool>`.
///
/// The prefix is not politeness. Two servers that both declare `search` would
/// otherwise collide, and a collision is refused at composition freeze — the
/// whole session, by name. Prefixing makes that a thing that cannot happen by
/// accident, and leaves the refusal for the case where somebody really did ask
/// for two of the same.
fn mapTools(alloc: std.mem.Allocator, name: []const u8, listed: []const client.Tool) ![]Mapped {
    var out = try alloc.alloc(Mapped, listed.len);
    for (listed, 0..) |t, i| {
        const exposed = try exposedName(alloc, name, t.name);
        for (out[0..i]) |seen| {
            if (std.mem.eql(u8, seen.exposed.name, exposed)) return error.DuplicateToolName;
        }
        out[i] = .{
            .exposed = .{ .name = exposed, .tool = t.name },
            .description = if (t.description.len != 0)
                t.description
            else
                try std.fmt.allocPrint(alloc, "The '{s}' tool on the {s} MCP server.", .{ t.name, name }),
            .input_schema = t.input_schema,
        };
    }
    return out;
}

/// The half of the mapping the frozen spec keeps: what the runtime needs to turn
/// the tool it was called as back into the tool the server knows.
fn toolMaps(alloc: std.mem.Allocator, mapped: []const Mapped) ![]spec_mod.ToolMap {
    var out = try alloc.alloc(spec_mod.ToolMap, mapped.len);
    for (mapped, 0..) |m, i| out[i] = m.exposed;
    return out;
}

/// A tool name a manifest accepts. An MCP name may hold characters an extension
/// tool name may not, so anything outside the alphabet becomes `_` — which is
/// why the mapping back to the server's own name is written down rather than
/// derived.
fn exposedName(alloc: std.mem.Allocator, prefix: []const u8, tool: []const u8) ![]u8 {
    const joined = try std.fmt.allocPrint(alloc, "{s}_{s}", .{ prefix, tool });
    for (joined) |*c| {
        const ok = std.ascii.isAlphanumeric(c.*) or c.* == '.' or c.* == '_' or c.* == '-';
        if (!ok) c.* = '_';
    }
    return joined;
}

fn isPlainName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The draft: the manifest, this program's own source, and the server's shape.
///
/// `src/` is cleared first and the package directory is not: a `current` pointer
/// beside it belongs to whoever activated the last version, and regenerating is
/// not the moment to decide what that pointer should say.
fn writeDraft(
    ctx: Ctx,
    draft: []const u8,
    id: []const u8,
    spec: spec_mod.Spec,
    mapped: []const Mapped,
) !void {
    const cwd = std.Io.Dir.cwd();
    const src = try std.fs.path.join(ctx.alloc, &.{ draft, "src" });
    cwd.deleteTree(ctx.io, src) catch {};
    try cwd.createDirPath(ctx.io, src);

    const manifest_path = try std.fs.path.join(ctx.alloc, &.{ draft, "extension.json" });
    try cwd.writeFile(ctx.io, .{ .sub_path = manifest_path, .data = try manifestJson(ctx.alloc, id, mapped) });

    for (embed.files) |file| {
        const path = try std.fs.path.join(ctx.alloc, &.{ src, file.name });
        try cwd.writeFile(ctx.io, .{ .sub_path = path, .data = file.bytes });
    }
    const spec_path = try std.fs.path.join(ctx.alloc, &.{ src, spec_mod.spec_file });
    try cwd.writeFile(ctx.io, .{ .sub_path = spec_path, .data = try spec_mod.encode(ctx.alloc, spec) });
}

/// The generated manifest. Every tool is `manual` and NOT recommended: a server
/// with forty tools must not become forty names on a model's face because
/// somebody installed it — the member line a person writes is the only thing
/// that selects any of them.
fn manifestJson(alloc: std.mem.Allocator, id: []const u8, mapped: []const Mapped) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var j: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };

    try j.beginObject();
    try j.objectField("schema");
    try j.write("nulya.extension/v2");
    try j.objectField("id");
    try j.write(id);
    try j.objectField("runtime");
    try j.beginObject();
    try j.objectField("entry");
    try j.write("bin/mcp");
    try j.endObject();
    try j.objectField("contributes");
    try j.beginObject();
    try j.objectField("tools");
    try j.beginArray();
    for (mapped) |m| {
        try j.beginObject();
        try j.objectField("name");
        try j.write(m.exposed.name);
        try j.objectField("surface");
        try j.write("manual");
        try j.objectField("recommended");
        try j.write(false);
        try j.objectField("timeout_ms");
        try j.write(tool_timeout_ms);
        try j.objectField("description");
        try j.write(m.description);
        try j.objectField("input");
        // The server's own schema, spliced in rather than re-modelled: this
        // package has no opinion about what its tools take.
        try j.beginWriteRaw();
        try out.writer.writeAll(m.input_schema);
        j.endWriteRaw();
        try j.endObject();
    }
    try j.endArray();
    try j.endObject();
    try j.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

/// What `mcp_add` answers with: what exists now, and the two decisions it did
/// not make (which version is current, and which tools a session carries).
fn report(
    ctx: Ctx,
    id: []const u8,
    version: []const u8,
    draft: []const u8,
    spec: spec_mod.Spec,
    mapped: []const Mapped,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("{s}@{s} — {d} tool(s) from '{s}", .{ id, version, mapped.len, spec.command });
    for (spec.args) |a| try w.print(" {s}", .{a});
    try w.print("', frozen from its tools/list. Draft in {s}.\n", .{draft});
    try w.writeAll("tools:");
    for (mapped) |m| try w.print(" {s}", .{m.exposed.name});
    try w.writeAll("\n");
    try w.print(
        "It is built, not activated, and in no session. Two decisions are still yours:\n" ++
            "  nulya ext activate {s} {s}\n" ++
            "  then name the tools you want: --with {s}:<tool>,<tool> (or the same line in [extensions] with)\n" ++
            "Every tool is `manual` and not recommended, so nothing reaches a model's face until that line names it.\n",
        .{ id, version, id },
    );
    if (spec.env.len != 0) {
        try w.writeAll("It needs");
        for (spec.env) |key| try w.print(" {s}", .{key});
        try w.writeAll(" at call time. Values never enter the package; write them into the first of:\n");
        for (try spec_mod.candidates(ctx.alloc, ctx.env, spec.name)) |path| try w.print("  {s}\n", .{path});
        try w.writeAll("as {\"env\": {");
        for (spec.env, 0..) |key, i| try w.print("{s}\"{s}\": \"…\"", .{ if (i == 0) "" else ", ", key });
        try w.writeAll("}}.\n");
    }
    try w.print("Regenerating after the server changes writes a NEW version; `nulya ext activate {s} <version>` is the only switch, and the old one stays.", .{id});
    return out.toOwnedSlice();
}

fn connectionRefusal(
    alloc: std.mem.Allocator,
    server: *client.Server,
    command: []const u8,
    during: []const u8,
    err: client.Error,
) !rpc.Outcome {
    const said = if (err == error.ServerError) server.fault else server.stderrTail(600);
    return rpc.refuse(
        alloc,
        "'{s}' did not complete {s} ({s}){s}{s}",
        .{ command, during, @errorName(err), if (said.len == 0) "" else ": ", said },
    );
}

// ── calling the kernel ──────────────────────────────────────────────────────

pub const Run = struct { code: u8, stdout: []u8, stderr: []u8 };

/// One `nulya <args…>`, in this process's working directory — which is the
/// workspace, because that is where the host spawns an extension.
pub fn run(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Run {
    const result = try std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_child_output),
        .stderr_limit = .limited(max_child_output),
    });
    return .{
        .code = switch (result.term) {
            .exited => |c| c,
            else => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

const max_detail_bytes: usize = 400;

fn detail(r: Run) []const u8 {
    const err = std.mem.trim(u8, r.stderr, " \t\r\n");
    const said = if (err.len != 0) err else std.mem.trim(u8, r.stdout, " \t\r\n");
    if (said.len == 0) return "no output";
    return said[said.len -| max_detail_bytes..];
}

/// The shortest run of hex a `v-` must carry to be the version and not part of
/// the path printed beside it (`.nulya/extensions/mcp.dev-tools` holds a `v-`).
const version_hex_min: usize = 16;

/// The `v-<hex>` `ext build` printed, or null when it printed none.
fn versionOf(text: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "v-")) |at| {
        var end = at + 2;
        while (end < text.len and std.ascii.isHex(text[end])) end += 1;
        if (end - (at + 2) >= version_hex_min) return text[at..end];
        from = at + 2;
    }
    return null;
}

test "an exposed name carries the server prefix and only characters a manifest takes" {
    const alloc = std.testing.allocator;
    const plain = try exposedName(alloc, "github", "create_issue");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("github_create_issue", plain);

    const awkward = try exposedName(alloc, "fs", "read/file");
    defer alloc.free(awkward);
    try std.testing.expectEqualStrings("fs_read_file", awkward);
}

test "two server tools that sanitize to one name are refused rather than silently merged" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    try std.testing.expectError(error.DuplicateToolName, mapTools(arena.allocator(), "s", &.{
        .{ .name = "a/b" },
        .{ .name = "a:b" },
    }));
}

test "the generated manifest keeps the server's schema and puts every tool behind a name" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const mapped = try mapTools(a, "fake", &.{
        .{ .name = "echo", .description = "Say it back.", .input_schema = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}" },
    });
    const bytes = try manifestJson(a, "mcp.fake", mapped);

    // The schema arrived whole, and the two keys that keep a fifty-tool server
    // off the model's face are on the tool.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"properties\": {") != null or
        std.mem.indexOf(u8, bytes, "\"properties\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"fake_echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"surface\": \"manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"recommended\": false") != null);

    // …and it is a manifest, not just text that looks like one.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    try std.testing.expect(parsed == .object);
}

test "a version is read out of what ext build prints, past a path that also holds a v-" {
    try std.testing.expectEqualStrings(
        "v-0f1e2d3c4b5a69788796",
        versionOf(".nulya/extensions/mcp.dev-tools: v-0f1e2d3c4b5a69788796 (built, in store)\n").?,
    );
    try std.testing.expect(versionOf("build FAILED\n") == null);
}
