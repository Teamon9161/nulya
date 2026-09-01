//! Images in a user turn, end to end:
//! `session append --image` behind the shell's two gates — can this session's
//! FROZEN model see an image at all (`[[models]] vision = true`), and is this
//! file a png/jpeg small enough to send — then the base64 riding the ledger
//! line, surviving resume, and being left out of what `session events` prints.
//!
//! Everything here runs on the scripted stand-in: the subject is the ledger,
//! the projection and the gate, none of which needs a real model.

const std = @import("std");
const support = @import("support.zig");

const ledger = support.ledger;
const prompt = support.prompt;
const flattenIR = support.flattenIR;
const readSessionFile = support.readSessionFile;
const runCli = support.runCli;
const runCliEnv = support.runCliEnv;
const runCliStderr = support.runCliStderr;

/// A user layer that says the scripted profile's model id can be shown images.
/// `[[models]]` is trusted-layers only, so this is where a claim
/// like that has to live — a checkout cannot make one.
const vision_config =
    \\[[models]]
    \\id = "scripted-demo"
    \\label = "Scripted"
    \\vision = true
    \\
;

/// The same catalog entry WITHOUT the claim: an entry that says nothing about
/// images says no.
const silent_config =
    \\[[models]]
    \\id = "scripted-demo"
    \\label = "Scripted"
    \\
;

/// The smallest thing the sniffer must accept: a real PNG signature followed by
/// bytes nulya never looks at. The gate reads MAGIC, not pixels — decoding an
/// image is the provider's job, and pretending otherwise here would be testing
/// a decoder we do not have.
const png_bytes = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\rIHDR" ++ "not really pixels";
const jpeg_bytes = "\xFF\xD8\xFF\xE0" ++ "JFIF-ish bytes";

fn writeUserConfig(io: std.Io, ws: std.Io.Dir, body: []const u8) !void {
    try ws.createDirPath(io, support.home_subdir);
    try ws.writeFile(io, .{ .sub_path = support.home_subdir ++ std.fs.path.sep_str ++ "config.toml", .data = body });
}

/// How many events are waiting in this session's inbox. A refused append must
/// leave this at zero: the gate is only worth having if nothing is deposited
/// before it runs.
fn inboxCount(io: std.Io, ws: std.Io.Dir, alloc: std.mem.Allocator, id: []const u8) !usize {
    const path = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.inbox", .{id});
    defer alloc.free(path);
    var dir = ws.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) n += 1;
    }
    return n;
}

fn newScriptedSession(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe: []const u8) ![]u8 {
    const new = try runCli(alloc, io, ws, &.{ exe, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    try std.testing.expectEqual(@as(u8, 0), new.code);
    return alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
}

test "session append --image: the catalog gate refuses a model that does not claim vision, and nothing is deposited" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try ws.writeFile(io, .{ .sub_path = "shot.png", .data = png_bytes });

    const id = try newScriptedSession(alloc, io, ws, exe_abs);
    defer alloc.free(id);
    const argv = [_][]const u8{ exe_abs, "session", "append", id, "what is this", "--image", "shot.png" };

    // 1. No catalog entry at all for the frozen model id. "No claim" is not
    //    "yes": the refusal names the key that would say yes.
    {
        const run = try runCli(alloc, io, ws, &argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        try std.testing.expectEqualStrings("", run.stdout); // stdout stays clean
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "scripted-demo") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "[[models]]") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "vision = true") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "nulya config show") != null);
        try std.testing.expectEqual(@as(usize, 0), try inboxCount(io, ws, alloc, id));
    }

    // 2. An entry that describes the model but claims nothing about images.
    {
        try writeUserConfig(io, ws, silent_config);
        const run = try runCli(alloc, io, ws, &argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "not marked as accepting images") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "vision = true") != null);
        try std.testing.expectEqual(@as(usize, 0), try inboxCount(io, ws, alloc, id));
    }

    // 3. The gate is only about images: a plain text append is untouched by any
    //    of this, and lands in the inbox as it always did.
    {
        const run = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", id, "just words" });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expectEqual(@as(usize, 1), try inboxCount(io, ws, alloc, id));
    }

    // 4. `config show` projects the claim from the same catalog the gate reads,
    //    so a picker and the gate can never disagree.
    try writeUserConfig(io, ws, vision_config);
    const shown = try runCli(alloc, io, ws, &.{ exe_abs, "config", "show" });
    defer alloc.free(shown.stdout);
    try std.testing.expectEqual(@as(u8, 0), shown.code);
    try std.testing.expect(std.mem.indexOf(u8, shown.stdout, "vision") != null);
    const shown_json = try runCli(alloc, io, ws, &.{ exe_abs, "config", "show", "--json" });
    defer alloc.free(shown_json.stdout);
    try std.testing.expect(std.mem.indexOf(u8, shown_json.stdout, "\"vision\":true") != null);
}

