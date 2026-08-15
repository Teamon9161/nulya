//! Session-scoped capability composition.
//!
//! The composition freezes extension-derived capabilities once at
//! `AgentSession.init()`. The unified part is lifecycle/pinning; Tool, Skill,
//! and System Prompt snapshots stay strongly typed and keep their own semantics.

const std = @import("std");
const registry = @import("registry.zig");
const prompt = @import("prompt.zig");
const skill = @import("skill.zig");
const manifest = @import("extension/manifest.zig");
const store = @import("extension/store.zig");
const integrity = @import("extension/integrity.zig");

const max_prompt_bytes: usize = 2 * 1024 * 1024;

const kernel_system_prompt =
    "You are Nulya, a minimal self-evolving agent harness. " ++
    "The model-facing builtin tools are shell and edit; extension capabilities are invoked through the nulya CLI.";

pub const PinnedExtension = struct {
    id: []const u8,
    version: []const u8,
};

pub const SessionComposition = struct {
    pinned_extensions: []const PinnedExtension,
    tools: registry.ToolSetSnapshot,
    skills: skill.SkillSetSnapshot,
    system_prompts: prompt.SystemPromptSnapshot,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        ext_root_rel: []const u8,
    ) !SessionComposition {
        const tools = try registry.snapshot(alloc);
        errdefer tools.deinit(alloc);

        const pinned = try resolvePinnedExtensions(alloc, io, cwd, ext_root_rel);
        errdefer freePinned(alloc, pinned);
        sortPinned(pinned);

        var root = openExtRoot(io, cwd, ext_root_rel) catch |err| switch (err) {
            error.FileNotFound => {
                const skills = skill.SkillSetSnapshot{ .skills = try alloc.alloc(skill.SkillDescriptor, 0) };
                errdefer skills.deinit(alloc);
                const system_prompts = try buildSystemPrompts(alloc, null, pinned, skills);
                return .{ .pinned_extensions = pinned, .tools = tools, .skills = skills, .system_prompts = system_prompts };
            },
            else => return err,
        };
        defer root.close(io);

        var descriptors: std.ArrayList(skill.SkillDescriptor) = .empty;
        errdefer skill.freeDescriptorList(alloc, descriptors.items);
        try appendSkillsFromPins(alloc, io, root, pinned, &descriptors);
        skill.sortDescriptors(descriptors.items);
        const skills = skill.SkillSetSnapshot{ .skills = try descriptors.toOwnedSlice(alloc) };
        errdefer skills.deinit(alloc);

        const system_prompts = try buildSystemPrompts(alloc, .{ .io = io, .root = root }, pinned, skills);
        errdefer system_prompts.deinit(alloc);

        return .{ .pinned_extensions = pinned, .tools = tools, .skills = skills, .system_prompts = system_prompts };
    }

    pub fn deinit(self: SessionComposition, alloc: std.mem.Allocator) void {
        self.tools.deinit(alloc);
        self.skills.deinit(alloc);
        self.system_prompts.deinit(alloc);
        freePinned(alloc, self.pinned_extensions);
    }
};

const OpenRoot = struct { io: std.Io, root: std.Io.Dir };

fn resolvePinnedExtensions(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, ext_root_rel: []const u8) ![]PinnedExtension {
    var root = openExtRoot(io, cwd, ext_root_rel) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc(PinnedExtension, 0),
        else => return err,
    };
    defer root.close(io);
    const st = store.Store.init(io, root);

    var pins: std.ArrayList(PinnedExtension) = .empty;
    errdefer freePinned(alloc, pins.items);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const active = (st.activeVersion(alloc, entry.name) catch continue) orelse continue;
        defer alloc.free(active);
        if (!st.versionExists(alloc, entry.name, active)) continue;
        const id = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(id);
        const version = try alloc.dupe(u8, active);
        errdefer alloc.free(version);
        try pins.append(alloc, .{ .id = id, .version = version });
    }
    return pins.toOwnedSlice(alloc);
}

