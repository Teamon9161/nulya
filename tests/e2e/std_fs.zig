//! The bundled `std` extension's file tools — `read` / `write` / `append` /
//! `edit` and the on-disk freshness they share.
//! Fixtures come from `std.zig`.
//!
//! Everything here goes through the real binary: `ext run std@<v> <tool> '<json>'`
//! in a scratch workspace, with `NULYA_SESSION_ID` set when the point is what a
//! session remembers between calls, unset when the point is that nothing is.
//! One test additionally drives `read` through a real session step, because
//! the claim "the host's output budget never truncates a read" can only be
//! proven where that budget is applied.

const std = @import("std");
const std_ext = @import("std.zig");
const support = @import("support.zig");

const runStd = std_ext.runStd;
const buildStd = std_ext.buildStd;
const nulyaExe = std_ext.nulyaExe;
const runCli = support.runCli;
const runCliEnvs = support.runCliEnvs;
const session = support.session;
const environment = support.environment;
const provider = support.provider;

/// The clip marker's opening, assembled so this file stays editable by an
/// `edit` tool (std's refuses an old_string containing it).
const marker_open = "\u{2026}[+";

const Ws = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    exe: []const u8,
    ref: []const u8,

    fn read(w: Ws, args_json: []const u8, sid: ?[]const u8) !support.CliRun {
        return runStd(w.alloc, w.io, w.dir, w.exe, w.ref, "read", args_json, sid);
    }
    fn write(w: Ws, args_json: []const u8, sid: ?[]const u8) !support.CliRun {
        return runStd(w.alloc, w.io, w.dir, w.exe, w.ref, "write", args_json, sid);
    }
    fn append(w: Ws, args_json: []const u8, sid: ?[]const u8) !support.CliRun {
        return runStd(w.alloc, w.io, w.dir, w.exe, w.ref, "append", args_json, sid);
    }
    fn edit(w: Ws, args_json: []const u8, sid: ?[]const u8) !support.CliRun {
        return runStd(w.alloc, w.io, w.dir, w.exe, w.ref, "edit", args_json, sid);
    }
};

fn expectOk(run: support.CliRun, want: []const u8) !void {
    try std.testing.expectEqual(@as(u8, 0), run.code);
    // `ext run` prints the tool's text plus one newline.
    try std.testing.expectEqualStrings(want, std.mem.trimEnd(u8, run.stdout, "\r\n"));
}

fn expectOkContains(run: support.CliRun, needle: []const u8) !void {
    try std.testing.expectEqual(@as(u8, 0), run.code);
    if (std.mem.indexOf(u8, run.stdout, needle) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ needle, run.stdout });
        return error.TestUnexpectedResult;
    }
}

fn expectRefusal(run: support.CliRun, needle: []const u8) !void {
    try std.testing.expectEqual(@as(u8, 1), run.code);
    try std.testing.expect(std.mem.startsWith(u8, run.stdout, "exit 1\nstderr:\n"));
    if (std.mem.indexOf(u8, run.stdout, needle) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ needle, run.stdout });
        return error.TestUnexpectedResult;
    }
}

fn numberedLines(alloc: std.mem.Allocator, count: usize, width: usize) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i <= count) : (i += 1) {
        try body.print(alloc, "line {d} ", .{i});
        while (body.items.len % (width + 1) != width) try body.append(alloc, 'x');
        try body.append(alloc, '\n');
    }
    return body.toOwnedSlice(alloc);
}

