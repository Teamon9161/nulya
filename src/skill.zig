//! Core Agent Skill metadata and session catalog semantics. Source-agnostic:
//! extensions, MCP or local files all produce the same `SkillDescriptor` values.

const std = @import("std");

pub const SkillDescriptor = struct {
    ref: []const u8,
    name: []const u8,
    description: []const u8,
    /// A manual rather than a method: it stays out of the session catalogue
    /// and is reached by asking for it. Declared by the contributing package
    /// (`contributes.skills[].surface`); every other producer leaves it false.
    reference: bool = false,
};

pub const SkillSetSnapshot = struct {
    skills: []const SkillDescriptor,

    pub fn deinit(self: SkillSetSnapshot, alloc: std.mem.Allocator) void {
        for (self.skills) |s| {
            alloc.free(s.ref);
            alloc.free(s.name);
            alloc.free(s.description);
        }
        alloc.free(self.skills);
    }

    /// The `<available_skills>` block, or null when this session has nothing
    /// to advertise. `reference` skills are never advertised: they stay in the
    /// snapshot and stay loadable by ref, and a set holding nothing else
    /// yields no block at all rather than an empty heading.
    pub fn catalogText(self: SkillSetSnapshot, alloc: std.mem.Allocator) !?[]u8 {
        var listed: usize = 0;
        for (self.skills) |s| {
            if (!s.reference) listed += 1;
        }
        if (listed == 0) return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "Available skills:\n");
        for (self.skills) |s| {
            if (s.reference) continue;
            try out.print(alloc, "- {s} — {s}\n  load: nulya skill load {s}\n", .{ s.name, s.description, s.ref });
        }
        return try out.toOwnedSlice(alloc);
    }
};

pub const SkillFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

pub fn parseFrontmatter(bytes: []const u8) !SkillFrontmatter {
    if (!std.mem.startsWith(u8, bytes, "---")) return error.MissingSkillFrontmatter;
    var pos: usize = 3;
    if (pos < bytes.len and bytes[pos] == '\r') pos += 1;
    if (pos >= bytes.len or bytes[pos] != '\n') return error.MissingSkillFrontmatter;
    pos += 1;

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    while (pos <= bytes.len) {
        const line_start = pos;
        const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse bytes.len;
        pos = if (nl < bytes.len) nl + 1 else bytes.len + 1;
        var line = std.mem.trim(u8, bytes[line_start..nl], "\r");
        line = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, line, "---")) break;
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = unquote(std.mem.trim(u8, line[colon + 1 ..], " \t"));
        if (std.mem.eql(u8, key, "name")) name = value;
        if (std.mem.eql(u8, key, "description")) description = value;
    } else return error.MissingSkillFrontmatterEnd;

    const metadata: SkillFrontmatter = .{
        .name = name orelse return error.MissingSkillName,
        .description = description orelse return error.MissingSkillDescription,
    };
    try validateMetadata(metadata);
    return metadata;
}

pub fn validateMetadata(metadata: SkillFrontmatter) !void {
    if (!isValidName(metadata.name)) return error.InvalidSkillName;
    if (metadata.description.len == 0 or metadata.description.len > 1024) return error.InvalidSkillDescription;
}

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;
    var previous_hyphen = false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
        if (c == '-' and previous_hyphen) return false;
        previous_hyphen = c == '-';
    }
    return true;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) return s[1 .. s.len - 1];
    return s;
}

pub fn sortDescriptors(descriptors: []SkillDescriptor) void {
    std.mem.sort(SkillDescriptor, descriptors, {}, struct {
        fn lessThan(_: void, a: SkillDescriptor, b: SkillDescriptor) bool {
            return std.mem.lessThan(u8, a.ref, b.ref);
        }
    }.lessThan);
}

pub fn deinitDescriptorArrayList(alloc: std.mem.Allocator, descriptors: *std.ArrayList(SkillDescriptor)) void {
    for (descriptors.items) |s| {
        alloc.free(s.ref);
        alloc.free(s.name);
        alloc.free(s.description);
    }
    descriptors.deinit(alloc);
}

test "a reference skill is in the snapshot but not in the catalogue, and a set of only those has no catalogue" {
    const alloc = std.testing.allocator;

    const mixed = SkillSetSnapshot{ .skills = &.{
        .{ .ref = "ext:a@v/method", .name = "method", .description = "how to work" },
        .{ .ref = "ext:a@v/manual", .name = "manual", .description = "how to set up", .reference = true },
    } };
    const text = (try mixed.catalogText(alloc)).?;
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "method") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "manual") == null);

    // Not an empty heading: a package whose only skill is a manual contributes
    // nothing to advertise, and saying so with a header would spend the very
    // attention `reference` exists to save.
    const only = SkillSetSnapshot{ .skills = &.{
        .{ .ref = "ext:a@v/manual", .name = "manual", .description = "how to set up", .reference = true },
    } };
    try std.testing.expect(try only.catalogText(alloc) == null);
}

test "parses minimal Agent Skill frontmatter" {
    const fm = try parseFrontmatter("---\nname: risk-parity\ndescription: Construct and analyze risk parity portfolios.\n---\nbody\n");
    try std.testing.expectEqualStrings("risk-parity", fm.name);
    try std.testing.expectEqualStrings("Construct and analyze risk parity portfolios.", fm.description);
}

test "accepts quoted scalar descriptions" {
    const fm = try parseFrontmatter("---\nname: risk-parity\ndescription: \"Construct portfolios.\"\n---\nbody\n");
    try std.testing.expectEqualStrings("Construct portfolios.", fm.description);
}

test "validates Agent Skill name contract" {
    try std.testing.expectError(error.InvalidSkillName, validateMetadata(.{ .name = "RiskParity", .description = "ok" }));
    try std.testing.expectError(error.InvalidSkillName, validateMetadata(.{ .name = "risk--parity", .description = "ok" }));
    try std.testing.expectError(error.InvalidSkillName, validateMetadata(.{ .name = "-risk", .description = "ok" }));
    try std.testing.expectError(error.InvalidSkillName, validateMetadata(.{ .name = "risk-", .description = "ok" }));
}

test "validates Agent Skill description length" {
    try std.testing.expectError(error.InvalidSkillDescription, validateMetadata(.{ .name = "risk", .description = "" }));
    const long = "x" ** 1025;
    try std.testing.expectError(error.InvalidSkillDescription, validateMetadata(.{ .name = "risk", .description = long }));
}
