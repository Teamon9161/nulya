//! Session-scoped Skill contribution catalog.
//!
//! Skills are static Agent Skills-style directories contributed by immutable
//! extension versions. The session catalog exposes only name/description/ref;
//! full `SKILL.md` bodies are loaded on demand from the pinned frozen package.

const std = @import("std");
const manifest = @import("extension/manifest.zig");
const store = @import("extension/store.zig");
const integrity = @import("extension/integrity.zig");

const max_skill_md_bytes: usize = 2 * 1024 * 1024;
const skill_file = "SKILL.md";

pub const SkillDescriptor = struct {
    ref: []const u8,
    name: []const u8,
    description: []const u8,
    extension_id: []const u8,
    extension_version: []const u8,
    frozen_skill_path: []const u8,
};

pub const SkillSetSnapshot = struct {
    skills: []const SkillDescriptor,

    pub fn deinit(self: SkillSetSnapshot, alloc: std.mem.Allocator) void {
        for (self.skills) |s| {
            alloc.free(s.ref);
            alloc.free(s.name);
            alloc.free(s.description);
            alloc.free(s.extension_id);
            alloc.free(s.extension_version);
            alloc.free(s.frozen_skill_path);
        }
        alloc.free(self.skills);
    }

    pub fn catalogText(self: SkillSetSnapshot, alloc: std.mem.Allocator) !?[]u8 {
        if (self.skills.len == 0) return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "Available skills:\n");
        for (self.skills) |s| {
            try out.print(alloc, "- {s} — {s}\n  load: nulya skill load {s}\n", .{ s.name, s.description, s.ref });
        }
        return try out.toOwnedSlice(alloc);
    }
};

pub const SkillFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

pub const ParsedSkillRef = struct {
    extension_id: []const u8,
    version: []const u8,
    name: []const u8,
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

    const n = name orelse return error.MissingSkillName;
    const d = description orelse return error.MissingSkillDescription;
    if (n.len == 0) return error.MissingSkillName;
    if (d.len == 0) return error.MissingSkillDescription;
    return .{ .name = n, .description = d };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) return s[1 .. s.len - 1];
    return s;
}

pub fn refFor(alloc: std.mem.Allocator, extension_id: []const u8, version: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "ext:{s}@{s}/{s}", .{ extension_id, version, name });
}

pub fn parseRef(ref: []const u8) !ParsedSkillRef {
    if (!std.mem.startsWith(u8, ref, "ext:")) return error.InvalidSkillRef;
    const rest = ref[4..];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return error.InvalidSkillRef;
    const slash = std.mem.indexOfScalarPos(u8, rest, at + 1, '/') orelse return error.InvalidSkillRef;
    if (at == 0 or slash == at + 1 or slash + 1 >= rest.len) return error.InvalidSkillRef;
    return .{
        .extension_id = rest[0..at],
        .version = rest[at + 1 .. slash],
        .name = rest[slash + 1 ..],
    };
}

pub fn appendFromManifest(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    descriptors: *std.ArrayList(SkillDescriptor),
    extension_id: []const u8,
    version: []const u8,
    m: manifest.Manifest,
) !void {
    for (m.skills) |skill_path| {
        const frozen_dir = try std.fs.path.join(alloc, &.{ extension_id, "versions", version, integrity.package_dir, skill_path });
        defer alloc.free(frozen_dir);
        const skill_md = try std.fs.path.join(alloc, &.{ frozen_dir, skill_file });
        defer alloc.free(skill_md);
        const bytes = try root.readFileAlloc(io, skill_md, alloc, .limited(max_skill_md_bytes));
        defer alloc.free(bytes);
        const fm = try parseFrontmatter(bytes);
        const ref = try refFor(alloc, extension_id, version, fm.name);
        errdefer alloc.free(ref);
        const name = try alloc.dupe(u8, fm.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, fm.description);
        errdefer alloc.free(description);
        const owned_extension_id = try alloc.dupe(u8, extension_id);
        errdefer alloc.free(owned_extension_id);
        const owned_extension_version = try alloc.dupe(u8, version);
        errdefer alloc.free(owned_extension_version);
        const frozen_skill_path = try alloc.dupe(u8, frozen_dir);
        errdefer alloc.free(frozen_skill_path);
        try descriptors.append(alloc, .{
            .ref = ref,
            .name = name,
            .description = description,
            .extension_id = owned_extension_id,
            .extension_version = owned_extension_version,
            .frozen_skill_path = frozen_skill_path,
        });
    }
}

/// Load a full SKILL.md body from a pinned ref. This deliberately validates and
/// reads the named frozen version; it never follows the extension's `current`.
pub fn loadPinned(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    pinned_ref: []const u8,
) ![]u8 {
    const parsed = try parseRef(pinned_ref);
    const st = store.Store.init(io, root);
    if (!st.versionExists(alloc, parsed.extension_id, parsed.version)) return error.VersionIntegrityInvalid;

    const manifest_rel = try st.versionManifestPath(alloc, parsed.extension_id, parsed.version);
    defer alloc.free(manifest_rel);
    const manifest_bytes = try root.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20));
    defer alloc.free(manifest_bytes);
    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();

    for (m.skills) |skill_path| {
        const skill_md = try std.fs.path.join(alloc, &.{ parsed.extension_id, "versions", parsed.version, integrity.package_dir, skill_path, skill_file });
        defer alloc.free(skill_md);
        const bytes = try root.readFileAlloc(io, skill_md, alloc, .limited(max_skill_md_bytes));
        errdefer alloc.free(bytes);
        const fm = try parseFrontmatter(bytes);
        if (std.mem.eql(u8, fm.name, parsed.name)) return bytes;
        alloc.free(bytes);
    }
    return error.SkillNotFound;
}

pub fn sortDescriptors(descriptors: []SkillDescriptor) void {
    std.mem.sort(SkillDescriptor, descriptors, {}, struct {
        fn lessThan(_: void, a: SkillDescriptor, b: SkillDescriptor) bool {
            return std.mem.lessThan(u8, a.ref, b.ref);
        }
    }.lessThan);
}

pub fn freeDescriptorList(alloc: std.mem.Allocator, descriptors: []SkillDescriptor) void {
    (SkillSetSnapshot{ .skills = descriptors }).deinit(alloc);
}

test "parses minimal Agent Skill frontmatter" {
    const fm = try parseFrontmatter("---\nname: risk-parity\ndescription: Construct and analyze risk parity portfolios.\n---\nbody\n");
    try std.testing.expectEqualStrings("risk-parity", fm.name);
    try std.testing.expectEqualStrings("Construct and analyze risk parity portfolios.", fm.description);
}

test "pinned skill refs round-trip" {
    const alloc = std.testing.allocator;
    const ref = try refFor(alloc, "finance", "v-a83fe2", "risk-parity");
    defer alloc.free(ref);
    try std.testing.expectEqualStrings("ext:finance@v-a83fe2/risk-parity", ref);
    const parsed = try parseRef(ref);
    try std.testing.expectEqualStrings("finance", parsed.extension_id);
    try std.testing.expectEqualStrings("v-a83fe2", parsed.version);
    try std.testing.expectEqualStrings("risk-parity", parsed.name);
}