test "bundled std read: verbatim without gutter; unchanged stub in a session and force; window footers and the widened minimum; new range returns only the gap; offset past the end; directory / binary refusals, a missing file answers instead; changed-on-disk note; empty file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ref = try buildStd(alloc, io, tmp.dir, exe);
    defer alloc.free(ref);
    const ws: Ws = .{ .alloc = alloc, .io = io, .dir = tmp.dir, .exe = exe, .ref = ref };
    const sid = "s-fs-read";

    // Verbatim, no gutter; a CRLF file reads as lines (write/append below prove
    // the bytes on disk are never touched).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\r\ntwo\nthree" });
    {
        const first = try ws.read("{\"path\":\"a.txt\"}", sid);
        defer alloc.free(first.stdout);
        try expectOk(first, "one\ntwo\nthree");
        const again = try ws.read("{\"path\":\"a.txt\"}", sid);
        defer alloc.free(again.stdout);
        try expectOk(again, "unchanged: a.txt has not changed since you last read it; the content is already in your context above. (force=true overrides.)");
        const forced = try ws.read("{\"path\":\"a.txt\",\"force\":true}", sid);
        defer alloc.free(forced.stdout);
        try expectOk(forced, "one\ntwo\nthree");
        // The record is this session's file, in the kernel's scratch layout.
        try tmp.dir.access(io, ".nulya/scratch/" ++ sid ++ "/std-freshness.jsonl", .{});
    }

    // Windows: limit 10 is widened to 120; the footer says how to continue; a
    // wider re-read at the same offset returns only what is new; a window that
    // reaches the end gets the plain footer; past the end is a sentence.
    const big = try numberedLines(alloc, 300, 20);
    defer alloc.free(big);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = big });
    {
        const w1 = try ws.read("{\"path\":\"big.txt\",\"offset\":1,\"limit\":10}", sid);
        defer alloc.free(w1.stdout);
        try expectOkContains(w1, "line 120 ");
        try expectOkContains(w1, "\n[showing lines 1-120 of 300; continue with offset=121]");
        try std.testing.expect(std.mem.indexOf(u8, w1.stdout, "line 121 ") == null);

        const w2 = try ws.read("{\"path\":\"big.txt\",\"offset\":1,\"limit\":150}", sid);
        defer alloc.free(w2.stdout);
        try expectOkContains(w2, "note: showing only the new lines 121-150; the rest of the requested range 1-150 is already in your context from an earlier read.\nline 121 ");
        try expectOkContains(w2, "\n[showing lines 121-150 of 300; continue with offset=151]");
        try std.testing.expect(std.mem.indexOf(u8, w2.stdout, "line 120 ") == null);

        const w3 = try ws.read("{\"path\":\"big.txt\",\"offset\":200}", sid);
        defer alloc.free(w3.stdout);
        try expectOkContains(w3, "\n[showing lines 200-300 of 300]");
        try std.testing.expect(std.mem.indexOf(u8, w3.stdout, "continue with") == null);

        const past = try ws.read("{\"path\":\"big.txt\",\"offset\":301}", sid);
        defer alloc.free(past.stdout);
        try expectOk(past, "big.txt has 300 lines; offset 301 is past the end of the file.");
    }

    // A directory and a binary file are refused, each naming what is wrong. A
    // missing file is not a refusal: it answers with its parent's contents (or
    // that the parent is missing too), so a wrong path costs no failed call.
    try tmp.dir.createDirPath(io, "d");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/inner.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin.dat", .data = "abc\x00def" });
    {
        const dir = try ws.read("{\"path\":\"d\"}", sid);
        defer alloc.free(dir.stdout);
        try expectRefusal(dir, "is a directory, not a file. It contains: inner.txt");

        const missing = try ws.read("{\"path\":\"d/nope.txt\"}", sid);
        defer alloc.free(missing.stdout);
        try expectOkContains(missing, "File not found: ");
        try expectOkContains(missing, "exists and contains: inner.txt");

        const no_parent = try ws.read("{\"path\":\"nowhere/nope.txt\"}", sid);
        defer alloc.free(no_parent.stdout);
        try expectOkContains(no_parent, "does not exist either.");

        const bin = try ws.read("{\"path\":\"bin.dat\"}", sid);
        defer alloc.free(bin.stdout);
        try expectRefusal(bin, "is a binary file (7 bytes); refusing to dump it into context.");
    }

    // The file changed under the model: content again, with a note up front.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "changed\n" });
    {
        const changed = try ws.read("{\"path\":\"a.txt\"}", sid);
        defer alloc.free(changed.stdout);
        try expectOk(changed, "note: this file changed on disk since you last read it.\nchanged");
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "" });
    {
        const empty = try ws.read("{\"path\":\"e.txt\"}", sid);
        defer alloc.free(empty.stdout);
        try expectOk(empty, "(empty file)");
    }
}