test "session append --image: a claimed model takes the image onto the ledger line, through a step, a resume and the events projection" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try writeUserConfig(io, ws, vision_config);
    try ws.writeFile(io, .{ .sub_path = "shot.png", .data = png_bytes });
    try ws.writeFile(io, .{ .sub_path = "photo.jpg", .data = jpeg_bytes });

    const id = try newScriptedSession(alloc, io, ws, exe_abs);
    defer alloc.free(id);

    // Two images and text are ONE user turn — the flag is repeatable, not a
    // second event.
    {
        const run = try runCli(alloc, io, ws, &.{
            exe_abs,   "session",  "append",  id,          "what is this",
            "--image", "shot.png", "--image", "photo.jpg",
        });
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        try std.testing.expectEqual(@as(usize, 1), try inboxCount(io, ws, alloc, id));
    }

    const step = try runCliEnv(alloc, io, ws, &.{ exe_abs, "session", "step", id }, "NULYA_SCRIPTED_MODE", "finish");
    defer alloc.free(step.stdout);
    try std.testing.expectEqual(@as(u8, 0), step.code);

    // The file carries the base64 itself: the ledger stores the fact.
    const encoder = std.base64.standard.Encoder;
    const png_b64 = try alloc.alloc(u8, encoder.calcSize(png_bytes.len));
    defer alloc.free(png_b64);
    _ = encoder.encode(png_b64, png_bytes);

    const bytes = try readSessionFile(alloc, io, ws, id);
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"media_type\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"media_type\":\"image/jpeg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, png_b64) != null);

    // Resume projects the same turn, image included: a second process reading
    // the file alone sees exactly what the first one sent.
    {
        const rel = try sessionRel(alloc, id);
        defer alloc.free(rel);
        var l = try ledger.openDurable(alloc, io, ws, rel);
        defer l.deinit();
        const ir = try prompt.project(alloc, l.view());
        defer ir.deinit(alloc);
        const flat = try flattenIR(alloc, ir);
        defer alloc.free(flat);
        try std.testing.expect(std.mem.indexOf(u8, flat, "U|what is this\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, flat, "I|image/png|") != null);
        try std.testing.expect(std.mem.indexOf(u8, flat, "I|image/jpeg|") != null);
        try std.testing.expect(std.mem.indexOf(u8, flat, png_b64) != null);
    }

    // …but `session events` prints the turn without the payload: same seq, same
    // text, a placeholder where the base64 was.
    const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", id });
    defer alloc.free(events.stdout);
    try std.testing.expectEqual(@as(u8, 0), events.code);
    try std.testing.expect(std.mem.indexOf(u8, events.stdout, png_b64) == null);
    try std.testing.expect(std.mem.indexOf(u8, events.stdout, "[image image/png,") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.stdout, "[image image/jpeg,") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.stdout, "\"seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.stdout, "what is this") != null);
    // The assistant turn that followed is printed exactly as the file has it.
    try std.testing.expect(std.mem.indexOf(u8, events.stdout, "\"kind\":\"assistant\"") != null);
}

test "session append --image: the file's magic decides the type, and 5 MB is the ceiling" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    try writeUserConfig(io, ws, vision_config);

    const id = try newScriptedSession(alloc, io, ws, exe_abs);
    defer alloc.free(id);

    // A GIF named `.png`: the extension is a claim, the bytes are the fact.
    try ws.writeFile(io, .{ .sub_path = "liar.png", .data = "GIF89a and then some" });
    {
        const argv = [_][]const u8{ exe_abs, "session", "append", id, "look", "--image", "liar.png" };
        const run = try runCli(alloc, io, ws, &argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "not a PNG or JPEG") != null);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "image/jpeg") != null);
        try std.testing.expectEqual(@as(usize, 0), try inboxCount(io, ws, alloc, id));
    }

    // One byte over the per-image limit, with a perfectly good PNG signature.
    {
        const too_big = try alloc.alloc(u8, (5 << 20) + 1);
        defer alloc.free(too_big);
        @memset(too_big, 'x');
        @memcpy(too_big[0..8], "\x89PNG\r\n\x1a\n");
        try ws.writeFile(io, .{ .sub_path = "huge.png", .data = too_big });

        const argv = [_][]const u8{ exe_abs, "session", "append", id, "look", "--image", "huge.png" };
        const run = try runCli(alloc, io, ws, &argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "5242881 bytes") != null); // the actual size
        try std.testing.expect(std.mem.indexOf(u8, err_text, "5242880") != null); // and the limit
        try std.testing.expectEqual(@as(usize, 0), try inboxCount(io, ws, alloc, id));
    }

    // A path that is not there at all.
    {
        const argv = [_][]const u8{ exe_abs, "session", "append", id, "look", "--image", "nope.png" };
        const run = try runCli(alloc, io, ws, &argv);
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 1), run.code);
        const err_text = try runCliStderr(alloc, io, ws, &argv, &.{});
        defer alloc.free(err_text);
        try std.testing.expect(std.mem.indexOf(u8, err_text, "cannot read --image 'nope.png'") != null);
        try std.testing.expectEqual(@as(usize, 0), try inboxCount(io, ws, alloc, id));
    }
}

fn sessionRel(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, ".nulya" ++ std.fs.path.sep_str ++ "sessions" ++ std.fs.path.sep_str ++ "{s}.jsonl", .{id});
}
