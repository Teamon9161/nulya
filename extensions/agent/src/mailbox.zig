//! `<d>/inbox/` — the queue a runner whose harness has no inbox of its own takes
//! its messages from, plus the interrupt marker that goes with it. A queue with a
//! delivery contract, where `record.zig` next door records facts that already
//! happened. The nulya runner uses neither: it appends into the child session's
//! own inbox. Four rules:
//!
//! 1. ONE PUBLISH ORDER, and the numbers agree with it. A message is
//!    `<12 digits>.json`, and a sender holds `<d>/inbox/.writer.lock` for the
//!    whole of taking a number, writing the body and publishing it. Without the
//!    lock two senders take 1 and 2, the one holding 2 finishes first, and a
//!    reader delivers 2 before it sees 1.
//! 2. PUBLISHING IS A RENAME. A directory entry exists the moment a file is
//!    created, not when it is closed, so the body goes into `<n>.tmp` and the
//!    rename is what makes it a message.
//! 3. READING DOES NOT CONSUME; DELIVERY DOES. `peek` leaves everything where it
//!    is; `ack` drops one message once the harness confirmed it. AT-LEAST-ONCE:
//!    the failure direction is "delivered twice" rather than "gone". A reader
//!    that cannot read a message must LEAVE it and STOP there — the only thing
//!    `peek` ever drops is a file it read and proved to be no message at all.
//! 4. HOW A MESSAGE WAS SENT TRAVELS WITH IT. `interrupt` is a fact about
//!    DELIVERY, not a kind of message, and rides in the same atomic write as the
//!    text because two writes is a race in either order (`Message`).

const std = @import("std");
const record = @import("record.zig");

pub const inbox_name = "inbox";
pub const interrupt_name = "interrupt";

/// Serialises senders, so the order numbers are taken in is the order messages
/// are published in (rule 1). Readers never take it: a `.json` name appears by
/// rename, so what a reader finds is always whole.
pub const writer_lock_name = ".writer.lock";

/// Where one round's message is staged for a runner that reads it as a file
/// (`external.zig`'s contract). A path rather than a value because a task is as
/// long as it needs to be and a command line is not; whoever holds the runner
/// lease is the only writer, so one name is enough.
pub const message_name = "message.txt";

/// How many messages may WAIT — the count of them, not the highest number one of
/// them carries. A backstop against a directory nobody is draining, not a
/// budget: `max_exchanges` is where a delegation's turns are counted.
const max_queued: usize = 4096;

/// The largest body a reader will read back, and therefore the largest one a
/// sender may write. One constant, enforced on BOTH sides: a message this side
/// could publish but not read back would have to be delivered or abandoned by a
/// rule made up on the spot (rule 3).
const max_message_bytes: usize = 4 << 20;

/// One message waiting for a runner, and how it was sent.
///
/// `interrupt` rides in the envelope because two writes is a race whichever
/// order they go in:
///
///   * message first, then the marker: a runner that drains mid-turn — the codex
///     arm does, that is what `turn/steer` is for — can take the message in the
///     gap and steer it INTO the very turn the marker is about to cut down.
///   * marker first, then the message: a sender that dies in the gap has cut a
///     turn short and delivered no new direction to replace it.
///
/// One atomic rename carries both. The `<d>/interrupt` marker still exists and
/// is still what stops a turn on the arms that do NOT drain mid-turn (claude,
/// pi, an external runner): they take their one message at the start of a round
/// and watch the marker while it runs.
pub const Message = struct {
    text: []const u8,
    interrupt: bool = false,
};

/// One message waiting, under the name it waits by.
pub const Entry = struct {
    /// The number in its name. Strictly increasing in publish order (rule 1),
    /// which is what lets a reader that has already offered everything up to `n`
    /// ask only for what came after (`peekAfter`).
    seq: usize,
    /// Its file name inside `<d>/inbox/` — the handle `ack` is given.
    name: []const u8,
    msg: Message,
};

