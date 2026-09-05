//! One MCP server over stdio: spawn it, speak JSON-RPC 2.0 one line per
//! message, ask it what it can do or ask it to do one thing, then stop it.
//!
//! Both of the server's output pipes are read TOGETHER: a server that logs to
//! stderr while we wait on stdout would otherwise fill that pipe and block
//! forever. Its stderr is captured rather than inherited, because a failed call's
//! message belongs to this package — the server's own words go inside it, cut to
//! a quotable tail.
//!
//! Every exchange shares one deadline taken at `start`, so a server that accepts
//! a request and never answers ends as a failed call rather than a hung process.

const std = @import("std");

pub const Error = error{
    SpawnFailed,
    /// The server ended, or its stdin would not take another message.
    ServerClosed,
    ServerTimeout,
    ServerUnreadable,
    /// The server answered with a JSON-RPC error; `fault` holds what it said.
    ServerError,
    /// A well-formed answer that does not hold what the method promises.
    BadResponse,
    /// More tools than one generated package may carry.
    TooManyTools,
} || std.mem.Allocator.Error;

/// The revision this client speaks. A server that answers with a different one
/// is not refused: MCP servers commonly serve several revisions, and the two
/// methods used here have been in every one of them.
pub const protocol_version = "2025-06-18";

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Options = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    /// Variables for the server's own environment, on top of this process's.
    /// Their values came from a file this package read; they are never in the
    /// package's frozen bytes.
    env: []const Pair = &.{},
    timeout_ms: u32 = 60_000,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8 = "",
    /// The server's own JSON Schema for this tool's arguments, re-encoded but
    /// otherwise untouched — including the key order it sent.
    input_schema: []const u8 = "{}",
};

pub const CallResult = struct {
    text: []const u8,
    /// The server's own `isError`: a tool that ran and reports failure, which is
    /// a failed call to the model rather than a broken server.
    is_error: bool = false,
};

