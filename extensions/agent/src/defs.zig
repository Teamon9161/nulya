//! An agent definition, and what it becomes.
//!
//! A definition is a markdown file with front matter: `.nulya/agents/<name>.md`
//! in the workspace, or `<NULYA_HOME | ~/.nulya>/agents/<name>.md` on this
//! machine. Its front matter is a set of `session new` arguments and its body is
//! a system prompt — PLAN §3.2's "an agent is a `session new` with a particular
//! set of arguments", made literal.
//!
//! **Why materialising lives here and not in the front end.** A system prompt
//! reaches a session exactly one way (physics #3/#4): contributed by a frozen
//! extension version the session composed. So a definition has to become a data
//! extension, and that rendering — the manifest bytes, the prompt file, which
//! store root — decides the VERSION ID, which is the hash of exactly those
//! bytes. Two implementations of it would be two versions of the same persona
//! that happen to disagree about a trailing newline. There is one writer, and it
//! is this tool; the TUI reads definitions (to list them) and asks this to build.
//!
//! The front matter dialect is deliberately small — `key: value`, `key: [a, b]`,
//! and the `- item` block form. Every field below is a word, a flag, a number or
//! a list of tool ids; the day one needs nesting is the day this reads a real
//! YAML, and a dependency plus its failure modes is a poor trade until then.

const std = @import("std");
const builtin = @import("builtin.zig");

/// Which layer a definition came from, in search order. Workspace wins on a
/// name collision — a checkout says what its own work needs, the machine's copy
/// is the fallback, and this package's own `builtin` personas are the floor
/// nobody had to install. The loser is never dropped, only marked `shadowed`:
/// the store roots' rule (DESIGN §7.2), for the store roots' reason.
pub const Layer = enum { workspace, user, builtin };

/// Where a materialised version lands. A workspace definition belongs to this
/// checkout; a user definition and a builtin persona belong to the machine.
pub fn userStore(layer: Layer) bool {
    return layer != .workspace;
}

pub const Def = struct {
    name: []const u8,
    description: []const u8 = "",
    /// A hard ceiling on the tool face, enforced at the gate by whoever runs the
    /// delegation (`runner.zig`). A claim, not a sandbox (DESIGN §9).
    readonly: bool = false,
    /// `--profile`; empty means "inherit whatever asked for the delegation".
    profile: []const u8 = "",
    /// `--model` within that profile; empty means the profile's default.
    model: []const u8 = "",
    /// `ext:<id>/<tool>` ids for `--pin`, on top of the session's usual face.
    pins: []const []const u8 = &.{},
    /// The agents this one may delegate to. **Empty is a leaf** — the default,
    /// and what every persona but `orchestrator` is: a delegated session carries
    /// this package only when its definition names somebody to pass work to, so
    /// "can it delegate" is one decision written in one place (DESIGN §7.8).
    agents: []const []const u8 = &.{},
    /// How many turns a caller may send into one delegated session — the
    /// follow-ups `agent{session, task}` adds on top of the first. 0 = no limit;
    /// each turn is still bounded by `max_steps`, and the caller is still the
    /// one deciding whether another one is worth it.
    max_exchanges: u32 = 0,
    /// `session step --max-steps`; 0 means the kernel's own budget.
    max_steps: u32 = 0,
    /// The markdown body: this agent's system prompt, verbatim.
    prompt: []const u8,
    layer: Layer,
    /// The file it was read from, or `builtin:<name>`, for messages.
    source: []const u8,
};

pub const ParseError = error{ NoFrontMatter, NoBody, BadName, OutOfMemory };

/// One path component and the `/agent <name>` word: a name becomes `<name>.md`,
/// so a separator or a `..` would be a lookup outside the two directories this
/// tool may read.
pub fn isPlainName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or (c == '.' and i != 0);
        if (!ok) return false;
    }
    return true;
}