/// Deliver one message into `<d>/inbox/`.
pub fn put(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    msg: Message,
) !void {
    const dir = try record.pathIn(alloc, id, inbox_name);
    try base.createDirPath(io, dir);

    const lock_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, writer_lock_name });
    var lease = try base.createFile(io, lock_path, .{ .truncate = false, .read = true, .lock = .exclusive });
    defer lease.close(io);

    var body: std.Io.Writer.Allocating = .init(alloc);
    var jw: std.json.Stringify = .{ .writer = &body.writer };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(1);
    try jw.objectField("text");
    try jw.write(msg.text);
    // Only when it is one, so an ordinary message is the same bytes it always
    // was.
    if (msg.interrupt) {
        try jw.objectField("interrupt");
        try jw.write(true);
    }
    try jw.endObject();

    // Refused BEFORE a number is taken: `peek` reads back through the same limit
    // and rule 3 leaves what it cannot read where it is, so writing this would
    // be a permanent blockage at the head of the queue.
    if (body.writer.buffered().len > max_message_bytes) return error.MessageTooLarge;

    const n = try scanForPut(io, base, dir);
    const staged = try std.fmt.allocPrint(alloc, "{s}/{d:0>12}.tmp", .{ dir, n });
    const path = try std.fmt.allocPrint(alloc, "{s}/{d:0>12}.json", .{ dir, n });
    // Exclusive because the name is supposed to be free: the scan just proved it
    // is past every number in the directory, and the lock says nobody else is
    // adding one. `PathAlreadyExists` means one of those two is not true.
    const file = try base.createFile(io, staged, .{ .exclusive = true });
    {
        defer file.close(io);
        try file.writeStreamingAll(io, body.writer.buffered());
    }
    try base.rename(staged, base, path, io);
}

/// Every message waiting whose number is past `after`, oldest first. Pass `0`
/// for everything.
///
/// `after` is how a reader that offers several messages into one turn asks for
/// only what is new. A NUMBER rather than a set of names because nothing is
/// dropped until the round ends (rule 3). Rule 1 is what makes the cursor sound:
/// a message published during a round has a number past everything already seen.
///
/// A file that was READ and proved to be no message is deleted here, and it is
/// the only thing that is: it cannot be half-written, so it will never parse, and
/// leaving it would hold `pending` true for ever. A file that could not be read AT
/// ALL stays, and the peek stops there (rule 3).
pub fn peekAfter(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    after: usize,
) ![]const Entry {
    return peekUpTo(alloc, io, base, id, after, max_queued);
}

/// The oldest message waiting, or null when there is none. For a runner that
/// answers one message per round (claude, pi, an external one).
pub fn peekOne(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) !?Entry {
    const found = try peekUpTo(alloc, io, base, id, 0, 1);
    return if (found.len == 0) null else found[0];
}

/// This message has been delivered: drop it.
///
/// Best effort, and the DIRECTION of that is the point: an ack that does not
/// land leaves the message for the next round, which delivers it twice, where
/// deleting before delivery is certain would lose it.
pub fn ack(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8, name: []const u8) void {
    const dir = record.pathIn(alloc, id, inbox_name) catch return;
    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch return;
    base.deleteFile(io, path) catch {};
}

/// Is a message sitting here that nobody has taken yet? The runner's own
/// question between rounds. Unreadable counts as nothing waiting.
pub fn pending(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) bool {
    const path = record.pathIn(alloc, id, inbox_name) catch return false;
    var dir = base.openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind == .directory) continue;
        // Only a `.json` is a message that has actually landed (rule 2).
        if (std.mem.endsWith(u8, entry.name, ".json")) return true;
    }
    return false;
}

