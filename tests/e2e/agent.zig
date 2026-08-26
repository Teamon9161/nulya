//! Delegation end to end (CLAUDE.md T32, docs/goals/agent-runner.md): the
//! bundled `agent` package and every runner that can hold a delegation.
//!
//! A delegation is a `d-*` identity of its own with its own append-only record;
//! the runner behind it may be a nulya session, an external harness driven over
//! its own protocol (Codex, Claude, pi — all answered offline by the fakes
//! `build.zig` builds for exactly this), or somebody else's extension speaking
//! the `agent_runner` contract. What is pinned down here is the side of that
//! conversation this repository owns: which requests go out and when, what the
//! record freezes, how a turn sent mid-run is queued rather than refused, how an
//! interrupt stops a round, and how the report comes back to the parent through
//! its inbox.
//!
//! Split out of `extension.zig` so `zig build e2e-agent` is a step of its own
//! (the tests here are the suite's slowest: every one drives a real background
//! task). The tests moved verbatim.

const std = @import("std");
const support = @import("support.zig");

const EnvPair = support.EnvPair;
const buildBundled = support.buildBundled;
const extractVersion = support.extractVersion;
const runCli = support.runCli;
const runCliEnvs = support.runCliEnvs;

/// How long a wait in this file sits before calling it a failure — as an
/// argument to `nulya task wait`, and as a poll count at 50 ms below.
///
/// These are budgets, not delays: every one of them returns the instant the
/// thing it waits for happens, so a large number costs nothing on a healthy
/// run. It is only paid when a test is already failing. A SMALL number, on the
/// other hand, is paid whenever the machine is busy — as a red suite that says
/// nothing about the code (docs/goals/agent-runner.md §6, "测试提速"). Every
/// test here drives at least one real child `nulya session step`, so "busy"
/// includes the other three e2e groups running beside this one.
const wait_budget_ms = "180000";
const wait_tries = 3600; // × 50 ms — the same budget, polled

// ── The bundled agent extension: delegation over the task substrate ─────────

test "bundled agent: render writes a persona nothing installs; a delegation opens a child session wearing its bytes, runs it as a background task of the parent, holds a read-only agent to the gate, and reports back through the parent's inbox" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // Two definitions: one read-only, one ordinary. Front matter is a set of
    // `session new` arguments; the body is the system prompt.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data =
        \\---
        \\description: a read-only prober
        \\readonly: true
        \\max_steps: 2
        \\pins: [nonsense]
        \\---
        \\You only read. Report what you found.
        \\
        ,
    });

    // ① `render` is the ONE implementation of that rendering: it writes the body
    // where `session new --prompt` can read it and answers with the whole set of
    // arguments the definition asks for. Content-determined, so running it twice
    // is the same file.
    var prompt_rel: []u8 = undefined;
    {
        const first = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"prober\"}" });
        defer alloc.free(first.stdout);
        try std.testing.expectEqual(@as(u8, 0), first.code);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, first.stdout, " \r\n"), .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("agent-prober", obj.get("label").?.string);
        try std.testing.expectEqual(true, obj.get("readonly").?.bool);
        try std.testing.expectEqual(@as(i64, 2), obj.get("max_steps").?.integer);
        // A pin the kernel could not resolve refuses the whole `session new`, so
        // a malformed one is dropped here — and said out loud.
        try std.testing.expectEqual(@as(usize, 0), obj.get("pins").?.array.items.len);
        try std.testing.expect(std.mem.indexOf(u8, obj.get("warnings").?.array.items[0].string, "nonsense") != null);
        prompt_rel = try alloc.dupe(u8, obj.get("prompt").?.string);

        const again = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"prober\"}" });
        defer alloc.free(again.stdout);
        try std.testing.expect(std.mem.indexOf(u8, again.stdout, prompt_rel) != null);
    }
    defer alloc.free(prompt_rel);

    // The persona is a FILE, and nothing installed it: no `agent-*` package
    // appears in the store, so `/ext` has nothing new in it and `ext prune`
    // cannot break the resume of a session wearing one.
    {
        const body = try ws.readFileAlloc(io, prompt_rel, alloc, .limited(1 << 16));
        defer alloc.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "You only read.") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/extensions/agent-prober", .{}));
    }

    // ② An unknown name lists the ones there are, and creates nothing.
    {
        const unknown = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"nope\"}" });
        defer alloc.free(unknown.stdout);
        try std.testing.expectEqual(@as(u8, 1), unknown.code);
        try std.testing.expect(std.mem.indexOf(u8, unknown.stdout, "no agent 'nope'") != null);
        try std.testing.expect(std.mem.indexOf(u8, unknown.stdout, "prober") != null);
    }

    // ③ Outside a session there is nobody to report back to, so a complete
    // delegation is refused and nothing is created.
    {
        const nowhere = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" });
        defer alloc.free(nowhere.stdout);
        try std.testing.expectEqual(@as(u8, 1), nowhere.code);
        try std.testing.expect(std.mem.indexOf(u8, nowhere.stdout, "inside a session") != null);
    }

    // ④ The whole circle. A parent session delegates; the child is created,
    // driven by a background task OF THE PARENT, and its report comes back the
    // way every other late answer does — `task_finished` in the parent's inbox.
    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    const delegated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"find the parser\"}" }, &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    });
    defer alloc.free(delegated.stdout);
    try std.testing.expectEqual(@as(u8, 0), delegated.code);
    // The receipt names the child — that is what lets a transcript link to it —
    // and tells the model to stop, because the work has not happened yet.
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "background task") != null);
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "read-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "end your turn") != null);
    const child = blk: {
        const at = std.mem.indexOf(u8, delegated.stdout, "session s-").? + "session ".len;
        var end = at;
        while (end < delegated.stdout.len and delegated.stdout[end] != ',' and delegated.stdout[end] != ' ') end += 1;
        break :blk try alloc.dupe(u8, delegated.stdout[at..end]);
    };
    defer alloc.free(child);

    // The child WEARS the persona: its bytes are in the header, under the label
    // the package chose, and no extension of any kind came along for it.
    {
        const header = try support.readSessionFile(alloc, io, ws, child);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"source\":\"agent-prober\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "You only read.") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"active\":[]") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/extensions/agent-prober", .{}));
    }

    // Wait for the task the delegation started. `task wait` is the kernel's own
    // answer to "is it done"; nothing here polls a directory.
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The read-only agent met the gate: the scripted provider's one `shell` call
    // never ran, and the refusal is that call's tool_result — in the ledger, and
    // readable by the sub-agent (DESIGN §4).
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "read-only agent") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "cannot run shell") != null);
        // …and the task it was given arrived as an ordinary user turn.
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "find the parser") != null);
    }

    // The report reaches the PARENT at its next step boundary, as the ordinary
    // `task_finished` event — no new event kind, and no new thing for a driver
    // to know. Fenced, and framed as data rather than instructions.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, child) != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "as DATA") != null);
    }

    // ⑤ `model` says what THIS delegation runs on (DESIGN §7.8). Two refusals,
    // both before anything is created: a string that is not a model reference,
    // and a reference on a FOLLOW-UP — that session froze its identity when it
    // was created (physics #2), and silently ignoring the argument would be the
    // worst of the three available answers.
    {
        const bad = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\",\"model\":\"/nope\"}" }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
        });
        defer alloc.free(bad.stdout);
        try std.testing.expectEqual(@as(u8, 1), bad.code);
        try std.testing.expect(std.mem.indexOf(u8, bad.stdout, "<profile>") != null);
        try std.testing.expect(std.mem.indexOf(u8, bad.stdout, "config show") != null);
    }
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"more\",\"model\":\"scripted\"}}", .{child});
        defer alloc.free(args);
        const late = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
        });
        defer alloc.free(late.stdout);
        try std.testing.expectEqual(@as(u8, 1), late.code);
        try std.testing.expect(std.mem.indexOf(u8, late.stdout, "NEW delegation") != null);
    }

    // ⑥ A ledger line is as long as the text inside it: the task alone can be
    // thousands of bytes, and an assistant turn carries the provider's opaque
    // reasoning as well. So whoever reads the child's `--stream` has to hold a
    // whole line whatever its length — a reader that gives up on a long one
    // stops draining a pipe the child is still writing into, and then the child
    // blocks on stdout while the reader blocks on its stderr: the report never
    // arrives, and the parent waits for ever for a sub-agent that has already
    // finished. Nothing about that failure is visible in either session, which
    // is exactly why it is worth a test.
    {
        const long = try alloc.alloc(u8, 12 << 10);
        defer alloc.free(long);
        @memset(long, 'x');
        const args = try std.fmt.allocPrint(alloc, "{{\"name\":\"prober\",\"task\":\"{s}\"}}", .{long});
        defer alloc.free(args);
        const big = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(big.stdout);
        try std.testing.expectEqual(@as(u8, 0), big.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
    }
}

