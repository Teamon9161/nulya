//! The bundled `std` extension's search tools — `grep` / `glob` and the
//! gitignore-aware walk under them (docs/goals/std.md §1.3). Owned by std-d;
//! fixtures come from `std.zig`.
//!
//! Every case runs the real binary through `nulya ext run std@<v> <tool> '<json>'`
//! in a scratch workspace that is its own repository root (an empty `.git`), so
//! the ignore rules in play are exactly the ones the test wrote — nothing from
//! the checkout this test happens to run in leaks down. Paths in the output use
//! the platform separator; assertions normalize `\` to `/`.

const std = @import("std");
const std_ext = @import("std.zig");

const buildStd = std_ext.buildStd;
const nulyaExe = std_ext.nulyaExe;
const runStd = std_ext.runStd;

/// The workspace's own ignore file. `.nulya/` (the extension store the build
/// put there) and the test home are hidden the way a real checkout hides them.
const gitignore = ".nulya/\n.nulya-test-home/\n*.log\nignored/\n";

fn write(io: std.Io, ws: std.Io.Dir, rel: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel)) |d| try ws.createDirPath(io, d);
    try ws.writeFile(io, .{ .sub_path = rel, .data = data });
}

/// A copy of `s` with `\` turned into `/`; caller frees.
fn slashed(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// One search call; the answer's stdout with separators normalized. Caller frees.
fn call(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe: []const u8, ref: []const u8, tool: []const u8, json: []const u8, expect_code: u8) ![]u8 {
    const run = try runStd(alloc, io, ws, exe, ref, tool, json, null);
    defer alloc.free(run.stdout);
    if (run.code != expect_code) {
        std.debug.print("{s} {s} exited {d} (expected {d}):\n{s}\n", .{ tool, json, run.code, expect_code, run.stdout });
        return error.TestUnexpectedResult;
    }
    return slashed(alloc, run.stdout);
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "bundled std grep: hits, smart case, glob filter, context shape, per-file cap, paging, no-match notes, gitignore, pruned dirs, oversized / binary / CRLF files, invalid regex, output budget" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    const ref = try buildStd(alloc, io, ws, exe);
    defer alloc.free(ref);

    // The tree: an ignore file, an ignored file and directory, a pruned
    // directory, an oversized file, a binary file, a CRLF file, a crowded file
    // and its neighbour, a context fixture, and a bulk corner for the budget.
    try ws.createDirPath(io, ".git");
    try write(io, ws, ".gitignore", gitignore);
    try write(io, ws, "README.md", "hello ZQX_ALPHA\nsecond line\n");
    try write(io, ws, "src/main.zig", "const zqx_alpha = 1;\nZQX_ALPHA again\n");
    try write(io, ws, "src/util.zig", "fn zqxBeta() void {}\n");
    try write(io, ws, "src/notes.log", "ZQX_ALPHA in a log\n");
    try write(io, ws, "ignored/x.txt", "ZQX_ALPHA ignored\n");
    try write(io, ws, "node_modules/pkg/index.js", "ZQX_ALPHA node\n");
    try write(io, ws, "bin.dat", "ZQX_ALPHA\x00\x01\x02 binary\n");
    try write(io, ws, "crlf.txt", "line one\r\nZQX_ALPHA crlf\r\nline three\r\n");
    try write(io, ws, "ctx.txt", "a1\nZQX_CTX\na3\na4\na5\na6\nZQX_CTX\na8\n");
    try write(io, ws, "other.txt", "ZQX_MANY tail\n");
    {
        const big = try alloc.alloc(u8, 600 * 1024);
        defer alloc.free(big);
        @memset(big, 'x');
        @memcpy(big[big.len - 11 ..], "\nZQX_ALPHA\n");
        try write(io, ws, "big.txt", big);

        var many: std.Io.Writer.Allocating = .init(alloc);
        defer many.deinit();
        for (1..36) |i| try many.writer.print("ZQX_MANY {d}\n", .{i});
        try write(io, ws, "many.txt", many.written());

        const filler = try alloc.alloc(u8, 400);
        defer alloc.free(filler);
        @memset(filler, 'w');
        for (0..60) |f| {
            var body: std.Io.Writer.Allocating = .init(alloc);
            defer body.deinit();
            for (0..30) |l| try body.writer.print("ZQX_BULK {d}-{d} {s}\n", .{ f, l, filler });
            const name = try std.fmt.allocPrint(alloc, "bulk/f{d:0>2}.txt", .{f});
            defer alloc.free(name);
            try write(io, ws, name, body.written());
        }
    }

    // A hit lists one heading per file and `N: text` lines, relative to cwd;
    // the ignored file and directory, the pruned directory, the oversized file
    // and the binary file are absent; the CRLF line shows without its \r; the
    // prune note names what was skipped.
    {
        const out = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_ALPHA\"}", 0);
        defer alloc.free(out);
        try std.testing.expect(has(out, "README.md:\n1: hello ZQX_ALPHA"));
        try std.testing.expect(has(out, "src/main.zig:\n2: ZQX_ALPHA again"));
        try std.testing.expect(has(out, "crlf.txt:\n2: ZQX_ALPHA crlf\n"));
        try std.testing.expect(!has(out, "\r"));
        try std.testing.expect(!has(out, "notes.log"));
        try std.testing.expect(!has(out, "ignored/"));
        try std.testing.expect(!has(out, "node_modules/pkg"));
        try std.testing.expect(!has(out, "bin.dat"));
        try std.testing.expect(!has(out, "big.txt"));
        try std.testing.expect(!has(out, "zqx_alpha = 1")); // uppercase in the pattern: exact
        try std.testing.expect(has(out, "[2 pruned directories were skipped: .git/, node_modules/ — set `path` inside one explicitly to search it]"));
    }

    // Smart case: all-lowercase matches every casing; the knob widens an
    // uppercase pattern.
    {
        const lower = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"zqx_alpha\",\"path\":\"src/main.zig\"}", 0);
        defer alloc.free(lower);
        try std.testing.expectEqualStrings("src/main.zig:\n1: const zqx_alpha = 1;\n2: ZQX_ALPHA again\n", lower);
        const forced = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_ALPHA\",\"path\":\"src/main.zig\",\"case_insensitive\":true}", 0);
        defer alloc.free(forced);
        try std.testing.expectEqualStrings(lower, forced);
    }

    // The glob filter: by name anywhere, or by path from the base.
    {
        const zig = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"zqx\",\"glob\":\"*.zig\"}", 0);
        defer alloc.free(zig);
        try std.testing.expect(has(zig, "src/main.zig:"));
        try std.testing.expect(has(zig, "src/util.zig:\n1: fn zqxBeta() void {}"));
        try std.testing.expect(!has(zig, "README.md"));
        const md = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"zqx\",\"glob\":\"*.md\"}", 0);
        defer alloc.free(md);
        try std.testing.expect(has(md, "README.md:"));
        try std.testing.expect(!has(md, "src/"));
        const deep = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"zqx\",\"glob\":\"src/**/*.{zig,txt}\"}", 0);
        defer alloc.free(deep);
        try std.testing.expect(has(deep, "src/main.zig:"));
        try std.testing.expect(!has(deep, "README.md"));
        // A gitignored file stays excluded even when the glob names it.
        const logs = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_ALPHA\",\"glob\":\"*.log\"}", 0);
        defer alloc.free(logs);
        try std.testing.expect(std.mem.startsWith(u8, logs, "no matches for /ZQX_ALPHA/ (0 files scanned, glob *.log)"));
        try std.testing.expect(has(logs, "[.gitignore entries are excluded]"));
    }

    // Context: `N- text` around each match, `--` between disjoint blocks. An
    // explicit file is not walked, so the answer is exactly the listing.
    {
        const out = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_CTX\",\"context\":1,\"path\":\"ctx.txt\"}", 0);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("ctx.txt:\n1- a1\n2: ZQX_CTX\n3- a3\n--\n6- a6\n7: ZQX_CTX\n8- a8\n", out);
        const after = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_CTX\",\"after\":1,\"before\":0,\"path\":\"ctx.txt\",\"head_limit\":1}", 0);
        defer alloc.free(after);
        try std.testing.expectEqualStrings("ctx.txt:\n2: ZQX_CTX\n3- a3\n[more matches beyond this page — raise head_limit or set offset=1]\n", after);
    }

    // The per-file cap: a crowded file cannot hide its neighbour, and the cap
    // explains itself; alone, the same file is exempt and pages by offset.
    {
        const out = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_MANY\"}", 0);
        defer alloc.free(out);
        try std.testing.expect(has(out, "30: ZQX_MANY 30"));
        try std.testing.expect(!has(out, "31: ZQX_MANY 31"));
        try std.testing.expect(has(out, "other.txt:\n1: ZQX_MANY tail"));
        try std.testing.expect(has(out, "[5 further matches in 1 file not shown — over 30 per file; re-run with `path` set to one of them for the rest]"));

        const page1 = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_MANY\",\"path\":\"many.txt\",\"head_limit\":10}", 0);
        defer alloc.free(page1);
        try std.testing.expect(std.mem.startsWith(u8, page1, "many.txt:\n1: ZQX_MANY 1\n"));
        try std.testing.expect(has(page1, "\n10: ZQX_MANY 10\n[more matches beyond this page — raise head_limit or set offset=10]\n"));
        try std.testing.expect(!has(page1, "11: ZQX_MANY 11"));
        const page4 = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_MANY\",\"path\":\"many.txt\",\"head_limit\":10,\"offset\":30}", 0);
        defer alloc.free(page4);
        try std.testing.expectEqualStrings("many.txt:\n31: ZQX_MANY 31\n32: ZQX_MANY 32\n33: ZQX_MANY 33\n34: ZQX_MANY 34\n35: ZQX_MANY 35\n", page4);
        const past = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_MANY\",\"path\":\"many.txt\",\"offset\":99}", 0);
        defer alloc.free(past);
        try std.testing.expectEqualStrings("offset=99 is past the last of 35 matches for /ZQX_MANY/ — lower offset or drop it\n", past);
    }

    // No match: the count, the oversized skip with both remedies, the prune
    // note, the gitignore reminder.
    {
        const out = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_NOPE\"}", 0);
        defer alloc.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "no matches for /ZQX_NOPE/ ("));
        try std.testing.expect(has(out, " files scanned)\n"));
        try std.testing.expect(has(out, "[1 file over 512 KiB skipped — set `path` to a specific file up to 10240 KiB, or use shell for an unbounded search]"));
        try std.testing.expect(has(out, "[2 pruned directories were skipped: .git/, node_modules/"));
        try std.testing.expect(has(out, "[.gitignore entries are excluded]"));
    }

    // An explicit file path searches past the directory-scan size cap; and an
    // explicit path into a pruned directory searches it.
    {
        const big = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_ALPHA\",\"path\":\"big.txt\"}", 0);
        defer alloc.free(big);
        try std.testing.expectEqualStrings("big.txt:\n2: ZQX_ALPHA\n", big);
        const pruned = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_ALPHA\",\"path\":\"node_modules/pkg\"}", 0);
        defer alloc.free(pruned);
        try std.testing.expectEqualStrings("node_modules/pkg/index.js:\n1: ZQX_ALPHA node\n", pruned);
    }

    // Refusals: a pattern that will not compile teaches escaping; a path that
    // does not exist says so. Both are failed calls — on the `plain` wire that
    // is the message on stderr and a non-zero exit, which the CLI reports as
    // `exit 1` followed by it.
    {
        const bad = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_(unclosed\"}", 1);
        defer alloc.free(bad);
        try std.testing.expect(has(bad, "exit 1\nstderr:\ninvalid regex: /ZQX_(unclosed/"));
        try std.testing.expect(has(bad, "escape literal ( ) [ ] { } . * + ? with a backslash"));
        const gone = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"x\",\"path\":\"no/such/dir\"}", 1);
        defer alloc.free(gone);
        try std.testing.expect(has(gone, "exit 1\nstderr:\nsearch path does not exist: "));
        const missing = try call(alloc, io, ws, exe, ref, "grep", "{}", 1);
        defer alloc.free(missing);
        try std.testing.expect(has(missing, "exit 1\nstderr:\nmissing required parameter: pattern"));
    }

    // The whole answer stays under 100 KB on a tree that would exceed it, cut
    // at match granularity, and the paging note advertises the exact offset.
    {
        const out = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"ZQX_BULK\",\"path\":\"bulk\",\"head_limit\":400}", 0);
        defer alloc.free(out);
        try std.testing.expect(out.len <= 100 * 1024 + 1); // + the CLI's trailing newline
        try std.testing.expect(out.len > 90 * 1024);
        try std.testing.expect(has(out, "[more matches beyond this page — raise head_limit or set offset="));
        try std.testing.expect(!has(out, "[full output:")); // never the kernel's spill footer
        var shown: usize = 0;
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            if (line.len > 0 and std.ascii.isDigit(line[0])) {
                try std.testing.expect(std.mem.endsWith(u8, line, "w"));
                shown += 1;
            }
        }
        try std.testing.expect(shown > 100 and shown < 400);
        const marker = "set offset=";
        const at = std.mem.indexOf(u8, out, marker).?;
        const digits = out[at + marker.len .. std.mem.indexOfScalarPos(u8, out, at + marker.len, ']').?];
        try std.testing.expectEqual(shown, try std.fmt.parseInt(usize, digits, 10));
    }
}