fn peekUpTo(
    alloc: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    id: []const u8,
    after: usize,
    limit: usize,
) ![]const Entry {
    const dir = try record.pathIn(alloc, id, inbox_name);
    var found: std.ArrayList(Entry) = .empty;
    {
        var d = base.openDir(io, dir, .{ .iterate = true }) catch return &.{};
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const seq = std.fmt.parseInt(usize, std.mem.sliceTo(entry.name, '.'), 10) catch continue;
            if (seq <= after) continue;
            try found.append(alloc, .{
                .seq = seq,
                .name = try alloc.dupe(u8, entry.name),
                .msg = undefined,
            });
        }
    }
    std.mem.sort(Entry, found.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.seq < b.seq;
        }
    }.lessThan);

    var out: std.ArrayList(Entry) = .empty;
    for (found.items) |entry| {
        if (out.items.len >= limit) break;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, entry.name });
        // Could not read it at all — out of memory, a handle this process could
        // not get, a body past the limit. None of those says whether it is a
        // message, so it is left where it is: deleting would drop a message
        // already accepted, which rule 3 forbids.
        //
        // And the peek STOPS rather than skipping: rule 1 is an order, and
        // reaching past this message would deliver it after messages sent later.
        // A transient failure costs a round; a permanent one strands the
        // delegation loudly.
        const raw = base.readFileAlloc(io, path, alloc, .limited(max_message_bytes)) catch break;
        // Read, and not a message. It never will be, so it goes.
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
            base.deleteFile(io, path) catch {};
            continue;
        };
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                base.deleteFile(io, path) catch {};
                continue;
            },
        };
        const text = stringOf(obj, "text") orelse "";
        if (text.len == 0) {
            base.deleteFile(io, path) catch {};
            continue;
        }
        try out.append(alloc, .{
            .seq = entry.seq,
            .name = entry.name,
            .msg = .{ .text = text, .interrupt = boolOf(obj, "interrupt") },
        });
    }
    return out.items;
}

/// One pass over the inbox on behalf of a sender that holds the lock: clear the
/// wreckage, count what is waiting, and answer with the number to publish under.
///
/// The count is of MESSAGES, not of numbers — checking `max_queued` against the
/// number about to be handed out would refuse an inbox that once reached the cap
/// and has since been drained.
///
/// The `.tmp` files go: holding the lock means no live sender is part way through
/// one, so each belongs to a sender that died mid-write and would hold a number
/// for ever.
///
/// The number handed back is one past the highest still present, so a number IS
/// reused once the directory empties. Order only has to hold among messages that
/// coexist.
fn scanForPut(io: std.Io, base: std.Io.Dir, dir: []const u8) !usize {
    var d = base.openDir(io, dir, .{ .iterate = true }) catch return 1;
    defer d.close(io);
    var highest: usize = 0;
    var queued: usize = 0;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (std.mem.endsWith(u8, entry.name, ".tmp")) {
            d.deleteFile(io, entry.name) catch {};
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        queued += 1;
        const n = std.fmt.parseInt(usize, std.mem.sliceTo(entry.name, '.'), 10) catch continue;
        if (n > highest) highest = n;
    }
    if (queued >= max_queued) return error.InboxFull;
    return highest + 1;
}

// ── the interrupt marker ────────────────────────────────────────────────────

/// "Stop what you are doing and take the new message now." Written after the
/// message, so a runner that sees the marker always finds something behind it.
pub fn markInterrupt(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) !void {
    const dir = try record.dirOf(alloc, id);
    try base.createDirPath(io, dir);
    const path = try record.pathIn(alloc, id, interrupt_name);
    try base.writeFile(io, .{ .sub_path = path, .data = "" });
}

/// Take the marker if it is there. Taking rather than reading, so a runner
/// cannot see the same interrupt twice and cut short the round it started
/// BECAUSE of it.
pub fn takeInterrupt(alloc: std.mem.Allocator, io: std.Io, base: std.Io.Dir, id: []const u8) bool {
    const path = record.pathIn(alloc, id, interrupt_name) catch return false;
    return takeInterruptAt(io, base, path);
}

/// The same, with the path worked out once: the runner polls between stream
/// lines, thousands of times in a turn.
pub fn takeInterruptAt(io: std.Io, base: std.Io.Dir, path: []const u8) bool {
    base.access(io, path, .{}) catch return false;
    base.deleteFile(io, path) catch return false;
    return true;
}