test "bundled agent: the personas the package ships need no files — list layers workspace over user over builtin and marks what it shadows, and a delegation to the builtin explore runs read-only with the pins its definition asks for" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // ① Nothing written anywhere: `explore`, `plan` and `general` are already
    // there. Distribution is the binary (DESIGN §7.8) — no install step, and no
    // directory to create.
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "list", "{}" });
        defer alloc.free(listed.stdout);
        try std.testing.expectEqual(@as(u8, 0), listed.code);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, listed.stdout, " \r\n"), .{});
        defer parsed.deinit();
        const rows = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 4), rows.len);
        for ([_][]const u8{ "explore", "general", "orchestrator", "plan" }) |want| {
            for (rows) |row| {
                if (!std.mem.eql(u8, row.object.get("name").?.string, want)) continue;
                try std.testing.expectEqualStrings("builtin", row.object.get("layer").?.string);
                try std.testing.expectEqual(false, row.object.get("shadowed").?.bool);
                try std.testing.expect(row.object.get("description").?.string.len != 0);
                // Every persona brings SOMETHING: tools to work with, or the
                // names it may pass work to (the coordinator's whole job).
                try std.testing.expect(row.object.get("pins").?.array.items.len != 0 or
                    row.object.get("agents").?.array.items.len != 0);
                break;
            } else return error.TestUnexpectedResult;
        }
        // The one that is read-only is the one that says so.
        for (rows) |row| {
            const ro = row.object.get("readonly").?.bool;
            try std.testing.expectEqual(std.mem.eql(u8, row.object.get("name").?.string, "explore"), ro);
        }
    }

    // ② A workspace definition of the same name WINS, and the builtin is still
    // listed, marked — the store roots' rule (§7.2), not a reserved name.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{ .sub_path = ".nulya/agents/explore.md", .data = "---\ndescription: mine\n---\nmy own explore\n" });
    {
        const listed = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "list", "{}" });
        defer alloc.free(listed.stdout);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, listed.stdout, " \r\n"), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 5), parsed.value.array.items.len);
        var winner_layer: []const u8 = "";
        var shadowed_builtin = false;
        for (parsed.value.array.items) |row| {
            if (!std.mem.eql(u8, row.object.get("name").?.string, "explore")) continue;
            if (row.object.get("shadowed").?.bool) {
                try std.testing.expectEqualStrings("builtin", row.object.get("layer").?.string);
                shadowed_builtin = true;
            } else winner_layer = row.object.get("layer").?.string;
        }
        try std.testing.expectEqualStrings("workspace", winner_layer);
        try std.testing.expect(shadowed_builtin);
        // …and the winner is what rendering that name writes.
        const m = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"explore\"}" });
        defer alloc.free(m.stdout);
        try std.testing.expect(std.mem.indexOf(u8, m.stdout, "\"layer\":\"workspace\"") != null);
    }
    try ws.deleteFile(io, ".nulya/agents/explore.md");

    // ③ The builtin `explore` pins `std`'s read-only tools. `render` hands those
    // pins on as written and has no opinion about whether they resolve: a pin
    // brings its own package into the session (DESIGN §5.1), so there is exactly
    // one judge of that, and it is the `session new` that would be refused.
    // Nothing is derived here, and no `members` list is answered any more.
    {
        const rendered = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "render", "{\"name\":\"explore\"}" });
        defer alloc.free(rendered.stdout);
        try std.testing.expectEqual(@as(u8, 0), rendered.code);
        try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "\"ext:std/read\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered.stdout, "\"members\"") == null);
    }

    // ④ With `std` active, the builtin persona delegates for real: its pins
    // become the child's tool face, the membership they imply comes with them,
    // and `readonly` is held at the kernel's gate.
    const std_ref = try buildBundled(alloc, io, ws, exe_abs, "std");
    defer alloc.free(std_ref);
    const std_version = std_ref[std.mem.indexOfScalar(u8, std_ref, '@').? + 1 ..];
    {
        const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", "std", std_version });
        defer alloc.free(activated.stdout);
        try std.testing.expectEqual(@as(u8, 0), activated.code);
    }

    // What "read-only" MEANS at the gate now travels on the gate request itself
    // (DESIGN §4), frozen from this very manifest at composition time. `ext
    // inspect <id>@<version>` still has to answer for it — it is how a person
    // checks the same claim — but nothing reads it to build an allow-list any
    // more, which is the derivation that once came back empty and made a
    // read-only delegation read-only in name only (BUGS #16).
    {
        const frozen = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "inspect", std_ref });
        defer alloc.free(frozen.stdout);
        try std.testing.expectEqual(@as(u8, 0), frozen.code);
        try std.testing.expect(std.mem.indexOf(u8, frozen.stdout, "\"readonly\": true") != null);
    }

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    const delegated = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"explore\",\"task\":\"find the parser\"}" }, &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    });
    defer alloc.free(delegated.stdout);
    try std.testing.expectEqual(@as(u8, 0), delegated.code);
    try std.testing.expect(std.mem.indexOf(u8, delegated.stdout, "read-only") != null);
    const child = blk: {
        const at = std.mem.indexOf(u8, delegated.stdout, "session s-").? + "session ".len;
        var end = at;
        while (end < delegated.stdout.len and delegated.stdout[end] != ',' and delegated.stdout[end] != ' ') end += 1;
        break :blk try alloc.dupe(u8, delegated.stdout[at..end]);
    };
    defer alloc.free(child);

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The child's frozen composition: the persona as BYTES the header holds, the
    // `std` its pins brought in as the only member (nothing on the delegation's
    // command line named it — the kernel's own implication did, DESIGN §5.1),
    // and exactly the three read-only tools on its native face. The persona is
    // not an extension — the store gained nothing from this delegation.
    {
        const header = try support.readSessionFile(alloc, io, ws, child);
        defer alloc.free(header);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"source\":\"agent-explore\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"id\":\"agent-explore\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"id\":\"std\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, header, "\"native_tools\":[\"ext:std/read\",\"ext:std/grep\",\"ext:std/glob\"]") != null);
        try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/extensions/agent-explore", .{}));
    }
    // …and the gate held it to them: the scripted provider's `shell` never ran.
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "cannot run shell") != null);
    }
}

test "bundled agent: a delegation is a d-id of its own — another turn goes into the same conversation, its exchange budget is counted from the delegation's record rather than the child's ledger, and a session id is refused with the word that replaced it" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // No pins: this test is about the conversation, not about a tool face.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/worker.md",
        .data = "---\ndescription: plain worker\nmax_exchanges: 2\n---\nDo the work.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const in_parent: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // ① The first delegation. The receipt names the DELEGATION — what the model
    //    says back to this tool — and, because the abstraction does not hide
    //    anything (D2), the remote conversation behind it as well.
    const first = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"first\"}" }, in_parent);
    defer alloc.free(first.stdout);
    try std.testing.expectEqual(@as(u8, 0), first.code);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "call agent again with session=d-") != null);
    const d = try delegationOf(alloc, first.stdout);
    defer alloc.free(d);
    const child = try remoteOf(alloc, first.stdout);
    defer alloc.free(child);

    // The record is this package's own journal of it: one opening row naming the
    // runner and what it opened, then one row per message.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"kind\":\"created\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"nulya\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, child) != null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }
    // Read the first report, as a model would before following up — and as this
    // test must, since `task wait --any` counts a done task whose result nobody
    // has drained yet.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        // The frame names the delegation, and the sentence under it still points
        // at the remote transcript.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, d) != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "session events") != null);
    }

    // ② The exchange budget is the RECORD's turn count, not the child ledger's
    //    user turns — the only count an external runner could ever answer too.
    //    Two turns appended to the child directly, behind this tool's back, are
    //    three user turns in that session and still one message in the
    //    delegation: the budget must not move.
    {
        for ([_][]const u8{ "sideband one", "sideband two" }) |text| {
            const said = try runCli(alloc, io, ws, &.{ exe_abs, "session", "append", child, text });
            defer alloc.free(said.stdout);
            try std.testing.expectEqual(@as(u8, 0), said.code);
        }
    }

    const before = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(before.stdout);
    const follow_request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"second, be specific\"}}", .{d});
    defer alloc.free(follow_request);
    const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", follow_request }, in_parent);
    defer alloc.free(again.stdout);
    try std.testing.expectEqual(@as(u8, 0), again.code);
    try std.testing.expect(std.mem.indexOf(u8, again.stdout, d) != null);
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }
    // Nothing new was created: another turn goes into the conversation that
    // already holds everything it found (DESIGN §1).
    const after = try runCli(alloc, io, ws, &.{ exe_abs, "session", "list" });
    defer alloc.free(after.stdout);
    try std.testing.expectEqual(std.mem.count(u8, before.stdout, "\n"), std.mem.count(u8, after.stdout, "\n"));
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "second, be specific") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "sideband two") != null);
    }
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
    }

    // ③ The budget itself. Two turns have been sent into the delegation and it
    //    allows two follow-ups on top of the first, so a third goes through —
    //    which the child's four user turns would already have refused — and the
    //    fourth is named, with the number.
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"third\"}}", .{d});
        defer alloc.free(request);
        const within = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(within.stdout);
        try std.testing.expectEqual(@as(u8, 0), within.code);
    }
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"fourth\"}}", .{d});
        defer alloc.free(request);
        const over = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(over.stdout);
        try std.testing.expectEqual(@as(u8, 1), over.code);
        try std.testing.expect(std.mem.indexOf(u8, over.stdout, "follow-up turn") != null);
    }

    // ④ The vocabulary. A SESSION id is what this took before delegations had
    //    ids of their own; it is refused with the word that replaced it rather
    //    than with a missing directory (D11), and an id of the right shape that
    //    names nothing is a different answer again.
    {
        const old_shape = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"x\"}}", .{child});
        defer alloc.free(old_shape);
        const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", old_shape }, in_parent);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "d-") != null);

        const unknown = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"session\":\"d-000000000000\",\"task\":\"x\"}" }, in_parent);
        defer alloc.free(unknown.stdout);
        try std.testing.expectEqual(@as(u8, 1), unknown.code);
        try std.testing.expect(std.mem.indexOf(u8, unknown.stdout, "no delegation") != null);
    }

    // ⑤ Neither / both / interrupt without something to interrupt.
    {
        const neither = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"task\":\"x\"}" }, in_parent);
        defer alloc.free(neither.stdout);
        try std.testing.expect(std.mem.indexOf(u8, neither.stdout, "EITHER name") != null);
        const both = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"session\":\"d-000000000000\",\"task\":\"x\"}" }, in_parent);
        defer alloc.free(both.stdout);
        try std.testing.expect(std.mem.indexOf(u8, both.stdout, "not both") != null);
        const early = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"x\",\"interrupt\":true}" }, in_parent);
        defer alloc.free(early.stdout);
        try std.testing.expectEqual(@as(u8, 1), early.code);
        try std.testing.expect(std.mem.indexOf(u8, early.stdout, "interrupt applies") != null);
    }

    // Let the last runner finish before the workspace goes away.
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        alloc.free(waited.stdout);
    }
}