/// A live server. Hold it PUT once started: the reader's bookkeeping points back
/// into this value.
pub const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child = undefined,
    streams: std.Io.File.MultiReader.Buffer(2) = undefined,
    reader: std.Io.File.MultiReader = undefined,
    running: bool = false,
    next_id: i64 = 1,
    deadline: std.Io.Timeout = .none,
    /// What the last `ServerError` said, for the message the caller builds.
    fault: []const u8 = "",

    pub fn start(
        self: *Server,
        environ: *const std.process.Environ.Map,
        opts: Options,
    ) Error!void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(self.alloc, opts.command);
        try argv.appendSlice(self.alloc, opts.args);

        var env: std.process.Environ.Map = .init(self.alloc);
        var it = environ.iterator();
        while (it.next()) |entry| {
            // This call's own wire variables are not the server's business, and
            // one of them (`NULYA_TOOL`) names a tool the server never heard of.
            if (isCallVariable(entry.key_ptr.*)) continue;
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        for (opts.env) |p| try env.put(p.key, p.value);

        self.child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        }) catch return error.SpawnFailed;
        self.running = true;
        self.deadline = .{ .deadline = std.Io.Clock.Timestamp.fromNow(
            self.io,
            .{ .clock = .awake, .raw = .fromMilliseconds(opts.timeout_ms) },
        ) };
        self.reader.init(
            self.alloc,
            self.io,
            self.streams.toStreams(),
            &.{ self.child.stdout.?, self.child.stderr.? },
        );
    }

    /// The handshake every MCP session opens with: one request, then the
    /// notification that says the client is ready.
    pub fn initialize(self: *Server) Error!void {
        const params = "{\"protocolVersion\":\"" ++ protocol_version ++
            "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"nulya-mcp\",\"version\":\"1\"}}";
        _ = try self.request("initialize", params);
        try self.notify("notifications/initialized");
    }

    /// Every tool the server declares, following its cursor to the end.
    pub fn listTools(self: *Server, max: usize) Error![]Tool {
        var out: std.ArrayList(Tool) = .empty;
        var cursor: ?[]const u8 = null;
        while (true) {
            const params = if (cursor) |c| blk: {
                var body: std.Io.Writer.Allocating = .init(self.alloc);
                body.writer.writeAll("{\"cursor\":") catch return error.OutOfMemory;
                std.json.Stringify.encodeJsonString(c, .{}, &body.writer) catch return error.OutOfMemory;
                body.writer.writeAll("}") catch return error.OutOfMemory;
                break :blk body.written();
            } else "{}";

            const result = try self.request("tools/list", params);
            const obj = switch (result) {
                .object => |o| o,
                else => return error.BadResponse,
            };
            const listed = switch (obj.get("tools") orelse return error.BadResponse) {
                .array => |a| a.items,
                else => return error.BadResponse,
            };
            for (listed) |item| {
                const tool_obj = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                const name = switch (tool_obj.get("name") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                if (out.items.len >= max) return error.TooManyTools;
                try out.append(self.alloc, .{
                    .name = name,
                    .description = switch (tool_obj.get("description") orelse std.json.Value{ .null = {} }) {
                        .string => |s| s,
                        else => "",
                    },
                    .input_schema = try schemaText(self.alloc, tool_obj.get("inputSchema")),
                });
            }
            cursor = switch (obj.get("nextCursor") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                else => null,
            };
            if (cursor == null) break;
        }
        return out.items;
    }

    /// One `tools/call`. `arguments_json` is the caller's own arguments object,
    /// passed through untouched: the schema the model wrote against is the
    /// server's, so nothing here is in a position to reshape it.
    pub fn callTool(self: *Server, name: []const u8, arguments_json: []const u8) Error!CallResult {
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        const w = &body.writer;
        w.writeAll("{\"name\":") catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(name, .{}, w) catch return error.OutOfMemory;
        w.print(",\"arguments\":{s}}}", .{arguments_json}) catch return error.OutOfMemory;

        const result = try self.request("tools/call", body.written());
        const obj = switch (result) {
            .object => |o| o,
            else => return error.BadResponse,
        };
        return .{
            .text = try renderContent(self.alloc, obj),
            .is_error = switch (obj.get("isError") orelse std.json.Value{ .bool = false }) {
                .bool => |b| b,
                else => false,
            },
        };
    }

    /// Whatever the server has said on stderr so far, cut to a quotable tail.
    /// Read rather than waited for: everything it wrote while this client was
    /// waiting on stdout is already here.
    pub fn stderrTail(self: *Server, limit: usize) []const u8 {
        if (!self.running) return "";
        const buffered = self.reader.reader(1).buffered();
        const trimmed = std.mem.trim(u8, buffered, " \t\r\n");
        if (trimmed.len <= limit) return trimmed;
        return trimmed[trimmed.len - limit ..];
    }

    /// End the server, THEN stop reading — and never the other way round.
    ///
    /// The reader is parked on both pipes, and those reads end only when the
    /// process holding their write ends is gone; stopping the reader first waits
    /// on a server nobody has told to stop, which never returns. The two files
    /// are detached before the kill so that no handle is closed while a read
    /// still names it, and closed here once the reader has let go.
    ///
    /// Killing rather than waiting: this process answers one call and exits, and
    /// a server that ignores the EOF on its stdin must not be able to hold that
    /// exit open — its inherited handles would keep the caller waiting for
    /// output that has already been written.
    pub fn stop(self: *Server) void {
        if (!self.running) return;
        self.running = false;
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }
        const out = self.child.stdout;
        const err = self.child.stderr;
        self.child.stdout = null;
        self.child.stderr = null;
        self.child.kill(self.io);
        self.reader.deinit();
        if (out) |file| file.close(self.io);
        if (err) |file| file.close(self.io);
    }

    fn request(self: *Server, method: []const u8, params_json: []const u8) Error!std.json.Value {
        const id = self.next_id;
        self.next_id += 1;

        var body: std.Io.Writer.Allocating = .init(self.alloc);
        const w = &body.writer;
        w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id}) catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(method, .{}, w) catch return error.OutOfMemory;
        w.print(",\"params\":{s}}}\n", .{params_json}) catch return error.OutOfMemory;
        try self.send(body.written());

        while (true) {
            const line = try self.readLine();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.alloc, line, .{}) catch continue;
            const obj = switch (parsed) {
                .object => |o| o,
                else => continue,
            };
            // A notification has no id, and an answer to somebody else's request
            // is not ours; both are skipped rather than mistaken for this one.
            const answered = switch (obj.get("id") orelse continue) {
                .integer => |n| n,
                else => continue,
            };
            if (answered != id) continue;
            if (obj.get("error")) |e| {
                self.fault = try faultText(self.alloc, e);
                return error.ServerError;
            }
            return obj.get("result") orelse .{ .object = .empty };
        }
    }

    fn notify(self: *Server, method: []const u8) Error!void {
        var body: std.Io.Writer.Allocating = .init(self.alloc);
        const w = &body.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":") catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(method, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}\n") catch return error.OutOfMemory;
        try self.send(body.written());
    }

    fn send(self: *Server, bytes: []const u8) Error!void {
        const stdin = self.child.stdin orelse return error.ServerClosed;
        stdin.writeStreamingAll(self.io, bytes) catch return error.ServerClosed;
    }

    /// One message. Owned by the caller's arena, because the next fill may move
    /// the buffer this came out of.
    fn readLine(self: *Server) Error![]u8 {
        while (true) {
            const stdout = self.reader.reader(0);
            if (std.mem.indexOfScalar(u8, stdout.buffered(), '\n')) |at| {
                const line = stdout.take(at + 1) catch return error.ServerUnreadable;
                return self.alloc.dupe(u8, std.mem.trimEnd(u8, line[0..at], "\r"));
            }
            self.reader.fill(1, self.deadline) catch |err| return switch (err) {
                error.EndOfStream => error.ServerClosed,
                error.Timeout => error.ServerTimeout,
                else => error.ServerUnreadable,
            };
        }
    }
};