fn stringOf(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn boolOf(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

// ── tests ───────────────────────────────────────────────────────────────────

test "messages come back in the order they were sent, and stay until they are acked" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-00000000cafe";
    // Nothing queued is not an error: a runner asks this every round.
    try std.testing.expectEqual(@as(usize, 0), (try peekAfter(a, io, ws, id, 0)).len);
    try std.testing.expect(!pending(a, io, ws, id));

    try put(a, io, ws, id, .{ .text = "first" });
    try put(a, io, ws, id, .{ .text = "second" });
    try put(a, io, ws, id, .{ .text = "third" });

    const seen = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 3), seen.len);
    try std.testing.expectEqualStrings("first", seen[0].msg.text);
    try std.testing.expectEqualStrings("third", seen[2].msg.text);
    try std.testing.expect(pending(a, io, ws, id));

    // Reading is not taking: a round that died here leaves all three where the
    // next runner finds them.
    try std.testing.expectEqual(@as(usize, 3), (try peekAfter(a, io, ws, id, 0)).len);

    ack(a, io, ws, id, seen[0].name);
    ack(a, io, ws, id, seen[1].name);
    const left = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("third", left[0].msg.text);

    // A message queued later still sorts after one that is still waiting.
    try put(a, io, ws, id, .{ .text = "fourth" });
    const both = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqualStrings("third", both[0].msg.text);
    try std.testing.expectEqualStrings("fourth", both[1].msg.text);
}

test "a cursor asks only for what arrived after what a round has already offered" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // The codex arm's round in miniature: offer what is waiting, keep the number,
    // then ask only for what is new — acking nothing, so all of it is still there.
    const id = "d-0000000000c0";
    try put(a, io, ws, id, .{ .text = "A" });
    try put(a, io, ws, id, .{ .text = "B" });

    const first = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    const cursor = first[1].seq;

    // Nothing new yet, though both are still sitting there.
    try std.testing.expectEqual(@as(usize, 0), (try peekAfter(a, io, ws, id, cursor)).len);

    try put(a, io, ws, id, .{ .text = "C" });
    const next = try peekAfter(a, io, ws, id, cursor);
    try std.testing.expectEqual(@as(usize, 1), next.len);
    try std.testing.expectEqualStrings("C", next[0].msg.text);
    try std.testing.expect(next[0].seq > cursor);
}

test "a message that could not be used stays in its place, so a later one cannot overtake it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // A message is read, the round cannot use it (a refused steer, a harness
    // that would not start), and a second message arrives before the first is
    // dealt with. The first must keep its place.
    const id = "d-0000000000f0";
    try put(a, io, ws, id, .{ .text = "A" });
    const first = (try peekOne(a, io, ws, id)).?;
    try std.testing.expectEqualStrings("A", first.msg.text);

    try put(a, io, ws, id, .{ .text = "B" });

    const next_round = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 2), next_round.len);
    try std.testing.expectEqualStrings("A", next_round[0].msg.text);
    try std.testing.expectEqualStrings("B", next_round[1].msg.text);
}

test "how a message was sent travels with it, in the same atomic write" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-0000000000e1";
    try put(a, io, ws, id, .{ .text = "carry on" });
    try put(a, io, ws, id, .{ .text = "stop", .interrupt = true });

    const seen = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 2), seen.len);
    try std.testing.expect(!seen[0].msg.interrupt);
    try std.testing.expect(seen[1].msg.interrupt);

    // Still an interrupt when a round leaves it for the next: nothing is
    // rewritten, so it cannot quietly become an ordinary turn.
    ack(a, io, ws, id, seen[0].name);
    const again = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expectEqualStrings("stop", again[0].msg.text);
    try std.testing.expect(again[0].msg.interrupt);
}