test "bundled std write/append: a new file (parent dirs made) and its line count; the overwrite gate — unseen, partially seen (ranges named), stale — and read-in-full passes; std's own `edit` is tracked, so writing after one passes while a change made any other way is refused as changed on disk; a read marker in content is refused; append creates, refuses unread, extends after a read with a numbered tail and a merge note; bytes are exact" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ref = try buildStd(alloc, io, tmp.dir, exe);
    defer alloc.free(ref);
    const ws: Ws = .{ .alloc = alloc, .io = io, .dir = tmp.dir, .exe = exe, .ref = ref };
    const sid = "s-fs-write";
    const sep = std.fs.path.sep_str;

    // write: new file, parents created, count is `lines()` (CRLF content stays CRLF).
    {
        const made = try ws.write("{\"path\":\"n/deep/new.txt\",\"content\":\"one\\r\\ntwo\\r\\n\"}", sid);
        defer alloc.free(made.stdout);
        try expectOk(made, "wrote n" ++ sep ++ "deep" ++ sep ++ "new.txt (2 lines)");
        const bytes = try tmp.dir.readFileAlloc(io, "n/deep/new.txt", alloc, .unlimited);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings("one\r\ntwo\r\n", bytes);
    }

    // The gate, in the order a model would hit it.
    const g = try numberedLines(alloc, 300, 20);
    defer alloc.free(g);
    try tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = g });
    const overwrite = "{\"path\":\"g.txt\",\"content\":\"replaced\\n\"}";
    {
        const unseen = try ws.write(overwrite, sid);
        defer alloc.free(unseen.stdout);
        try expectRefusal(unseen, "g.txt already exists and you have not read its current version; read it first so no content is destroyed unknowingly.");

        const part = try ws.read("{\"path\":\"g.txt\",\"limit\":120}", sid);
        defer alloc.free(part.stdout);
        try std.testing.expectEqual(@as(u8, 0), part.code);
        const partial = try ws.write(overwrite, sid);
        defer alloc.free(partial.stdout);
        try expectRefusal(partial, "g.txt already exists and you have only seen lines 1-120 of its current version; `write` replaces the whole file. Read the remaining lines first, or use `edit`/`append` for a targeted change.");

        // Two windows that together cover the file are still two windows: the
        // record learns the line total only from a whole-file read, so the
        // gate keeps asking (naming the coalesced range) until one happens.
        const rest = try ws.read("{\"path\":\"g.txt\",\"offset\":121}", sid);
        defer alloc.free(rest.stdout);
        try std.testing.expectEqual(@as(u8, 0), rest.code);
        const still = try ws.write(overwrite, sid);
        defer alloc.free(still.stdout);
        try expectRefusal(still, "you have only seen lines 1-300 of its current version");

        const whole = try ws.read("{\"path\":\"g.txt\"}", sid);
        defer alloc.free(whole.stdout);
        try expectOkContains(whole, "line 300 ");
        const ok = try ws.write(overwrite, sid);
        defer alloc.free(ok.stdout);
        try expectOk(ok, "wrote g.txt (1 lines)");
        const bytes = try tmp.dir.readFileAlloc(io, "g.txt", alloc, .unlimited);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings("replaced\n", bytes);
    }

    // One record, one package: `edit` reports its own change here, so a read →
    // edit → write sequence never demands a re-read (it did while `edit` was a
    // kernel builtin that could not reach this journal). A change made any
    // OTHER way still makes the next write stale — that is the gate working.
    {
        const seen = try ws.read("{\"path\":\"g.txt\"}", sid);
        defer alloc.free(seen.stdout);
        try std.testing.expectEqual(@as(u8, 0), seen.code);

        const edited = try ws.edit("{\"path\":\"g.txt\",\"old_string\":\"replaced\",\"new_string\":\"rewritten\"}", sid);
        defer alloc.free(edited.stdout);
        try expectOk(edited, "edited g.txt (1 replacement). Result:\n     1\trewritten");
        const after_edit = try ws.write(overwrite, sid);
        defer alloc.free(after_edit.stdout);
        try expectOk(after_edit, "wrote g.txt (1 lines)");

        try tmp.dir.writeFile(io, .{ .sub_path = "g.txt", .data = "changed by something else\n" });
        const stale = try ws.write(overwrite, sid);
        defer alloc.free(stale.stdout);
        try expectRefusal(stale, "g.txt changed on disk since you last read it; re-read it before overwriting so the external changes are not destroyed unknowingly.");
        const bytes = try tmp.dir.readFileAlloc(io, "g.txt", alloc, .unlimited);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings("changed by something else\n", bytes);
    }

    // A read marker is not file content.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"m.txt\",\"content\":\"keep {s}40 bytes]\\n\"}}", .{marker_open});
        defer alloc.free(args);
        const marked = try ws.write(args, sid);
        defer alloc.free(marked.stdout);
        try expectRefusal(marked, "content contains a truncation marker that `read`/`grep` added to their output");
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "m.txt", .{}));
    }

    // append: create, refuse unread, extend after a (partial) read.
    {
        const created = try ws.append("{\"path\":\"ap/log.txt\",\"content\":\"first\\n\"}", sid);
        defer alloc.free(created.stdout);
        try expectOk(created, "created new file ap" ++ sep ++ "log.txt (1 line). Result:\n     1\tfirst");

        try tmp.dir.writeFile(io, .{ .sub_path = "u.txt", .data = "alpha\nbeta" });
        const unread = try ws.append("{\"path\":\"u.txt\",\"content\":\" gamma\\n\"}", sid);
        defer alloc.free(unread.stdout);
        try expectRefusal(unread, "u.txt already exists and you have not read its current version; read it (even partially) before appending so you know what you are extending.");

        const seen = try ws.read("{\"path\":\"u.txt\"}", sid);
        defer alloc.free(seen.stdout);
        try std.testing.expectEqual(@as(u8, 0), seen.code);
        const extended = try ws.append("{\"path\":\"u.txt\",\"content\":\" gamma\\ndelta\\n\"}", sid);
        defer alloc.free(extended.stdout);
        try expectOk(extended, "appended 2 lines to u.txt (now 3 lines).\nnote: the file did not end with a newline; the appended text continues its last line. Result:\n     1\talpha\n     2\tbeta gamma\n     3\tdelta");
        const bytes = try tmp.dir.readFileAlloc(io, "u.txt", alloc, .unlimited);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings("alpha\nbeta gamma\ndelta\n", bytes);
        // What append echoed is what the model has: the whole file is seen, so
        // a whole-file overwrite now passes the gate.
        const over = try ws.write("{\"path\":\"u.txt\",\"content\":\"\"}", sid);
        defer alloc.free(over.stdout);
        try expectOk(over, "wrote u.txt (0 lines)");
    }
}

