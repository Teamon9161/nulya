//! Extension wire protocol.
//!
//! The transport is oneshot: the host spawns the extension, writes the call's
//! arguments to stdin, reads its stdout, and the process exits. No daemon, no
//! streaming, no bidirectional events, no host callbacks. The wire IS the ABI,
//! so extensions need not be written in Zig.
//!
//! There is ONE wire, `plain`, and everything about a call other than the four
//! things below is the same whatever a runtime is written in: the same timeout,
//! the same process-tree kill, the same sanitized environment with NULYA_EXE
//! (and NULYA_SESSION inside a session), the same working directory, the same
//! result. `nulya ext run <id> <tool> --arg k=v` and a model's own call go down
//! the same path, so a runtime cannot tell who called it.
//!
//! ── the wire ───────────────────────────────────────────────────────────────
//!
//! Nothing in the manifest selects it. No JSON to parse unless the tool wants
//! to, no envelope, no id to echo.
//!
//!   stdin   The arguments for this call: one compact JSON object, the exact
//!           bytes the model produced (`{}` when there are none).
//!   env     NULYA_TOOL=<tool name>. Plus NULYA_ARG_<k>=<value> for every
//!           TOP-LEVEL argument whose value is a string, number or boolean:
//!           strings verbatim, numbers as written, booleans `true` / `false`.
//!           Arrays, objects and null are not exported, nor is a key outside
//!           [A-Za-z0-9_] — those live on stdin only.
//!   stdout  The tool's output, VERBATIM. It reaches the model exactly as
//!           printed — text, or JSON when the caller is a driver that parses
//!           one; stdout is bytes, so one wire carries both.
//!   exit    0 = success. Non-zero = a failed call, whose text is `exit <code>`
//!           followed by stderr, and by stdout if anything was printed. So the
//!           message a tool writes to stderr before failing IS what the model
//!           reads: say what went wrong and what would work next call. Nothing
//!           else may go to stderr — on a failing call it is the message.
//!
//!     #!/bin/sh
//!     printf 'hello %s\n' "${NULYA_ARG_name:-world}"
//!
//! ONE CONSTRAINT ON WHAT YOU SPAWN. The caller learns this call is over when
//! your stdout closes, and a child you start inherits that write end (Windows
//! has no handle allowlist here). So a tool that starts a helper process must
//! kill it before exiting, or the caller waits out its whole timeout on an EOF
//! that never arrives. Tear down your readers AFTER the kill, never before:
//! their parked reads end only once the process holding the write end is gone.

const std = @import("std");

/// One name/value pair of a per-call environment.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// The bytes that go to stdin: the model's arguments object, trimmed, with
/// "nothing" spelled `{}`.
pub fn normalizedArguments(args_json: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    return if (trimmed.len == 0) "{}" else trimmed;
}

/// The arguments are a JSON object — the one shape rule of this wire, checked
/// before anything is spawned or sent anywhere.
pub fn requireArgumentsObject(alloc: std.mem.Allocator, arguments: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArgumentsJson,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.ArgumentsNotObject;
}

/// `NULYA_TOOL`, every exported argument, and the presentation file when the
/// caller has one. Caller deinits.
pub fn callEnv(
    alloc: std.mem.Allocator,
    tool_name: []const u8,
    arguments: []const u8,
    presentation_file: ?[]const u8,
) !PlainEnv {
    var vars: PlainEnv = .empty;
    errdefer vars.deinit(alloc);
    try vars.add(alloc, "NULYA_TOOL", tool_name);
    if (presentation_file) |path| try vars.add(alloc, "NULYA_PRESENTATION_FILE", path);
    try vars.addArguments(alloc, arguments);
    return vars;
}

/// The per-call environment, owning every string it hands to `runExtension`.
pub const PlainEnv = struct {
    list: std.ArrayList(EnvVar) = .empty,

    pub const empty: PlainEnv = .{};

    pub fn deinit(self: *PlainEnv, alloc: std.mem.Allocator) void {
        for (self.list.items) |v| {
            alloc.free(v.name);
            alloc.free(v.value);
        }
        self.list.deinit(alloc);
    }

    pub fn add(self: *PlainEnv, alloc: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_value = try alloc.dupe(u8, value);
        errdefer alloc.free(owned_value);
        try self.list.append(alloc, .{ .name = owned_name, .value = owned_value });
    }

    /// `NULYA_ARG_<k>` for each TOP-LEVEL scalar argument. Arrays, objects and
    /// null do not appear: an environment variable is a string, and stdin
    /// already carries the whole object exactly. Keys outside `[A-Za-z0-9_]+`
    /// are skipped rather than mangled, for the same reason.
    ///
    /// The parse is also where "the arguments are a JSON object" is enforced,
    /// before anything is spawned.
    pub fn addArguments(self: *PlainEnv, alloc: std.mem.Allocator, arguments: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch |err| switch (err) {
            // The parser allocates while validating: a host OOM is a resource
            // fault and must not be misreported as malformed arguments.
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArgumentsJson,
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.ArgumentsNotObject,
        };

        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!isEnvSafeKey(key)) continue;
            var buf: [64]u8 = undefined;
            const value: []const u8 = switch (entry.value_ptr.*) {
                .string => |s| s,
                .bool => |b| if (b) "true" else "false",
                .integer => |n| std.fmt.bufPrint(&buf, "{d}", .{n}) catch continue,
                .float => |f| std.fmt.bufPrint(&buf, "{d}", .{f}) catch continue,
                .number_string => |s| s,
                else => continue,
            };
            // A NUL byte ENDS an environment string on both platforms, so a
            // value carrying one would arrive silently truncated. Skipped —
            // stdin still has it whole.
            if (std.mem.indexOfScalar(u8, value, 0) != null) continue;
            const name = try std.fmt.allocPrint(alloc, "NULYA_ARG_{s}", .{key});
            defer alloc.free(name);
            try self.add(alloc, name, value);
        }
    }
};

