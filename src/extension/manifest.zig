//! `extension.json` — the manifest (DESIGN §7.2).
//!
//! The manifest is the SINGLE source of truth for an extension's identity and
//! model-facing schema. Nulya never starts a binary just to ask what tools it
//! has: that would split truth across source / manifest / runtime describe().
//! Runtime processes only ever handle calls declared by the manifest.
//!
//! `parse` loads the structure into arena-owned memory (so the caller may free
//! the source bytes); `validate` enforces the kernel's deterministic rules
//! (DESIGN §7.4, §12). Whether a tool is "good taste" is policy, not validation.

const std = @import("std");

pub const schema_id = "nulya.extension/v2";

/// Builtin names are permanently reserved; an extension may not shadow them
/// (DESIGN §5.2, §6).
pub const reserved_tool_names = [_][]const u8{ "shell", "edit" };

pub const Runtime = struct {
    /// Relative path to the runtime entry within the package. A `bin/<name>`
    /// entry is a COMPILED Zig extension (built from `src/main.zig`); any other
    /// entry (e.g. `src/run.ps1`) is a SCRIPT extension frozen as-is — see
    /// `isScript`.
    entry: []const u8,
    /// For a script extension, the executable used to run `entry` (e.g. `sh`,
    /// `powershell`, `python3`). Absent means the entry is directly executable
    /// (a `.cmd`/`.bat` on Windows, or a shebang script with the exec bit).
    interpreter: ?[]const u8 = null,
};

/// A script extension is frozen and run as-is (no compilation); a compiled Zig
/// extension outputs a binary under `bin/`. The `bin/` prefix is the sole,
/// purely-syntactic distinguisher, so every consumer decides identically without
/// probing the filesystem.
pub fn isScript(rt: Runtime) bool {
    return !std.mem.startsWith(u8, rt.entry, "bin/");
}

/// How an extension version is materialized — the one axis that decides what
/// belongs in its content-addressed identity (DESIGN §7.1, §7.4):
///   - `data`     : no runtime at all (pure skills / system prompts). Identity is
///                  the package snapshot alone; building needs no compiler.
///   - `script`   : a runtime entry frozen and run as-is (`src/…`). Same as data
///                  for identity purposes: no compilation, so no compiler/target.
///   - `compiled` : a Zig runtime built into `bin/…`. Its binary depends on the
///                  compiler and host target, so BOTH enter the version id.
/// Only `compiled` requires a toolchain; `data` and `script` never touch zig.
pub const ImplementationKind = enum { data, script, compiled };

pub fn implementationKind(m: Manifest) ImplementationKind {
    const rt = m.runtime orelse return .data;
    return if (isScript(rt)) .script else .compiled;
}

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON of the tool's `input` schema. Only fed to the model when the
    /// extension is promoted into `tools[]`; otherwise pure discoverability
    /// metadata (DESIGN §7.2 note).
    input_schema: []const u8,
};

pub const Permissions = struct {
    fs: []const []const u8 = &.{},
    network: []const []const u8 = &.{},
    process: []const []const u8 = &.{},
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    schema: []const u8,
    id: []const u8,
    runtime: ?Runtime,
    tools: []const ToolSpec,
    skills: []const []const u8,
    system_prompts: []const []const u8,
    permissions: Permissions,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Enforce the deterministic kernel rules (DESIGN §7.4, §12). Whether a tool
    /// is "good taste" is policy, checked elsewhere — not here.
    pub fn validate(self: Manifest) ValidateError!void {
        if (!std.mem.eql(u8, self.schema, schema_id)) return error.UnsupportedSchema;
        if (!isValidId(self.id)) return error.InvalidId;
        if (self.tools.len == 0 and self.skills.len == 0 and self.system_prompts.len == 0) return error.NoContributions;

        if (self.runtime) |rt| {
            if (!isSafeRelPath(rt.entry)) return error.InvalidEntry;
            // A compiled entry lives under `bin/` (the build output); a script
            // entry lives under `src/` (frozen with the source tree). Anything
            // else is rejected so every consumer can locate the entry the same way.
            if (isScript(rt) and !std.mem.startsWith(u8, rt.entry, "src/")) return error.InvalidEntry;
            if (rt.interpreter) |i| {
                if (i.len == 0) return error.InvalidInterpreter;
                for (i) |c| if (c < 0x20) return error.InvalidInterpreter;
            }
        } else if (self.tools.len != 0) {
            return error.MissingRuntime;
        }

        for (self.tools, 0..) |t, i| {
            if (!isValidId(t.name)) return error.InvalidToolName;
            for (reserved_tool_names) |r| {
                if (std.mem.eql(u8, t.name, r)) return error.ReservedToolName;
            }
            for (self.tools[i + 1 ..]) |other| {
                if (std.mem.eql(u8, t.name, other.name)) return error.DuplicateToolName;
            }
        }

        for (self.skills, 0..) |skill, i| {
            if (!isSafeRelPath(skill)) return error.InvalidSkillPath;
            for (self.skills[i + 1 ..]) |other| {
                if (std.mem.eql(u8, skill, other)) return error.DuplicateSkillPath;
            }
        }

        for (self.system_prompts, 0..) |prompt_path, i| {
            if (!isSafeRelPath(prompt_path)) return error.InvalidSystemPromptPath;
            for (self.system_prompts[i + 1 ..]) |other| {
                if (std.mem.eql(u8, prompt_path, other)) return error.DuplicateSystemPromptPath;
            }
        }
    }
};