test "bundled agent: the wake invariant — a turn sent while a runner holds the delegation's lease is queued rather than refused and starts nothing, a runner that loses the race for that lease reports nothing at all, and a turn sent once the lease is free starts a fresh runner that finds everything waiting" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/worker.md",
        .data = "---\ndescription: plain worker\n---\nDo the work.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const in_parent: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const first = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"first\"}" }, in_parent);
    defer alloc.free(first.stdout);
    try std.testing.expectEqual(@as(u8, 0), first.code);
    const d = try delegationOf(alloc, first.stdout);
    defer alloc.free(d);
    const child = try remoteOf(alloc, first.stdout);
    defer alloc.free(child);
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, in_parent);
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stepped.stdout, "\"kind\":\"task_finished\""));
    }

    const lock_path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/.runner.lock", .{d});
    defer alloc.free(lock_path);

    // ① A runner is driving. Its lease is what says so — an OS lock, so nothing
    //    has to be believed about a process that may already be dead. A turn
    //    sent now is ACCEPTED (D3: it is what a person typing mid-answer does),
    //    queued into the conversation, and starts no second runner: the holder
    //    will find it.
    var held = try ws.createFile(io, lock_path, .{ .truncate = false, .read = true, .lock = .exclusive });
    const tasks_before = try countTasks(alloc, io, ws, exe_abs, parent);
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"queued one\"}}", .{d});
        defer alloc.free(request);
        const queued = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(queued.stdout);
        try std.testing.expectEqual(@as(u8, 0), queued.code);
        try std.testing.expect(std.mem.indexOf(u8, queued.stdout, "working right now") != null);
    }
    try std.testing.expectEqual(tasks_before, try countTasks(alloc, io, ws, exe_abs, parent));

    // ② A redundant runner — two senders probing at the same moment is the race
    //    the lease exists for — loses it and says NOTHING. A report frame from a
    //    runner that drove nothing would be a sub-agent's findings that no
    //    sub-agent produced, arriving in the parent as an ordinary message.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"delegation\":\"{s}\",\"session\":\"{s}\",\"agent\":\"worker\"}}", .{ d, child });
        defer alloc.free(args);
        const lost = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "run", args }, in_parent);
        defer alloc.free(lost.stdout);
        try std.testing.expectEqual(@as(u8, 0), lost.code);
        try std.testing.expect(std.mem.indexOf(u8, lost.stdout, "<agent-report") == null);
    }

    // ③ The lease is free again — the runner left, or was killed, and the OS
    //    released it either way. The next turn starts a fresh runner, and that
    //    runner finds BOTH messages: the one queued while the lease was held has
    //    been waiting in the conversation all along.
    held.close(io);
    {
        const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"queued two\"}}", .{d});
        defer alloc.free(request);
        const sent = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, in_parent);
        defer alloc.free(sent.stdout);
        try std.testing.expectEqual(@as(u8, 0), sent.code);
        try std.testing.expect(std.mem.indexOf(u8, sent.stdout, "background task") != null);
    }
    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }
    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "queued one") != null);
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "queued two") != null);
    }
}

test "bundled agent: an interrupt stops the run in flight — the step is killed where it stands, the kernel repairs the batch it left, and the message the interrupt carried is taken up in the next round" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // `loop` never ends its turn, so this delegation keeps stepping until its
    // budget runs out — a run that is genuinely in flight to interrupt.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/slow.md",
        .data = "---\ndescription: never finishes on its own\nmax_steps: 30\n---\nKeep going.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const looping: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "loop" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"slow\",\"task\":\"go on for a while\"}" }, looping);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const child = try remoteOf(alloc, started.stdout);
    defer alloc.free(child);

    // Wait until the run is actually under way: the first tool result in the
    // child's ledger says a step is executing, which is what an interrupt is for.
    try waitForEvent(alloc, io, ws, exe_abs, child, "\"kind\":\"tool_results\"");

    const request = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"INTERRUPT-SENTINEL\",\"interrupt\":true}}", .{d});
    defer alloc.free(request);
    const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, looping);
    defer alloc.free(interrupted.stdout);
    try std.testing.expectEqual(@as(u8, 0), interrupted.code);

    // An interrupt is a DELIVERY, not a kind of message (D3): the record holds
    // one ordinary turn row, marked with how it was sent.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"interrupt\":true") != null);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", child });
        defer alloc.free(events.stdout);
        // The step that was running died where it stood, leaving a call batch
        // with no results; the kernel closes it at the next step boundary, which
        // is the next round of the very same runner (DESIGN §4).
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "interrupted before Nulya recorded results") != null);
        // …and the message the interrupt carried is in the conversation.
        try std.testing.expect(std.mem.indexOf(u8, events.stdout, "INTERRUPT-SENTINEL") != null);
    }
    // The marker is consumed, never left behind to cut short a later round.
    {
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        try std.testing.expectError(error.FileNotFound, ws.access(io, marker, .{}));
    }
}

/// The delegation id out of a receipt (`… — delegation d-…, session s-…`).
fn delegationOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "delegation d-").? + "delegation ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

/// The remote conversation out of the same receipt — named on purpose: the
/// abstraction gives the facts one name, it does not hide them (D2).
fn remoteOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "session s-").? + "session ".len;
    var end = at;
    while (end < text.len and text[end] != ',' and text[end] != ' ') end += 1;
    return alloc.dupe(u8, text[at..end]);
}

fn readRecord(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, d: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/record.jsonl", .{d});
    defer alloc.free(path);
    return ws.readFileAlloc(io, path, alloc, .limited(1 << 20));
}

fn countTasks(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    parent: []const u8,
) !usize {
    const listed = try runCli(alloc, io, ws, &.{ exe_abs, "task", "list", "--session", parent, "--json" });
    defer alloc.free(listed.stdout);
    return std.mem.count(u8, listed.stdout, "\"full\"");
}