test "bundled std edit: an exact unique match rewrites and echoes; ambiguity, a miss and a bad target_line refuse without touching the file; replace_all and target_line select; no session still edits" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ref = try buildStd(alloc, io, tmp.dir, exe);
    defer alloc.free(ref);
    const ws: Ws = .{ .alloc = alloc, .io = io, .dir = tmp.dir, .exe = exe, .ref = ref };
    const sid = "s-fs-edit";

    // Exact and unique: the file changes and the answer carries the edited
    // region, numbered, so nothing needs re-reading.
    {
        try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "alpha\nbeta\ngamma\n" });
        const ok = try ws.edit("{\"path\":\"one.txt\",\"old_string\":\"beta\",\"new_string\":\"BETA\"}", sid);
        defer alloc.free(ok.stdout);
        try expectOk(ok, "edited one.txt (1 replacement). Result:\n     1\talpha\n     2\tBETA\n     3\tgamma");
        const bytes = try tmp.dir.readFileAlloc(io, "one.txt", alloc, .unlimited);
        defer alloc.free(bytes);
        try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", bytes);
    }

    // Ambiguous: the count, the occurrences with line numbers, and the three
    // ways out — and the file is untouched.
    {
        try tmp.dir.writeFile(io, .{ .sub_path = "two.txt", .data = "x = 1\nmiddle\nx = 1\n" });
        const many = try ws.edit("{\"path\":\"two.txt\",\"old_string\":\"x = 1\",\"new_string\":\"x = 2\"}", sid);
        defer alloc.free(many.stdout);
        try expectRefusal(many, "old_string appears 2 times; add surrounding context to make it unique, pass target_line from one occurrence below, or set replace_all=true.");
        try expectRefusal(many, "candidate 1 (line 1):");
        try expectRefusal(many, "candidate 2 (line 3):");
        const untouched = try tmp.dir.readFileAlloc(io, "two.txt", alloc, .unlimited);
        defer alloc.free(untouched);
        try std.testing.expectEqualStrings("x = 1\nmiddle\nx = 1\n", untouched);

        // target_line picks the second one.
        const one = try ws.edit("{\"path\":\"two.txt\",\"old_string\":\"x = 1\",\"new_string\":\"x = 2\",\"target_line\":3}", sid);
        defer alloc.free(one.stdout);
        try std.testing.expectEqual(@as(u8, 0), one.code);
        const after = try tmp.dir.readFileAlloc(io, "two.txt", alloc, .unlimited);
        defer alloc.free(after);
        try std.testing.expectEqualStrings("x = 1\nmiddle\nx = 2\n", after);

        // A target_line with no occurrence on it refuses and changes nothing.
        const miss = try ws.edit("{\"path\":\"two.txt\",\"old_string\":\"x = 1\",\"new_string\":\"x = 3\",\"target_line\":2}", sid);
        defer alloc.free(miss.stdout);
        try expectRefusal(miss, "target_line 2 does not contain an exact old_string occurrence");

        // replace_all takes both, and says so in the plural.
        try tmp.dir.writeFile(io, .{ .sub_path = "three.txt", .data = "x = 1\nmiddle\nx = 1\n" });
        const all = try ws.edit("{\"path\":\"three.txt\",\"old_string\":\"x = 1\",\"new_string\":\"x = 9\",\"replace_all\":true}", sid);
        defer alloc.free(all.stdout);
        try expectOkContains(all, "edited three.txt (2 replacements). Result:");
        const both = try tmp.dir.readFileAlloc(io, "three.txt", alloc, .unlimited);
        defer alloc.free(both);
        try std.testing.expectEqualStrings("x = 9\nmiddle\nx = 9\n", both);
    }

    // No match: similar lines as diagnostic hints, plus the note that this
    // session has not read the file.
    {
        try tmp.dir.writeFile(io, .{ .sub_path = "miss.txt", .data = "fn helper() {\n    actual();\n}\n" });
        const gone = try ws.edit("{\"path\":\"miss.txt\",\"old_string\":\"fn helper() {\\n    expected();\\n}\",\"new_string\":\"x\"}", sid);
        defer alloc.free(gone.stdout);
        try expectRefusal(gone, "old_string not found in file.");
        try expectRefusal(gone, "diagnostic hints, not replacement targets");
        try expectRefusal(gone, "note: you have not read the current version of this file");
    }

    // Outside a session there is no record to consult, so no note is invented
    // — and the edit itself happens exactly the same way.
    {
        try tmp.dir.writeFile(io, .{ .sub_path = "free.txt", .data = "solo\n" });
        const ok = try ws.edit("{\"path\":\"free.txt\",\"old_string\":\"solo\",\"new_string\":\"duo\"}", null);
        defer alloc.free(ok.stdout);
        try expectOk(ok, "edited free.txt (1 replacement). Result:\n     1\tduo");
        const missing = try ws.edit("{\"path\":\"free.txt\",\"old_string\":\"nope\",\"new_string\":\"x\"}", null);
        defer alloc.free(missing.stdout);
        try expectRefusal(missing, "old_string not found in file.");
        try std.testing.expect(std.mem.indexOf(u8, missing.stdout, "you have not read the current version") == null);
    }
}