/// A session id, as the kernel mints them (`s-<digits>-<hex>`); checked because
/// it becomes a path, and because "that is not a session id" is a better answer
/// than a file that is not there.
pub fn isPlainSessionId(id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, "s-") or id.len > 128) return false;
    for (id["s-".len..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return id.len > "s-".len;
}

/// A pin has one shape, and a pin the kernel cannot resolve does not cost a
/// tool — it refuses the whole `session new` (`PinToolNotDeclared`). So a
/// malformed one is dropped here rather than carried to a message about
/// something else entirely.
pub fn isPin(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "ext:")) return false;
    const rest = text["ext:".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const id = rest[0..slash];
    const tool = rest[slash + 1 ..];
    if (id.len == 0 or tool.len == 0) return false;
    for (rest, 0..) |c, i| {
        if (i == slash) continue;
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

fn unquote(value: []const u8) []const u8 {
    const t = std.mem.trim(u8, value, " \t\r");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// Parse one definition file. Warnings are collected rather than fatal: losing a
/// whole persona over one bad line is the expensive answer, and the two errors
/// that ARE fatal are the two ways to not be a definition at all.
pub fn parse(
    alloc: std.mem.Allocator,
    text: []const u8,
    stem: []const u8,
    layer: Layer,
    source: []const u8,
    warnings: *std.ArrayList([]const u8),
) ParseError!Def {
    // A BOM and CRLF both arrive from real editors; neither is a syntax error.
    const no_bom = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
    const cleaned = try std.mem.replaceOwned(u8, alloc, no_bom, "\r\n", "\n");
    if (!std.mem.startsWith(u8, cleaned, "---\n")) return error.NoFrontMatter;
    const close = std.mem.indexOfPos(u8, cleaned, 3, "\n---") orelse return error.NoFrontMatter;
    const after = std.mem.indexOfScalarPos(u8, cleaned, close + 1, '\n') orelse cleaned.len;
    const front = cleaned[4 .. close + 1];
    const body = std.mem.trim(u8, if (after >= cleaned.len) "" else cleaned[after + 1 ..], " \t\r\n");
    if (body.len == 0) return error.NoBody;

    var def: Def = .{ .name = stem, .prompt = body, .layer = layer, .source = source };
    var pins: std.ArrayList([]const u8) = .empty;
    var agents: std.ArrayList([]const u8) = .empty;
    // The key a bare `- item` list belongs to, or empty between lists.
    var list_key: []const u8 = "";

    var lines = std.mem.splitScalar(u8, front, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const lead = std.mem.trimStart(u8, line, " \t");
        if (lead.len == 0 or lead[0] == '#') continue;
        if (std.mem.startsWith(u8, lead, "- ")) {
            if (list_key.len != 0) try addItem(alloc, list_key, unquote(lead[2..]), &pins, &agents, warnings, source);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, lead, ':') orelse continue;
        const key = std.mem.trim(u8, lead[0..colon], " \t");
        const value = std.mem.trim(u8, lead[colon + 1 ..], " \t");
        list_key = "";

        if (std.mem.eql(u8, key, "pins") or std.mem.eql(u8, key, "agents")) {
            list_key = key;
            if (value.len == 0) continue;
            if (!(value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']')) {
                try warn(alloc, warnings, source, try std.fmt.allocPrint(alloc, "{s} must be a list, ignored", .{key}));
                continue;
            }
            var items = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
            while (items.next()) |item| {
                const one = unquote(item);
                if (one.len == 0) continue;
                try addItem(alloc, key, one, &pins, &agents, warnings, source);
            }
            continue;
        }
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "name")) {
            def.name = unquote(value);
        } else if (std.mem.eql(u8, key, "description")) {
            def.description = unquote(value);
        } else if (std.mem.eql(u8, key, "readonly")) {
            const v = unquote(value);
            if (std.mem.eql(u8, v, "true")) def.readonly = true else if (!std.mem.eql(u8, v, "false")) {
                try warn(alloc, warnings, source, "readonly must be true or false, read as false");
            }
        } else if (std.mem.eql(u8, key, "model")) {
            // `profile` or `profile/model-id`: the kernel's two flags, which mean
            // different things (DESIGN §9.5). Naming only the profile is legal.
            const v = unquote(value);
            if (std.mem.indexOfScalar(u8, v, '/')) |at| {
                def.profile = std.mem.trim(u8, v[0..at], " \t");
                def.model = std.mem.trim(u8, v[at + 1 ..], " \t");
                if (def.profile.len == 0 or def.model.len == 0) {
                    def.profile = "";
                    def.model = "";
                    try warn(alloc, warnings, source, "model must be <profile> or <profile>/<model-id>, ignored");
                }
            } else def.profile = v;
        } else if (std.mem.eql(u8, key, "max_steps")) {
            def.max_steps = std.fmt.parseInt(u32, unquote(value), 10) catch 0;
            if (def.max_steps == 0) try warn(alloc, warnings, source, "max_steps must be a positive whole number, ignored");
        } else if (std.mem.eql(u8, key, "max_exchanges")) {
            def.max_exchanges = std.fmt.parseInt(u32, unquote(value), 10) catch 0;
            if (def.max_exchanges == 0) try warn(alloc, warnings, source, "max_exchanges must be a positive whole number, ignored");
        }
    }

    if (!isPlainName(def.name)) return error.BadName;
    def.pins = pins.items;
    def.agents = agents.items;
    return def;
}

/// One entry of either list, validated by its own rule. A malformed one is
/// dropped and named: a bad pin refuses the whole `session new`, and a bad agent
/// name is a delegation that could only ever fail.
fn addItem(
    alloc: std.mem.Allocator,
    key: []const u8,
    item: []const u8,
    pins: *std.ArrayList([]const u8),
    agents: *std.ArrayList([]const u8),
    warnings: *std.ArrayList([]const u8),
    source: []const u8,
) !void {
    if (item.len == 0) return;
    if (std.mem.eql(u8, key, "pins")) {
        if (isPin(item)) try pins.append(alloc, item) else try warnPin(alloc, warnings, source, item);
        return;
    }
    if (isPlainName(item)) try agents.append(alloc, item) else {
        try warnings.append(alloc, try std.fmt.allocPrint(alloc, "{s}: '{s}' is not an agent name, dropped", .{ source, item }));
    }
}

fn warn(alloc: std.mem.Allocator, into: *std.ArrayList([]const u8), source: []const u8, what: []const u8) !void {
    try into.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {s}", .{ source, what }));
}

fn warnPin(alloc: std.mem.Allocator, into: *std.ArrayList([]const u8), source: []const u8, item: []const u8) !void {
    try into.append(alloc, try std.fmt.allocPrint(alloc, "{s}: '{s}' is not a pin (want ext:<id>/<tool>), dropped", .{ source, item }));
}

/// Where definitions live, relative to the workspace (this process's cwd).
pub const project_dir = ".nulya/agents";

/// This machine's directory: `$NULYA_HOME/agents`, else `<home>/.nulya/agents`
/// — the kernel's own rule for the user config dir. Null when there is no home,
/// which is a fact about the machine and not a failure.
pub fn userDir(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("NULYA_HOME")) |home| {
        if (home.len > 0) return try std.fs.path.join(alloc, &.{ home, "agents" });
    }
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(alloc, &.{ home, ".nulya", "agents" });
}

