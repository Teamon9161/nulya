//! Bridging the CLI closed loop into a running conversation (DESIGN §5.3, §3).
//!
//! When the agent builds and activates an extension mid-conversation (via
//! `shell` -> `nulya ext …`), the CLI runs in a subprocess and cannot touch the
//! session's in-memory ledger — and it must not append to the session file
//! directly either, because that file has a single writer (the session process)
//! and an interleaved write could land a note inside a tool batch. Instead the
//! CLI, when `NULYA_SESSION` names the session file, DEPOSITS the note as one
//! uniquely-named file in the sibling `<stem>.inbox/` directory. The session
//! DRAINS that inbox at each step boundary (`prepareStep`, after any interrupted
//! batch is repaired), appending one `capability_note` per new active version.
//!
//! Because the drain runs only at a step boundary and is a plain append, the
//! prompt prefix stays stable (the cache keeps hitting), the batch invariant
//! (assistant-with-calls ↔ one tool_results) is never split, and the model can
//! invoke new tools through `shell` or load skills through `nulya skill load` on
//! its next step. Promotion into `tools[]` waits for the next session, at zero
//! cache cost (DESIGN §5.1).

const std = @import("std");
const ledger = @import("../ledger.zig");
const manifest = @import("manifest.zig");
const ext_skills = @import("skills.zig");
const skill = @import("../skill.zig");
const store = @import("store.zig");
const testkit = @import("testkit.zig");

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

/// The inbox directory path for a session file: a sibling directory named
/// `<stem>.inbox` (e.g. `.nulya/sessions/s-1.jsonl` → `.nulya/sessions/s-1.inbox`).
/// Purely lexical, so it preserves whether `session_path` is relative or absolute.
/// Caller owns the result.
pub fn inboxPath(alloc: std.mem.Allocator, session_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(session_path);
    const stem = std.fs.path.stem(base);
    const name = try std.fmt.allocPrint(alloc, "{s}.inbox", .{stem});
    defer alloc.free(name);
    if (std.fs.path.dirname(session_path)) |dir| {
        return std.fs.path.join(alloc, &.{ dir, name });
    }
    return alloc.dupe(u8, name);
}

/// Deterministic model-facing announcement for one active extension version, or
/// null when the version declares nothing to announce (no tools, no skills) or
/// cannot be read. `root` is the extensions store root. Caller owns the result.
pub fn buildActiveNoteText(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, version: []const u8) !?[]u8 {
    const st = store.Store.init(io, root);
    var m = st.readManifest(alloc, id, version) catch |err| switch (err) {
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
/// announce deposits nothing. Idempotent per active version (one file per
/// `id@version`).
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

    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);
    try base.createDirPath(io, inbox);

    const fname = try std.fmt.allocPrint(alloc, "note-{s}-{s}.json", .{ id, version });
    defer alloc.free(fname);
    const rel = try std.fs.path.join(alloc, &.{ inbox, fname });
    defer alloc.free(rel);

    const line = try encodeNoteBody(alloc, id, version, text);
    defer alloc.free(line);
    try base.writeFile(io, .{ .sub_path = rel, .data = line });
}

/// Drain every deposited note in the session inbox into `l`, in filename order,
/// deleting each file once appended. A missing inbox is a no-op. Notes already
/// present in the ledger are skipped (still deleted), so the drain is idempotent
/// across a crash between append and delete. Runs at a step boundary, so an
/// appended note never splits a tool batch (DESIGN §3).
pub fn drainInbox(alloc: std.mem.Allocator, io: std.Io, l: *ledger.Ledger, base: std.Io.Dir, session_path: []const u8) !void {
    const inbox = try inboxPath(alloc, session_path);
    defer alloc.free(inbox);

    var dir = base.openDir(io, inbox, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(io, name, alloc, .limited(4 << 20));
        defer alloc.free(bytes);
        const note = try parseNoteBody(alloc, bytes);
        defer note.deinit(alloc);
        if (!try containsNoteFor(l, note.id, note.version)) {
            try l.append(.{ .capability_note = .{ .id = note.id, .version = note.version, .text = note.text } });
        }
        try dir.deleteFile(io, name);
    }
}

