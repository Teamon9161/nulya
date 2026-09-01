//! An agent definition, and what it becomes.
//!
//! A definition is a markdown file with front matter: `.nulya/agents/<name>.md`
//! in the workspace, or `<NULYA_HOME | ~/.nulya>/agents/<name>.md` on this
//! machine. Its front matter is a set of `session new` arguments; its body is a
//! system prompt.
//!
//! There is ONE writer of the rendering (this tool) and one reader of the format
//! (`main.list`): a front end that parsed front matter as well would be a second
//! answer to "is this agent read-only".
//!
//! The front matter dialect is deliberately small — `key: value`, `key: [a, b]`,
//! and the `- item` block form. Every field below is a word, a flag, a number or
//! a list of tool ids; the day one needs nesting is the day this reads real YAML.

const std = @import("std");
const builtin = @import("builtin.zig");
const header_mod = @import("header.zig");
const record = @import("record.zig");
const runners = @import("runners.zig");

/// Which layer a definition came from, in search order. Workspace wins on a name
/// collision; this package's own `builtin` personas are the floor nobody had to
/// install. The loser is never dropped, only marked `shadowed`.
pub const Layer = enum { workspace, user, builtin };

pub const Def = struct {
    name: []const u8,
    description: []const u8 = "",
    /// How much this agent may do: `readonly`, `default` or `unsafe`
    /// (`record.Permissions`). A ceiling every runner translates into its own
    /// harness's terms and refuses the delegation rather than exceed — a policy,
    /// not a sandbox. The `readonly: true` this replaced is REFUSED whole, never
    /// read as `default`.
    permissions: record.Permissions = record.default_permissions,
    /// WHICH HARNESS holds this agent's conversation. The default is this nulya —
    /// a session of its own, driven by a background task — and every other field
    /// below is written in that vocabulary. An unknown word costs the whole
    /// definition rather than a warning and a default: a persona quietly running
    /// on something other than what it asked for is worse than one that is not
    /// there.
    runner: runners.Runner = runners.default,
    /// `--profile`; empty means "inherit whatever asked for the delegation".
    /// Only the nulya runner has such a thing.
    profile: []const u8 = "",
    /// `--model` within that profile; empty means the profile's default.
    model: []const u8 = "",
    /// What an EXTERNAL runner should run on, in that harness's own vocabulary —
    /// `runner_model: gpt-5-codex`, say. Opaque here: a parser for it could only
    /// be a staler copy of somebody else's catalogue.
    ///
    /// A definition writes ONE of these vocabularies, decided by its `runner:`.
    /// The other is dropped with a warning once the front matter has been read
    /// WHOLE (`crossCheck`) — a definition may write its fields in any order.
    runner_model: []const u8 = "",
    /// `ext:<id>/<tool>` ids for `--pin`, on top of the session's usual face.
    pins: []const []const u8 = &.{},
    /// The agents this one may delegate to. EMPTY IS A LEAF, the default: a
    /// delegated session carries this package only when its definition names
    /// somebody to pass work to, so "can it delegate" is one decision in one
    /// place.
    agents: []const []const u8 = &.{},
    /// How many turns a caller may send into one delegated session — the
    /// follow-ups `agent{session, task}` adds on top of the first. 0 = no limit.
    max_exchanges: u32 = 0,
    /// `session step --max-steps`; 0 means the kernel's own budget.
    max_steps: u32 = 0,
    /// The markdown body: this agent's system prompt, verbatim.
    prompt: []const u8,
    layer: Layer,
    /// The file it was read from, or `builtin:<name>`, for messages.
    source: []const u8,
};

pub const ParseError = error{
    NoFrontMatter,
    NoBody,
    BadName,
    UnknownRunner,
    /// A `permissions:` this package cannot read, or the `readonly:` it
    /// replaced. Fatal for the reason `UnknownRunner` is: the alternative is
    /// running a persona at a ceiling nobody wrote down.
    UnknownPermissions,
    OutOfMemory,
};

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
/// it becomes a path.
pub fn isPlainSessionId(id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, "s-") or id.len > 128) return false;
    for (id["s-".len..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return id.len > "s-".len;
}

/// A pin has one shape. One the kernel cannot resolve does not cost a tool — it
/// refuses the whole `session new` — so a malformed one is dropped HERE.
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

/// `<profile>` or `<profile>/<model-id>` — the kernel's two flags, which mean
/// different things. Naming only the profile is legal and means "that profile's
/// default model". Null is "this is not a model reference".
///
/// TWO CALLERS, ONE SHAPE: a definition's `model:` front matter and the `model`
/// argument of the `agent` tool. The argument's whole purpose is to override the
/// field for one delegation, so two parsers would be two grammars.
pub const ModelRef = struct { profile: []const u8, model: []const u8 };

pub fn parseModelRef(value: []const u8) ?ModelRef {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len == 0) return null;
    const at = std.mem.indexOfScalar(u8, v, '/') orelse return .{ .profile = v, .model = "" };
    const profile = std.mem.trim(u8, v[0..at], " \t");
    const model = std.mem.trim(u8, v[at + 1 ..], " \t");
    if (profile.len == 0 or model.len == 0) return null;
    return .{ .profile = profile, .model = model };
}

