//! Bridging the CLI closed loop into a running conversation (DESIGN §5.3).
//!
//! When the agent builds and activates an extension mid-conversation (via
//! `shell` -> `nulya ext …`), the CLI runs in a subprocess and cannot touch the
//! in-memory ledger. The core reconciles instead: it scans the active
//! extensions on disk and, for any active version that the ledger has not yet
//! announced, appends ONE `capability_note`. Because that is a plain append, the
//! prompt prefix stays stable (the cache keeps hitting) and the model can invoke
//! new tools through `shell` or load new skills through `nulya skill load` on its
//! next step. Promotion into `tools[]` waits for the next conversation, at zero
//! cache cost (DESIGN §5.1).

const std = @import("std");
const builtin = @import("builtin");
const ledger = @import("../ledger.zig");
const manifest = @import("manifest.zig");
const ext_skills = @import("skills.zig");
const skill = @import("../skill.zig");
const store = @import("store.zig");
const integrity = @import("integrity.zig");

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// Model-facing announcement text for one active extension version.
/// Deterministic: the same inputs always yield the same bytes, so
/// `containsNoteFor` can detect it.
pub fn noteText(alloc: std.mem.Allocator, id: []const u8, version: []const u8, tools: []const manifest.ToolSpec, skills: []const skill.SkillDescriptor) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.print(alloc, "New capabilities from extension `{s}` version `{s}` are now available:\n", .{ id, version });
    if (tools.len != 0) {
        try out.appendSlice(alloc, "\nTools:\n");
        for (tools) |tool| {
            const description = if (tool.description.len == 0) "No description." else tool.description;
            try out.print(alloc, "- {s} — {s}\n", .{ tool.name, description });
        }
        try out.print(alloc,
            \\  invoke: nulya ext run {s} <tool> '<json-args>'
            \\
        , .{id});
    }
    if (skills.len != 0) {
        try out.appendSlice(alloc, "\nSkills:\n");
        for (skills) |s| {
            try out.print(alloc, "- {s} — {s}\n  load: nulya skill load {s}\n", .{ s.name, s.description, s.ref });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// True if the ledger already announced `id@version`.
pub fn containsNoteFor(l: *const ledger.Ledger, id: []const u8, version: []const u8) !bool {
    for (l.view()) |event| switch (event) {
        .capability_note => |note| if (std.mem.eql(u8, note.id, id) and std.mem.eql(u8, note.version, version)) return true,
        else => {},
    };
    return false;
}

/// Append a `capability_note` for every active extension version under
/// `ext_root_rel` (resolved against `cwd`) that the ledger has not announced yet.
/// Missing root is a no-op.
pub fn syncFromActiveExtensions(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    l: *ledger.Ledger,
    ext_root_rel: []const u8,
) !void {
    var root = openExtRoot(io, cwd, ext_root_rel) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer root.close(io);
    try syncOpen(alloc, io, l, root);
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

/// Reconcile against an already-open extensions directory. Idempotent, and
/// tolerant of malformed extensions (a broken one is skipped, never fatal).
pub fn syncOpen(alloc: std.mem.Allocator, io: std.Io, l: *ledger.Ledger, root: std.Io.Dir) !void {
    const st = store.Store.init(io, root);
    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const id = entry.name;

        const active = (st.activeVersion(alloc, id) catch continue) orelse continue;
        defer alloc.free(active);

        if (!st.versionExists(alloc, id, active)) continue;
        if (try containsNoteFor(l, id, active)) continue;

        const manifest_sub = st.versionManifestPath(alloc, id, active) catch continue;
        defer alloc.free(manifest_sub);
        const bytes = root.readFileAlloc(io, manifest_sub, alloc, .limited(1 << 20)) catch continue;
        defer alloc.free(bytes);

        var m = manifest.parse(alloc, bytes) catch continue;
        defer m.deinit();
        m.validate() catch continue;

        var descriptors: std.ArrayList(skill.SkillDescriptor) = .empty;
        defer skill.deinitDescriptorArrayList(alloc, &descriptors);
        ext_skills.appendFromManifest(alloc, io, root, &descriptors, m.id, active, m) catch continue;
        skill.sortDescriptors(descriptors.items);

        if (m.tools.len == 0 and descriptors.items.len == 0) continue;

        const text = try noteText(alloc, m.id, active, m.tools, descriptors.items);
        defer alloc.free(text);
        try l.append(.{ .capability_note = .{ .id = m.id, .version = active, .text = text } });
    }
}

const test_manifest =
    \\{"schema":"nulya.extension/v2","id":"demo","runtime":{"entry":"bin/demo"},
    \\ "contributes":{"tools":[{"name":"greet","description":"Say hello.","input":{}}],"skills":[]},"permissions":{}}
;

const test_manifest_v2 =
    \\{"schema":"nulya.extension/v2","id":"demo","runtime":{"entry":"bin/demo"},
    \\ "contributes":{"tools":[{"name":"greet","description":"Say hello.","input":{}},{"name":"wave","description":"Wave goodbye.","input":{}}],"skills":[]},"permissions":{}}
;

test "noteText is deterministic and names every invocation" {
    const alloc = std.testing.allocator;
    var m = try manifest.parse(alloc, test_manifest_v2);
    defer m.deinit();
    const a = try noteText(alloc, "demo", "v-bbbb", m.tools, &.{});
    defer alloc.free(a);
    const b = try noteText(alloc, "demo", "v-bbbb", m.tools, &.{});
    defer alloc.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "extension `demo` version `v-bbbb`") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "wave") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "nulya ext run demo <tool>") != null);
}