/// This call's own wire, which stops at this process.
fn isCallVariable(key: []const u8) bool {
    return std.mem.eql(u8, key, "NULYA_TOOL") or
        std.mem.eql(u8, key, "NULYA_PRESENTATION_FILE") or
        std.mem.startsWith(u8, key, "NULYA_ARG_");
}

/// A tool's argument schema as text. Re-encoded from what the server sent, so a
/// generated manifest is always valid JSON; the key order survives, because a
/// parsed object here keeps its insertion order.
fn schemaText(alloc: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const schema = value orelse return "{\"type\":\"object\"}";
    return switch (schema) {
        .object => std.json.Stringify.valueAlloc(alloc, schema, .{}),
        else => "{\"type\":\"object\"}",
    };
}

/// What a JSON-RPC error object says, in one line.
fn faultText(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return std.json.Stringify.valueAlloc(alloc, value, .{}),
    };
    const message = switch (obj.get("message") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };
    const code: i64 = switch (obj.get("code") orelse std.json.Value{ .null = {} }) {
        .integer => |n| n,
        else => 0,
    };
    if (message.len == 0) return std.json.Stringify.valueAlloc(alloc, value, .{});
    return std.fmt.allocPrint(alloc, "{s} (code {d})", .{ message, code });
}

/// What the model reads back from one `tools/call`.
///
/// Text blocks are the answer; anything else is named rather than dropped, so a
/// result that WAS an image does not read as an empty one. A result with no
/// content at all falls back to the structured half, then to the whole object —
/// the last two are rarer than they are worth a second shape for.
fn renderContent(alloc: std.mem.Allocator, result: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const blocks = switch (result.get("content") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        else => &.{},
    };
    for (blocks) |block| {
        const obj = switch (block) {
            .object => |o| o,
            else => continue,
        };
        const kind = switch (obj.get("type") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        };
        if (out.written().len != 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
        if (std.mem.eql(u8, kind, "text")) {
            const text = switch (obj.get("text") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                else => "",
            };
            out.writer.writeAll(text) catch return error.OutOfMemory;
        } else {
            out.writer.print("[{s} content, not shown]", .{if (kind.len == 0) "unlabelled" else kind}) catch
                return error.OutOfMemory;
        }
    }
    if (out.written().len != 0) return out.toOwnedSlice();
    if (result.get("structuredContent")) |structured| return std.json.Stringify.valueAlloc(alloc, structured, .{});
    return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = result }, .{});
}