fn unquote(value: []const u8) []const u8 {
    const t = std.mem.trim(u8, value, " \t\r");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// Parse one definition file. Warnings are collected rather than fatal: losing a
/// whole persona over one bad line is the expensive answer.
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
        } else if (std.mem.eql(u8, key, "permissions")) {
            def.permissions = record.Permissions.parse(unquote(value)) orelse return error.UnknownPermissions;
        } else if (std.mem.eql(u8, key, "readonly")) {
            // The word this field replaced. Refused rather than translated: a
            // ceiling must not be read approximately.
            return error.UnknownPermissions;
        } else if (std.mem.eql(u8, key, "runner")) {
            def.runner = runners.Runner.parse(unquote(value)) orelse return error.UnknownRunner;
        } else if (std.mem.eql(u8, key, "model")) {
            if (parseModelRef(unquote(value))) |ref| {
                def.profile = ref.profile;
                def.model = ref.model;
            } else try warn(alloc, warnings, source, "model must be <profile> or <profile>/<model-id>, ignored");
        } else if (std.mem.eql(u8, key, "runner_model")) {
            def.runner_model = unquote(value);
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
    try crossCheck(alloc, &def, warnings, source);
    return def;
}

/// The fields whose meaning depends on `runner:`, checked once the WHOLE front
/// matter has been read — a definition may name its runner after the field the
/// runner decides, and a line-by-line check would answer differently depending on
/// the order somebody typed.
///
/// A field belonging to the other harness is DROPPED and named, never honoured as
/// if it were the local one: `model: openai/gpt-5` on a codex agent would name a
/// model nobody serves. A warning rather than a refusal, because this can only
/// run the persona on the harness's default.
///
/// Nulya composition — pins, a step budget, a list of agents — is CLEARED for an
/// external harness so no field silently does nothing: `agents: [explore]` on a
/// codex persona would otherwise read as "this one can delegate".
fn crossCheck(
    alloc: std.mem.Allocator,
    def: *Def,
    warnings: *std.ArrayList([]const u8),
    source: []const u8,
) !void {
    if (def.runner.usesNulyaModels()) {
        if (def.runner_model.len != 0) {
            try warn(alloc, warnings, source, "runner_model is for an external runner; this one is nulya, so it was ignored (use `model:`)");
            def.runner_model = "";
        }
        return;
    }
    if (def.profile.len != 0 or def.model.len != 0) {
        try warn(alloc, warnings, source, "model names a nulya profile, which this runner does not have; it was ignored (use `runner_model:`)");
        def.profile = "";
        def.model = "";
    }
    // One sentence for all of them: three warnings about the same mistake would
    // bury the one thing the author has to change.
    var inert: std.ArrayList([]const u8) = .empty;
    if (def.pins.len != 0) {
        try inert.append(alloc, "pins");
        def.pins = &.{};
    }
    if (def.agents.len != 0) {
        try inert.append(alloc, "agents");
        def.agents = &.{};
    }
    if (def.max_steps != 0) {
        try inert.append(alloc, "max_steps");
        def.max_steps = 0;
    }
    if (inert.items.len == 0) return;
    try warn(alloc, warnings, source, try std.fmt.allocPrint(
        alloc,
        "{s} describe a nulya session; the {s} runner composes its own, so they were ignored",
        .{ try std.mem.join(alloc, ", ", inert.items), def.runner.label() },
    ));
}

/// One entry of either list, validated by its own rule. A malformed one is
/// dropped and named.
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