test "bundled std without a session: read never stubs, write overwrites the unread, append extends the unread, and no freshness record is created" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ref = try buildStd(alloc, io, tmp.dir, exe);
    defer alloc.free(ref);
    const ws: Ws = .{ .alloc = alloc, .io = io, .dir = tmp.dir, .exe = exe, .ref = ref };

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    const first = try ws.read("{\"path\":\"a.txt\"}", null);
    defer alloc.free(first.stdout);
    try expectOk(first, "one\ntwo");
    const again = try ws.read("{\"path\":\"a.txt\"}", null);
    defer alloc.free(again.stdout);
    try expectOk(again, "one\ntwo");

    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "never read\n" });
    const over = try ws.write("{\"path\":\"b.txt\",\"content\":\"gone\\n\"}", null);
    defer alloc.free(over.stdout);
    try expectOk(over, "wrote b.txt (1 lines)");
    const more = try ws.append("{\"path\":\"b.txt\",\"content\":\"more\\n\"}", null);
    defer alloc.free(more.stdout);
    try expectOk(more, "appended 1 line to b.txt (now 2 lines). Result:\n     1\tgone\n     2\tmore");

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, ".nulya/scratch", .{}));
}

/// A model that calls one tool with fixed arguments on its first step and ends
/// the turn on the next.
const OneCallModel = struct {
    tool: []const u8,
    args_json: []const u8,
    step_no: usize = 0,

    fn name(_: *anyopaque) []const u8 {
        return "one-call";
    }
    fn modelName(_: *anyopaque) []const u8 {
        return "one-call";
    }
    fn capabilities(_: *anyopaque) provider.ProviderCapabilities {
        return .{};
    }
    fn stream(ptr: *anyopaque, _: std.mem.Allocator, _: provider.Request, sink: provider.EventSink) anyerror!void {
        const self: *OneCallModel = @ptrCast(@alignCast(ptr));
        const n = self.step_no;
        self.step_no += 1;
        try sink.emit(.started);
        if (n > 0) {
            try sink.emit(.{ .text_delta = "read it." });
            try sink.emit(.{ .done = .end_turn });
            return;
        }
        try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "call", .name = self.tool } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = self.args_json } });
        try sink.emit(.{ .done = .tool_use });
    }
    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

