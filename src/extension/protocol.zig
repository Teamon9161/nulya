//! Extension wire protocol (DESIGN §7.3).
//!
//! The transport is deliberately dumb and oneshot: the host spawns the
//! extension, writes the call's arguments to stdin, reads its stdout, and the
//! process exits. No daemon, no streaming, no bidirectional events, no host
//! callbacks. The wire protocol IS the ABI, so extensions need not be written in
//! Zig (DESIGN §7.1).
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
//!           printed — a file's contents, a search listing, or JSON when the
//!           caller is a driver that parses one; stdout is bytes, so one wire
//!           carries both.
//!   exit    0 = success. Non-zero = a failed call, whose text is `exit <code>`
//!           followed by stderr, and by stdout if anything was printed. So the
//!           message a tool writes to stderr before failing IS what the model
//!           reads: say what went wrong and what would work next call. Nothing
//!           else may go to stderr — on a failing call it is the message.
//!
//!     #!/bin/sh
//!     printf 'hello %s\n' "${NULYA_ARG_name:-world}"
//!
//! Below are the two rules of that contract that are pure functions of the
//! arguments — what "no arguments" is, and which keys reach the environment.
//! They live with the contract rather than with the spawning code, so what
//! `nulya ext api protocol` prints is the contract AND its implementation.

const std = @import("std");
const environment = @import("../environment.zig");

/// The exact bytes that go to stdin: the model's arguments object, trimmed,
/// with "nothing" spelled `{}`.
pub fn normalizedArguments(args_json: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, args_json, " \t\r\n");
    return if (trimmed.len == 0) "{}" else trimmed;
}

/// The per-call environment, owning every string it hands to `runExtension`.
pub const PlainEnv = struct {
    list: std.ArrayList(environment.EnvVar) = .empty,

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
    /// null do not appear: an environment variable is a string, and inventing a
    /// serialization for a structure would be a second argument format for a
    /// script to parse — stdin already carries the whole object, exactly.
    ///
    /// Keys outside `[A-Za-z0-9_]+` are skipped rather than mangled, for the
    /// same reason: a name a shell cannot read is not made readable by rewriting
    /// it, and the value is still on stdin.
    ///
    /// The parse is also where "the arguments are a JSON object" is enforced,
    /// before anything is spawned — nothing runs with something a tool's
    /// declared `input` schema could not describe.
    pub fn addArguments(self: *PlainEnv, alloc: std.mem.Allocator, arguments: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch |err| switch (err) {
            // The parser allocates while validating the arguments object: a host
            // OOM is a resource fault and must not be misreported as malformed
            // arguments.
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
            // value carrying one would arrive silently truncated. Skipped
            // instead — stdin still has it whole.
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

/// Flatten a built environment to `NAME=VALUE\n` lines, so the assertions below
/// read like the thing a script sees.
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

test "arguments that are not a JSON object are refused, before anything is spawned" {
    const alloc = testing.allocator;
    var bad: PlainEnv = .empty;
    defer bad.deinit(alloc);
    try testing.expectError(error.InvalidArgumentsJson, bad.addArguments(alloc, "{bad"));
    try testing.expectError(error.ArgumentsNotObject, bad.addArguments(alloc, "[]"));
}

test "an allocation failure surfaces as OutOfMemory, not as malformed arguments" {
    // The first allocation inside `addArguments` is the parser building the
    // Value tree. A host OOM there must propagate — folding it into
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
