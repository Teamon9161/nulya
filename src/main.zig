//! Nulya — a minimal, self-evolving AI agent harness.
//!
//! This entry point is a *walking skeleton*: it stands up the immutable ledger,
//! the two builtin tools, the `emit` output primitive, and the batched agent
//! loop, then runs ONE scripted step so the whole geometry compiles and prints.
//! The scripted model stands in for the real provider (DESIGN §13).

const std = @import("std");
const ledger = @import("ledger.zig");
const provider = @import("provider.zig");
const openai = @import("providers/openai.zig");
const environment = @import("environment.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const cli = @import("cli.zig");

/// Scripted stand-in provider: on seeing a pending user turn, it issues two
/// shell calls in a single assistant turn — demonstrating batched execution.
const ScriptedProvider = struct {
    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted";
    }

    fn modelName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "scripted-demo";
    }

    fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
        _ = ptr;
        return .{ .parallel_tool_calls = true };
    }

    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = ptr;
        _ = alloc;
        _ = request;
        try sink.emit(.started);
        try sink.emit(.{ .text_delta = "Let me probe the environment." });
        try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo hello-from-nulya\"}" } });
        try sink.emit(.{ .tool_use_start = .{ .index = 1, .id = "c2", .name = "shell" } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 1, .fragment = "{\"command\":\"pwd\"}" } });
        try sink.emit(.{ .done = .tool_use });
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    // `nulya <cmd> ...` -> CLI (DESIGN §14); bare `nulya` -> the agent-loop demo.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        const argv = try init.arena.allocator().alloc([]const u8, args.len - 1);
        for (args[1..], 0..) |a, i| argv[i] = a;
        return cli.dispatch(alloc, io, argv);
    }

    try runDemo(alloc, io, init.environ_map);
    return 0;
}

fn runDemo(alloc: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
    var cfg = try config.load(alloc, io, env);
    defer cfg.deinit();

    if (cfg.environment.backend != .local) {
        std.debug.print("environment backend '{s}' is parsed but not implemented yet\n", .{@tagName(cfg.environment.backend)});
        return error.UnsupportedEnvironmentBackend;
    }

    // Execution env: the sanitized boundary every tool runs behind. Host secrets
    // in the host env never cross into it (DESIGN §9).
    var lenv = try environment.LocalEnvironment.init(alloc, io, .{ .dialect = cfg.environment.shell.toLocalOption() });
    defer lenv.deinit();

    var scripted = ScriptedProvider{};
    var openai_provider: openai.OpenAiProvider = undefined;
    var use_openai = false;
    defer if (use_openai) openai_provider.deinit();

    const selected_profile = cfg.provider.activeProfile() orelse cfg.provider.findProfile("scripted");
    const model_options: provider.Options = .{ .effort = if (selected_profile) |profile| profile.effort else null };
    const model: provider.Model = if (selected_profile) |profile| switch (profile.kind) {
        .scripted => .{ .ptr = &scripted, .vtable = &ScriptedProvider.vtable },
        .openai => if (resolveApiKey(profile, env)) |api_key| blk: {
            openai_provider = try openai.OpenAiProvider.init(alloc, io, .{
                .api_key = api_key,
                .model = nonEmpty(profile.model, "gpt-4o-mini"),
                .base_url = nonEmpty(profile.base_url, "https://api.openai.com/v1"),
            });
            use_openai = true;
            break :blk openai_provider.modelHandle();
        } else .{ .ptr = &scripted, .vtable = &ScriptedProvider.vtable },
    } else .{ .ptr = &scripted, .vtable = &ScriptedProvider.vtable };

    std.debug.print("provider: {s}/{s} (shell dialect: {s})\n", .{ model.name(), model.modelName(), lenv.dialect_val.label() });

    var sess = try session.AgentSession.init(alloc, .{
        .model = model,
        .step_ctx = .{
            .tool_context = .{
                .environment = lenv.environment(),
                .fs = lenv.workspaceFs(),
                .cwd = ".",
            },
            .scratch_dir = ".nulya/scratch",
        },
        .model_options = model_options,
    });
    defer sess.deinit();
    try sess.appendUser("What system am I on?");

    if (use_openai) {
        var steps: usize = 0;
        while (steps < 4) : (steps += 1) {
            _ = try sess.step();
            if (sess.lastAssistantDone()) break;
        }
    } else {
        _ = try sess.step();
    }

    printLedger(&sess.l);
    const total = sess.usage();
    std.debug.print(
        "=== usage: input={d} cache_read={d} output={d} ===\n",
        .{ total.input_tokens, total.cache_read_tokens, total.output_tokens },
    );

    // Ledger owns cloned assistant/tool-result payloads and frees them in deinit.
}

fn resolveApiKey(profile: config.ProviderProfile, env: *const std.process.Environ.Map) ?[]const u8 {
    if (profile.api_key) |api_key| if (api_key.len != 0) return api_key;
    if (profile.api_key_env.len == 0) return null;
    const api_key = env.get(profile.api_key_env) orelse return null;
    return if (api_key.len == 0) null else api_key;
}

fn nonEmpty(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len == 0) fallback else value;
}

fn printLedger(l: *const ledger.Ledger) void {
    const p = std.debug.print;
    p("=== ledger ({d} events) ===\n", .{l.len()});
    for (l.view(), 0..) |e, i| {
        switch (e) {
            .user_text => |t| p("[{d}] user: {s}\n", .{ i, t }),
            .assistant => |as| {
                p("[{d}] assistant: {s}\n", .{ i, as.text });
                for (as.calls) |c| p("      call {s} -> {s} {s}\n", .{ c.id, c.tool, c.args_json });
            },
            .tool_results => |rs| {
                p("[{d}] tool_results ({d}):\n", .{ i, rs.len });
                for (rs) |r| p("      {s} ok={} | {s}\n", .{ r.call_id, r.ok, std.mem.trimEnd(u8, r.output, "\n") });
            },
            .capability_note => |n| p("[{d}] note {s}@{s}: {s}\n", .{ i, n.id, n.version, n.text }),
        }
    }
}

// Pull unit tests from every module into `zig build test`.
test {
    std.testing.refAllDecls(@This());
    _ = @import("emit.zig");
    _ = @import("ledger.zig");
    _ = @import("tool.zig");
    _ = @import("registry.zig");
    _ = @import("skill.zig");
    _ = @import("composition.zig");
    _ = @import("loop.zig");
    _ = @import("prompt.zig");
    _ = @import("provider.zig");
    _ = @import("providers/openai.zig");
    _ = @import("environment.zig");
    _ = @import("config.zig");
    _ = @import("extension/protocol.zig");
    _ = @import("extension/manifest.zig");
    _ = @import("extension/store.zig");
    _ = @import("extension/build_ext.zig");
    _ = @import("session.zig");
    _ = @import("toolchain.zig");
}
