//! Live-provider integration checks (PLAN §1 M4 acceptance). Not part of
//! `zig build test` or `zig build e2e` — those stay hermetic and offline. Run:
//!
//!   NULYA_INTEGRATION_PROFILE=deepseek-anthropic zig build integration
//!
//! The profile name is a `default.toml` provider profile (`deepseek`,
//! `deepseek-anthropic`, `anthropic`, `codex`, …). Without the variable, or when
//! the named profile has no usable credential, every test here skips: the point
//! is to be runnable on demand, never to fail a keyless machine.
//!
//! What it proves is the one thing a unit test cannot: that the cache invariant
//! of DESIGN §1 shows up as real cache reads on a real endpoint. The kernel
//! guarantees the PromptIR block prefix only grows; whether that actually earns
//! a cache hit depends on the provider serializer and its breakpoints, and the
//! only honest way to know is to look at the meter.

const std = @import("std");
const support = @import("support");

const config = support.config;
const environment = support.environment;
const launch = support.launch;
const provider = support.provider;
const session = support.session;

/// A session under a live model, or null when this machine cannot run one.
const Live = struct {
    cfg: config.Config,
    env: std.process.Environ.Map,
    holder: launch.ModelHolder,
    lenv: environment.LocalEnvironment,
    tmp: std.testing.TmpDir,
    profile: []const u8,
    /// The frozen model id, so a test can ask the catalog what this model is
    /// (`[[models]] vision`) — the same claim `session append --image` reads.
    model_id: []const u8,
    effort: ?[]const u8,
    cache_key: [32]u8,

    fn open(alloc: std.mem.Allocator, io: std.Io) !?Live {
        // Every early exit here is a skip, not an error, so ownership is handed
        // over only on the one path that actually builds a Live.
        var opened = false;
        var env = try std.testing.environ.createMap(alloc);
        defer if (!opened) env.deinit();
        const profile = env.get("NULYA_INTEGRATION_PROFILE") orelse return null;
        if (profile.len == 0) return null;

        var cfg = try config.load(alloc, io, &env);
        defer if (!opened) cfg.deinit();
        if (cfg.provider.findProfile(profile) == null) {
            std.debug.print("integration: no provider profile named '{s}'\n", .{profile});
            return null;
        }

        // A profile whose credential is missing resolves to the scripted
        // identity (DESIGN §3) — measuring a canned provider's cache would
        // prove nothing, so skip instead.
        const identity = launch.resolveDescriptor(alloc, io, cfg.provider, &env, profile, null);
        if (std.mem.eql(u8, identity.provider, "scripted")) {
            std.debug.print("integration: profile '{s}' has no usable credential\n", .{profile});
            return null;
        }

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var lenv = try environment.LocalEnvironment.init(alloc, io, .{});
        errdefer lenv.deinit();

        // A fresh scope per run, exactly as a real session id would be. Sharing
        // one across runs makes the first step hit a stale entry whose
        // continuation then diverges, which is a property of the probe rather
        // than of the provider.
        var cache_key: [32]u8 = undefined;
        var key_writer = std.Io.Writer.fixed(&cache_key);
        try key_writer.print("probe-{d:0>20}", .{std.Io.Timestamp.now(io, .real).toNanoseconds()});
        const inline_key = if (cfg.provider.findProfile(profile)) |p| p.api_key else null;
        var holder = try launch.buildFromDescriptor(alloc, io, identity, &env, .{ .cache_key = &cache_key, .inline_key = inline_key });
        errdefer holder.deinit();

        opened = true;
        return .{
            .cache_key = cache_key,
            .cfg = cfg,
            .env = env,
            .holder = holder,
            .lenv = lenv,
            .tmp = tmp,
            .profile = profile,
            .model_id = identity.model,
            .effort = cfg.defaultEffort(profile, identity.model),
        };
    }

    fn deinit(self: *Live) void {
        self.holder.deinit();
        self.lenv.deinit();
        self.tmp.cleanup();
        self.cfg.deinit();
        self.env.deinit();
    }

    fn newSession(self: *Live, alloc: std.mem.Allocator) !session.AgentSession {
        return self.newSessionWithEffort(alloc, self.effort);
    }

    fn newSessionWithEffort(self: *Live, alloc: std.mem.Allocator, effort: ?[]const u8) !session.AgentSession {
        return session.AgentSession.init(alloc, .{
            .model = self.holder.model(),
            .step_ctx = .{
                .tool_context = .{ .environment = self.lenv.environment(), .cwd = "." },
                .scratch_dir = ".nulya/scratch",
            },
            .model_options = .{ .effort = effort },
        });
    }

    /// Does this machine's catalog say the live model accepts images? The claim
    /// is the user's to make (DESIGN §9.5), so an unmarked model means "not
    /// asked to be tested with images", not "broken".
    fn claimsVision(self: *const Live) bool {
        for (self.cfg.models) |m| {
            if (std.mem.eql(u8, m.id, self.model_id)) return m.vision;
        }
        return false;
    }
};