pub const ParseError = error{
    InvalidJson,
    NotAnObject,
    MissingField,
    WrongType,
} || std.mem.Allocator.Error;

pub const ValidateError = error{
    UnsupportedSchema,
    InvalidId,
    MissingRuntime,
    InvalidEntry,
    InvalidInterpreter,
    NoContributions,
    InvalidToolName,
    ReservedToolName,
    DuplicateToolName,
    InvalidSkillPath,
    DuplicateSkillPath,
    InvalidSystemPromptPath,
    DuplicateSystemPromptPath,
};

/// Load `extension.json` into arena-owned memory. Structural only — call
/// `validate` for the kernel rules.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Manifest {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    const contributes = switch (obj.get("contributes") orelse return error.MissingField) {
        .object => |o| o,
        else => return error.WrongType,
    };

    const schema = try dupString(a, obj, "schema");
    const id = try dupString(a, obj, "id");
    const runtime = try dupRuntime(a, obj);
    const tools = try dupTools(a, contributes);
    const skills = try dupStringList(a, contributes, "skills");
    const system_prompts = try dupStringList(a, contributes, "system_prompts");
    const permissions: Permissions = .{
        .fs = try dupPermissionList(a, obj, "fs"),
        .network = try dupPermissionList(a, obj, "network"),
        .process = try dupPermissionList(a, obj, "process"),
    };

    return .{
        .arena = arena,
        .schema = schema,
        .id = id,
        .runtime = runtime,
        .tools = tools,
        .skills = skills,
        .system_prompts = system_prompts,
        .permissions = permissions,
    };
}

pub fn isValidId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// A relative path that cannot escape the extension directory.
fn isSafeRelPath(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.fs.path.isAbsolute(s)) return false;
    var it = std.mem.splitAny(u8, s, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

fn dupRuntime(a: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!?Runtime {
    const value = obj.get("runtime") orelse return null;
    const runtime_obj = switch (value) {
        .object => |o| o,
        else => return error.WrongType,
    };
    const interpreter: ?[]const u8 = switch (runtime_obj.get("interpreter") orelse std.json.Value{ .null = {} }) {
        .string => |s| try a.dupe(u8, s),
        .null => null,
        else => return error.WrongType,
    };
    return .{
        .entry = try dupString(a, runtime_obj, "entry"),
        .interpreter = interpreter,
    };
}

fn dupTools(a: std.mem.Allocator, contributes: std.json.ObjectMap) ParseError![]const ToolSpec {
    const tools_val = switch (contributes.get("tools") orelse return a.alloc(ToolSpec, 0)) {
        .array => |arr| arr,
        else => return error.WrongType,
    };
    const tools = try a.alloc(ToolSpec, tools_val.items.len);
    for (tools_val.items, 0..) |tv, i| {
        const to = switch (tv) {
            .object => |o| o,
            else => return error.WrongType,
        };
        tools[i] = .{
            .name = try dupString(a, to, "name"),
            .description = try dupStringOr(a, to, "description", ""),
            .input_schema = if (to.get("input")) |iv| try compact(a, iv) else try a.dupe(u8, "{}"),
        };
    }
    return tools;
}

fn dupString(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]const u8 {
    return switch (obj.get(key) orelse return error.MissingField) {
        .string => |s| try a.dupe(u8, s),
        else => error.WrongType,
    };
}

fn dupStringOr(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ParseError![]const u8 {
    return switch (obj.get(key) orelse return a.dupe(u8, default)) {
        .string => |s| try a.dupe(u8, s),
        else => error.WrongType,
    };
}

fn dupStringList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]const []const u8 {
    const list = switch (obj.get(key) orelse return a.alloc([]const u8, 0)) {
        .array => |arr| arr,
        else => return error.WrongType,
    };
    const out = try a.alloc([]const u8, list.items.len);
    for (list.items, 0..) |v, i| {
        out[i] = switch (v) {
            .string => |s| try a.dupe(u8, s),
            else => return error.WrongType,
        };
    }
    return out;
}

/// Read a string list out of the nested `permissions` object; absent -> empty.
fn dupPermissionList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]const []const u8 {
    const perms = switch (obj.get("permissions") orelse return a.alloc([]const u8, 0)) {
        .object => |o| o,
        else => return error.WrongType,
    };
    return dupStringList(a, perms, key);
}

fn compact(a: std.mem.Allocator, value: std.json.Value) ParseError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const valid_manifest =
    \\{
    \\  "schema": "nulya.extension/v2",
    \\  "id": "web.search",
    \\  "runtime": { "entry": "bin/web-search" },
    \\  "contributes": {
    \\    "tools": [{
    \\      "name": "web_search",
    \\      "description": "Search the web.",
    \\      "input": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }
    \\    }],
    \\    "skills": ["skills/search-review"]
    \\  },
    \\  "permissions": { "fs": [], "network": ["https"], "process": [] }
    \\}
