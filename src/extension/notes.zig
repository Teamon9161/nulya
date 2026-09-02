//! Capability notes: announcing a newly active extension version to a running
//! conversation.
//!
//! When the agent builds and activates an extension mid-conversation (via
//! `shell` -> `nulya ext …`), the CLI runs in a subprocess and cannot touch the
//! session's ledger — the session file has one writer. So the CLI, when
//! `NULYA_SESSION` names the session file, deposits a `note` into the
//! session's inbox (`ledger.depositEvent`); the session drains it at its next
//! step boundary as a plain append. Promotion into `tools[]` still waits for
//! the next session.
//!
//! This module owns only what a note SAYS. The inbox mechanics live in
//! `ledger.zig`; the drain is `AgentSession.prepareStep`.

const std = @import("std");
const ledger = @import("../ledger.zig");
const manifest = @import("manifest.zig");
const ext_skills = @import("skills.zig");
const skill = @import("../skill.zig");
const store = @import("store.zig");
const testkit = @import("testkit.zig");

/// Model-facing announcement text for one active extension version.
/// Deterministic: the same inputs always yield the same bytes.
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

/// Deterministic model-facing announcement for one active extension version, or
/// null when the version declares nothing to announce (no tools, no skills) or
/// cannot be read. `root` is the extensions store root. Caller owns the result.
pub fn buildActiveNoteText(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, version: []const u8) !?[]u8 {
    const st = store.Store.init(io, root);
    var m = st.readManifest(alloc, id, version, .structural) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer m.deinit();

    var descriptors: std.ArrayList(skill.SkillDescriptor) = .empty;
    defer skill.deinitDescriptorArrayList(alloc, &descriptors);
    ext_skills.appendFromManifest(alloc, io, root, &descriptors, m.id, version, m) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    skill.sortDescriptors(descriptors.items);

    if (m.tools.len == 0 and descriptors.items.len == 0) return null;
    return try noteText(alloc, m.id, version, m.tools, descriptors.items);
}

/// Deposit a capability note for active `id@version` into the session inbox, so
/// the session process appends it at its next step boundary. `base` is the
/// directory `session_path` is relative to (or `cwd()` when `session_path` is
/// absolute); `ext_root` is the extensions store. A version with nothing to
/// announce deposits nothing. Idempotent per active version: the deposit name is
/// `note-<id>-<version>`, and the drain skips a note the ledger already holds.
pub fn depositActiveNote(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    session_path: []const u8,
    ext_root: std.Io.Dir,
    id: []const u8,
    version: []const u8,
) !void {
    const text = (try buildActiveNoteText(alloc, io, ext_root, id, version)) orelse return;
    defer alloc.free(text);
    const name = try std.fmt.allocPrint(alloc, "note-{s}-{s}", .{ id, version });
    defer alloc.free(name);
    const meta = try std.json.Stringify.valueAlloc(alloc, .{ .id = id, .version = version }, .{});
    defer alloc.free(meta);
    try ledger.depositEvent(alloc, io, base, session_path, name, .{ .note = .{
        .source = ledger.note_source_ext,
        .text = text,
        .meta = meta,
    } });
}

const test_manifest =
    \\{"schema":"nulya.extension/v2","id":"demo","runtime":{"entry":"bin/demo"},
    \\ "contributes":{"tools":[{"name":"greet","description":"Say hello.","input":{}}],"skills":[]}}
;

const test_manifest_v2 =
    \\{"schema":"nulya.extension/v2","id":"demo","runtime":{"entry":"bin/demo"},
    \\ "contributes":{"tools":[{"name":"greet","description":"Say hello.","input":{}},{"name":"wave","description":"Wave goodbye.","input":{}}],"skills":[]}}
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

const session_rel = ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s.jsonl";

/// A deposit goes into a session that EXISTS (`ledger.depositEventLeased`
/// refuses one that does not), so the tests below put a file where the ledger
/// they drain into would have written one.
fn touchSession(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, comptime std.fs.path.dirname(session_rel).?);
    try dir.writeFile(io, .{ .sub_path = session_rel, .data = "" });
}

test "a deposited note is drained into the ledger and is idempotent" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try touchSession(io, tmp.dir);

    const version = try writeVersion(alloc, io, tmp.dir, "demo", test_manifest);
    defer alloc.free(version);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    try store.Store.init(io, root).activate(alloc, "demo", version);

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();

    // The CLI deposits; the session drains at its step boundary.
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", version);
    try ledger.drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expect(l.view()[0] == .note);
    try std.testing.expectEqualStrings(ledger.note_source_ext, l.view()[0].note.source);
    try std.testing.expect(std.mem.indexOf(u8, l.view()[0].note.meta, version) != null);

    // Draining again with an empty inbox adds nothing.
    try ledger.drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try std.testing.expectEqual(@as(usize, 1), l.len());

    // A re-deposit of the same active version reuses the delivery name, which is
    // the exactly-once key, so the drain applies nothing.
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", version);
    try ledger.drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try std.testing.expectEqual(@as(usize, 1), l.len());
}

test "activating a new version deposits a new note with all tools" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try touchSession(io, tmp.dir);

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
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", first);
    try ledger.drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try st.activate(alloc, "demo", second);
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", second);
    try ledger.drainInbox(alloc, io, &l, tmp.dir, session_rel);

    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expect(std.mem.indexOf(u8, l.view()[0].note.meta, first) != null);
    try std.testing.expect(std.mem.indexOf(u8, l.view()[1].note.meta, second) != null);
    try std.testing.expect(std.mem.indexOf(u8, l.view()[1].note.text, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, l.view()[1].note.text, "wave") != null);
}

test "a deposited skill-only note announces its skills" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try touchSession(io, tmp.dir);

    const skill_manifest =
        \\{"schema":"nulya.extension/v2","id":"finance","contributes":{"skills":["skills/risk-parity"]}}
    ;
    const version = try testkit.writeFrozenVersion(alloc, io, tmp.dir, "finance", skill_manifest, &.{.{
        .rel = "skills/risk-parity/SKILL.md",
        .bytes = "---\nname: risk-parity\ndescription: Analyze risk parity portfolios.\n---\nbody\n",
    }});
    defer alloc.free(version);
    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    try store.Store.init(io, root).activate(alloc, "finance", version);

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "finance", version);
    try ledger.drainInbox(alloc, io, &l, tmp.dir, session_rel);

    try std.testing.expectEqual(@as(usize, 1), l.len());
    const text = l.view()[0].note.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "Skills:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "nulya skill load ext:finance@") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "risk-parity") != null);
}

fn writeVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, manifest_bytes: []const u8) ![]u8 {
    return testkit.writeFrozenVersion(alloc, io, root, id, manifest_bytes, &.{});
}