/// A real 64x64 solid-red PNG, already base64 — which is exactly the form the
/// ledger stores an image in (DESIGN §3.1), so the test needs no encoder and
/// nothing here has to be trusted to produce valid PNG bytes at run time.
const red_square_png_b64 =
    "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsItw/VMZyQi+hcEKLNO+FgEBAQEBAQEB" ++
    "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQGBywJmTwDiulNVfwAAAABJRU5ErkJggg==";

/// A first user turn comfortably past every provider's minimum cacheable
/// prefix, ending in real work for the model to do. Caller owns the result.
fn buildOpeningTurn(alloc: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("House rules for this session. Follow them exactly.\n");
    var i: usize = 1;
    while (i <= 220) : (i += 1) {
        try out.writer.print(
            "Rule {d}: when a command in group {d} fails, report the exit status verbatim and do not retry it silently.\n",
            .{ i, i % 7 },
        );
    }
    try out.writer.writeAll(
        \\
        \\Now work through these one at a time, using the shell tool for each,
        \\and report the output as you go:
        \\1. print the text `alpha`
        \\2. print the text `beta`
        \\3. print the text `gamma`
    );
    return out.toOwnedSlice();
}

test "live provider: an append-only transcript keeps hitting the prompt cache" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var live = (try Live.open(alloc, io)) orelse return error.SkipZigTest;
    defer live.deinit();

    var sess = try live.newSession(alloc);
    defer sess.deinit();

    const model = live.holder.model();
    std.debug.print("\nintegration: profile={s} provider={s} model={s}\n", .{ live.profile, model.name(), model.modelName() });

    // Providers only cache a prefix once it is long enough to be worth caching
    // (the OpenAI family draws the line at 1024 tokens), so a toy transcript
    // measures nothing at all — it reports zero cache reads whether or not the
    // prefix was stable. The opening turn is therefore made realistically long,
    // the way a real session's system prompt, skills and tool schemas make it.
    const opening = try buildOpeningTurn(alloc);
    defer alloc.free(opening);
    try sess.appendUser(opening);

    var usages: std.ArrayList(provider.Usage) = .empty;
    defer usages.deinit(alloc);

    var taken: usize = 0;
    while (taken < 8 and usages.items.len < 4) : (taken += 1) {
        // The model may decide it is finished before the transcript is long
        // enough to measure; a nudge keeps the SAME session growing, which is
        // exactly the shape the cache invariant is about.
        if (sess.lastAssistantDone()) try sess.appendUser("Continue with the next step, then summarize what you ran.");
        const outcome = try sess.step();
        const u = outcome.usage;
        if (u.input_tokens + u.cache_read_tokens == 0) continue; // no billed model call
        std.debug.print(
            "  step {d}: input={d} cache_read={d} cache_write={d} output={d}\n",
            .{ usages.items.len + 1, u.input_tokens, u.cache_read_tokens, u.cache_write_tokens, u.output_tokens },
        );
        try usages.append(alloc, u);
    }

    if (usages.items.len < 3) {
        std.debug.print("integration: only {d} billed steps; cannot judge the cache\n", .{usages.items.len});
        return error.NotEnoughSteps;
    }

    // From the second step on, everything the previous request sent is a prefix
    // of this one, so almost all of it should come back as a cache read. 90%
    // leaves room for the tail tokens the provider tokenizes into a fresh block.
    for (usages.items[1..], usages.items[0 .. usages.items.len - 1], 1..) |now, before, i| {
        const previous_total = before.input_tokens + before.cache_read_tokens;
        const floor = previous_total * 9 / 10;
        if (now.cache_read_tokens < floor) {
            std.debug.print(
                "step {d}: cache_read {d} is below 90% of the previous request's {d} input tokens\n",
                .{ i + 1, now.cache_read_tokens, previous_total },
            );
            return error.CacheReadTooLow;
        }
        if (now.cache_read_tokens < before.cache_read_tokens) {
            std.debug.print(
                "step {d}: cache_read went backwards ({d} -> {d})\n",
                .{ i + 1, before.cache_read_tokens, now.cache_read_tokens },
            );
            return error.CacheReadRegressed;
        }
    }
}