fn appendSkillsFromPins(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    pins: []const PinnedExtension,
    descriptors: *std.ArrayList(skill.SkillDescriptor),
) !void {
    for (pins) |pin| {
        var m = try readPinnedManifest(alloc, io, root, pin);
        defer m.deinit();
        try skill.appendFromManifest(alloc, io, root, descriptors, pin.id, pin.version, m);
    }
}

fn buildSystemPrompts(
    alloc: std.mem.Allocator,
    open_root: ?OpenRoot,
    pins: []const PinnedExtension,
    skills: skill.SkillSetSnapshot,
) !prompt.SystemPromptSnapshot {
    var blocks: std.ArrayList(prompt.SystemBlock) = .empty;
    errdefer (prompt.SystemPromptSnapshot{ .blocks = blocks.items }).deinit(alloc);

    try appendSystemBlock(alloc, &blocks, "kernel", kernel_system_prompt);

    if (open_root) |opened| {
        for (pins) |pin| {
            var m = try readPinnedManifest(alloc, opened.io, opened.root, pin);
            defer m.deinit();
            for (m.system_prompts) |prompt_path| {
                const source = try std.fmt.allocPrint(alloc, "ext:{s}@{s}/{s}", .{ pin.id, pin.version, prompt_path });
                defer alloc.free(source);
                const rel = try std.fs.path.join(alloc, &.{ pin.id, "versions", pin.version, integrity.package_dir, prompt_path });
                defer alloc.free(rel);
                const bytes = try opened.root.readFileAlloc(opened.io, rel, alloc, .limited(max_prompt_bytes));
                defer alloc.free(bytes);
                try appendSystemBlock(alloc, &blocks, source, bytes);
            }
        }
    }

    if (try skills.catalogText(alloc)) |catalog| {
        defer alloc.free(catalog);
        try appendSystemBlock(alloc, &blocks, "skills:catalog", catalog);
    }

    return .{ .blocks = try blocks.toOwnedSlice(alloc) };
}

fn appendSystemBlock(alloc: std.mem.Allocator, blocks: *std.ArrayList(prompt.SystemBlock), source: []const u8, bytes: []const u8) !void {
    const owned_source = try alloc.dupe(u8, source);
    errdefer alloc.free(owned_source);
    const owned_bytes = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned_bytes);
    try blocks.append(alloc, .{ .source = owned_source, .bytes = owned_bytes });
}

fn readPinnedManifest(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, pin: PinnedExtension) !manifest.Manifest {
    const st = store.Store.init(io, root);
    if (!st.versionExists(alloc, pin.id, pin.version)) return error.VersionIntegrityInvalid;
    const manifest_rel = try st.versionManifestPath(alloc, pin.id, pin.version);
    defer alloc.free(manifest_rel);
    const bytes = try root.readFileAlloc(io, manifest_rel, alloc, .limited(1 << 20));
    defer alloc.free(bytes);
    var m = try manifest.parse(alloc, bytes);
    errdefer m.deinit();
    try m.validate();
    return m;
}

fn openExtRoot(io: std.Io, cwd: []const u8, ext_root_rel: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(ext_root_rel)) {
        return std.Io.Dir.openDirAbsolute(io, ext_root_rel, .{ .iterate = true });
    }
    var workspace = if (std.fs.path.isAbsolute(cwd))
        try std.Io.Dir.openDirAbsolute(io, cwd, .{})
    else
        try std.Io.Dir.cwd().openDir(io, cwd, .{});
    defer workspace.close(io);
    return workspace.openDir(io, ext_root_rel, .{ .iterate = true });
}