test "bundled std glob: name and path patterns, mtime order with a stable tie-break, 200-per-page offset paging, pruned dirs reported, gitignore honoured, directory symlinks skipped by default" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const exe = try nulyaExe(alloc);
    defer alloc.free(exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;
    const ref = try buildStd(alloc, io, ws, exe);
    defer alloc.free(ref);

    try ws.createDirPath(io, ".git");
    try write(io, ws, ".gitignore", gitignore);
    try write(io, ws, "package.json", "{}\n");
    try write(io, ws, "src/app.zig", "a\n");
    try write(io, ws, "src/deep/x.zig", "b\n");
    try write(io, ws, "src/deep/x.log", "ignored\n");
    try write(io, ws, "ignored/y.zig", "ignored\n");
    try write(io, ws, "dist/index.d.ts", "export {};\n");
    try write(io, ws, "node_modules/@codemirror/lang-markdown/README.md", "docs\n");
    try write(io, ws, "node_modules/@codemirror/lang-markdown/dist/index.d.ts", "export {};\n");
    for (0..250) |i| {
        const name = try std.fmt.allocPrint(alloc, "pages/p{d:0>3}.txt", .{i});
        defer alloc.free(name);
        try write(io, ws, name, "x\n");
    }
    // Identical mtimes across the pages, then one made newer: order must come
    // from mtime first and the path tie-break second, run after run.
    {
        const stamp: std.Io.Timestamp = .now(io, .real);
        for (0..250) |i| {
            const name = try std.fmt.allocPrint(alloc, "pages/p{d:0>3}.txt", .{i});
            defer alloc.free(name);
            var f = try ws.openFile(io, name, .{ .mode = .read_write });
            defer f.close(io);
            try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = stamp } });
        }
        var f = try ws.openFile(io, "pages/p123.txt", .{ .mode = .read_write });
        defer f.close(io);
        try f.setTimestamps(io, .{ .modify_timestamp = .{ .new = stamp.addDuration(.fromSeconds(60)) } });
    }

    // A name pattern finds files at any depth; ignored and pruned ones are
    // absent and the pruned ones are reported.
    {
        const out = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.zig\"}", 0);
        defer alloc.free(out);
        try std.testing.expect(has(out, "src/app.zig"));
        try std.testing.expect(has(out, "src/deep/x.zig"));
        try std.testing.expect(!has(out, "ignored/"));
        try std.testing.expect(!has(out, ".log"));
        try std.testing.expect(has(out, "[3 pruned directories were skipped: .git/, dist/, node_modules/ — set `path` inside one explicitly to search it]"));
        const direct = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"src/*.zig\"}", 0);
        defer alloc.free(direct);
        try std.testing.expect(has(direct, "src/app.zig"));
        try std.testing.expect(!has(direct, "x.zig"));
        // Brace alternation, `path: "."`, and a pruned match that must not appear.
        const braces = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.{json,ts}\",\"path\":\".\"}", 0);
        defer alloc.free(braces);
        try std.testing.expect(std.mem.startsWith(u8, braces, "package.json\n"));
        try std.testing.expect(!has(braces, "dist/index.d.ts"));
    }

    // Pointed inside a pruned directory, the walk descends — through the
    // nested `dist` too.
    {
        const out = try call(alloc, io, ws, exe, ref, "glob", "{\"path\":\"node_modules/@codemirror/lang-markdown\",\"pattern\":\"**/*.d.ts\"}", 0);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("node_modules/@codemirror/lang-markdown/dist/index.d.ts\n", out);
    }

    // Newest first, ties by path, 200 per page, offset for the rest.
    {
        const first = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.txt\",\"path\":\"pages\"}", 0);
        defer alloc.free(first);
        try std.testing.expect(std.mem.startsWith(u8, first, "pages/p123.txt\npages/p000.txt\npages/p001.txt\n"));
        try std.testing.expect(has(first, "\n[250 matches; showing 1-200 — set offset=200 for more]\n"));
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, first, '\n');
        while (it.next()) |l| {
            if (std.mem.endsWith(u8, l, ".txt")) n += 1;
        }
        try std.testing.expectEqual(@as(usize, 200), n);
        const again = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.txt\",\"path\":\"pages\"}", 0);
        defer alloc.free(again);
        try std.testing.expectEqualStrings(first, again);

        const rest = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.txt\",\"path\":\"pages\",\"offset\":200}", 0);
        defer alloc.free(rest);
        try std.testing.expect(std.mem.startsWith(u8, rest, "pages/p200.txt\n"));
        try std.testing.expect(std.mem.endsWith(u8, rest, "pages/p249.txt\n"));
        try std.testing.expect(!has(rest, "set offset="));
        const past = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.txt\",\"path\":\"pages\",\"offset\":900}", 0);
        defer alloc.free(past);
        try std.testing.expectEqualStrings("offset=900 is past the last of 250 matches for *.txt — lower offset or drop it\n", past);
    }

    // Nothing matched: said under the base's name, with the prune note.
    {
        const out = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.nothing\"}", 0);
        defer alloc.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "no files match *.nothing under .\n"));
        try std.testing.expect(has(out, "[3 pruned directories were skipped"));
        const under = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"*.nothing\",\"path\":\"src\"}", 0);
        defer alloc.free(under);
        try std.testing.expectEqualStrings("no files match *.nothing under src\n", under);
    }

    // A directory symlink is skipped and counted by default, and followed on
    // request. Creating one needs a privilege Windows does not always grant;
    // without it this part is skipped, not failed (silently — the build runner
    // echoes any stderr as if the step had failed).
    {
        try ws.createDirPath(io, "root");
        try write(io, ws, "arbor-skill/SKILL.md", "skill\n");
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const ws_abs = buf[0..try ws.realPath(io, &buf)];
        const target = try std.fs.path.join(alloc, &.{ ws_abs, "arbor-skill" });
        defer alloc.free(target);
        const linked = ws.symLink(io, target, "root/arbor", .{ .is_directory = true });
        if (linked) |_| {
            const skipped = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"**/SKILL.md\",\"path\":\"root\"}", 0);
            defer alloc.free(skipped);
            try std.testing.expect(std.mem.startsWith(u8, skipped, "no files match **/SKILL.md under root\n"));
            try std.testing.expect(has(skipped, "[1 directory symlink was skipped — set follow_symlinks=true to search their targets]"));
            const followed = try call(alloc, io, ws, exe, ref, "glob", "{\"pattern\":\"**/SKILL.md\",\"path\":\"root\",\"follow_symlinks\":true}", 0);
            defer alloc.free(followed);
            try std.testing.expectEqualStrings("root/arbor/SKILL.md\n", followed);
            // grep never follows: the linked directory is simply not searched.
            const grepped = try call(alloc, io, ws, exe, ref, "grep", "{\"pattern\":\"skill\",\"path\":\"root\"}", 0);
            defer alloc.free(grepped);
            try std.testing.expect(std.mem.startsWith(u8, grepped, "no matches for /skill/ (0 files scanned)"));
        } else |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {},
            else => return err,
        }
    }
}