test "a half-written message is never read, and the sender after it clears the wreck" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-00000000beef";
    const dir = try record.pathIn(a, id, inbox_name);
    try ws.createDirPath(io, dir);

    // A sender that died part way through: the number is claimed, the body is
    // not there yet. A reader must not touch it.
    const staged = try std.fmt.allocPrint(a, "{s}/000000000001.tmp", .{dir});
    try ws.writeFile(io, .{ .sub_path = staged, .data = "" });
    try std.testing.expectEqual(@as(usize, 0), (try peekAfter(a, io, ws, id, 0)).len);
    try ws.access(io, staged, .{});

    // The next sender holds the writer lock, so it knows nobody is mid-write and
    // clears it — otherwise a dead sender's number is spent for ever.
    try put(a, io, ws, id, .{ .text = "after" });
    try std.testing.expectError(error.FileNotFound, ws.access(io, staged, .{}));
    const seen = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("after", seen[0].msg.text);
}

test "a file in the inbox that can never be a message is dropped rather than left to spin" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Published by a rename, so it is whole — and it will never parse. Leaving it
    // would hold `pending` true for ever.
    const id = "d-00000000ba17";
    const dir = try record.pathIn(a, id, inbox_name);
    try ws.createDirPath(io, dir);
    try ws.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/000000000001.json", .{dir}),
        .data = "not json at all",
    });
    try put(a, io, ws, id, .{ .text = "the real one" });

    const seen = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("the real one", seen[0].msg.text);
    try std.testing.expectError(
        error.FileNotFound,
        ws.access(io, try std.fmt.allocPrint(a, "{s}/000000000001.json", .{dir}), .{}),
    );
}

test "a message that cannot be read is left alone, and nothing behind it overtakes it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // Read failure and "read it, and it is no message" are two different answers,
    // and only the second may delete: dropping on any error would lose a message
    // already accepted (rule 3). A body past the reader's limit is that failure,
    // reachably — `put` refuses to write one, but a file on disk still has to be
    // handled.
    const id = "d-00000000f00d";
    const dir = try record.pathIn(a, id, inbox_name);
    try ws.createDirPath(io, dir);
    const huge_path = try std.fmt.allocPrint(a, "{s}/000000000001.json", .{dir});
    const huge = try a.alloc(u8, max_message_bytes + 1);
    @memset(huge, 'x');
    try ws.writeFile(io, .{ .sub_path = huge_path, .data = huge });

    try put(a, io, ws, id, .{ .text = "behind it" });

    // The peek stops where it cannot read: answering the second message now
    // would put it ahead of one sent before it, and the first would arrive
    // afterwards if it ever became readable (rule 1).
    try std.testing.expectEqual(@as(usize, 0), (try peekAfter(a, io, ws, id, 0)).len);
    // Still there. The delegation stalls, loudly, rather than answering the
    // wrong message and calling the other one delivered.
    try ws.access(io, huge_path, .{});
    try std.testing.expect(pending(a, io, ws, id));
}

test "a body the reader could not read back is refused before it is queued" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    // One limit, both sides. A body this side cannot read back would block the
    // queue it is at the head of, with its sender told it was accepted.
    const id = "d-00000000ba55";
    const oversized = try a.alloc(u8, max_message_bytes + 1);
    @memset(oversized, 'x');
    try std.testing.expectError(error.MessageTooLarge, put(a, io, ws, id, .{ .text = oversized }));
    try std.testing.expect(!pending(a, io, ws, id));

    // And nothing was left behind holding a number: a refusal happens before a
    // name is taken.
    try put(a, io, ws, id, .{ .text = "an ordinary one" });
    const seen = try peekAfter(a, io, ws, id, 0);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("an ordinary one", seen[0].msg.text);
}

test "the interrupt marker is taken once" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const id = "d-abcdef012345";
    try std.testing.expect(!takeInterrupt(a, io, ws, id));
    try markInterrupt(a, io, ws, id);
    try std.testing.expect(takeInterrupt(a, io, ws, id));
    try std.testing.expect(!takeInterrupt(a, io, ws, id));
}
