//! Extension-backed Agent Skill source.
//!
//! This adapter knows frozen versions, manifests and
//! `ext:<id>@<version>/<skill>` refs, so `skill.zig` stays source-agnostic.

const std = @import("std");
const skill = @import("../skill.zig");
const manifest = @import("manifest.zig");
const store = @import("store.zig");
const site_mod = @import("site.zig");
const integrity = @import("integrity.zig");

pub const max_skill_md_bytes: usize = 2 * 1024 * 1024;
const skill_file = "SKILL.md";

pub const ParsedRef = struct {
    extension_id: []const u8,
    version: []const u8,
    name: []const u8,
};

pub fn refFor(alloc: std.mem.Allocator, extension_id: []const u8, version: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "ext:{s}@{s}/{s}", .{ extension_id, version, name });
}

pub fn parseRef(ref: []const u8) !ParsedRef {
    if (!std.mem.startsWith(u8, ref, "ext:")) return error.InvalidSkillRef;
    const rest = ref[4..];
    const at = std.mem.indexOfScalar(u8, rest, '@') orelse return error.InvalidSkillRef;
    const slash = std.mem.indexOfScalarPos(u8, rest, at + 1, '/') orelse return error.InvalidSkillRef;
    if (at == 0 or slash == at + 1 or slash + 1 >= rest.len) return error.InvalidSkillRef;
    const name = rest[slash + 1 ..];
    if (!manifest.isValidId(rest[0..at])) return error.InvalidSkillRef;
    if (!integrity.isVersionId(rest[at + 1 .. slash])) return error.InvalidSkillRef;
    if (!skill.isValidName(name)) return error.InvalidSkillRef;
    return .{
        .extension_id = rest[0..at],
        .version = rest[at + 1 .. slash],
        .name = name,
    };
}

pub fn appendFromManifest(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    descriptors: *std.ArrayList(skill.SkillDescriptor),
    extension_id: []const u8,
    version: []const u8,
    m: manifest.Manifest,
) !void {
    for (m.skills) |spec| {
        const skill_path = spec.path;
        const expected_name = basename(skill_path) orelse return error.InvalidSkillDirectoryName;
        if (!skill.isValidName(expected_name)) return error.InvalidSkillDirectoryName;

        const skill_md = try std.fs.path.join(alloc, &.{ extension_id, "versions", version, integrity.package_dir, skill_path, skill_file });
        defer alloc.free(skill_md);
        const bytes = try root.readFileAlloc(io, skill_md, alloc, .limited(max_skill_md_bytes));
        defer alloc.free(bytes);
        const fm = try skill.parseFrontmatter(bytes);
        if (!std.mem.eql(u8, fm.name, expected_name)) return error.SkillNameDoesNotMatchDirectory;

        const ref = try refFor(alloc, extension_id, version, fm.name);
        errdefer alloc.free(ref);
        for (descriptors.items) |existing| {
            if (std.mem.eql(u8, existing.ref, ref)) return error.DuplicateSkillName;
        }
        const name = try alloc.dupe(u8, fm.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, fm.description);
        errdefer alloc.free(description);
        try descriptors.append(alloc, .{
            .ref = ref,
            .name = name,
            .description = description,
            .reference = spec.surfaceOf() == .reference,
        });
    }
}

pub fn validateSnapshot(alloc: std.mem.Allocator, m: manifest.Manifest, snapshot: integrity.PackageSnapshot) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);

    for (m.skills) |spec| {
        const skill_path = spec.path;
        const expected_name = basename(skill_path) orelse return error.InvalidSkillDirectoryName;
        if (!skill.isValidName(expected_name)) return error.InvalidSkillDirectoryName;

        const skill_rel = try integrity.canonicalRel(alloc, skill_path);
        defer alloc.free(skill_rel);
        const skill_md_rel = try integrity.joinCanonical(alloc, skill_rel, skill_file);
        defer alloc.free(skill_md_rel);

        const bytes = integrity.findSnapshotFile(snapshot, skill_md_rel) orelse return error.SkillFileMissing;
        if (bytes.len > max_skill_md_bytes) return error.SkillFileTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const fm = try skill.parseFrontmatter(bytes);
        if (!std.mem.eql(u8, fm.name, expected_name)) return error.SkillNameDoesNotMatchDirectory;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, fm.name)) return error.DuplicateSkillName;
        }
        try names.append(alloc, fm.name);
    }
}