/// One definition, as discovery found it.
pub const Entry = struct {
    def: Def,
    /// An earlier layer already defines this name, so this copy never runs.
    shadowed: bool = false,
    /// Everything wrong with the file that did not make it unusable.
    warnings: []const []const u8 = &.{},
};

/// Every definition all three layers hold, in search order, duplicates marked.
///
/// Warn-and-skip, never fatal (tcode's discipline): the two ways to be skipped
/// are the two ways to not be a definition — no front matter, no body — and a
/// field that cannot be read is a warning and a default, because losing a whole
/// persona over one bad line is the expensive answer.
pub fn discover(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    try readDir(alloc, io, project_dir, .workspace, &out);
    if (try userDir(alloc, env)) |dir| try readDir(alloc, io, dir, .user, &out);
    for (builtin.all) |b| {
        var warnings: std.ArrayList([]const u8) = .empty;
        const source = try std.fmt.allocPrint(alloc, "builtin:{s}", .{b.name});
        // A builtin that does not parse is this package's own bug, not a
        // person's, so it is dropped rather than reported at them.
        const def = parse(alloc, b.text, b.name, .builtin, source, &warnings) catch continue;
        try append(alloc, &out, .{ .def = def, .warnings = warnings.items });
    }
    return out.items;
}

fn append(alloc: std.mem.Allocator, out: *std.ArrayList(Entry), entry: Entry) !void {
    var marked = entry;
    for (out.items) |seen| {
        if (!seen.shadowed and std.mem.eql(u8, seen.def.name, entry.def.name)) marked.shadowed = true;
    }
    try out.append(alloc, marked);
}