;

test "parses and validates a well-formed manifest" {
    var m = try parse(std.testing.allocator, valid_manifest);
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqualStrings("web.search", m.id);
    try std.testing.expect(m.runtime != null);
    try std.testing.expectEqualStrings("bin/web-search", m.runtime.?.entry);
    try std.testing.expectEqual(@as(usize, 1), m.tools.len);
    try std.testing.expectEqualStrings("web_search", m.tools[0].name);
    try std.testing.expect(std.mem.indexOf(u8, m.tools[0].input_schema, "query") != null);
    try std.testing.expectEqual(@as(usize, 1), m.skills.len);
    try std.testing.expectEqualStrings("skills/search-review", m.skills[0]);
    try std.testing.expectEqual(@as(usize, 1), m.permissions.network.len);
    try std.testing.expectEqualStrings("https", m.permissions.network[0]);
}

test "parses and validates a script runtime with an interpreter" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"greeter","runtime":{"entry":"src/run.ps1","interpreter":"powershell"},"contributes":{"tools":[{"name":"greet","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(m.runtime != null);
    try std.testing.expect(isScript(m.runtime.?));
    try std.testing.expectEqualStrings("powershell", m.runtime.?.interpreter.?);
}

test "a bin/ entry is a compiled runtime, not a script" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(!isScript(m.runtime.?));
    try std.testing.expect(m.runtime.?.interpreter == null);
}

test "a script entry must live under src/" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"run.sh","interpreter":"sh"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidEntry, m.validate());
}

test "rejects an empty interpreter" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"src/run.sh","interpreter":""},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidInterpreter, m.validate());
}

test "validates a pure skill package without runtime" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"skills.finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(m.runtime == null);
    try std.testing.expectEqual(@as(usize, 0), m.tools.len);
    try std.testing.expectEqualStrings("skills/risk-parity", m.skills[0]);
}

test "rejects wrong schema" {
    const src =
        \\{"schema":"other/v9","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.UnsupportedSchema, m.validate());
}

test "rejects tool contribution without runtime" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.MissingRuntime, m.validate());
}

test "rejects manifest with no contributions" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.NoContributions, m.validate());
}

test "rejects reserved tool name" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"shell","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.ReservedToolName, m.validate());
}

test "rejects duplicate tool names" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}},{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.DuplicateToolName, m.validate());
}

test "rejects entry that escapes the extension dir" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"../evil"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidEntry, m.validate());
}

test "rejects skill path that escapes the extension dir" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"skills":["../evil"]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidSkillPath, m.validate());
}

test "missing required field is a parse error" {
    const src =
        \\{"schema":"nulya.extension/v2","contributes":{}}
    ;
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, src));
}

test "validates a prompt-only package without runtime" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"prompts.finance","contributes":{"system_prompts":["prompts/finance.md"]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try m.validate();
    try std.testing.expect(m.runtime == null);
    try std.testing.expectEqual(@as(usize, 0), m.tools.len);
    try std.testing.expectEqual(@as(usize, 0), m.skills.len);
    try std.testing.expectEqualStrings("prompts/finance.md", m.system_prompts[0]);
}

test "rejects invalid and duplicate system prompt paths" {
    const invalid =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["../evil.md"]}}
    ;
    var a = try parse(std.testing.allocator, invalid);
    defer a.deinit();
    try std.testing.expectError(error.InvalidSystemPromptPath, a.validate());

    const dup =
        \\{"schema":"nulya.extension/v2","id":"prompts","contributes":{"system_prompts":["prompts/a.md","prompts/a.md"]}}
    ;
    var b = try parse(std.testing.allocator, dup);
    defer b.deinit();
    try std.testing.expectError(error.DuplicateSystemPromptPath, b.validate());
}
