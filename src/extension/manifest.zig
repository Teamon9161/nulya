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
const tool = @import("../tool.zig");

pub const schema_id = "nulya.extension/v2";

/// The builtin name is permanently reserved; an extension may not shadow it
/// (DESIGN §5.2, §6). One name, because there is one builtin — `edit` left this
/// list when it became a tool of the bundled `std` extension (DESIGN §7.8).
pub const reserved_tool_names = [_][]const u8{"shell"};

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

/// Who a tool is FOR — the only question about a tool that only its own package
/// can answer (DESIGN §7.2.1).
///
///   - `model`  : it belongs on the model's tool face; pinning it is the point.
///   - `driver` : it is an interface for whoever DRIVES a session (`nulya ext
///                run`, a front end, a script). Putting it on the model's face
///                would at best waste a slot and at worst deadlock — `compact`
///                appends to and steps the very session it is called about.
pub const Audience = enum {
    model,
    driver,

    pub fn fromString(s: []const u8) ?Audience {
        if (std.mem.eql(u8, s, "model")) return .model;
        if (std.mem.eql(u8, s, "driver")) return .driver;
        return null;
    }
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON of the tool's `input` schema. Only fed to the model when the
    /// extension is promoted into `tools[]`; otherwise pure discoverability
    /// metadata (DESIGN §7.2 note).
    input_schema: []const u8,
    /// Wall-clock cap for one call of THIS tool, when it knows the host default
    /// (`tool.Timeouts.extension_ms`, 30s) is not enough — a driver tool that
    /// steps a real model is the case that exists (`extensions/compact`). Absent
    /// means the default; the ceiling is `tool.Timeouts.extension_max_ms`. The
    /// manifest is the one place this can be said, because the manifest is the
    /// single source of truth about a tool (DESIGN §7.2.1).
    timeout_ms: ?u32 = null,
    /// The package's claim that this tool only READS: it makes no change a
    /// person would want to approve first. A DECLARATION, exactly like
    /// `permissions` (DESIGN §9) — the kernel parses it, records it in the
    /// frozen manifest, and enforces nothing. What consumes it is a driver's
    /// approval policy (`loop.ToolGate`, DESIGN §4), which is free to ignore it;
    /// a real boundary needs OS enforcement (PLAN §3.8), not a boolean.
    ///
    /// Absent means the package did not say, which is not the same as `false`
    /// and must not be read as one.
    readonly: ?bool = null,
    /// The package's statement of who this tool is for — kept as WRITTEN, so
    /// that an unrecognized word is a named `validate` refusal rather than a
    /// silent default (`audienceOf`, `InvalidAudience`). Exactly the discipline
    /// `timeout_ms` follows: a wrong TYPE is a parse error, a wrong VALUE is a
    /// validate error.
    ///
    /// A DECLARATION, like `readonly` and `permissions` beside it: the kernel
    /// parses it, freezes it into the version's manifest, and enforces nothing.
    /// Nothing here filters a tool face or refuses a pin — pinning a `driver`
    /// tool stays legal, it is simply not what a driver would do by default.
    /// The consumers are a driver's own policies: which tools an activation
    /// pins, which ones a panel lists, which ones an approval rule is about.
    ///
    /// Absent is null, NOT `.model`. "The package did not say" and "the package
    /// said model" are different facts; a reader is free to treat silence as
    /// model (every manifest written before this field existed declares model
    /// tools), but that reading is the reader's, made where it is used.
    audience: ?[]const u8 = null,

    /// The declared audience, decoded. Null when absent — and also when the
    /// word is not one of the two, which `validate` refuses, so on a validated
    /// manifest null means only "did not say".
    pub fn audienceOf(self: ToolSpec) ?Audience {
        return Audience.fromString(self.audience orelse return null);
    }
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
            if (t.timeout_ms) |ms| {
                if (ms == 0 or ms > tool.Timeouts.extension_max_ms) return error.InvalidTimeout;
            }
            // A word outside the two is refused rather than read as the
            // default: a package that meant `driver` and typed `drivers` would
            // otherwise land its tool on the model's face, which is the exact
            // outcome the field exists to prevent.
            if (t.audience) |a| {
                if (Audience.fromString(a) == null) return error.InvalidAudience;
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
    /// A tool's `timeout_ms` is zero or above `tool.Timeouts.extension_max_ms`.
    InvalidTimeout,
    /// A tool's `audience` is a string, but not one of `model` / `driver`.
    InvalidAudience,
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
            .timeout_ms = try optionalU32(to, "timeout_ms"),
            .readonly = try optionalBool(to, "readonly"),
            .audience = try optionalString(a, to, "audience"),
        };
    }
    return tools;
}

/// Read an optional non-negative integer field. A value that is not an integer,
/// or does not fit, is a WrongType — never a silently dropped field, because
/// a mistyped timeout would otherwise read as "use the default".
fn optionalU32(obj: std.json.ObjectMap, key: []const u8) ParseError!?u32 {
    return switch (obj.get(key) orelse return null) {
        .integer => |n| std.math.cast(u32, n) orelse error.WrongType,
        else => error.WrongType,
    };
}