/// One layer's `*.md`, flat and sorted.
///
/// Flat and only `.md` on purpose: an `agents/` directory is a list of personas,
/// not a tree to organise. A layout that needs one can say so later; guessing
/// now would make the first thing anybody tries — drop a file in — the odd case.
fn readDir(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    layer: Layer,
    out: *std.ArrayList(Entry),
) !void {
    var found: std.ArrayList([]const u8) = .empty;
    var dir = (if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true })
    else
        std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true })) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |item| {
        if (item.kind == .directory) continue;
        if (!std.mem.endsWith(u8, item.name, ".md")) continue;
        if (item.name.len == ".md".len) continue;
        try found.append(alloc, try alloc.dupe(u8, item.name));
    }
    // Sorted, so two machines with the same files list them the same way.
    std.mem.sort([]const u8, found.items, {}, lessThan);

    for (found.items) |file| {
        const full = try std.fs.path.join(alloc, &.{ path, file });
        const text = std.Io.Dir.cwd().readFileAlloc(io, full, alloc, .limited(1 << 20)) catch continue;
        var warnings: std.ArrayList([]const u8) = .empty;
        const def = parse(alloc, text, file[0 .. file.len - ".md".len], layer, full, &warnings) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // The two ways to not be a definition, and a name nobody can use.
            error.NoFrontMatter, error.NoBody, error.BadName => continue,
        };
        try append(alloc, out, .{ .def = def, .warnings = warnings.items });
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The definition that WINS for `name` — the first layer that has one, which is
/// the only one that is not `shadowed`. Null when no layer does.
pub fn find(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    name: []const u8,
) !?Entry {
    for (try discover(alloc, io, env)) |entry| {
        if (!entry.shadowed and std.mem.eql(u8, entry.def.name, name)) return entry;
    }
    return null;
}

/// How many names an "unknown agent" message lists before it stops being help.
const max_listed_names: usize = 64;

/// The names a caller may use, in search order — the winners of all three
/// layers. This list only ever appears inside a message already telling the
/// model its name was wrong, so a shadowed copy has nothing to add to it.
pub fn names(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try discover(alloc, io, env)) |entry| {
        if (entry.shadowed) continue;
        if (out.items.len >= max_listed_names) break;
        try out.append(alloc, entry.def.name);
    }
    return out.items;
}

/// The extension id a definition materialises into.
pub fn extensionId(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "agent-{s}", .{name});
}

/// Where a definition is staged before `ext build` freezes it.
///
/// Under `.nulya/scratch/`, where this repository already stages things for the
/// CLI, and deliberately NOT under a store root: a draft in
/// `.nulya/extensions/<id>/` would be picked up by the next `ext sync` and built
/// as if somebody maintained it — and nobody does. It is a rendering of a file
/// that IS maintained, one directory away.
pub fn draftPath(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, ".nulya/scratch/agents/{s}", .{id});
}

