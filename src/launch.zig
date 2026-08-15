//! Shared session-launch helpers for the `nulya session *` CLI and the bare
//! `nulya` demo (DESIGN §14, PLAN §3.2).
//!
//! Both surfaces need the same three things: a deterministic scripted provider
//! (the offline stand-in when no API key is configured), a way to build a model
//! from a config profile, and the conventions for session file paths and ids.
//! Keeping them here means the demo runs through the exact same durable-session
//! path the CLI does.

const std = @import("std");
const provider = @import("provider.zig");
const prompt = @import("prompt.zig");
const openai = @import("providers/openai.zig");
const config = @import("config.zig");

pub const sessions_dir = ".nulya/sessions";
pub const scratch_dir = ".nulya/scratch";

/// A deterministic, terminating scripted provider — the offline stand-in for a
/// real model (DESIGN §13). Two modes, selected by `NULYA_SCRIPTED_MODE`:
///
///   finish (default): make one `shell` call, then end the turn once a tool
///                     result is already in the transcript. A turn completes in
///                     two steps, so a `session step` reaches an end state.
///   loop:             always make one `shell` call and never end the turn, so a
///                     `--max-steps` cap is the only thing that stops it.
pub const ScriptedProvider = struct {
    mode: Mode = .finish,

    pub const Mode = enum { finish, loop };

    pub fn fromEnv(env: *const std.process.Environ.Map) ScriptedProvider {
        const m = env.get("NULYA_SCRIPTED_MODE") orelse "";
        return .{ .mode = if (std.mem.eql(u8, m, "loop")) .loop else .finish };
    }

    pub fn handle(self: *ScriptedProvider) provider.Model {
        return .{ .ptr = self, .vtable = &vtable };
    }

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
        return .{};
    }
    fn stream(ptr: *anyopaque, alloc: std.mem.Allocator, request: provider.Request, sink: provider.EventSink) anyerror!void {
        _ = alloc;
        const self: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        try sink.emit(.started);

        if (self.mode == .finish and hasToolResult(request.prompt_ir.stable_blocks)) {
            try sink.emit(.{ .text_delta = "done" });
            try sink.emit(.{ .done = .end_turn });
            return;
        }

        try sink.emit(.{ .text_delta = "Let me probe the environment." });
        try sink.emit(.{ .tool_use_start = .{ .index = 0, .id = "c1", .name = "shell" } });
        try sink.emit(.{ .tool_use_input_delta = .{ .index = 0, .fragment = "{\"command\":\"echo hello-from-nulya\"}" } });
        try sink.emit(.{ .done = .tool_use });
    }

    const vtable: provider.Model.VTable = .{
        .name = name,
        .modelName = modelName,
        .capabilities = capabilities,
        .stream = stream,
    };
};

fn hasToolResult(blocks: []const prompt.StableBlock) bool {
    for (blocks) |b| {
        if (b.kind == .tool_result) return true;
    }
    return false;
}

/// Owns whichever concrete provider a session uses; `model()` hands out a stable
/// handle into it. Caller keeps this as a `var` so the handle stays valid.
pub const ModelHolder = union(enum) {
    scripted: ScriptedProvider,
    openai: openai.OpenAiProvider,

    pub fn deinit(self: *ModelHolder) void {
        switch (self.*) {
            .scripted => {},
            .openai => |*p| p.deinit(),
        }
    }

    pub fn model(self: *ModelHolder) provider.Model {
        return switch (self.*) {
            .scripted => |*p| p.handle(),
            .openai => |*p| p.modelHandle(),
        };
    }
};

/// Build the model for `profile_name`. Falls back to the scripted provider when
/// the profile is scripted, unknown, or an openai profile has no resolvable key
/// (so an offline session still runs). Caller owns the holder (`deinit`).
pub fn buildModel(
    alloc: std.mem.Allocator,
    io: std.Io,
    prov: config.Provider,
    env: *const std.process.Environ.Map,
    profile_name: []const u8,
) !ModelHolder {
    const scripted: ModelHolder = .{ .scripted = ScriptedProvider.fromEnv(env) };
    const profile = prov.findProfile(profile_name) orelse return scripted;
    switch (profile.kind) {
        .scripted => return scripted,
        .openai => {
            const api_key = resolveApiKey(profile, env) orelse return scripted;
            return .{ .openai = try openai.OpenAiProvider.init(alloc, io, .{
                .api_key = api_key,
                .model = nonEmpty(profile.model, "gpt-4o-mini"),
                .base_url = nonEmpty(profile.base_url, "https://api.openai.com/v1"),
            }) };
        },
    }
}

pub fn resolveApiKey(profile: config.ProviderProfile, env: *const std.process.Environ.Map) ?[]const u8 {
    if (profile.api_key) |api_key| if (api_key.len != 0) return api_key;
    if (profile.api_key_env.len == 0) return null;
    const api_key = env.get(profile.api_key_env) orelse return null;
    return if (api_key.len == 0) null else api_key;
}

pub fn nonEmpty(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len == 0) fallback else value;
}

/// Session file path relative to the workspace: `.nulya/sessions/<id>.jsonl`.
/// Caller owns the result.
pub fn sessionPath(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}.jsonl", .{ sessions_dir, id });
}

/// A time-ordered, collision-resistant session id: `s-<unix-ms>-<hex>`.
/// Caller owns the result.
pub fn genSessionId(alloc: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Timestamp.now(io, .real);
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(i64, @truncate(now.toNanoseconds()))));
    const suffix = prng.random().int(u24);
    return std.fmt.allocPrint(alloc, "s-{d}-{x}", .{ now.toMilliseconds(), suffix });
}

/// A valid session id contains only path-safe characters (never `/`, `\`, `..`),
/// so a caller-supplied id cannot escape the sessions directory.
pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    // Reject any `..` component defensively.
    if (std.mem.indexOf(u8, id, "..") != null) return false;
    return true;
}

test "session id is path-safe and unique-ish" {
    const alloc = std.testing.allocator;
    const a = try genSessionId(alloc, std.testing.io);
    defer alloc.free(a);
    try std.testing.expect(isValidSessionId(a));
    try std.testing.expect(std.mem.startsWith(u8, a, "s-"));
}

test "session id validation rejects traversal" {
    try std.testing.expect(isValidSessionId("s-123-abcd"));
    try std.testing.expect(!isValidSessionId("../evil"));
    try std.testing.expect(!isValidSessionId("a/b"));
    try std.testing.expect(!isValidSessionId(""));
    try std.testing.expect(!isValidSessionId(".."));
}

test "scripted provider mode comes from the environment" {
    const alloc = std.testing.allocator;
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try std.testing.expectEqual(ScriptedProvider.Mode.finish, ScriptedProvider.fromEnv(&env).mode);
    try env.put("NULYA_SCRIPTED_MODE", "loop");
    try std.testing.expectEqual(ScriptedProvider.Mode.loop, ScriptedProvider.fromEnv(&env).mode);
}