/// Read an optional boolean field. Absent stays absent — "the package did not
/// say" is its own answer — and a non-boolean is a WrongType rather than a
/// silently ignored key, for the same reason `optionalU32` is strict.
fn optionalBool(obj: std.json.ObjectMap, key: []const u8) ParseError!?bool {
    return switch (obj.get(key) orelse return null) {
        .bool => |b| b,
        else => error.WrongType,
    };
}

/// Read an optional string field. Absent stays absent, and a non-string is a
/// WrongType rather than a silently ignored key — the same strictness as
/// `optionalU32` / `optionalBool`, for the same reason.
fn optionalString(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError!?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| try a.dupe(u8, s),
        else => error.WrongType,
    };
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

test "rejects the one reserved tool name, and only that one" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"shell","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.ReservedToolName, m.validate());

    // `edit` is an extension tool now (the bundled `std` package declares it),
    // so the manifest layer must let a package claim that name.
    const editing =
        \\{"schema":"nulya.extension/v2","id":"b","runtime":{"entry":"bin/b"},"contributes":{"tools":[{"name":"edit","input":{}}]}}
    ;
    var e = try parse(std.testing.allocator, editing);
    defer e.deinit();
    try e.validate();
}

test "rejects duplicate tool names" {
    const src =
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}},{"name":"t","input":{}}]}}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.DuplicateToolName, m.validate());
}

test "a tool may declare its own timeout, within the host ceiling" {
    const alloc = std.testing.allocator;
    const with_timeout =
        \\{"schema":"nulya.extension/v2","id":"slow","runtime":{"entry":"bin/slow"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":60000}]}}
    ;
    var ok = try parse(alloc, with_timeout);
    defer ok.deinit();
    try ok.validate();
    try std.testing.expectEqual(@as(?u32, 60000), ok.tools[0].timeout_ms);

    // Absent means the host default; the field is optional and nothing else changes.
    var plain = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{}}]}}
    );
    defer plain.deinit();
    try plain.validate();
    try std.testing.expect(plain.tools[0].timeout_ms == null);

    // Zero is not "no timeout", and no manifest may exceed the host ceiling.
    var zero = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":0}]}}
    );
    defer zero.deinit();
    try std.testing.expectError(error.InvalidTimeout, zero.validate());

    var huge = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":700000}]}}
    );
    defer huge.deinit();
    try std.testing.expectError(error.InvalidTimeout, huge.validate());
    try std.testing.expectEqual(@as(u32, 600_000), tool.Timeouts.extension_max_ms);

    // A mistyped timeout is a parse error, not a silently defaulted one.
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"timeout_ms":"60s"}]}}
    ));
}

test "a tool may declare itself readonly; the kernel records the claim and enforces nothing" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"r","runtime":{"entry":"bin/r"},"contributes":{"tools":[{"name":"look","input":{},"readonly":true},{"name":"touch","input":{},"readonly":false},{"name":"quiet","input":{}}]}}
    );
    defer m.deinit();
    // Nothing in `validate` looks at it: the claim is for a driver's approval
    // policy to read, and a package that lies about it is exactly as dangerous
    // as one that lies in `permissions` (DESIGN §9).
    try m.validate();
    try std.testing.expectEqual(@as(?bool, true), m.tools[0].readonly);
    try std.testing.expectEqual(@as(?bool, false), m.tools[1].readonly);
    // Absent is NOT false: the package said nothing, and a reader that turns
    // silence into a claim would be inventing the one thing this field is for.
    try std.testing.expect(m.tools[2].readonly == null);

    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"r","runtime":{"entry":"bin/r"},"contributes":{"tools":[{"name":"look","input":{},"readonly":"yes"}]}}
    ));
}

test "a tool may declare who it is for; silence is not a claim and an unknown word is refused" {
    const alloc = std.testing.allocator;
    var m = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"ask","input":{},"audience":"model"},{"name":"drive","input":{},"audience":"driver"},{"name":"quiet","input":{}}]}}
    );
    defer m.deinit();
    // Nothing in `validate` acts on it beyond refusing a word it cannot read:
    // like `readonly`, the claim is recorded for a driver's policy to consult,
    // and the kernel neither filters the tool face nor refuses a pin over it.
    try m.validate();
    try std.testing.expectEqual(@as(?Audience, .model), m.tools[0].audienceOf());
    try std.testing.expectEqual(@as(?Audience, .driver), m.tools[1].audienceOf());
    // Absent is NOT `model`: the reading of silence belongs to whoever uses it.
    try std.testing.expect(m.tools[2].audience == null);
    try std.testing.expect(m.tools[2].audienceOf() == null);

    // A word outside the two is a named refusal, not a default.
    var typo = try parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"audience":"drivers"}]}}
    );
    defer typo.deinit();
    try std.testing.expectError(error.InvalidAudience, typo.validate());

    // And a wrong TYPE is a parse error, the same split `timeout_ms` makes.
    try std.testing.expectError(error.WrongType, parse(alloc,
        \\{"schema":"nulya.extension/v2","id":"a","runtime":{"entry":"bin/a"},"contributes":{"tools":[{"name":"t","input":{},"audience":true}]}}
    ));
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