/// This machine's directory: `$NULYA_HOME/agents`, else `<home>/.nulya/agents`.
/// Null when there is no home, which is a fact about the machine, not a failure.
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
/// Warn-and-skip, never fatal: a field that cannot be read is a warning and a
/// default, because losing a whole persona over one bad line is expensive.
pub fn discover(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    try readDir(alloc, io, project_dir, .workspace, &out);
    if (try userDir(alloc, env)) |dir| try readDir(alloc, io, dir, .user, &out);
    for (builtin.all) |b| {
        var warnings: std.ArrayList([]const u8) = .empty;
        const source = try std.fmt.allocPrint(alloc, "builtin:{s}", .{b.name});
        // A builtin that does not parse is this package's bug, not a person's.
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

/// One layer's `*.md`, flat and sorted. Flat and `.md` only: an `agents/`
/// directory is a list of personas, not a tree to organise.
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
            // A harness this package cannot talk to and a ceiling it cannot read
            // cost the whole definition: a persona that runs somewhere — or at
            // some width — nobody asked for is worse than one that is not there.
            error.NoFrontMatter,
            error.NoBody,
            error.BadName,
            error.UnknownRunner,
            error.UnknownPermissions,
            => continue,
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

/// The names a caller may use, in search order — the winners of all three layers.
/// It only appears inside a message already saying the name was wrong, so a
/// shadowed copy has nothing to add.
pub fn names(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try discover(alloc, io, env)) |entry| {
        if (entry.shadowed) continue;
        if (out.items.len >= max_listed_names) break;
        try out.append(alloc, entry.def.name);
    }
    return out.items;
}

/// The prefix this package writes on a persona's prompt and reads back off a
/// session header. A label, not an id: the kernel carries `source` verbatim and
/// never looks inside it, so both ends of the convention are here.
const label_prefix = "agent-";

/// The label a definition's system prompt block carries for the life of every
/// session that wears it.
pub fn promptLabel(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, label_prefix ++ "{s}", .{name});
}

/// Where a definition's body is rendered for `session new --prompt` to read.
///
/// Under `.nulya/scratch/` and NOT under a store root: a persona is text with no
/// life of its own outside the session that wears it, so it is never an installed
/// artifact. The file name's stem is the label `session new` takes as `source`.
pub fn promptPath(alloc: std.mem.Allocator, label: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, ".nulya/scratch/agents/{s}.md", .{label});
}

/// Render the definition's body to that file, overwriting whatever was there.
///
/// Content-determined, so two delegations to one definition race harmlessly. The
/// file is a handoff to `session new`, which reads it once and freezes the bytes
/// into the header; after that nothing depends on it existing.
pub fn writePrompt(alloc: std.mem.Allocator, io: std.Io, def: Def, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    const body = try std.fmt.allocPrint(alloc, "{s}\n", .{def.prompt});
    try cwd.writeFile(io, .{ .sub_path = path, .data = body });
}

