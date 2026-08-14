//! Bridging the CLI closed loop into a running conversation (DESIGN §5.3).
//!
//! When the agent builds and activates an extension mid-conversation (via
//! `shell` -> `nulya ext …`), the CLI runs in a subprocess and cannot touch the
//! in-memory ledger. The core reconciles instead: it scans the active
//! extensions on disk and, for any that the ledger has not yet announced,
//! appends ONE `tool_available_note`. Because that is a plain append, the prompt
//! prefix stays stable (the cache keeps hitting) and the model can invoke the
//! new tool through `shell` on its next step. Promotion into `tools[]` waits for
//! the next conversation, at zero cache cost (DESIGN §5.1).

const std = @import("std");
const builtin = @import("builtin");
const ledger = @import("../ledger.zig");
const manifest = @import("manifest.zig");
const store = @import("store.zig");

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// Model-facing announcement text for one extension. Deterministic: the same
/// inputs always yield the same bytes, so `containsNoteFor` can detect it.
pub fn noteText(alloc: std.mem.Allocator, id: []const u8, tool: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\New capability available: tool `{s}` from extension `{s}`.
        \\Invoke it through the shell tool: nulya ext run {s} '<json-args>'
    , .{ tool, id, id });
}

/// True if the ledger already announced `id`. Detection keys on the exact
/// ``extension `<id>` `` phrase `noteText` emits.
pub fn containsNoteFor(l: *const ledger.Ledger, alloc: std.mem.Allocator, id: []const u8) !bool {
    const marker = try std.fmt.allocPrint(alloc, "extension `{s}`", .{id});
    defer alloc.free(marker);
    for (l.view()) |event| switch (event) {
        .tool_available_note => |text| if (std.mem.indexOf(u8, text, marker) != null) return true,
        else => {},
    };
    return false;
}

/// Append a `tool_available_note` for every active extension under
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

        if (try containsNoteFor(l, alloc, id)) continue;

        const manifest_sub = st.versionManifestPath(alloc, id, active) catch continue;
        defer alloc.free(manifest_sub);
        const bytes = root.readFileAlloc(io, manifest_sub, alloc, .limited(1 << 20)) catch continue;
        defer alloc.free(bytes);

        var m = manifest.parse(alloc, bytes) catch continue;
        defer m.deinit();
        m.validate() catch continue;

        if (m.tools.len == 0) continue;

        const text = try noteText(alloc, m.id, m.tools[0].name);
        defer alloc.free(text);
        try l.append(.{ .tool_available_note = text });
    }
}

const test_manifest =
    \\{"schema":"nulya.extension/v2","id":"demo","version":"0.1.0","runtime":{"entry":"bin/demo","mode":"oneshot"},
    \\ "contributes":{"tools":[{"name":"greet","input":{}}],"skills":[]},"permissions":{}}
;

test "noteText is deterministic and names the invocation" {
    const alloc = std.testing.allocator;
    const a = try noteText(alloc, "demo", "greet");
    defer alloc.free(a);
    const b = try noteText(alloc, "demo", "greet");
    defer alloc.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "nulya ext run demo") != null);
}

test "sync appends one note per active extension and is idempotent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "demo" ++ std.fs.path.sep_str ++ "versions" ++ std.fs.path.sep_str ++ "v-aaaa" ++ std.fs.path.sep_str ++ "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "demo" ++ std.fs.path.sep_str ++ "extension.json", .data =
        \\{"schema":"nulya.extension/v2","id":"demo","version":"0.2.0","runtime":{"entry":"bin/stale","mode":"oneshot"},"contributes":{"tools":[{"name":"stale","input":{}}],"skills":[]},"permissions":{}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "demo" ++ std.fs.path.sep_str ++ "versions" ++ std.fs.path.sep_str ++ "v-aaaa" ++ std.fs.path.sep_str ++ "extension.json", .data = test_manifest });
    try tmp.dir.writeFile(io, .{ .sub_path = "demo" ++ std.fs.path.sep_str ++ "versions" ++ std.fs.path.sep_str ++ "v-aaaa" ++ std.fs.path.sep_str ++ "bin" ++ std.fs.path.sep_str ++ "demo" ++ exe_suffix, .data = "" });
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    try store.Store.init(io, root).activate(alloc, "demo", "v-aaaa");

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    try syncOpen(alloc, io, &l, root);
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expect(l.view()[0] == .tool_available_note);
    try std.testing.expect(try containsNoteFor(&l, alloc, "demo"));
    try std.testing.expect(std.mem.indexOf(u8, l.view()[0].tool_available_note, "stale") == null);

    // Running again adds nothing.
    try syncOpen(alloc, io, &l, root);
    try std.testing.expectEqual(@as(usize, 1), l.len());
}

test "an inactive extension is not announced" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Built but never activated: no `current` pointer.
    try tmp.dir.createDirPath(io, "demo" ++ std.fs.path.sep_str ++ "versions" ++ std.fs.path.sep_str ++ "v-aaaa");
    try tmp.dir.writeFile(io, .{ .sub_path = "demo" ++ std.fs.path.sep_str ++ "extension.json", .data = test_manifest });
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try syncOpen(alloc, io, &l, root);
    try std.testing.expectEqual(@as(usize, 0), l.len());
}