/// Render the definition into a draft directory. Written fresh every time: a
/// stale `prompt.md` from a definition that has since been edited would be
/// frozen into a version claiming to be the new one.
///
/// The manifest bytes are what the version id hashes, so they are produced in
/// one place with one spelling — the reason this is not also implemented on the
/// front end.
pub fn writeDraft(alloc: std.mem.Allocator, io: std.Io, def: Def, id: []const u8, draft: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, draft) catch {};
    try cwd.createDirPath(io, draft);

    var manifest: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &manifest.writer, .options = .{ .whitespace = .indent_2 } };
    try jw.beginObject();
    try jw.objectField("schema");
    try jw.write("nulya.extension/v2");
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("contributes");
    try jw.beginObject();
    try jw.objectField("system_prompts");
    try jw.beginArray();
    try jw.write("prompt.md");
    try jw.endArray();
    try jw.endObject();
    // No runtime and no permissions: it contributes TEXT. What the agent may do
    // is its pins and the gate, never this file.
    try jw.objectField("permissions");
    try jw.beginObject();
    inline for (.{ "fs", "network", "process" }) |field| {
        try jw.objectField(field);
        try jw.beginArray();
        try jw.endArray();
    }
    try jw.endObject();
    try jw.endObject();
    try manifest.writer.writeByte('\n');

    const manifest_path = try std.fs.path.join(alloc, &.{ draft, "extension.json" });
    try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = manifest.writer.buffered() });

    const prompt_path = try std.fs.path.join(alloc, &.{ draft, "prompt.md" });
    const prompt = try std.fmt.allocPrint(alloc, "{s}\n", .{def.prompt});
    try cwd.writeFile(io, .{ .sub_path = prompt_path, .data = prompt });
}

/// The persona a session is wearing, from its frozen header: the `agent-<name>`
/// member `session new --with` put there (DESIGN §3.4). Null for a session that
/// is not a delegation — a top-level conversation, where nothing is restricted.
///
/// The header is the authority on purpose: it is frozen, so it says what this
/// session actually composed with rather than what a definition file says today.
pub fn wornPersona(alloc: std.mem.Allocator, io: std.Io, session_id: []const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{session_id});
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var buf: [16 << 10]u8 = undefined;
    var reader = file.reader(io, &buf);
    const line = (reader.interface.takeDelimiter('\n') catch return null) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return null;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const composition = switch (root.get("composition") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const active = switch (composition.get("active") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (active.items) |entry| {
        const member = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (member.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.startsWith(u8, id, "agent-")) return try alloc.dupe(u8, id["agent-".len..]);
    }
    return null;
}

// ── tests ───────────────────────────────────────────────────────────────────

fn parseOne(alloc: std.mem.Allocator, text: []const u8, warnings: *std.ArrayList([]const u8)) !Def {
    return parse(alloc, text, "stem", .workspace, "x.md", warnings);
}

test "front matter reads into the arguments of one session new" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;

    const def = try parseOne(a,
        \\---
        \\# a comment
        \\name: explore
        \\description: "Read-only, and thorough"
        \\readonly: true
        \\model: deepseek/deepseek-v4-pro
        \\pins: [ext:std/read, ext:std/grep]
        \\max_steps: 12
        \\---
        \\You only read.
        \\
    , &warnings);
    try std.testing.expectEqualStrings("explore", def.name);
    // The quotes come off and the comma inside them is not a separator.
    try std.testing.expectEqualStrings("Read-only, and thorough", def.description);
    try std.testing.expect(def.readonly);
    try std.testing.expectEqualStrings("deepseek", def.profile);
    try std.testing.expectEqualStrings("deepseek-v4-pro", def.model);
    try std.testing.expectEqual(@as(u32, 12), def.max_steps);
    try std.testing.expectEqual(@as(usize, 2), def.pins.len);
    try std.testing.expectEqualStrings("ext:std/read", def.pins[0]);
    // The body is the system prompt, verbatim and nothing else.
    try std.testing.expectEqualStrings("You only read.", def.prompt);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "the block list form, the stem as a default name, and CRLF" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;

    const def = try parseOne(a, "---\r\npins:\r\n  - ext:std/read\r\n  - ext:std/glob\r\n---\r\njust a persona\r\n", &warnings);
    try std.testing.expectEqualStrings("stem", def.name);
    try std.testing.expectEqual(@as(usize, 2), def.pins.len);
    try std.testing.expectEqualStrings("ext:std/glob", def.pins[1]);
    try std.testing.expect(!def.readonly);
    try std.testing.expectEqual(@as(u32, 0), def.max_steps);
}