test "bundled std read of a 200 KB file caps itself under the host budget: through ext run the answer is ≤ 120 KB with no line over the host's line limit and a continue-with-offset footer; through a session step that pins ext:std/read the ledger holds that footer and no spill footer, and the freshness record is this session's" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ref = try buildStd(alloc, io, tmp.dir, exe);
    defer alloc.free(ref);
    const ws: Ws = .{ .alloc = alloc, .io = io, .dir = tmp.dir, .exe = exe, .ref = ref };
    var ws_real: [std.fs.max_path_bytes]u8 = undefined;
    const ws_path = ws_real[0..try tmp.dir.realPath(io, &ws_real)];

    // 2000 lines of 100 bytes: within the default line limit, over the byte cap.
    const big = try numberedLines(alloc, 2000, 99);
    defer alloc.free(big);
    try std.testing.expect(big.len == 200_000);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = big });

    var continue_from: usize = 0;
    {
        const run = try ws.read("{\"path\":\"big.txt\"}", "s-cap");
        defer alloc.free(run.stdout);
        try std.testing.expectEqual(@as(u8, 0), run.code);
        // The body is capped at 120 KB and the footer rides on top of it: the
        // whole answer stays under the host's 128 KB per-result budget, so the
        // host never has to spill it (`[full output: …]`) or elide its middle.
        try std.testing.expect(run.stdout.len <= 120 * 1024 + 256);
        try std.testing.expect(run.stdout.len < 128 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, run.stdout, "[full output:") == null);
        const at = std.mem.indexOf(u8, run.stdout, "; continue with offset=") orelse return error.TestUnexpectedResult;
        const digits = run.stdout[at + "; continue with offset=".len ..];
        const close = std.mem.indexOfScalar(u8, digits, ']') orelse return error.TestUnexpectedResult;
        continue_from = try std.fmt.parseInt(usize, digits[0..close], 10);
        try std.testing.expect(continue_from > 1 and continue_from <= 2000);
        var lines = std.mem.splitScalar(u8, run.stdout, '\n');
        while (lines.next()) |line| try std.testing.expect(line.len <= 16384);
    }
    // The rest, in the same session, is a new range: it starts exactly where the
    // footer said and reaches the end.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"big.txt\",\"offset\":{d}}}", .{continue_from});
        defer alloc.free(args);
        const rest = try ws.read(args, "s-cap");
        defer alloc.free(rest.stdout);
        const first_line = try std.fmt.allocPrint(alloc, "line {d} ", .{continue_from});
        defer alloc.free(first_line);
        try std.testing.expect(std.mem.startsWith(u8, rest.stdout, first_line));
        try expectOkContains(rest, "line 2000 ");
        const footer = try std.fmt.allocPrint(alloc, "\n[showing lines {d}-2000 of 2000]", .{continue_from});
        defer alloc.free(footer);
        try expectOkContains(rest, footer);
    }

    // Now natively: a session that pins ext:std/read, stepped in-process with a
    // model that calls `read` by name. The tool result the ledger records went
    // through the host's output discipline; it must be our footer, whole, and
    // never the host's spill footer.
    {
        const activated = try runCli(alloc, io, tmp.dir, &.{ exe, "ext", "activate", "std", ref["std@".len..] });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
        const new = try runCli(alloc, io, tmp.dir, &.{ exe, "session", "new", "--profile", "scripted", "--pin", "ext:std/read" });
        defer alloc.free(new.stdout);
        try std.testing.expectEqual(@as(u8, 0), new.code);
        const id = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
        defer alloc.free(id);
        const spath = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{id});
        defer alloc.free(spath);

        var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .extension_roots = support.workspace_store_roots });
        defer lenv.deinit();
        // What `session step` gives every child: the session's file (for the
        // things that need a file) and its id (for the things that need a name
        // — like the record this tool keys by).
        try lenv.publishSession(spath, id);
        var model = OneCallModel{ .tool = "read", .args_json = "{\"path\":\"big.txt\"}" };
        var sess = try session.AgentSession.openDurable(alloc, .{
            .model = .{ .ptr = &model, .vtable = &OneCallModel.vtable },
            .step_ctx = .{
                .tool_context = .{ .environment = lenv.environment(), .cwd = ws_path },
                .scratch_dir = ".nulya/scratch",
            },
        }, .{ .workspace = tmp.dir, .session_path = spath });
        defer sess.deinit();
        try std.testing.expect(sess.composition.tools.lookup("read") != null);
        try sess.appendUser("read big.txt");
        _ = try sess.step();
        _ = try sess.step();

        const ledger_bytes = try support.readSessionFile(alloc, io, tmp.dir, id);
        defer alloc.free(ledger_bytes);
        try std.testing.expect(std.mem.indexOf(u8, ledger_bytes, "\"tool\":\"read\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, ledger_bytes, "; continue with offset=") != null);
        try std.testing.expect(std.mem.indexOf(u8, ledger_bytes, "[full output:") == null);
        try std.testing.expect(std.mem.indexOf(u8, ledger_bytes, "output elided") == null);

        const record = try std.fmt.allocPrint(alloc, ".nulya/scratch/{s}/std-freshness.jsonl", .{id});
        defer alloc.free(record);
        const events = try tmp.dir.readFileAlloc(io, record, alloc, .unlimited);
        defer alloc.free(events);
        try std.testing.expect(std.mem.indexOf(u8, events, "\"op\":\"read\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, events, "big.txt") != null);
    }
}