fn encodeNoteBody(alloc: std.mem.Allocator, id: []const u8, version: []const u8, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try ledger.encodeEventBody(&jw, .{ .capability_note = .{ .id = id, .version = version, .text = text } });
    try jw.endObject();
    return out.toOwnedSlice();
}

const ParsedNote = struct {
    id: []const u8,
    version: []const u8,
    text: []const u8,

    fn deinit(self: ParsedNote, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.version);
        alloc.free(self.text);
    }
};

fn parseNoteBody(alloc: std.mem.Allocator, bytes: []const u8) !ParsedNote {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.InvalidInboxNote;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidInboxNote,
    };
    const kind = stringField(obj, "kind") orelse return error.InvalidInboxNote;
    if (!std.mem.eql(u8, kind, "capability_note")) return error.InvalidInboxNote;
    const id = try alloc.dupe(u8, stringField(obj, "id") orelse return error.InvalidInboxNote);
    errdefer alloc.free(id);
    const version = try alloc.dupe(u8, stringField(obj, "version") orelse return error.InvalidInboxNote);
    errdefer alloc.free(version);
    const text = try alloc.dupe(u8, stringField(obj, "text") orelse return error.InvalidInboxNote);
    return .{ .id = id, .version = version, .text = text };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
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

test "inboxPath is a sibling directory named <stem>.inbox" {
    const alloc = std.testing.allocator;
    const a = try inboxPath(alloc, ".nulya/sessions/s-1.jsonl");
    defer alloc.free(a);
    try std.testing.expectEqualStrings(".nulya/sessions" ++ std.fs.path.sep_str ++ "s-1.inbox", a);

    const b = try inboxPath(alloc, "s-2.jsonl");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("s-2.inbox", b);
}

const session_rel = ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "s.jsonl";

test "a deposited note is drained into the ledger and is idempotent" {
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

    // The CLI deposits; the session drains at its step boundary.
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", version);
    try drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try std.testing.expectEqual(@as(usize, 1), l.len());
    try std.testing.expect(l.view()[0] == .capability_note);
    try std.testing.expect(try containsNoteFor(&l, "demo", version));

    // Draining again with an empty inbox adds nothing.
    try drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try std.testing.expectEqual(@as(usize, 1), l.len());

    // A re-deposit of the same active version is skipped on drain (already present).
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", version);
    try drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try std.testing.expectEqual(@as(usize, 1), l.len());
}

test "activating a new version deposits a new note with all tools" {
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
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", first);
    try drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try st.activate(alloc, "demo", second);
    try depositActiveNote(alloc, io, tmp.dir, session_rel, root, "demo", second);
    try drainInbox(alloc, io, &l, tmp.dir, session_rel);

    try std.testing.expectEqual(@as(usize, 2), l.len());
    try std.testing.expect(try containsNoteFor(&l, "demo", first));
    try std.testing.expect(try containsNoteFor(&l, "demo", second));
    try std.testing.expect(std.mem.indexOf(u8, l.view()[1].capability_note.text, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, l.view()[1].capability_note.text, "wave") != null);
}

test "a deposited skill-only note announces its skills" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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
    try drainInbox(alloc, io, &l, tmp.dir, session_rel);

    try std.testing.expectEqual(@as(usize, 1), l.len());
    const text = l.view()[0].capability_note.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "Skills:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "nulya skill load ext:finance@") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "risk-parity") != null);
}

test "draining a missing inbox is a no-op" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var l = ledger.Ledger.init(alloc);
    defer l.deinit();
    try drainInbox(alloc, io, &l, tmp.dir, session_rel);
    try std.testing.expectEqual(@as(usize, 0), l.len());
}

fn writeVersion(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, id: []const u8, manifest_bytes: []const u8) ![]u8 {
    return testkit.writeFrozenVersion(alloc, io, root, id, manifest_bytes, &.{});
}