/// Every skill of every extension a pointer names here, workspace winning.
pub fn listActive(
    alloc: std.mem.Allocator,
    site: *const site_mod.Site,
) !skill.SkillSetSnapshot {
    var descriptors: std.ArrayList(skill.SkillDescriptor) = .empty;
    errdefer skill.deinitDescriptorArrayList(alloc, &descriptors);

    const active = try site.listActive(alloc);
    defer site_mod.Site.freeActive(alloc, active);

    for (active) |entry| {
        // Skip broken extensions, but let host cancellation propagate.
        // `.structural`: a catalog only names what a complete version declares —
        // nothing here runs, and the paths that do ask `.sealed` themselves.
        const r = site.resolveEntry(alloc, entry, .structural) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => continue,
        };
        defer r.deinit(alloc);
        try appendFromManifest(alloc, site.io, site.store().?.root, &descriptors, r.id, r.version, r.manifest);
    }
    skill.sortDescriptors(descriptors.items);
    return .{ .skills = try descriptors.toOwnedSlice(alloc) };
}

/// A full SKILL.md body from a frozen skill ref, out of this machine's store.
/// Validates and reads the NAMED version; never follows `current`.
pub fn loadFrozenInStore(
    alloc: std.mem.Allocator,
    site: *const site_mod.Site,
    frozen_ref: []const u8,
) ![]u8 {
    const parsed = try parseRef(frozen_ref); // malformed: fail before touching the store
    // `.sealed`: a loaded body goes straight into the model's context, so this
    // read CONSUMES the frozen bytes rather than listing them.
    const r = try site.resolveVersion(alloc, parsed.extension_id, parsed.version, .sealed);
    defer r.deinit(alloc);
    return readSkillBody(alloc, site.io, site.store().?.root, parsed, r.manifest);
}

pub fn loadFrozen(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    frozen_ref: []const u8,
) ![]u8 {
    const parsed = try parseRef(frozen_ref);
    var m = try readFrozenManifest(alloc, io, root, parsed.extension_id, parsed.version);
    defer m.deinit();
    return readSkillBody(alloc, io, root, parsed, m);
}

/// The body a parsed ref names, from an already-resolved version's manifest and
/// the root holding it. Caller owns the result.
fn readSkillBody(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    parsed: ParsedRef,
    m: manifest.Manifest,
) ![]u8 {
    for (m.skills) |spec| {
        const skill_path = spec.path;
        const expected_name = basename(skill_path) orelse return error.InvalidSkillDirectoryName;
        if (!std.mem.eql(u8, expected_name, parsed.name)) continue;

        const skill_md = try std.fs.path.join(alloc, &.{ parsed.extension_id, "versions", parsed.version, integrity.package_dir, skill_path, skill_file });
        defer alloc.free(skill_md);
        const bytes = try root.readFileAlloc(io, skill_md, alloc, .limited(max_skill_md_bytes));
        errdefer alloc.free(bytes);
        const fm = try skill.parseFrontmatter(bytes);
        if (!std.mem.eql(u8, fm.name, expected_name)) return error.SkillNameDoesNotMatchDirectory;
        return bytes;
    }
    return error.SkillNotFound;
}

fn readFrozenManifest(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, version: []const u8) !manifest.Manifest {
    // The single validate+parse path, so `error.Canceled` is preserved.
    return store.Store.init(io, root).readManifest(alloc, id, version, .sealed);
}

fn basename(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    if (end == 0) return null;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    if (start == end) return null;
    return path[start..end];
}

test "frozen skill refs round-trip" {
    const alloc = std.testing.allocator;
    const version = "v-a83fe2000000000000000000";
    const ref = try refFor(alloc, "finance", version, "risk-parity");
    defer alloc.free(ref);
    try std.testing.expectEqualStrings("ext:finance@v-a83fe2000000000000000000/risk-parity", ref);
    const parsed = try parseRef(ref);
    try std.testing.expectEqualStrings("finance", parsed.extension_id);
    try std.testing.expectEqualStrings(version, parsed.version);
    try std.testing.expectEqualStrings("risk-parity", parsed.name);
}

test "rejects invalid skill refs" {
    try std.testing.expectError(error.InvalidSkillRef, parseRef("ext:finance@v-a83fe2000000000000000000/RiskParity"));
    try std.testing.expectError(error.InvalidSkillRef, parseRef("ext:finance@v-a83fe2000000000000000000/risk--parity"));
    try std.testing.expectError(error.InvalidSkillRef, parseRef("ext:../finance@v-a83fe2000000000000000000/risk-parity"));
    try std.testing.expectError(error.InvalidSkillRef, parseRef("ext:finance@../v-a83fe2000000000000000000/risk-parity"));
    try std.testing.expectError(error.InvalidSkillRef, parseRef("ext:finance@v-a83fe2/risk-parity"));
}