test "sync appends one note per active extension version and is idempotent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const version = try writeVersion(alloc, io, tmp.dir, "demo", test_manifest);
    defer alloc.free(version);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    try store.Store.init(io, root).activate(alloc, "demo", version);

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try syncOpen(alloc, io, &l, root);
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expect(l.view()[0] == .capability_note);
    try std.testing.expect(try containsNoteFor(&l, "demo", version));
    try std.testing.expect(std.mem.indexOf(u8, l.view()[0].capability_note.text, "stale") == null);

    // Running again adds nothing for the same active version.
    try syncOpen(alloc, io, &l, root);
    try std.testing.expectEqual(@as(usize, 1), l.len());
}

test "activating a new version appends a new note with all tools" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try writeVersion(alloc, io, tmp.dir, "demo", test_manifest);
    defer alloc.free(first);
    const second = try writeVersion(alloc, io, tmp.dir, "demo", test_manifest_v2);
    defer alloc.free(second);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    const st = store.Store.init(io, root);

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try st.activate(alloc, "demo", first);
    try syncOpen(alloc, io, &l, root);
    try st.activate(alloc, "demo", second);
    try syncOpen(alloc, io, &l, root);

    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expect(try containsNoteFor(&l, "demo", first));
    try std.testing.expect(try containsNoteFor(&l, "demo", second));
    try std.testing.expect(std.mem.indexOf(u8, l.view()[1].capability_note.text, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, l.view()[1].capability_note.text, "wave") != null);
}

test "sync announces skill-only active extensions" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const skill_manifest =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const version = try writeVersionWithFiles(alloc, io, tmp.dir, "finance", skill_manifest, &.{.{
        .rel = "skills/risk-parity/SKILL.md",
        .bytes = "---\nname: risk-parity\ndescription: Analyze risk parity portfolios.\n---\nbody\n",
    }});
    defer alloc.free(version);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    try store.Store.init(io, root).activate(alloc, "finance", version);

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try syncOpen(alloc, io, &l, root);

    try std.testing.expectEqual(@as(usize, 1), l.len());
    const text = l.view()[0].capability_note.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "Skills:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "nulya skill load ext:finance@") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "risk-parity") != null);
}

test "an inactive extension is not announced" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Built but never activated: no `current` pointer.
    const version = try writeVersion(alloc, io, tmp.dir, "demo", test_manifest);
    defer alloc.free(version);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try syncOpen(alloc, io, &l, root);
    try std.testing.expectEqual(@as(usize, 0), l.len());
}