test "live provider: a batched tool turn round-trips through the real wire format" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var live = (try Live.open(alloc, io)) orelse return error.SkipZigTest;
    defer live.deinit();

    var sess = try live.newSession(alloc);
    defer sess.deinit();

    // Two calls in one assistant turn come back as ONE tool_results event
    // (DESIGN §0 rule 2). Serializing that batch is where the three wire formats
    // differ most, so it is worth proving against a live endpoint.
    try sess.appendUser("Using the shell tool, print `alpha` and print `beta`. Then say DONE.");
    const taken = try sess.run(12);

    var saw_call = false;
    var saw_result = false;
    for (sess.l.view()) |event| switch (event) {
        .assistant => |a| {
            if (a.calls.len != 0) saw_call = true;
        },
        .tool_results => |r| {
            if (r.len != 0) saw_result = true;
        },
        else => {},
    };
    try std.testing.expect(saw_call);
    try std.testing.expect(saw_result);
    // Reaching an end state matters as much as the round-trip: it means every
    // tool result the model got back was intelligible to it on this wire.
    if (!sess.lastAssistantDone()) {
        std.debug.print("the model never ended its turn within {d} steps\n", .{taken});
        return error.TurnNeverEnded;
    }
    const total = sess.usage();
    std.debug.print(
        "  totals: input={d} cache_read={d} output={d}\n",
        .{ total.input_tokens, total.cache_read_tokens, total.output_tokens },
    );
}

test "live provider: a thinking model's tool loop replays its reasoning and still ends" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var live = (try Live.open(alloc, io)) orelse return error.SkipZigTest;
    defer live.deinit();
    // Only wires that carry reasoning back can be checked for it.
    if (!live.holder.model().capabilities().thinking_replay) return error.SkipZigTest;

    // Thinking must be ON for this to prove anything: with it, the Anthropic
    // API rejects a tool-use turn whose thinking block was not replayed, so a
    // loop that reaches its end is the positive evidence; the Responses wire
    // accepts either way, so there the recorded reasoning is what is checked.
    var sess = try live.newSessionWithEffort(alloc, live.effort orelse "high");
    defer sess.deinit();

    try sess.appendUser("Using the shell tool, print `one`, then print `two`, one command per turn. Then say DONE.");
    const taken = try sess.run(12);

    var turns_with_reasoning: usize = 0;
    var tool_turns: usize = 0;
    for (sess.l.view()) |event| switch (event) {
        .assistant => |a| {
            if (a.calls.len != 0) tool_turns += 1;
            if (a.reasoning.len != 0) turns_with_reasoning += 1;
        },
        else => {},
    };
    std.debug.print("  tool turns={d} turns with reasoning={d} steps={d}\n", .{ tool_turns, turns_with_reasoning, taken });
    try std.testing.expect(tool_turns >= 2);
    if (!sess.lastAssistantDone()) {
        std.debug.print("the model never ended its turn within {d} steps\n", .{taken});
        return error.TurnNeverEnded;
    }
    if (turns_with_reasoning == 0) {
        // The model may legitimately decide not to think on a trivial task, but
        // a thinking-on tool loop that recorded nothing at all is worth a hard
        // look before trusting the replay path.
        std.debug.print("no assistant turn carried reasoning; nothing was replayed\n", .{});
        return error.NoReasoningRecorded;
    }
}

test "live provider: an image in a user turn reaches the model and it describes what it sees" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var live = (try Live.open(alloc, io)) orelse return error.SkipZigTest;
    defer live.deinit();

    // Only a model the catalog claims can see images (DESIGN §3.1, §14). Today
    // that is the codex profile's `gpt-5.5` and Anthropic's own models — but the
    // claim is written in the user's config, never guessed here, exactly as
    // `session append --image` reads it. DeepSeek's endpoints do not take
    // images, so the two cheap profiles skip.
    if (!live.claimsVision()) {
        std.debug.print(
            "integration: '{s}' is not marked `vision = true` in [[models]]; skipping the image turn\n",
            .{live.model_id},
        );
        return error.SkipZigTest;
    }

    var sess = try live.newSession(alloc);
    defer sess.deinit();

    // The library path, not `session append --image`: the CLI gate has already
    // been proven offline, and what a live endpoint alone can prove is that the
    // bytes we serialize are bytes the model actually sees.
    try sess.l.append(.{ .user_text = .{
        .text = "What single colour fills this image? Answer with the colour word only.",
        .images = &.{.{ .media_type = "image/png", .data = red_square_png_b64 }},
    } });
    _ = try sess.run(2);

    var said: []const u8 = "";
    for (sess.l.view()) |event| switch (event) {
        .assistant => |a| if (a.text.len != 0) {
            said = a.text;
        },
        else => {},
    };
    std.debug.print("  model saw: {s}\n", .{said});

    const lowered = try std.ascii.allocLowerString(alloc, said);
    defer alloc.free(lowered);
    if (std.mem.indexOf(u8, lowered, "red") == null) {
        std.debug.print("the reply never mentions the image's colour: {s}\n", .{said});
        return error.ImageNotSeen;
    }
}