fn sortPinned(pins: []PinnedExtension) void {
    std.mem.sort(PinnedExtension, pins, {}, struct {
        fn lessThan(_: void, a: PinnedExtension, b: PinnedExtension) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
}

fn freePinned(alloc: std.mem.Allocator, pins: []const PinnedExtension) void {
    for (pins) |pin| {
        alloc.free(pin.id);
        alloc.free(pin.version);
    }
    alloc.free(pins);
}

pub fn testingKernelPrompt() []const u8 {
    return kernel_system_prompt;
}

const FileSpec = struct { rel: []const u8, bytes: []const u8 };

fn writeStaticVersion(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    id: []const u8,
    manifest_bytes: []const u8,
    extra_files: []const FileSpec,
) ![]u8 {
    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();

    const files = try alloc.alloc(integrity.SnapshotFile, extra_files.len + 1);
    files[0] = .{ .rel = try alloc.dupe(u8, integrity.manifest_file), .bytes = try alloc.dupe(u8, manifest_bytes) };
    for (extra_files, 0..) |file, i| {
        files[i + 1] = .{ .rel = try alloc.dupe(u8, file.rel), .bytes = try alloc.dupe(u8, file.bytes) };
    }
    std.mem.sort(integrity.SnapshotFile, files, {}, lessSnapshotFileRel);
    const snapshot: integrity.PackageSnapshot = .{ .files = files };
    defer snapshot.deinit(alloc);

    const canonical = try snapshot.canonicalBytes(alloc);
    defer alloc.free(canonical);
    const compiler = "zig test";
    const target = "test-target";
    const version = try integrity.versionId(alloc, canonical, compiler, target);
    errdefer alloc.free(version);

    const version_rel = try std.fs.path.join(alloc, &.{ id, "versions", version });
    defer alloc.free(version_rel);
    try integrity.freezeSnapshot(alloc, io, root, version_rel, manifest_bytes, snapshot);
    const package_digest = try integrity.packageDigestHex(alloc, snapshot);
    defer alloc.free(package_digest);
    const seal = try integrity.sealJson(alloc, package_digest, compiler, target, null);
    defer alloc.free(seal);
    const seal_rel = try std.fs.path.join(alloc, &.{ version_rel, integrity.seal_file });
    defer alloc.free(seal_rel);
    try root.writeFile(io, .{ .sub_path = seal_rel, .data = seal });
    return version;
}

fn lessSnapshotFileRel(_: void, a: integrity.SnapshotFile, b: integrity.SnapshotFile) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}

fn tmpPath(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return try alloc.dupe(u8, buf[0..len]);
}

fn activateVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, version: []const u8) !void {
    var iter_root = try root.openDir(io, ".", .{ .iterate = true });
    defer iter_root.close(io);
    try store.Store.init(io, iter_root).activate(alloc, id, version);
}

test "session composition pins active extension versions for the session" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_v1 =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const manifest_v2 =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const skill_v1 = "---\nname: risk-parity\ndescription: v1 skill\n---\nv1 body\n";
    const skill_v2 = "---\nname: risk-parity\ndescription: v2 skill\n---\nv2 body\n";
    const v1 = try writeStaticVersion(alloc, io, tmp.dir, "finance", manifest_v1, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = skill_v1 }});
    defer alloc.free(v1);
    const v2 = try writeStaticVersion(alloc, io, tmp.dir, "finance", manifest_v2, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = skill_v2 }});
    defer alloc.free(v2);

    try activateVersion(alloc, io, tmp.dir, "finance", v1);
    var first = try SessionComposition.init(alloc, io, cwd, ".");
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), first.pinned_extensions.len);
    try std.testing.expectEqualStrings(v1, first.pinned_extensions[0].version);
    try std.testing.expectEqualStrings("v1 skill", first.skills.skills[0].description);
    try std.testing.expectEqual(@as(usize, 2), first.system_prompts.blocks.len);
    try std.testing.expectEqualStrings("skills:catalog", first.system_prompts.blocks[1].source);
    try std.testing.expect(std.mem.indexOf(u8, first.system_prompts.blocks[1].bytes, first.skills.skills[0].ref) != null);

    try activateVersion(alloc, io, tmp.dir, "finance", v2);
    try std.testing.expectEqualStrings(v1, first.pinned_extensions[0].version);
    try std.testing.expectEqualStrings("v1 skill", first.skills.skills[0].description);

    var second = try SessionComposition.init(alloc, io, cwd, ".");
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings(v2, second.pinned_extensions[0].version);
    try std.testing.expectEqualStrings("v2 skill", second.skills.skills[0].description);
}

