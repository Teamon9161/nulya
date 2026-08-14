//! `extension.json` — the manifest (DESIGN §7.2).
//!
//! The manifest is the SINGLE source of truth for an extension's identity and
//! model-facing schema. Nulya never starts a binary just to ask what tools it
//! has: that would split truth across source / manifest / runtime describe().
//! The binary only ever answers `execute(tool, args)` (DESIGN §7.2).
//!
//! `parse` loads the structure into arena-owned memory (so the caller may free
//! the source bytes); `validate` enforces the kernel's deterministic rules
//! (DESIGN §7.4, §12). Whether a tool is "good taste" is policy, not validation.

const std = @import("std");

pub const schema_id = "nulya.extension/v1";

/// Builtin names are permanently reserved; an extension may not shadow them
/// (DESIGN §5.2, §6).
pub const reserved_tool_names = [_][]const u8{ "shell", "edit" };

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
    version: []const u8,
    entry: []const u8,
    tools: []const ToolSpec,
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
        if (self.version.len == 0) return error.MissingVersion;
        if (!isSafeRelPath(self.entry)) return error.InvalidEntry;
        if (self.tools.len == 0) return error.NoTools;

        for (self.tools, 0..) |t, i| {
            if (!isValidId(t.name)) return error.InvalidToolName;
            for (reserved_tool_names) |r| {
                if (std.mem.eql(u8, t.name, r)) return error.ReservedToolName;
            }
            for (self.tools[i + 1 ..]) |other| {
                if (std.mem.eql(u8, t.name, other.name)) return error.DuplicateToolName;
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
    MissingVersion,
    InvalidEntry,
    NoTools,
    InvalidToolName,
    ReservedToolName,
    DuplicateToolName,
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

    const tools_val = switch (obj.get("tools") orelse return error.MissingField) {
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

    return .{
        .arena = arena,
        .schema = try dupString(a, obj, "schema"),
        .id = try dupString(a, obj, "id"),
        .version = try dupString(a, obj, "version"),
        .entry = try dupString(a, obj, "entry"),
        .tools = tools,
        .permissions = .{
            .fs = try dupPermissionList(a, obj, "fs"),
            .network = try dupPermissionList(a, obj, "network"),
            .process = try dupPermissionList(a, obj, "process"),
        },
    };
}

fn isValidId(s: []const u8) bool {
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

/// Read a string list out of the nested `permissions` object; absent -> empty.
fn dupPermissionList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]const []const u8 {
    const perms = switch (obj.get("permissions") orelse return a.alloc([]const u8, 0)) {
        .object => |o| o,
        else => return error.WrongType,
    };
    const list = switch (perms.get(key) orelse return a.alloc([]const u8, 0)) {
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

fn compact(a: std.mem.Allocator, value: std.json.Value) ParseError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

const valid_manifest =
    \\{
    \\  "schema": "nulya.extension/v1",
    \\  "id": "web.search",
    \\  "version": "0.1.0",
    \\  "entry": "bin/web-search",
    \\  "tools": [{
    \\    "name": "web_search",
    \\    "description": "Search the web.",
    \\    "input": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }
    \\  }],
    \\  "permissions": { "fs": [], "network": ["https"], "process": [] }
    \\}
;

test "parses and validates a well-formed manifest" {
    var m = try parse(std.testing.allocator, valid_manifest);
    defer m.deinit();
    try m.validate();
    try std.testing.expectEqualStrings("web.search", m.id);
    try std.testing.expectEqualStrings("bin/web-search", m.entry);
    try std.testing.expectEqual(@as(usize, 1), m.tools.len);
    try std.testing.expectEqualStrings("web_search", m.tools[0].name);
    try std.testing.expect(std.mem.indexOf(u8, m.tools[0].input_schema, "query") != null);
    try std.testing.expectEqual(@as(usize, 1), m.permissions.network.len);
    try std.testing.expectEqualStrings("https", m.permissions.network[0]);
}

test "rejects wrong schema" {
    const src =
        \\{"schema":"other/v9","id":"a","version":"1","entry":"bin/a","tools":[{"name":"t","input":{}}]}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.UnsupportedSchema, m.validate());
}

test "rejects reserved tool name" {
    const src =
        \\{"schema":"nulya.extension/v1","id":"a","version":"1","entry":"bin/a","tools":[{"name":"shell","input":{}}]}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.ReservedToolName, m.validate());
}

test "rejects duplicate tool names" {
    const src =
        \\{"schema":"nulya.extension/v1","id":"a","version":"1","entry":"bin/a","tools":[{"name":"t","input":{}},{"name":"t","input":{}}]}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.DuplicateToolName, m.validate());
}

test "rejects entry that escapes the extension dir" {
    const src =
        \\{"schema":"nulya.extension/v1","id":"a","version":"1","entry":"../evil","tools":[{"name":"t","input":{}}]}
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectError(error.InvalidEntry, m.validate());
}

test "missing required field is a parse error" {
    const src =
        \\{"schema":"nulya.extension/v1","id":"a","tools":[]}
    ;
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, src));
}