pub fn isEnvSafeKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

const testing = std.testing;

test "no arguments is the empty object, and anything else goes through as written" {
    try testing.expectEqualStrings("{}", normalizedArguments(""));
    try testing.expectEqualStrings("{}", normalizedArguments("  \n\t "));
    try testing.expectEqualStrings("{\"a\":1}", normalizedArguments("  {\"a\":1}\n"));
    // Not a validator: shape is decided once, by `PlainEnv.addArguments`.
    try testing.expectEqualStrings("[]", normalizedArguments("[]"));
}

/// `NAME=VALUE\n` lines, so assertions read like the thing a script sees.
fn flatten(alloc: std.mem.Allocator, vars: *PlainEnv) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (vars.list.items) |v| try out.writer.print("{s}={s}\n", .{ v.name, v.value });
    return out.toOwnedSlice();
}

test "every top-level scalar argument is exported; structures and unreadable keys are not" {
    const alloc = testing.allocator;
    var vars: PlainEnv = .empty;
    defer vars.deinit(alloc);
    try vars.add(alloc, "NULYA_TOOL", "greet");
    try vars.addArguments(alloc, "{\"name\":\"world\",\"count\":3,\"deep\":true,\"list\":[1,2],\"obj\":{\"a\":1},\"nothing\":null,\"bad-key\":\"x\"}");

    const flat = try flatten(alloc, &vars);
    defer alloc.free(flat);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_TOOL=greet\n") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_name=world\n") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_count=3\n") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_deep=true\n") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_list") == null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_obj") == null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_nothing") == null);
    try testing.expect(std.mem.indexOf(u8, flat, "bad-key") == null);
}

test "a value carrying NUL is left on stdin only, never silently truncated" {
    const alloc = testing.allocator;
    var vars: PlainEnv = .empty;
    defer vars.deinit(alloc);
    try vars.addArguments(alloc, "{\"a\":\"x\\u0000y\",\"b\":\"fine\"}");

    const flat = try flatten(alloc, &vars);
    defer alloc.free(flat);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_a") == null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_b=fine\n") != null);
}

test "one call's whole environment is the tool name, the scalars, and a presentation file when there is one" {
    const alloc = testing.allocator;

    var vars = try callEnv(alloc, "greet", "{\"name\":\"world\",\"list\":[1,2]}", null);
    defer vars.deinit(alloc);
    const flat = try flatten(alloc, &vars);
    defer alloc.free(flat);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_TOOL=greet\n") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_name=world\n") != null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_ARG_list") == null);
    try testing.expect(std.mem.indexOf(u8, flat, "NULYA_PRESENTATION_FILE") == null);

    // The presentation file appears only when a driver offered one, which a
    // remote environment never does.
    var bare = try callEnv(alloc, "t", "{}", ".nulya/scratch/s/p.json");
    defer bare.deinit(alloc);
    const bare_flat = try flatten(alloc, &bare);
    defer alloc.free(bare_flat);
    try testing.expectEqualStrings("NULYA_TOOL=t\nNULYA_PRESENTATION_FILE=.nulya/scratch/s/p.json\n", bare_flat);
}

test "arguments that are not a JSON object are refused, before anything is spawned" {
    const alloc = testing.allocator;
    var bad: PlainEnv = .empty;
    defer bad.deinit(alloc);
    try testing.expectError(error.InvalidArgumentsJson, bad.addArguments(alloc, "{bad"));
    try testing.expectError(error.ArgumentsNotObject, bad.addArguments(alloc, "[]"));

    // The same rule as its own question, which is what the seam asks before
    // spawning anything or sending a frame anywhere.
    try requireArgumentsObject(alloc, "{\"a\":1}");
    try testing.expectError(error.InvalidArgumentsJson, requireArgumentsObject(alloc, "{bad"));
    try testing.expectError(error.ArgumentsNotObject, requireArgumentsObject(alloc, "[]"));
}

test "an allocation failure surfaces as OutOfMemory, not as malformed arguments" {
    // A host OOM in the parser must propagate: folding it into
    // InvalidArgumentsJson would misreport a resource fault as a broken call.
    const alloc = testing.allocator;
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var vars: PlainEnv = .empty;
    try testing.expectError(error.OutOfMemory, vars.addArguments(failing.allocator(), "{\"a\":\"b\"}"));
}

test "an env key is exactly [A-Za-z0-9_]+" {
    try testing.expect(isEnvSafeKey("name"));
    try testing.expect(isEnvSafeKey("A_1"));
    try testing.expect(!isEnvSafeKey(""));
    try testing.expect(!isEnvSafeKey("bad-key"));
    try testing.expect(!isEnvSafeKey("a.b"));
    try testing.expect(!isEnvSafeKey("é"));
}
