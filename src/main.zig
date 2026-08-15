//! Nulya — a minimal, self-evolving AI agent harness.
//!
//! This entry point is a *walking skeleton*: it stands up the immutable ledger,
//! the two builtin tools, the `emit` output primitive, and the batched agent
//! loop, then runs ONE scripted step so the whole geometry compiles and prints.
//! The scripted model stands in for the real provider (DESIGN §13).

const std = @import("std");
const ledger = @import("ledger.zig");
const provider = @import("provider.zig");
const environment = @import("environment.zig");
const config = @import("config.zig");
const session = @import("session.zig");
const cli = @import("cli.zig");
const promotion = @import("promotion.zig");
const launch = @import("launch.zig");

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

/// Bare `nulya` runs a fixed-prompt demo — now over the same durable session
/// path the `nulya session *` CLI uses (DESIGN §3.4, §14): it creates a session
/// file, appends one user turn, and runs to the turn's end, then prints the
/// ledger. The offline scripted provider stands in when no API key is set.
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

    const profile = if (cfg.provider.active_profile.len != 0) cfg.provider.active_profile else "scripted";
    // One model-resolution decision: resolve the identity, then build the running
    // model from it — so the demo runs exactly what gets frozen into the header.
    const identity = launch.resolveDescriptor(cfg.provider, env, profile);
    var holder = try launch.buildFromDescriptor(alloc, io, identity, env);
    defer holder.deinit();
    const model = holder.model();
    const effort = if (cfg.provider.findProfile(profile)) |p| p.effort else null;

    std.debug.print("provider: {s}/{s} (shell dialect: {s})\n", .{ model.name(), model.modelName(), lenv.dialect_val.label() });

    // Usage-driven automatic native promotion (DESIGN §5.1 rule 3) lives entirely
    // at this session-setup boundary: read the journal, rank extension stable ids,
    // and hand the composition a plain best-first id list.
    const ranked_ids = try promotion.rankExtensionTools(alloc, io, ".", .{
        .uses_recent = cfg.registry.weights.uses_recent,
        .uses_total = cfg.registry.weights.uses_total,
        .last_used = cfg.registry.weights.last_used,
        .success_rate = cfg.registry.weights.success_rate,
    });
    defer promotion.freeRankedIds(alloc, ranked_ids);

    try std.Io.Dir.cwd().createDirPath(io, launch.sessions_dir);
    const id = try launch.genSessionId(alloc, io);
    defer alloc.free(id);
    const spath = try launch.sessionPath(alloc, id);
    defer alloc.free(spath);

    var sess = try session.AgentSession.createDurable(alloc, .{
        .model = model,
        .step_ctx = .{
            .tool_context = .{ .environment = lenv.environment(), .fs = lenv.workspaceFs(), .cwd = "." },
            .scratch_dir = launch.scratch_dir,
        },
        .model_options = .{ .effort = effort },
        // Config lives only at this boundary; the composition receives a narrow,
        // already-resolved selection, never the config itself.
        .registry = .{
            .pinned_native_tools = cfg.registry.pinned_native_tools,
            .ranked_native_tools = ranked_ids,
            .max_tools = cfg.registry.max_tools,
        },
    }, .{
        .workspace = std.Io.Dir.cwd(),
        .session_path = spath,
        .session_id = id,
        .model_profile = profile,
        .model_identity = identity,
    });
    defer sess.deinit();

    std.debug.print("session: {s}\n", .{id});
    try sess.appendUser("What system am I on?");
    _ = try sess.run(4);

    printLedger(&sess.l);
    const total = sess.usage();
    std.debug.print(
        "=== usage: input={d} cache_read={d} output={d} ===\n",
        .{ total.input_tokens, total.cache_read_tokens, total.output_tokens },
    );

    // Ledger owns cloned assistant/tool-result payloads and frees them in deinit.
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
    _ = @import("tool_stats.zig");
    _ = @import("tool_selection.zig");
    _ = @import("promotion.zig");
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
    _ = @import("extension/invoke.zig");
    _ = @import("extension/tools.zig");
    _ = @import("extension/manifest.zig");
    _ = @import("extension/skills.zig");
    _ = @import("extension/store.zig");
    _ = @import("extension/build_ext.zig");
    _ = @import("session.zig");
    _ = @import("launch.zig");
    _ = @import("cli.zig");
    _ = @import("toolchain.zig");
}