/// The persona a session is wearing, from its frozen header: the `agent-<name>`
/// system prompt `session new --prompt` froze into it. Null for a session that is
/// not a delegation.
///
/// The header is the authority because it is FROZEN: it says what this session
/// actually composed with, not what a definition file says today.
pub fn wornPersona(alloc: std.mem.Allocator, io: std.Io, session_id: []const u8) !?[]const u8 {
    const root = header_mod.object(alloc, io, session_id) orelse return null;
    const composition = switch (root.get("composition") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const prompts = switch (composition.get("prompts") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    for (prompts.items) |entry| {
        const block = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const source = switch (block.get("source") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.startsWith(u8, source, label_prefix)) return try alloc.dupe(u8, source[label_prefix.len..]);
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
        \\permissions: readonly
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
    try std.testing.expectEqual(record.Permissions.readonly, def.permissions);
    try std.testing.expectEqualStrings("deepseek", def.profile);
    try std.testing.expectEqualStrings("deepseek-v4-pro", def.model);
    try std.testing.expectEqual(@as(u32, 12), def.max_steps);
    // Unwritten means this nulya, which is what every persona shipped here is.
    try std.testing.expectEqual(runners.Runner.nulya, def.runner);
    try std.testing.expectEqual(@as(usize, 2), def.pins.len);
    try std.testing.expectEqualStrings("ext:std/read", def.pins[0]);
    // The body is the system prompt, verbatim and nothing else.
    try std.testing.expectEqualStrings("You only read.", def.prompt);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "which model vocabulary a definition writes in is decided by its runner, whatever order the two are written in" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // `runner:` is written AFTER the fields it decides, on purpose: the answer
    // must not depend on the order somebody typed.
    {
        var warnings: std.ArrayList([]const u8) = .empty;
        const def = try parseOne(
            a,
            "---\nmodel: deepseek/deepseek-v4-pro\npins: [ext:std/read]\nagents: [explore]\nmax_steps: 12\nmax_exchanges: 3\nrunner_model: gpt-5-codex\nrunner: codex\n---\nbody\n",
            &warnings,
        );
        try std.testing.expectEqual(runners.Runner.codex, def.runner);
        try std.testing.expectEqualStrings("gpt-5-codex", def.runner_model);
        try std.testing.expectEqualStrings("", def.profile);
        try std.testing.expectEqualStrings("", def.model);
        // Nulya composition, cleared rather than left to look like it does
        // something.
        try std.testing.expectEqual(@as(usize, 0), def.pins.len);
        try std.testing.expectEqual(@as(usize, 0), def.agents.len);
        try std.testing.expectEqual(@as(u32, 0), def.max_steps);
        // …but exchanges are counted from the record, which every runner has.
        try std.testing.expectEqual(@as(u32, 3), def.max_exchanges);
        // One sentence for the model, one for the rest.
        try std.testing.expectEqual(@as(usize, 2), warnings.items.len);
    }

    // …and the mirror.
    {
        var warnings: std.ArrayList([]const u8) = .empty;
        const def = try parseOne(a, "---\nrunner_model: gpt-5-codex\nmodel: deepseek\n---\nbody\n", &warnings);
        try std.testing.expectEqual(runners.Runner.nulya, def.runner);
        try std.testing.expectEqualStrings("", def.runner_model);
        try std.testing.expectEqualStrings("deepseek", def.profile);
        try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    }
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
    // An unwritten ceiling is an ordinary delegation.
    try std.testing.expectEqual(record.Permissions.default, def.permissions);
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
    // A harness this package cannot talk to costs the whole definition.
    try std.testing.expectError(error.UnknownRunner, parseOne(a, "---\nrunner: borges\n---\nbody\n", &warnings));
    // …and so does a ceiling nobody can read, in either spelling: reading one as
    // "default" is the widening the field exists to prevent.
    try std.testing.expectError(error.UnknownPermissions, parseOne(a, "---\npermissions: none\n---\nbody\n", &warnings));
    try std.testing.expectError(error.UnknownPermissions, parseOne(a, "---\nreadonly: true\n---\nbody\n", &warnings));
    try std.testing.expectError(error.UnknownPermissions, parseOne(a, "---\nreadonly: false\n---\nbody\n", &warnings));

    // Everything else survives with a default and a sentence.
    const def = try parseOne(a,
        \\---
        \\model: /nope
        \\pins: [read, ext:std/read]
        \\max_steps: soon
        \\---
        \\body
        \\
    , &warnings);
    try std.testing.expectEqualStrings("", def.profile);
    try std.testing.expectEqual(@as(u32, 0), def.max_steps);
    // An unresolvable pin refuses the whole `session new`, so it never reaches
    // one.
    try std.testing.expectEqual(@as(usize, 1), def.pins.len);
    try std.testing.expectEqualStrings("ext:std/read", def.pins[0]);
    try std.testing.expectEqual(@as(usize, 3), warnings.items.len);
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

    // The block form works for both lists, and an unusable name is dropped with
    // a sentence rather than carried to a failing delegation.
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

// The front matter field and the `agent` tool's `model` argument share this
// grammar, so this is the whole of both readings.
test "a model reference is a profile, optionally with an id inside it" {
    const only_profile = parseModelRef("deepseek").?;
    try std.testing.expectEqualStrings("deepseek", only_profile.profile);
    // Empty is "that profile's default", which is not the same as naming one.
    try std.testing.expectEqualStrings("", only_profile.model);

    const both = parseModelRef(" anthropic / claude-opus-5 ").?;
    try std.testing.expectEqualStrings("anthropic", both.profile);
    try std.testing.expectEqualStrings("claude-opus-5", both.model);

    // Half a reference names nothing that can run.
    try std.testing.expect(parseModelRef("/claude-opus-5") == null);
    try std.testing.expect(parseModelRef("anthropic/") == null);
    try std.testing.expect(parseModelRef("   ") == null);
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

    // Nothing written anywhere: the shipped personas are the floor, and enough.
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
    // listed rather than dropped.
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
        // No builtin carries its own step ceiling: a persona-sized budget cuts
        // the sub-agent off mid-investigation, and everything it found dies in a
        // session nobody will ever read.
        try std.testing.expectEqual(@as(u32, 0), def.max_steps);
        // The coordinator has no pins on purpose: delegation is its whole job.
        try std.testing.expect(def.pins.len != 0 or def.agents.len != 0);
        for (def.pins) |pin| try std.testing.expect(isPin(pin));
        // Nothing names a model: a persona that does not care runs on whatever
        // asked for it.
        try std.testing.expectEqualStrings("", def.profile);
    }
    var w: std.ArrayList([]const u8) = .empty;
    try std.testing.expectEqual(
        record.Permissions.readonly,
        (try parse(a, builtin.find("explore").?.text, "explore", .builtin, "b", &w)).permissions,
    );
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