/// Poll a session's ledger until `needle` shows up. Bounded, because a test that
/// hangs says less than one that fails.
fn waitForEvent(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    session_id: []const u8,
    needle: []const u8,
) !void {
    var tries: usize = 0;
    while (tries < wait_tries) : (tries += 1) {
        const events = try runCli(alloc, io, ws, &.{ exe_abs, "session", "events", session_id });
        defer alloc.free(events.stdout);
        if (std.mem.indexOf(u8, events.stdout, needle) != null) return;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "bundled agent: only a persona with an agents whitelist carries the tool, it may reach only the names on that list, and the depth backstop stops an indirect cycle" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{ .sub_path = ".nulya/agents/worker.md", .data = "---\ndescription: a leaf\n---\nDo the work.\n" });
    try ws.writeFile(io, .{ .sub_path = ".nulya/agents/boss.md", .data = "---\ndescription: coordinates\nagents: [worker]\n---\nYou coordinate.\n" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const in_parent: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // A coordinator's session carries the tool; a leaf's does not — one field in
    // one place decides it, so a leaf has nothing to refuse later.
    //
    // MEMBERSHIP is the whole of that decision. `agent` is `surface: "auto"`
    // (§5.1), so the one `--with` the delegation adds for a coordinator both
    // freezes the package into `active` and puts its entry tool in the native
    // face; no pin is passed, and one naming it would be refused. The three
    // `internal` tools stay off that face — `--bare` means nothing else can put
    // them there either, so the list is exactly one long.
    const boss_file = try delegateTo(alloc, io, ws, exe_abs, ref, in_parent, parent, "boss", "coordinate");
    defer alloc.free(boss_file);
    const worker_file = try delegateTo(alloc, io, ws, exe_abs, ref, in_parent, parent, "worker", "work");
    defer alloc.free(worker_file);
    {
        const boss_header = try support.readSessionFile(alloc, io, ws, std.fs.path.stem(boss_file));
        defer alloc.free(boss_header);
        try std.testing.expect(std.mem.indexOf(u8, boss_header, "\"native_tools\":[\"ext:agent/agent\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, boss_header, "\"id\":\"agent\"") != null);
        // A leaf is not a member at all, so the tool is nowhere in its header —
        // neither as a frozen member nor as a native slot.
        const worker_header = try support.readSessionFile(alloc, io, ws, std.fs.path.stem(worker_file));
        defer alloc.free(worker_header);
        try std.testing.expect(std.mem.indexOf(u8, worker_header, "ext:agent/agent") == null);
        try std.testing.expect(std.mem.indexOf(u8, worker_header, "\"id\":\"agent\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, worker_header, "\"native_tools\":[]") != null);
    }

    const in_boss: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = boss_file },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // The whitelist is read from the persona this session is WEARING (its frozen
    // header), and a name off the list comes back with the list.
    {
        const denied = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"explore\",\"task\":\"x\"}" }, in_boss);
        defer alloc.free(denied.stdout);
        try std.testing.expectEqual(@as(u8, 1), denied.code);
        try std.testing.expect(std.mem.indexOf(u8, denied.stdout, "may only delegate to: worker") != null);
    }

    // A leaf's session refuses every name, and says why rather than listing none.
    {
        const in_worker: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = worker_file },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        };
        const denied = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"x\"}" }, in_worker);
        defer alloc.free(denied.stdout);
        try std.testing.expectEqual(@as(u8, 1), denied.code);
        try std.testing.expect(std.mem.indexOf(u8, denied.stdout, "cannot delegate") != null);
    }

    // The depth backstop: a whitelist cannot see an INDIRECT cycle (`a` may
    // delegate to `b`, `b` to `a`), so the runner tells each step how deep it is
    // and this refuses at the bound. Not a security boundary — the variable is
    // absent when a person drives a delegated session — and it says so in DESIGN.
    {
        const deep: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = boss_file },
            .{ .key = "NULYA_AGENT_DEPTH", .value = "3" },
        };
        const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"worker\",\"task\":\"x\"}" }, deep);
        defer alloc.free(refused.stdout);
        try std.testing.expectEqual(@as(u8, 1), refused.code);
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "levels deep") != null);
    }
}

/// Delegate to `name` from `parent` and wait for the report; returns the child's
/// session FILE path (what `NULYA_SESSION` takes). Caller frees.
fn delegateTo(
    alloc: std.mem.Allocator,
    io: std.Io,
    ws: std.Io.Dir,
    exe_abs: []const u8,
    ref: []const u8,
    env: []const EnvPair,
    parent: []const u8,
    name: []const u8,
    task: []const u8,
) ![]u8 {
    const request = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"task\":\"{s}\"}}", .{ name, task });
    defer alloc.free(request);
    const out = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", request }, env);
    defer alloc.free(out.stdout);
    try std.testing.expectEqual(@as(u8, 0), out.code);
    const at = std.mem.indexOf(u8, out.stdout, "session s-").? + "session ".len;
    var end = at;
    while (end < out.stdout.len and out.stdout[end] != ',' and out.stdout[end] != ' ') end += 1;
    const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
    alloc.free(waited.stdout);
    return std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{out.stdout[at..end]});
}

// ── the Codex runner (contract ar-d) ────────────────────────────────────────
//
// A delegation whose definition says `runner: codex` is held by a Codex thread
// instead of a nulya session. These run against `tests/fake_codex.zig` — an
// app-server that answers the protocol and never leaves this machine — because
// everything worth pinning down is on THIS side of that conversation: which
// requests the runner sends, when it sends them, and what it refuses to open.

/// The offline app-server, built by `build.zig` for exactly this. Absent means
/// the suite was not launched through `zig build e2e`.
fn fakeCodex(alloc: std.mem.Allocator) !?[]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const named = host_env.get("NULYA_FAKE_CODEX") orelse return null;
    if (named.len == 0) return null;
    return try std.fs.path.resolve(alloc, &.{named});
}

/// The remote out of a codex receipt (`… — delegation d-…, codex thread t-…`).
/// Named on purpose, like the nulya one: the abstraction gives the facts one
/// name, it does not hide them (D2).
fn codexThreadOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "codex thread ").? + "codex thread ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

/// Poll a file in the workspace until it holds `needle`. Bounded, because a test
/// that hangs says less than one that fails.
fn waitForText(
    io: std.Io,
    alloc: std.mem.Allocator,
    ws: std.Io.Dir,
    path: []const u8,
    needle: []const u8,
) !void {
    var tries: usize = 0;
    while (tries < wait_tries) : (tries += 1) {
        if (ws.readFileAlloc(io, path, alloc, .limited(1 << 20))) |body| {
            defer alloc.free(body);
            if (std.mem.indexOf(u8, body, needle) != null) return;
        } else |_| {}
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

/// Poll until a path is gone. Used on the runner's own on-disk state — an empty
/// `<d>/inbox/` means the runner took the message, a missing `<d>/interrupt`
/// means it took the marker — so a test waits on a FACT rather than on a guess
/// about how fast a background task runs.
fn waitForGone(io: std.Io, ws: std.Io.Dir, path: []const u8) !void {
    var tries: usize = 0;
    while (tries < wait_tries) : (tries += 1) {
        ws.access(io, path, .{}) catch return;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

fn inboxEmpty(io: std.Io, alloc: std.mem.Allocator, ws: std.Io.Dir, d: []const u8) !bool {
    const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/inbox", .{d});
    defer alloc.free(path);
    var dir = ws.openDir(io, path, .{ .iterate = true }) catch return true;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".json")) return false;
    }
    return true;
}

fn waitForInboxDrained(io: std.Io, alloc: std.mem.Allocator, ws: std.Io.Dir, d: []const u8) !void {
    var tries: usize = 0;
    while (tries < wait_tries) : (tries += 1) {
        if (try inboxEmpty(io, alloc, ws, d)) return;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "bundled agent: a codex delegation is a thread, not a session — the record freezes the runner and its opaque model, the report comes back through the parent's inbox, and a turn sent while it is idle waits in the delegation's own inbox until the next round takes it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const codex_exe = (try fakeCodex(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(codex_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    // A definition whose only nulya-shaped field is the body. `runner_model` is
    // the other harness's vocabulary (D9) — never parsed here.
    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: reads the codebase through codex\nrunner: codex\nrunner_model: some-codex-model\n---\nYou are a scout. Report what you found.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const with_codex: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // ① The call's `model` beats the definition's, and for an external runner it
    // is passed through WHOLE. `/nope` is the string a nulya delegation refuses
    // outright as a malformed profile reference — one string, two runners, two
    // right answers, because the grammar belongs to the harness (D9).
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"find the parser\",\"model\":\"/nope\"}" }, with_codex);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    // The receipt names the delegation AND what is behind it — a thread here,
    // never a session id that does not exist.
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "codex thread") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "session events") == null);

    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const thread = try codexThreadOf(alloc, started.stdout);
    defer alloc.free(thread);

    // ② The record froze which harness holds this delegation and what it was
    // asked to run on — in its own column, so nothing has to be interpreted to
    // be read (D2).
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"codex\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_model\":\"/nope\"") != null);
        const remote = try std.fmt.allocPrint(alloc, "\"remote\":\"{s}\"", .{thread});
        defer alloc.free(remote);
        try std.testing.expect(std.mem.indexOf(u8, rows, remote) != null);
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // ③ The report reaches the parent exactly the way a nulya delegation's does:
    // the ordinary `task_finished` event, drained at the next step boundary. The
    // runner contract earned that for free — no new event kind, and no driver
    // had to learn anything (D8).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        // The fake echoes what it was given, so this is the task travelling the
        // whole way: inbox file -> drain -> `turn/start` input -> agent message.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: find the parser") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "as DATA") != null);
    }

    // ④ Another turn into the same delegation, sent while nothing is running.
    // The channel is the delegation's own inbox (D5) — Codex has no inbox for us
    // to append to — and the proof that it was used is both the directory being
    // there and the second report quoting a message that could only have come
    // through it.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"and the lexer\"}}", .{d});
        defer alloc.free(args);
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, with_codex);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);

        const inbox = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/inbox", .{d});
        defer alloc.free(inbox);
        try ws.access(io, inbox, .{});

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: and the lexer") != null);
        // Drained, so the wake invariant's `pending` goes false and nobody
        // starts a runner for a message that has already been answered.
        try std.testing.expect(try inboxEmpty(io, alloc, ws, d));
    }

    // ⑤ Exchanges are counted from the record, whatever runner is behind it.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
}