const TestFile = struct { rel: []const u8, bytes: []const u8 };

fn writeVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, manifest_bytes: []const u8) ![]u8 {
    return writeVersionWithFiles(alloc, io, root, id, manifest_bytes, &.{});
}

fn writeVersionWithFiles(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, manifest_bytes: []const u8, extra_files: []const TestFile) ![]u8 {
    var m = try manifest.parse(alloc, manifest_bytes);
    defer m.deinit();
    try m.validate();
    const has_runtime = m.runtime != null;

    const source_bytes = "pub fn main() void {}";
    const file_count = extra_files.len + 1 + @intFromBool(has_runtime);
    const files = try alloc.alloc(integrity.SnapshotFile, file_count);
    files[0] = .{ .rel = try alloc.dupe(u8, "extension.json"), .bytes = try alloc.dupe(u8, manifest_bytes) };
    var next: usize = 1;
    if (has_runtime) {
        files[next] = .{ .rel = try alloc.dupe(u8, "src/main.zig"), .bytes = try alloc.dupe(u8, source_bytes) };
        next += 1;
    }
    for (extra_files) |file| {
        files[next] = .{ .rel = try alloc.dupe(u8, file.rel), .bytes = try alloc.dupe(u8, file.bytes) };
        next += 1;
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

    const manifest_sub = try std.fs.path.join(alloc, &.{ id, "versions", version, "extension.json" });
    defer alloc.free(manifest_sub);
    if (std.fs.path.dirname(manifest_sub)) |dir| try root.createDirPath(io, dir);
    try root.writeFile(io, .{ .sub_path = manifest_sub, .data = manifest_bytes });

    if (has_runtime) {
        const src_dir = try std.fs.path.join(alloc, &.{ id, "versions", version, "package", "src" });
        defer alloc.free(src_dir);
        try root.createDirPath(io, src_dir);
        const source_sub = try std.fs.path.join(alloc, &.{ id, "versions", version, "package", "src", "main.zig" });
        defer alloc.free(source_sub);
        try root.writeFile(io, .{ .sub_path = source_sub, .data = source_bytes });

        const bin_dir = try std.fs.path.join(alloc, &.{ id, "versions", version, "bin" });
        defer alloc.free(bin_dir);
        try root.createDirPath(io, bin_dir);
        const entry_sub = try std.fs.path.join(alloc, &.{ id, "versions", version, "bin", "demo" ++ exe_suffix });
        defer alloc.free(entry_sub);
        try root.writeFile(io, .{ .sub_path = entry_sub, .data = "" });
    }

    for (extra_files) |file| {
        const file_sub = try std.fs.path.join(alloc, &.{ id, "versions", version, "package", file.rel });
        defer alloc.free(file_sub);
        if (std.fs.path.dirname(file_sub)) |dir| try root.createDirPath(io, dir);
        try root.writeFile(io, .{ .sub_path = file_sub, .data = file.bytes });
    }

    const package_digest = try integrity.packageDigestHex(alloc, snapshot);
    defer alloc.free(package_digest);
    const binary_digest = if (has_runtime) blk: {
        const entry_sub = try std.fs.path.join(alloc, &.{ id, "versions", version, "bin", "demo" ++ exe_suffix });
        defer alloc.free(entry_sub);
        break :blk try integrity.fileDigestHex(alloc, io, root, entry_sub);
    } else null;
    defer if (binary_digest) |digest| alloc.free(digest);
    const seal = try integrity.sealJson(alloc, package_digest, compiler, target, binary_digest);
    defer alloc.free(seal);
    const seal_sub = try std.fs.path.join(alloc, &.{ id, "versions", version, "seal.json" });
    defer alloc.free(seal_sub);
    try root.writeFile(io, .{ .sub_path = seal_sub, .data = seal });

    return version;
}

fn lessSnapshotFileRel(_: void, a: integrity.SnapshotFile, b: integrity.SnapshotFile) bool {
    return std.mem.lessThan(u8, a.rel, b.rel);
}