test "a file that is not a definition is refused; a bad field is a warning and a default" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;

    // The two ways to not be a definition at all.
    try std.testing.expectError(error.NoFrontMatter, parseOne(a, "just some notes\n", &warnings));
    try std.testing.expectError(error.NoBody, parseOne(a, "---\nname: empty\n---\n\n", &warnings));
    try std.testing.expectError(error.BadName, parseOne(a, "---\nname: ../etc/passwd\n---\nbody\n", &warnings));

    // Everything else survives with a default and a sentence: losing a whole
    // persona over one bad line is the expensive answer.
    const def = try parseOne(a,
        \\---
        \\readonly: yes
        \\model: /nope
        \\pins: [read, ext:std/read]
        \\max_steps: soon
        \\---
        \\body
        \\
    , &warnings);
    try std.testing.expect(!def.readonly);
    try std.testing.expectEqualStrings("", def.profile);
    try std.testing.expectEqual(@as(u32, 0), def.max_steps);
    // The bad pin is dropped and the good one kept — an unresolvable pin refuses
    // the whole `session new`, so it must never reach one.
    try std.testing.expectEqual(@as(usize, 1), def.pins.len);
    try std.testing.expectEqualStrings("ext:std/read", def.pins[0]);
    try std.testing.expectEqual(@as(usize, 4), warnings.items.len);
}

test "the spawn whitelist and the exchange budget, and what a bad entry costs" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;

    const boss = try parseOne(a,
        \\---
        \\agents: [explore, plan]
        \\max_exchanges: 4
        \\---
        \\You coordinate.
        \\
    , &warnings);
    try std.testing.expectEqual(@as(usize, 2), boss.agents.len);
    try std.testing.expectEqualStrings("explore", boss.agents[0]);
    try std.testing.expectEqual(@as(u32, 4), boss.max_exchanges);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);

    // Empty is a leaf, and that is the default every other persona takes.
    const leaf = try parseOne(a, "---\nname: leaf\n---\nbody\n", &warnings);
    try std.testing.expectEqual(@as(usize, 0), leaf.agents.len);
    try std.testing.expectEqual(@as(u32, 0), leaf.max_exchanges);

    // The block form works for both lists, and a name nobody could delegate to
    // is dropped with a sentence rather than carried to a failing delegation.
    const blocky = try parseOne(a, "---\nagents:\n  - one\n  - ../two\nmax_exchanges: soon\n---\nbody\n", &warnings);
    try std.testing.expectEqual(@as(usize, 1), blocky.agents.len);
    try std.testing.expectEqualStrings("one", blocky.agents[0]);
    try std.testing.expectEqual(@as(u32, 0), blocky.max_exchanges);
    try std.testing.expect(warnings.items.len >= 2);
}

test "a session id is checked because it becomes a path" {
    try std.testing.expect(isPlainSessionId("s-1787207848147-47acf2"));
    try std.testing.expect(!isPlainSessionId("s-"));
    try std.testing.expect(!isPlainSessionId("nope"));
    try std.testing.expect(!isPlainSessionId("s-../etc/passwd"));
}

test "a pin has one shape, and a name is one path component" {
    try std.testing.expect(isPin("ext:std/read"));
    try std.testing.expect(isPin("ext:my-ext/some_tool"));
    try std.testing.expect(!isPin("read"));
    try std.testing.expect(!isPin("ext:std"));
    try std.testing.expect(!isPin("ext:/read"));
    try std.testing.expect(!isPin("ext:std/"));
    try std.testing.expect(!isPin("ext:../std/read"));

    try std.testing.expect(isPlainName("explore"));
    try std.testing.expect(isPlainName("my.agent_2-b"));
    try std.testing.expect(!isPlainName(""));
    try std.testing.expect(!isPlainName(".hidden"));
    try std.testing.expect(!isPlainName("a/b"));
    try std.testing.expect(!isPlainName("../x"));
}