test "bundled agent: a codex delegation that is running takes a message as turn/steer and an interrupt as turn/interrupt" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const codex_exe = (try fakeCodex(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(codex_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: scouts\nrunner: codex\n---\nYou are a scout.\n",
    });

    // The fake holds its first turn open while this file exists, so the test
    // decides when the run in flight ends rather than racing it; every request
    // it receives lands in the log, which is how "the runner sent turn/steer"
    // becomes a fact rather than an inference from a report.
    try ws.writeFile(io, .{ .sub_path = "hold", .data = "" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const held: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "FAKE_CODEX_LOG", .value = "codex-log.txt" },
        .{ .key = "FAKE_CODEX_HOLD", .value = "hold" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"go on for a while\"}" }, held);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    // Wait until a turn is genuinely under way — that is what a steer and an
    // interrupt are for.
    try waitForText(io, alloc, ws, "codex-log.txt", "turn/start");

    // ① An ordinary message, delivered while the turn is running. The runner
    // drains `<d>/inbox/` between the lines it reads, and a message found there
    // mid-turn becomes `turn/steer` — the same act as typing while the main
    // conversation is answering (D3). An empty inbox is the runner saying it
    // took it.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"also check the lexer\"}}", .{d});
        defer alloc.free(args);
        const steered = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(steered.stdout);
        try std.testing.expectEqual(@as(u8, 0), steered.code);
        // It is working, so nothing new was started for it.
        try std.testing.expect(std.mem.indexOf(u8, steered.stdout, "queued") != null);
        try waitForInboxDrained(io, alloc, ws, d);
    }

    // ② An interrupt: the same message, then the marker (D6). The runner checks
    // the marker BEFORE it drains, so the message behind it stays where it is,
    // and the marker becomes this harness's own stop verb.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"STOP-SENTINEL\",\"interrupt\":true}}", .{d});
        defer alloc.free(args);
        const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(interrupted.stdout);
        try std.testing.expectEqual(@as(u8, 0), interrupted.code);
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        // Taken, never left behind to cut short a later round.
        try waitForGone(io, ws, marker);
    }

    // Let the held turn end, so the round that was interrupted can finish.
    try ws.deleteFile(io, "hold");

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // Both verbs really went down the wire. The fake reads what was sent mid-turn
    // once the turn is over, so the log is the record of it either way.
    {
        const log = try ws.readFileAlloc(io, "codex-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "turn/steer") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "turn/interrupt") != null);
    }
}

test "bundled agent: a read-only codex delegation is refused outright when the sandbox comes back wider than it asked for" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const codex_exe = (try fakeCodex(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(codex_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data = "---\ndescription: only reads\nreadonly: true\nrunner: codex\n---\nYou only read.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    // The lever is the sandbox the harness REPORTS applying — the one fact D10's
    // check reads. Everything else about this delegation is identical between
    // the two runs below, so the refusal can have no other cause.
    const wide: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "FAKE_CODEX_SANDBOX", .value = "workspaceWrite" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, wide);
    defer alloc.free(refused.stdout);
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "read-only") != null);
    // Fail CLOSED: nothing was opened, so there is no delegation to drive and
    // nothing to quietly run wider than it said.
    try std.testing.expectError(error.FileNotFound, ws.access(io, ".nulya/delegations", .{}));

    // …and with a harness that confirms the ceiling, the same definition opens.
    const narrow: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CODEX_EXE", .value = codex_exe },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const opened = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, narrow);
    defer alloc.free(opened.stdout);
    try std.testing.expectEqual(@as(u8, 0), opened.code);
    try std.testing.expect(std.mem.indexOf(u8, opened.stdout, "read-only") != null);

    const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
    defer alloc.free(waited.stdout);
    try std.testing.expectEqual(@as(u8, 0), waited.code);
}

// ── the Claude runner (contract ar-f) ───────────────────────────────────────
//
// A delegation whose definition says `runner: claude` is held by a Claude Code
// session instead of a nulya one. These run against `tests/fake_claude.zig` — a
// `claude -p` that answers the stream-json protocol and never leaves this
// machine — because everything worth pinning down is on THIS side of that
// conversation: which flags the runner passes, when it writes a message into
// stdin, and what it refuses to run.

/// The offline `claude`, built by `build.zig` for exactly this. Absent means the
/// suite was not launched through `zig build e2e`.
fn fakeClaude(alloc: std.mem.Allocator) !?[]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const named = host_env.get("NULYA_FAKE_CLAUDE") orelse return null;
    if (named.len == 0) return null;
    return try std.fs.path.resolve(alloc, &.{named});
}

/// The remote out of a claude receipt (`… — delegation d-…, claude session <uuid>`).
fn claudeSessionOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "claude session ").? + "claude session ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

test "bundled agent: a claude delegation is a claude session — the record freezes runner, version and opaque model, the persona is frozen beside it, the report comes back through the parent's inbox, and the next round resumes the session it opened" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const claude_exe = (try fakeClaude(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(claude_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: reads the codebase through claude\nrunner: claude\nrunner_model: some-claude-model\n---\nYou are a scout. Report what you found.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const with_claude: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
        .{ .key = "FAKE_CLAUDE_LOG", .value = "claude-log.txt" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    // ① The call's `model` beats the definition's, and for an external runner it
    // is passed through WHOLE — `/nope` is the string a nulya delegation refuses
    // outright as a malformed profile reference (D9).
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"find the parser\",\"model\":\"/nope\"}" }, with_claude);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    // The receipt names the delegation AND what is behind it — a claude session
    // here, never a nulya session id that does not exist.
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "claude session") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "nulya session events") == null);

    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const remote = try claudeSessionOf(alloc, started.stdout);
    defer alloc.free(remote);

    // ② The record froze which harness holds this delegation, at what version,
    // and what it was asked to run on — each in its own column, so nothing has to
    // be interpreted to be read (D2/D7).
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"claude\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_model\":\"/nope\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_version\":") != null);
        const named = try std.fmt.allocPrint(alloc, "\"remote\":\"{s}\"", .{remote});
        defer alloc.free(named);
        try std.testing.expect(std.mem.indexOf(u8, rows, named) != null);
    }

    // ③ The persona is frozen INTO the delegation, because claude rebuilds its
    // prompt from flags on every round: without this copy the delegation would
    // silently follow later edits to the definition file.
    {
        const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/persona.md", .{d});
        defer alloc.free(path);
        const frozen = try ws.readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(frozen);
        try std.testing.expect(std.mem.indexOf(u8, frozen, "You are a scout.") != null);
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // ④ The report reaches the parent exactly the way a nulya delegation's does:
    // the ordinary `task_finished` event, drained at the next step boundary. No
    // new event kind, and no driver had to learn anything (D8).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "<agent-report agent=") != null);
        // The fake echoes what it was given, so this is the task travelling the
        // whole way: inbox file -> take -> stdin user message -> assistant text.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: find the parser") != null);
    }

    // ⑤ The first round OPENED the session under the name we minted, carrying the
    // persona and the model straight through.
    {
        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        const opened = try std.fmt.allocPrint(alloc, "--session-id {s}", .{remote});
        defer alloc.free(opened);
        try std.testing.expect(std.mem.indexOf(u8, log, opened) != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--append-system-prompt") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--model /nope") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--resume") == null);
    }

    // ⑥ Another turn, sent while nothing is running. The channel is the
    // delegation's own inbox (D5), and the round that takes it RESUMES the
    // session rather than opening a second one — which is what makes a follow-up
    // cheap in the first place.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"and the lexer\"}}", .{d});
        defer alloc.free(args);
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, with_claude);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: and the lexer") != null);
        // Drained, so the wake invariant's `pending` goes false and nobody starts
        // a runner for a message that has already been answered.
        try std.testing.expect(try inboxEmpty(io, alloc, ws, d));

        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        const resumed = try std.fmt.allocPrint(alloc, "--resume {s}", .{remote});
        defer alloc.free(resumed);
        try std.testing.expect(std.mem.indexOf(u8, log, resumed) != null);
    }

    // ⑦ Exchanges are counted from the record, whatever runner is behind it.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
}