test "pinned skill load survives current changes and absent draft source" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const v1 = try writeStaticVersion(alloc, io, tmp.dir, "finance", manifest_bytes, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = "---\nname: risk-parity\ndescription: v1 skill\n---\nv1 body\n" }});
    defer alloc.free(v1);
    const v2 = try writeStaticVersion(alloc, io, tmp.dir, "finance", manifest_bytes, &.{.{ .rel = "skills/risk-parity/SKILL.md", .bytes = "---\nname: risk-parity\ndescription: v2 skill\n---\nv2 body\n" }});
    defer alloc.free(v2);
    try activateVersion(alloc, io, tmp.dir, "finance", v1);

    var comp = try SessionComposition.init(alloc, io, cwd, ".");
    defer comp.deinit(alloc);
    const ref = try alloc.dupe(u8, comp.skills.skills[0].ref);
    defer alloc.free(ref);

    try activateVersion(alloc, io, tmp.dir, "finance", v2);
    var root = try tmp.dir.openDir(io, ".", .{});
    defer root.close(io);
    const body = try skill.loadPinned(alloc, io, root, ref);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "v1 body") != null);
}

test "inactive extension contributions do not enter composition" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_bytes =
        \\{"schema":"nulya.extension/v2","id":"inactive","contributes":{"skills":["skills/demo"],"system_prompts":["prompts/base.md"]}}
    ;
    const version = try writeStaticVersion(alloc, io, tmp.dir, "inactive", manifest_bytes, &.{
        .{ .rel = "skills/demo/SKILL.md", .bytes = "---\nname: demo\ndescription: demo skill\n---\nbody\n" },
        .{ .rel = "prompts/base.md", .bytes = "inactive prompt\n" },
    });
    defer alloc.free(version);

    var comp = try SessionComposition.init(alloc, io, cwd, ".");
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), comp.pinned_extensions.len);
    try std.testing.expectEqual(@as(usize, 0), comp.skills.skills.len);
    try std.testing.expectEqual(@as(usize, 1), comp.system_prompts.blocks.len); // kernel only
}

test "system prompt ordering is deterministic by pinned extension id and manifest order" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmpPath(alloc, io, tmp.dir);
    defer alloc.free(cwd);

    const manifest_b =
        \\{"schema":"nulya.extension/v2","id":"b","contributes":{"system_prompts":["prompts/b1.md"]}}
    ;
    const manifest_a =
        \\{"schema":"nulya.extension/v2","id":"a","contributes":{"system_prompts":["prompts/a1.md","prompts/a2.md"]}}
    ;
    const vb = try writeStaticVersion(alloc, io, tmp.dir, "b", manifest_b, &.{.{ .rel = "prompts/b1.md", .bytes = "B1" }});
    defer alloc.free(vb);
    const va = try writeStaticVersion(alloc, io, tmp.dir, "a", manifest_a, &.{
        .{ .rel = "prompts/a1.md", .bytes = "A1" },
        .{ .rel = "prompts/a2.md", .bytes = "A2" },
    });
    defer alloc.free(va);
    try activateVersion(alloc, io, tmp.dir, "b", vb);
    try activateVersion(alloc, io, tmp.dir, "a", va);

    var comp = try SessionComposition.init(alloc, io, cwd, ".");
    defer comp.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), comp.system_prompts.blocks.len);
    try std.testing.expectEqualStrings("kernel", comp.system_prompts.blocks[0].source);
    try std.testing.expectEqualStrings("A1", comp.system_prompts.blocks[1].bytes);
    try std.testing.expectEqualStrings("A2", comp.system_prompts.blocks[2].bytes);
    try std.testing.expectEqualStrings("B1", comp.system_prompts.blocks[3].bytes);
}