test "discovery layers workspace over user over builtin, and marks what it shadows" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = home_buf[0..try tmp.dir.realPath(io, &home_buf)];

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("NULYA_HOME", home);

    // Nothing written anywhere: the personas the package ships are the floor,
    // and they are enough to delegate with.
    {
        const found = try discover(a, io, &env);
        try std.testing.expectEqual(builtin.all.len, found.len);
        for (found) |entry| {
            try std.testing.expectEqual(Layer.builtin, entry.def.layer);
            try std.testing.expect(!entry.shadowed);
            try std.testing.expect(entry.def.prompt.len != 0);
        }
        const names_found = try names(a, io, &env);
        try std.testing.expectEqual(builtin.all.len, names_found.len);
    }

    // A user definition of a builtin's name wins, and the builtin is still
    // listed — the store roots' rule, not tcode's reserved names.
    try tmp.dir.createDirPath(io, "agents");
    try tmp.dir.writeFile(io, .{ .sub_path = "agents/explore.md", .data = "---\ndescription: mine\n---\nmy explore\n" });
    {
        const found = try discover(a, io, &env);
        try std.testing.expectEqual(builtin.all.len + 1, found.len);
        var saw_user = false;
        var saw_shadowed_builtin = false;
        for (found) |entry| {
            if (!std.mem.eql(u8, entry.def.name, "explore")) continue;
            if (entry.def.layer == .user) {
                saw_user = true;
                try std.testing.expect(!entry.shadowed);
                try std.testing.expectEqualStrings("mine", entry.def.description);
            } else {
                saw_shadowed_builtin = true;
                try std.testing.expect(entry.shadowed);
            }
        }
        try std.testing.expect(saw_user and saw_shadowed_builtin);
        // `find` answers with the winner, and only the winner.
        const winner = (try find(a, io, &env, "explore")).?;
        try std.testing.expectEqual(Layer.user, winner.def.layer);
        try std.testing.expectEqualStrings("my explore", winner.def.prompt);
        // …and the names a caller may use hold one of each.
        for (try names(a, io, &env)) |n| {
            var count: usize = 0;
            for (try names(a, io, &env)) |m| {
                if (std.mem.eql(u8, n, m)) count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), count);
        }
    }

    // A version lands in the user store for a user or builtin definition, and in
    // this checkout's for one that came with it.
    try std.testing.expect(userStore(.builtin));
    try std.testing.expect(userStore(.user));
    try std.testing.expect(!userStore(.workspace));

    try std.testing.expect((try find(a, io, &env, "not-a-thing")) == null);
}

test "the bundled personas parse, and explore is the read-only one" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    for (builtin.all) |b| {
        var warnings: std.ArrayList([]const u8) = .empty;
        const def = try parse(a, b.text, b.name, .builtin, b.name, &warnings);
        // A builtin with a warning is this package shipping a typo.
        try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
        try std.testing.expectEqualStrings(b.name, def.name);
        try std.testing.expect(def.description.len != 0);
        try std.testing.expect(def.max_steps != 0);
        // The coordinator has no pins on purpose: delegation is its whole job.
        try std.testing.expect(def.pins.len != 0 or def.agents.len != 0);
        for (def.pins) |pin| try std.testing.expect(isPin(pin));
        // Nothing names a model: a persona that does not care should run on
        // whatever asked for it.
        try std.testing.expectEqualStrings("", def.profile);
    }
    var w: std.ArrayList([]const u8) = .empty;
    try std.testing.expect((try parse(a, builtin.find("explore").?.text, "explore", .builtin, "b", &w)).readonly);
    // Exactly one of them coordinates, and it is the only one that is not a leaf.
    var coordinators: usize = 0;
    for (builtin.all) |b| {
        var bw: std.ArrayList([]const u8) = .empty;
        const def = try parse(a, b.text, b.name, .builtin, b.name, &bw);
        if (def.agents.len != 0) {
            coordinators += 1;
            try std.testing.expectEqualStrings("orchestrator", def.name);
            try std.testing.expect(def.max_exchanges != 0);
            // It may only name personas this package actually ships.
            for (def.agents) |one| try std.testing.expect(builtin.find(one) != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), coordinators);
}