test "bundled agent: a claude delegation that is running takes an interrupt as a control request, and the message behind it is answered by the next round" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const claude_exe = (try fakeClaude(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(claude_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: scouts\nrunner: claude\n---\nYou are a scout.\n",
    });

    // The fake holds its first turn open while this file exists, so the test
    // decides when the run in flight ends rather than racing it; everything the
    // runner sent lands in the log, which is how "it sent the interrupt" becomes
    // a fact rather than an inference from a report.
    try ws.writeFile(io, .{ .sub_path = "hold", .data = "" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const held: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
        .{ .key = "FAKE_CLAUDE_LOG", .value = "claude-log.txt" },
        .{ .key = "FAKE_CLAUDE_HOLD", .value = "hold" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"go on for a while\"}" }, held);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    // Wait until a turn is genuinely under way — that is what an interrupt is for.
    try waitForText(io, alloc, ws, "claude-log.txt", "user ");

    // The interrupt: the message first, then the marker (D6). The runner checks
    // the marker between the lines it reads, so the message behind it stays in
    // the inbox rather than being fed to a turn that is about to be cut short.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"STOP-SENTINEL\",\"interrupt\":true}}", .{d});
        defer alloc.free(args);
        const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(interrupted.stdout);
        try std.testing.expectEqual(@as(u8, 0), interrupted.code);
        // It is working, so nothing new was started for it.
        try std.testing.expect(std.mem.indexOf(u8, interrupted.stdout, "queued") != null);
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        // Taken, never left behind to cut short a later round.
        try waitForGone(io, ws, marker);
    }

    // Let the held turn end, so the round that was interrupted can finish.
    try ws.deleteFile(io, "hold");

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The stop verb really went down the wire…
    {
        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "control_request interrupt") != null);
    }

    // …and the message behind it was answered rather than lost: the interrupt is
    // execution control, not a kind of message (D3).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: STOP-SENTINEL") != null);
    }
}

test "bundled agent: a read-only claude delegation asks for the narrow shape and refuses the round when the session it gets back is wider" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const claude_exe = (try fakeClaude(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(claude_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data = "---\ndescription: only reads\nreadonly: true\nrunner: claude\n---\nYou only read.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    // The lever is what the harness REPORTS its session having — the one fact
    // D10's check can read, because unlike a sandbox nothing else comes back.
    const wide: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
        .{ .key = "FAKE_CLAUDE_LOG", .value = "claude-log.txt" },
        .{ .key = "FAKE_CLAUDE_TOOLS", .value = "Read,Glob,Write" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, wide);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "read-only") != null);

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The round refused rather than ran: what comes back to the parent says the
    // ceiling could not be held, and nothing the sub-agent might have said.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "read-only") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") == null);
    }

    // …and the narrow shape really was asked for. The flags are the mechanism —
    // availability, a permission mode that never asks, and no MCP server to add
    // a tool nobody here has seen the name of — and the echo above is the check.
    {
        const log = try ws.readFileAlloc(io, "claude-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "--tools Read,Glob,Grep") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--permission-mode dontAsk") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--strict-mcp-config") != null);
    }

    // With a session that comes back inside the ceiling, the same definition runs.
    {
        const narrow: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "NULYA_CLAUDE_EXE", .value = claude_exe },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        };
        const opened = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, narrow);
        defer alloc.free(opened.stdout);
        try std.testing.expectEqual(@as(u8, 0), opened.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") != null);
    }
}

// ── the Pi runner (contract ar-e) ───────────────────────────────────────────
//
// A delegation whose definition says `runner: pi` is held by a `pi --mode rpc`
// session. These run against `tests/fake_pi.zig` — a process that answers the
// documented RPC protocol offline — because everything worth pinning down is on
// THIS side of it.

/// The offline `pi`, built by `build.zig` for exactly this.
fn fakePi(alloc: std.mem.Allocator) !?[]u8 {
    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const named = host_env.get("NULYA_FAKE_PI") orelse return null;
    if (named.len == 0) return null;
    return try std.fs.path.resolve(alloc, &.{named});
}

/// The remote out of a pi receipt (`… — delegation d-…, pi session <uuid>`).
fn piSessionOf(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, "pi session ").? + "pi session ".len;
    var end = at;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-')) end += 1;
    return alloc.dupe(u8, text[at..end]);
}

test "bundled agent: a pi delegation is a pi session — one flag opens or resumes it, the persona is frozen beside the record, and the report comes back through the parent's inbox" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const pi_exe = (try fakePi(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(pi_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: reads the codebase through pi\nrunner: pi\nrunner_model: anthropic/some-model\n---\nYou are a scout. Report what you found.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const with_pi: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_PI_EXE", .value = pi_exe },
        .{ .key = "FAKE_PI_LOG", .value = "pi-log.txt" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"find the parser\"}" }, with_pi);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "pi session") != null);

    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);
    const remote = try piSessionOf(alloc, started.stdout);
    defer alloc.free(remote);

    // The record froze which harness holds this delegation, at what version, and
    // what it was asked to run on — each in its own column (D2/D7).
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"pi\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_model\":\"anthropic/some-model\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_version\":") != null);
    }

    // The persona is frozen INTO the delegation, and handed over as a PATH — pi
    // reads the file when the argument is one, so nothing has to fit on a command
    // line.
    {
        const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/persona.md", .{d});
        defer alloc.free(path);
        const frozen = try ws.readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(frozen);
        try std.testing.expect(std.mem.indexOf(u8, frozen, "You are a scout.") != null);
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The report reaches the parent the way every other delegation's does.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: find the parser") != null);
    }

    // One flag opens or resumes: `--session-id` is passed on every round, and
    // there is no second form for this arm to choose between.
    {
        const log = try ws.readFileAlloc(io, "pi-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        const named = try std.fmt.allocPrint(alloc, "--session-id {s}", .{remote});
        defer alloc.free(named);
        try std.testing.expect(std.mem.indexOf(u8, log, named) != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--mode rpc") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--append-system-prompt") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "--model anthropic/some-model") != null);
    }

    // Another turn, sent while nothing is running: the channel is the
    // delegation's own inbox (D5) and the next round takes it.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"and the lexer\"}}", .{d});
        defer alloc.free(args);
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, with_pi);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: and the lexer") != null);
        try std.testing.expect(try inboxEmpty(io, alloc, ws, d));
    }

    // Exchanges are counted from the record, whatever runner is behind it.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
}

test "bundled agent: a pi delegation that is running takes an interrupt as abort, and the message behind it is answered by the next round" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const pi_exe = (try fakePi(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(pi_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/scout.md",
        .data = "---\ndescription: scouts\nrunner: pi\n---\nYou are a scout.\n",
    });
    try ws.writeFile(io, .{ .sub_path = "hold", .data = "" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const held: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_PI_EXE", .value = pi_exe },
        .{ .key = "FAKE_PI_LOG", .value = "pi-log.txt" },
        .{ .key = "FAKE_PI_HOLD", .value = "hold" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"scout\",\"task\":\"go on for a while\"}" }, held);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    try waitForText(io, alloc, ws, "pi-log.txt", "prompt");

    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"STOP-SENTINEL\",\"interrupt\":true}}", .{d});
        defer alloc.free(args);
        const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(interrupted.stdout);
        try std.testing.expectEqual(@as(u8, 0), interrupted.code);
        try std.testing.expect(std.mem.indexOf(u8, interrupted.stdout, "queued") != null);
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        try waitForGone(io, ws, marker);
    }

    try ws.deleteFile(io, "hold");

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The stop verb really went down the wire…
    {
        const log = try ws.readFileAlloc(io, "pi-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "abort") != null);
    }

    // …and the message behind it was answered rather than lost (D3).
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: STOP-SENTINEL") != null);
    }
}

