//! Minimal agent session orchestration.
//!
//! `loop.zig` owns one provider turn and batched tool execution. `AgentSession`
//! owns the conversation-level preparation around those turns: ledger lifetime,
//! active extension capability notes, interrupted tool-batch repair, the frozen
//! builtin tool snapshot for a step, and cumulative usage accounting.

const std = @import("std");
const ledger = @import("ledger.zig");
const loop = @import("loop.zig");
const registry = @import("registry.zig");
const provider = @import("provider.zig");
const notes = @import("extension/notes.zig");
const environment = @import("environment.zig");

pub const AgentSession = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    l: ledger.Ledger,
    tools: registry.ToolSetSnapshot,
    model: provider.Model,
    step_ctx: loop.StepContext,
    model_options: provider.Options,
    cwd: []const u8,
    extension_root: []const u8,
    total_usage: provider.Usage = .{},

    pub const Options = struct {
        io: std.Io,
        model: provider.Model,
        step_ctx: loop.StepContext,
        model_options: provider.Options = .{},
        cwd: []const u8 = ".",
        extension_root: []const u8 = ".nulya/extensions",
    };

    pub fn init(alloc: std.mem.Allocator, opts: Options) !AgentSession {
        const tools = try registry.snapshot(alloc);
        errdefer tools.deinit(alloc);

        return .{
            .alloc = alloc,
            .io = opts.io,
            .l = ledger.Ledger.init(alloc),
            .tools = tools,
            .model = opts.model,
            .step_ctx = opts.step_ctx,
            .model_options = opts.model_options,
            .cwd = opts.cwd,
            .extension_root = opts.extension_root,
        };
    }

    pub fn deinit(self: *AgentSession) void {
        self.l.deinit();
        self.tools.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn appendUser(self: *AgentSession, text: []const u8) !void {
        try self.l.append(.{ .user_text = text });
    }

    pub fn step(self: *AgentSession) !provider.Usage {
        try self.prepareStep();
        const step_usage = try loop.runStepWithOptions(self.alloc, &self.l, self.model, self.tools, self.step_ctx, self.model_options);
        accumulate(&self.total_usage, step_usage);
        return step_usage;
    }

    pub fn usage(self: *const AgentSession) provider.Usage {
        return self.total_usage;
    }

    pub fn lastAssistantDone(self: *const AgentSession) bool {
        if (self.l.len() == 0) return false;
        return switch (self.l.view()[self.l.len() - 1]) {
            .assistant => |as| as.calls.len == 0,
            else => false,
        };
    }

    fn prepareStep(self: *AgentSession) !void {
        // Repair before extension note sync so a note append cannot hide an
        // illegal assistant-with-tool-calls tail from the prior process.
        try loop.completeInterruptedToolBatch(self.alloc, &self.l);
        try notes.syncFromActiveExtensions(self.alloc, self.io, self.cwd, &self.l, self.extension_root);
    }
};

fn accumulate(total: *provider.Usage, step: provider.Usage) void {
    total.input_tokens += step.input_tokens;
    total.output_tokens += step.output_tokens;
    total.cache_read_tokens += step.cache_read_tokens;
    total.cache_write_tokens += step.cache_write_tokens;
}

test "session repairs interrupted tool batch before provider request" {
    const alloc = std.testing.allocator;

    const RecoveringModel = struct {
        saw_unknown_result: bool = false,

        fn name(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "recovering";
        }

        fn modelName(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return "recovering-test";
        }

        fn capabilities(ptr: *anyopaque) provider.ProviderCapabilities {
            _ = ptr;
            return .{};
        }

        fn stream(ptr: *anyopaque, a: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
            _ = a;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqual(@as(usize, 4), request.prompt_ir.stable_blocks.len);
            try std.testing.expect(std.mem.indexOf(u8, request.prompt_ir.stable_blocks[3].bytes, "state is unknown") != null);
            self.saw_unknown_result = true;
            try sink.emit(.started);
            try sink.emit(.{ .text_delta = "recovered" });
            try sink.emit(.{ .usage = .{ .input_tokens = 3, .output_tokens = 2 } });
            try sink.emit(.{ .done = .end_turn });
        }

        const vtable: provider.Model.VTable = .{
            .name = name,
            .modelName = modelName,
            .capabilities = capabilities,
            .stream = stream,
        };
    };

    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();

    var lenv = try environment.LocalEnvironment.init(alloc, threaded.io(), .{});
    defer lenv.deinit();

    var model_impl = RecoveringModel{};
    var sess = try AgentSession.init(alloc, .{
        .io = threaded.io(),
        .model = .{ .ptr = &model_impl, .vtable = &RecoveringModel.vtable },
        .step_ctx = .{
            .tool_context = .{
                .environment = lenv.environment(),
                .fs = lenv.workspaceFs(),
                .cwd = ".",
            },
            .scratch_dir = "/tmp",
        },
    });
    defer sess.deinit();

    try sess.appendUser("go");
    try sess.l.append(.{ .assistant = .{
        .text = "running",
        .calls = &.{.{ .id = "c1", .tool = "shell", .args_json = "{\"command\":\"touch marker\"}" }},
    } });

    _ = try sess.step();

    try std.testing.expect(model_impl.saw_unknown_result);
    try std.testing.expectEqual(@as(usize, 4), sess.l.len());
    try std.testing.expectEqual(@as(u64, 3), sess.usage().input_tokens);
    try std.testing.expectEqual(@as(u64, 2), sess.usage().output_tokens);
}