test "bundled agent: a read-only pi delegation asks for the allow-list and stops the run when a tool outside it begins" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var host_env = try std.testing.environ.createMap(alloc);
    defer host_env.deinit();
    const exe_rel = host_env.get("NULYA_EXE") orelse return error.SkipZigTest;
    const exe_abs = try std.fs.path.resolve(alloc, &.{exe_rel});
    defer alloc.free(exe_abs);
    const pi_exe = (try fakePi(alloc)) orelse return error.SkipZigTest;
    defer alloc.free(pi_exe);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = tmp.dir;

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data = "---\ndescription: only reads\nreadonly: true\nrunner: pi\n---\nYou only read.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    // Pi reports no tool list, so the lever is the one thing the protocol does
    // say: a tool BEGINNING. `write` is not in the ceiling, so the run stops.
    const wide: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "NULYA_PI_EXE", .value = pi_exe },
        .{ .key = "FAKE_PI_LOG", .value = "pi-log.txt" },
        .{ .key = "FAKE_PI_TOOL", .value = "write" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };
    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, wide);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "read-only") != null);

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "read-only") != null);
        // Stopped rather than reported: whatever it was going on to say does not
        // come back as a sub-agent's findings.
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") == null);
    }

    // The allow-list really was asked for. (That `abort` went down the wire is
    // pinned by the interrupt test above; here the process is closed right after
    // the refusal, so the fake never gets to read it back — which is fine: the
    // ceiling's job is that the round produces nothing, and that is asserted.)
    {
        const log = try ws.readFileAlloc(io, "pi-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "--tools read,grep,find,ls") != null);
    }

    // With a run that stays inside the ceiling, the same definition reports.
    {
        const narrow: []const EnvPair = &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "NULYA_PI_EXE", .value = pi_exe },
            .{ .key = "FAKE_PI_TOOL", .value = "read" },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        };
        const opened = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, narrow);
        defer alloc.free(opened.stdout);
        try std.testing.expectEqual(@as(u8, 0), opened.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go") != null);
    }
}

// ── ar-g: a runner that lives outside this package ──────────────────────────
//
// The four arms in `extensions/agent` are there because they were first;
// nothing about them is privileged. `runner: ext:<id>` is the claim that a
// fifth harness needs no code in that package at all — one extension with one
// `agent_runner` tool, and the delegation world view comes with it. The fixture
// below is that extension, written the way a third party would write one: a
// SCRIPT, no Zig, no toolchain, answering the two operations of the contract
// (`extensions/agent/src/external.zig`).
//
// It echoes rather than talks to a model — what these tests pin down is on this
// side of the wire (which version is called, that the message is staged where
// the contract says, that the interrupt marker crosses the boundary, that a
// refusal at `op=open` costs the whole delegation), and a test that needed a
// model is a test nobody runs. `$tag` is how a round says WHICH BUILD answered
// it, which is the whole of the version-freeze assertion.

fn runnerScriptPs1(alloc: std.mem.Allocator, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\$ErrorActionPreference = 'Stop'
        \\$null = [Console]::In.ReadToEnd()
        \\$tag = '{s}'
        \\if ($env:ECHO_RUNNER_LOG) {{ Add-Content -Path $env:ECHO_RUNNER_LOG -Value "$($env:NULYA_ARG_op) $tag" }}
        \\if ($env:NULYA_ARG_op -eq 'open') {{
        \\  if ($env:NULYA_ARG_readonly -eq 'true' -and $env:ECHO_RUNNER_REFUSE_READONLY) {{
        \\    [Console]::Error.Write('this runner cannot hold a sub-agent to reading only')
        \\    exit 1
        \\  }}
        \\  [Console]::Out.Write('{{"remote":"echo-' + $env:NULYA_ARG_delegation + '"}}')
        \\  exit 0
        \\}}
        \\$msg = (Get-Content -Raw -Path $env:NULYA_ARG_message_file).Trim()
        \\if ($env:ECHO_RUNNER_HOLD) {{
        \\  while (Test-Path $env:ECHO_RUNNER_HOLD) {{
        \\    if ($env:NULYA_ARG_interrupt -and (Test-Path $env:NULYA_ARG_interrupt)) {{
        \\      Remove-Item -Force $env:NULYA_ARG_interrupt
        \\      [Console]::Out.Write('{{"text":"","interrupted":true}}')
        \\      exit 0
        \\    }}
        \\    Start-Sleep -Milliseconds 50
        \\  }}
        \\}}
        \\[Console]::Out.Write('{{"text":"heard: ' + $msg + ' (' + $tag + ')"}}')
        \\
    , .{tag});
}

fn runnerScriptSh(alloc: std.mem.Allocator, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\#!/bin/sh
        \\cat >/dev/null
        \\tag={s}
        \\if [ -n "$ECHO_RUNNER_LOG" ]; then printf '%s %s\n' "$NULYA_ARG_op" "$tag" >> "$ECHO_RUNNER_LOG"; fi
        \\if [ "$NULYA_ARG_op" = "open" ]; then
        \\  if [ "$NULYA_ARG_readonly" = "true" ] && [ -n "$ECHO_RUNNER_REFUSE_READONLY" ]; then
        \\    printf 'this runner cannot hold a sub-agent to reading only' >&2
        \\    exit 1
        \\  fi
        \\  printf '{{"remote":"echo-%s"}}' "$NULYA_ARG_delegation"
        \\  exit 0
        \\fi
        \\msg=$(cat "$NULYA_ARG_message_file")
        \\if [ -n "$ECHO_RUNNER_HOLD" ]; then
        \\  while [ -e "$ECHO_RUNNER_HOLD" ]; do
        \\    if [ -n "$NULYA_ARG_interrupt" ] && [ -e "$NULYA_ARG_interrupt" ]; then
        \\      rm -f "$NULYA_ARG_interrupt"
        \\      printf '{{"text":"","interrupted":true}}'
        \\      exit 0
        \\    fi
        \\    sleep 0.1
        \\  done
        \\fi
        \\printf '{{"text":"heard: %s (%s)"}}' "$msg" "$tag"
        \\
    , .{tag});
}

const runner_id = "echo-runner";
const runner_src = "runner-src";

/// Write the runner extension's draft (manifest + host-appropriate script) at
/// `runner-src`, with `tag` baked into what a round answers.
fn writeRunnerDraft(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, tag: []const u8) !void {
    const windows = @import("builtin").os.tag == .windows;
    const entry = if (windows) "src/run.ps1" else "src/run.sh";
    const interpreter = if (windows) "powershell" else "sh";

    try ws.createDirPath(io, runner_src ++ std.fs.path.sep_str ++ "src");
    const manifest_bytes = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "schema": "nulya.extension/v2",
        \\  "id": "{s}",
        \\  "runtime": {{ "entry": "{s}", "interpreter": "{s}" }},
        \\  "contributes": {{
        \\    "tools": [{{
        \\      "name": "agent_runner",
        \\      "surface": "internal",
        \\      "description": "Drive one round of a delegation on the harness this package speaks to.",
        \\      "input": {{
        \\        "type": "object",
        \\        "properties": {{
        \\          "op": {{ "type": "string" }},
        \\          "delegation": {{ "type": "string" }},
        \\          "remote": {{ "type": "string" }},
        \\          "persona": {{ "type": "string" }},
        \\          "message_file": {{ "type": "string" }},
        \\          "interrupt": {{ "type": "string" }},
        \\          "model": {{ "type": "string" }},
        \\          "readonly": {{ "type": "boolean" }}
        \\        }},
        \\        "required": ["op"]
        \\      }}
        \\    }}]
        \\  }}
        \\}}
        \\
    , .{ runner_id, entry, interpreter });
    defer alloc.free(manifest_bytes);
    try ws.writeFile(io, .{ .sub_path = runner_src ++ std.fs.path.sep_str ++ "extension.json", .data = manifest_bytes });

    const body = if (windows) try runnerScriptPs1(alloc, tag) else try runnerScriptSh(alloc, tag);
    defer alloc.free(body);
    const rel = if (windows)
        runner_src ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "run.ps1"
    else
        runner_src ++ std.fs.path.sep_str ++ "src" ++ std.fs.path.sep_str ++ "run.sh";
    try ws.writeFile(io, .{ .sub_path = rel, .data = body });
}

/// Build that draft and make it `current`, the way anybody installing a runner
/// would. Returns the built version; caller frees.
fn buildAndActivateRunner(alloc: std.mem.Allocator, io: std.Io, ws: std.Io.Dir, exe_abs: []const u8, tag: []const u8) ![]u8 {
    try writeRunnerDraft(alloc, io, ws, tag);
    const built = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "build", runner_src });
    defer alloc.free(built.stdout);
    if (built.code != 0) {
        std.debug.print("runner extension failed to build:\n{s}\n", .{built.stdout});
        return error.ExtensionBuildFailed;
    }
    const version = try extractVersion(alloc, built.stdout);
    errdefer alloc.free(version);
    const activated = try runCli(alloc, io, ws, &.{ exe_abs, "ext", "activate", runner_id, version });
    defer alloc.free(activated.stdout);
    try std.testing.expectEqual(@as(u8, 0), activated.code);
    return version;
}

/// Does any delegation on disk have a record? The question a refused `op=open`
/// answers with "no": a delegation exists exactly when this journal says so.
fn anyDelegationRecorded(io: std.Io, alloc: std.mem.Allocator, ws: std.Io.Dir) !bool {
    var dir = ws.openDir(io, ".nulya/delegations", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/record.jsonl", .{entry.name});
        defer alloc.free(path);
        ws.access(io, path, .{}) catch continue;
        return true;
    }
    return false;
}

test "bundled agent: a delegation can be held by a runner that is somebody else's extension — the version is frozen when it opens, every later round calls that same one, and the report comes back through the parent's inbox" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);
    const v1 = try buildAndActivateRunner(alloc, io, ws, exe_abs, "v1");
    defer alloc.free(v1);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/outsider.md",
        .data = "---\ndescription: runs on a harness nulya knows nothing about\nrunner: ext:echo-runner\nrunner_model: someone/else\n---\nYou are an outsider. Report what you found.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const with_runner: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "ECHO_RUNNER_LOG", .value = "runner-log.txt" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"outsider\",\"task\":\"find the parser\"}" }, with_runner);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    // The receipt names the runner as the delegation's own word for it, and does
    // not call the handle a session — this side does not know what kind of thing
    // it is (D2).
    try std.testing.expect(std.mem.indexOf(u8, started.stdout, "ext:echo-runner conversation") != null);

    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    // The record froze WHICH runner and WHICH VERSION of it (D7) — the whole
    // point of resolving `current` once, at the moment the delegation opens.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner\":\"ext:echo-runner\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rows, "\"runner_model\":\"someone/else\"") != null);
        const frozen = try std.fmt.allocPrint(alloc, "\"runner_version\":\"{s}\"", .{v1});
        defer alloc.free(frozen);
        try std.testing.expect(std.mem.indexOf(u8, rows, frozen) != null);
    }

    // The persona is frozen into the delegation and handed over as a path: the
    // runner is given something that cannot change under it.
    {
        const path = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/persona.md", .{d});
        defer alloc.free(path);
        const frozen = try ws.readFileAlloc(io, path, alloc, .limited(1 << 20));
        defer alloc.free(frozen);
        try std.testing.expect(std.mem.indexOf(u8, frozen, "You are an outsider.") != null);
    }

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The report reaches the parent the way every other delegation's does — the
    // background task's `task_finished`, drained at the parent's next step.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expectEqual(@as(u8, 0), stepped.code);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "\"kind\":\"task_finished\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: find the parser (v1)") != null);
    }

    // Both operations of the contract were called, and by the build that was
    // frozen.
    {
        const log = try ws.readFileAlloc(io, "runner-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "open v1") != null);
        try std.testing.expect(std.mem.indexOf(u8, log, "round v1") != null);
    }

    // Now a NEWER version of the runner becomes `current`…
    const v2 = try buildAndActivateRunner(alloc, io, ws, exe_abs, "v2");
    defer alloc.free(v2);
    try std.testing.expect(!std.mem.eql(u8, v1, v2));

    // …and the delegation already under way is still answered by the one it
    // froze. Activating a runner decides what the NEXT delegation runs on.
    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"and the lexer\"}}", .{d});
        defer alloc.free(args);
        const again = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, with_runner);
        defer alloc.free(again.stdout);
        try std.testing.expectEqual(@as(u8, 0), again.code);

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: and the lexer (v1)") != null);
        // …and the message travelled through the delegation's own inbox (D5),
        // which the round drained.
        try std.testing.expect(try inboxEmpty(io, alloc, ws, d));
    }

    {
        const log = try ws.readFileAlloc(io, "runner-log.txt", alloc, .limited(1 << 20));
        defer alloc.free(log);
        try std.testing.expect(std.mem.indexOf(u8, log, "round v2") == null);
    }

    // Exchanges are counted from the record, whatever runner is behind it.
    {
        const rows = try readRecord(alloc, io, ws, d);
        defer alloc.free(rows);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rows, "\"kind\":\"turn\""));
    }
}

test "bundled agent: an outside runner that cannot hold a delegation to reading only refuses it at open, and nothing is recorded" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);
    const version = try buildAndActivateRunner(alloc, io, ws, exe_abs, "v1");
    defer alloc.free(version);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/prober.md",
        .data = "---\ndescription: only reads\nreadonly: true\nrunner: ext:echo-runner\n---\nYou only read.\n",
    });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);

    // The ceiling reaches the runner at `op=open`, and a runner that cannot
    // enforce it refuses the whole delegation rather than opening one that would
    // run wider than it said (D10).
    {
        const refused = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "ECHO_RUNNER_REFUSE_READONLY", .value = "1" },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(refused.stdout);
        try std.testing.expect(refused.code != 0);
        // The runner's own sentence reaches the model: it is the only thing that
        // knows why.
        try std.testing.expect(std.mem.indexOf(u8, refused.stdout, "reading only") != null);
        // Nothing was recorded, so there is no delegation to send anything into.
        try std.testing.expect(!(try anyDelegationRecorded(io, alloc, ws)));
    }

    // With a runner that accepts the ceiling, the same definition opens.
    {
        const opened = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"prober\",\"task\":\"go\"}" }, &.{
            .{ .key = "NULYA_SESSION", .value = session_file },
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(opened.stdout);
        try std.testing.expectEqual(@as(u8, 0), opened.code);
        try std.testing.expect(try anyDelegationRecorded(io, alloc, ws));

        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);

        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go (v1)") != null);
    }
}

test "bundled agent: an interrupt crosses the contract — an outside runner takes the marker, stops the round, and the message behind it is answered by the next one" {
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

    const ref = try buildBundled(alloc, io, ws, exe_abs, "agent");
    defer alloc.free(ref);
    const version = try buildAndActivateRunner(alloc, io, ws, exe_abs, "v1");
    defer alloc.free(version);

    try ws.createDirPath(io, ".nulya/agents");
    try ws.writeFile(io, .{
        .sub_path = ".nulya/agents/outsider.md",
        .data = "---\ndescription: runs elsewhere\nrunner: ext:echo-runner\n---\nYou are an outsider.\n",
    });
    try ws.writeFile(io, .{ .sub_path = "hold", .data = "" });

    const new = try runCli(alloc, io, ws, &.{ exe_abs, "session", "new", "--profile", "scripted" });
    defer alloc.free(new.stdout);
    const parent = try alloc.dupe(u8, std.mem.trim(u8, new.stdout, " \r\n"));
    defer alloc.free(parent);
    const session_file = try std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{parent});
    defer alloc.free(session_file);
    const held: []const EnvPair = &.{
        .{ .key = "NULYA_SESSION", .value = session_file },
        .{ .key = "ECHO_RUNNER_LOG", .value = "runner-log.txt" },
        .{ .key = "ECHO_RUNNER_HOLD", .value = "hold" },
        .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
    };

    const started = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", "{\"name\":\"outsider\",\"task\":\"go on for a while\"}" }, held);
    defer alloc.free(started.stdout);
    try std.testing.expectEqual(@as(u8, 0), started.code);
    const d = try delegationOf(alloc, started.stdout);
    defer alloc.free(d);

    try waitForText(io, alloc, ws, "runner-log.txt", "round v1");

    {
        const args = try std.fmt.allocPrint(alloc, "{{\"session\":\"{s}\",\"task\":\"STOP-SENTINEL\",\"interrupt\":true}}", .{d});
        defer alloc.free(args);
        const interrupted = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "ext", "run", ref, "agent", args }, held);
        defer alloc.free(interrupted.stdout);
        try std.testing.expectEqual(@as(u8, 0), interrupted.code);
        // The runner took the marker — that is the fact this waits for, rather
        // than a length of time.
        const marker = try std.fmt.allocPrint(alloc, ".nulya/delegations/{s}/interrupt", .{d});
        defer alloc.free(marker);
        try waitForGone(io, ws, marker);
    }

    // Let the next round through: it is a fresh process, so nothing about the
    // hold is remembered across it.
    try ws.deleteFile(io, "hold");

    {
        const waited = try runCli(alloc, io, ws, &.{ exe_abs, "task", "wait", "--any", "--session", parent, "--timeout-ms", wait_budget_ms });
        defer alloc.free(waited.stdout);
        try std.testing.expectEqual(@as(u8, 0), waited.code);
    }

    // The message the interrupt carried was answered rather than lost (D3/D6),
    // and the answer the cut-short round was going to give is not reported.
    {
        const stepped = try runCliEnvs(alloc, io, ws, &.{ exe_abs, "session", "step", parent, "--max-steps", "1" }, &.{
            .{ .key = "NULYA_SCRIPTED_MODE", .value = "finish" },
        });
        defer alloc.free(stepped.stdout);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: STOP-SENTINEL") != null);
        try std.testing.expect(std.mem.indexOf(u8, stepped.stdout, "heard: go on for a while") == null);
    }
}
