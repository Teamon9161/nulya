//! Shared provider wire plumbing.
//!
//! Three providers — `openai` (chat/completions), `anthropic` (messages) and
//! `codex` (the ChatGPT-subscription responses endpoint) — speak different JSON
//! dialects over the same transport: one streaming HTTPS POST whose body is SSE.
//! What all three genuinely share lives here: the POST + SSE loop, the JSON
//! scalar readers, and the one piece of PromptIR serialization that is the same
//! everywhere (`writeReasoningItems`). A provider file is then only its own wire
//! shape — the turn structure it needs comes typed out of `prompt.Turn`.

const std = @import("std");

// ---------------------------------------------------------------- PromptIR --

/// Write every item of a turn's `reasoning` (the JSON array a `TurnCollector`
/// joined from the provider's own `reasoning_item`s) as one JSON value each,
/// into whatever array `jw` is currently inside. Both wires that replay
/// reasoning place the items bare — Anthropic as content blocks, Responses as
/// input items — so the splitting is shared; only the surrounding container is
/// the provider's. Items are re-serialized from the parsed value, which keeps
/// key order and is what a signature / encrypted blob is indifferent to.
pub fn writeReasoningItems(jw: *std.json.Stringify, alloc: std.mem.Allocator, reasoning: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, reasoning, .{}) catch return error.CorruptReasoning;
    defer parsed.deinit();
    if (parsed.value != .array) return error.CorruptReasoning;
    for (parsed.value.array.items) |item| try jw.write(item);
}

/// The `data:<media_type>;base64,<data>` URI an inline image travels as on BOTH
/// JSON dialects that take one as a URL (chat/completions' `image_url`, the
/// responses endpoint's `input_image`). Anthropic's block carries the two parts
/// separately, so it does not come through here — two consumers, not three.
/// Built as a string rather than spliced raw so the JSON writer still escapes
/// it: the ledger stores whatever it was handed, and this is the wire, not
/// the place to trust it. Caller owns the result.
pub fn dataUri(alloc: std.mem.Allocator, media_type: []const u8, data: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "data:{s};base64,{s}", .{ media_type, data });
}

// ------------------------------------------------------------------- JSON --

pub fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

pub fn string(v: std.json.Value, name: []const u8) ?[]const u8 {
    const child = field(v, name) orelse return null;
    if (child != .string) return null;
    return child.string;
}

pub fn uint(v: std.json.Value, name: []const u8) u64 {
    const child = field(v, name) orelse return 0;
    return switch (child) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        .float => |f| if (f >= 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

/// Splice an already-serialized JSON document (a tool's `input_schema`) into the
/// stream without reparsing it.
pub fn writeRaw(jw: *std.json.Stringify, raw: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeAll(raw);
    jw.endWriteRaw();
}

// ------------------------------------------------------------------- HTTP --

pub const Post = struct {
    url: []const u8,
    body: []const u8,
    /// The HTTP method. Every model request is a POST; the one exception is the
    /// Codex subscription's model catalogue, a plain GET that is otherwise the
    /// same exchange — same auth headers, same status classification, same stall
    /// guard — so it rides here rather than in a second transport (`getJson`).
    method: std.http.Method = .POST,
    /// Full `Authorization` header value (e.g. `Bearer sk-…`); null omits it.
    authorization: ?[]const u8 = null,
    /// Provider-specific headers (`x-api-key`, `anthropic-version`, …).
    extra_headers: []const std.http.Header = &.{},
    /// Silence budget (`provider.RetryPolicy.stall_timeout_ms`): if the server
    /// sends NOTHING — not a response head, not one more line of body — for this
    /// long, the exchange is canceled and reported as `Transport`, so the loop
    /// retries instead of the process hanging until the OS gives up on the
    /// socket. Counted from the request going out and reset by every line,
    /// keepalives and events we never decode included, so a live-but-slow model
    /// is only mistaken for a stall after this much true silence. 0 = off.
    stall_ms: u64 = 0,
};

/// When the server was last heard from, shared between the exchange task that
/// stamps it and the watchdog that reads it.
const Heartbeat = struct {
    io: std.Io,
    last_ms: std.atomic.Value(i64),
    /// Set by the watchdog's side once it declared a stall and is canceling the
    /// exchange: whatever read error the interrupted exchange then sees is our
    /// doing, not worth a diagnostic of its own.
    stalled: std.atomic.Value(bool) = .init(false),

    fn init(io: std.Io) Heartbeat {
        return .{ .io = io, .last_ms = .init(nowMs(io)) };
    }

    fn beat(self: *Heartbeat) void {
        self.last_ms.store(nowMs(self.io), .monotonic);
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Timestamp.now(io, .awake).toMilliseconds();
    }
};

/// Returns once `stall_ms` passed with no beat. Being canceled — the exchange
/// finished first — is simply the end of the watch.
fn watchdog(hb: *Heartbeat, stall_ms: u64) void {
    while (true) {
        const idle = Heartbeat.nowMs(hb.io) - hb.last_ms.load(.monotonic);
        if (idle >= @as(i64, @intCast(stall_ms))) return;
        std.Io.sleep(hb.io, .fromMilliseconds(@as(i64, @intCast(stall_ms)) - idle), .awake) catch return;
    }
}

/// Run `exchange(args…, *Heartbeat)` under the stall watchdog. Both are their
/// own tasks so whichever finishes first cancels the other — a stalled exchange
/// is interrupted in its blocking read (`std.Io` cancellation reaches syscalls on
/// every backend we run on). Our own cancellation arrives at `await`, cancels
/// both, and propagates. If the io cannot give the pair their own units of
/// concurrency the exchange simply runs unguarded: never a false stall, just no
/// guard. `R` is the exchange's (error-union) result type.
fn Watched(comptime R: type) type {
    return struct {
        const Race = union(enum) { exchange: R, stall: void };

        fn run(io: std.Io, stall_ms: u64, comptime exchange: anytype, args: anytype) R {
            var hb: Heartbeat = .init(io);
            if (stall_ms == 0) return @call(.auto, exchange, args ++ .{&hb});

            var buf: [2]Race = undefined;
            var sel: std.Io.Select(Race) = .init(io, &buf);
            sel.concurrent(.stall, watchdog, .{ &hb, stall_ms }) catch return @call(.auto, exchange, args ++ .{&hb});
            sel.concurrent(.exchange, exchange, args ++ .{&hb}) catch {
                sel.cancelDiscard();
                return @call(.auto, exchange, args ++ .{&hb});
            };
            const first = sel.await() catch |err| {
                sel.cancelDiscard();
                return err;
            };
            if (first == .stall) hb.stalled.store(true, .release);
            sel.cancelDiscard();
            return switch (first) {
                .exchange => |r| r,
                .stall => transport(error.Stalled, &hb),
            };
        }
    };
}

/// How a request can fail short of a good stream. The loop retries the
/// transient ones (`provider.isTransient`); a provider handles `Unauthorized`
/// itself when it can refresh; the rest fail the step.
pub const HttpError = error{
    /// The connection itself failed — connect, TLS, send, headers, or the body
    /// cut off — as opposed to the server answering. `transport` folds every
    /// such fault into this one error and prints the concrete cause.
    Transport,
    /// 401: the caller may be able to refresh a credential and retry once.
    Unauthorized,
    /// 429.
    RateLimited,
    /// Any 5xx (Anthropic's 529 overloaded included).
    ServerError,
    /// Any other non-2xx: the request itself is wrong, so re-sending it cannot
    /// help. The response body is printed as a diagnostic.
    ApiError,
};

/// See `HttpError.Transport`. Cancellation and OOM are the host's, not the wire's.
fn transport(err: anyerror, hb: *const Heartbeat) anyerror {
    switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => {
            // The read the watchdog interrupted fails too; only the stall is news.
            if (err != error.Stalled and hb.stalled.load(.acquire)) return error.Transport;
            // (Silent under `zig build test`, whose stall test provokes this on purpose.)
            if (!@import("builtin").is_test) std.debug.print("provider transport error: {s}\n", .{@errorName(err)});
            return error.Transport;
        },
    }
}

fn open(client: *std.http.Client, p: Post, hb: *const Heartbeat) !std.http.Client.Request {
    const uri = try std.Uri.parse(p.url);
    return client.request(p.method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (p.authorization) |a| .{ .override = a } else .default,
            // A bodiless request has no content type to declare.
            .content_type = if (p.method.requestHasBody()) .{ .override = "application/json" } else .default,
            // Avoid gzip/deflate here so the SSE parser can read directly.
            .accept_encoding = .omit,
        },
        .extra_headers = p.extra_headers,
    }) catch |err| return transport(err, hb);
}

/// Send the body and receive the response head; the whole exchange is transport.
fn send(req: *std.http.Client.Request, body: []const u8, redirect_buffer: []u8, hb: *const Heartbeat) !std.http.Client.Response {
    return sendInner(req, body, redirect_buffer) catch |err| return transport(err, hb);
}

fn sendInner(req: *std.http.Client.Request, body: []const u8, redirect_buffer: []u8) !std.http.Client.Response {
    if (!req.method.requestHasBody()) {
        try req.sendBodiless();
        return req.receiveHead(redirect_buffer);
    }
    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
    return req.receiveHead(redirect_buffer);
}

/// POST `p` and hand every SSE `data:` payload to `onData`, stopping when it
/// returns true (the stream's own terminator) or the body ends.
///
/// SSE lines are accumulated into a growable buffer rather than the reader's
/// fixed transfer buffer: one `data:` line can carry a whole response object
/// (Codex's `response.completed`), far past any fixed line limit.
pub fn postSse(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    p: Post,
    ctx: anytype,
    comptime onData: fn (@TypeOf(ctx), []const u8) anyerror!bool,
) !void {
    // A task needs a plain (non-generic) function: bind `onData` here.
    const Exchange = struct {
        fn run(c: *std.http.Client, a: std.mem.Allocator, post: Post, cx: @TypeOf(ctx), hb: *Heartbeat) anyerror!void {
            return exchangeSse(c, a, post, cx, onData, hb);
        }
    };
    return Watched(anyerror!void).run(client.io, p.stall_ms, Exchange.run, .{ client, alloc, p, ctx });
}

fn exchangeSse(
    client: *std.http.Client,
    alloc: std.mem.Allocator,
    p: Post,
    ctx: anytype,
    comptime onData: fn (@TypeOf(ctx), []const u8) anyerror!bool,
    hb: *Heartbeat,
) anyerror!void {
    var req = try open(client, p, hb);
    defer req.deinit();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try send(&req, p.body, &redirect_buffer, hb);
    hb.beat();
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    if (response.head.status.class() != .success) return reportStatus(alloc, response.head.status, reader);

    var line: std.Io.Writer.Allocating = .init(alloc);
    defer line.deinit();
    while (true) {
        line.clearRetainingCapacity();
        _ = reader.streamDelimiterEnding(&line.writer, '\n') catch |err| return transport(err, hb);
        hb.beat();
        // Documented contract: at end of stream nothing is left buffered;
        // otherwise the next byte is the delimiter we just stopped at.
        const at_end = reader.bufferedLen() == 0;
        if (!at_end) reader.toss(1);

        const text = std.mem.trimEnd(u8, line.written(), "\r");
        if (std.mem.startsWith(u8, text, "data:")) {
            const data = std.mem.trim(u8, text[5..], " ");
            // `event:` lines are ignored on purpose: every dialect we speak also
            // carries its event name inside the payload (`type` / `choices`).
            if (data.len != 0 and try onData(ctx, data)) return;
        }
        if (at_end) break;
    }
}

/// POST `p` and return the whole response body (caller owns). Used for the small
/// non-streaming calls a provider needs around its stream, such as the Codex
/// OAuth token refresh.
pub fn postJson(client: *std.http.Client, alloc: std.mem.Allocator, p: Post) ![]u8 {
    return jsonExchange(client, alloc, p);
}

/// GET `p.url` and return the whole response body (caller owns) — the same
/// exchange minus a body. Its one caller is the Codex subscription's model
/// catalogue, which is a projection rather than a model request; `p.body` and
/// `p.method` are ignored.
pub fn getJson(client: *std.http.Client, alloc: std.mem.Allocator, p: Post) ![]u8 {
    var get = p;
    get.method = .GET;
    get.body = "";
    return jsonExchange(client, alloc, get);
}

fn jsonExchange(client: *std.http.Client, alloc: std.mem.Allocator, p: Post) ![]u8 {
    return Watched(anyerror![]u8).run(client.io, p.stall_ms, exchangeJson, .{ client, alloc, p });
}

fn exchangeJson(client: *std.http.Client, alloc: std.mem.Allocator, p: Post, hb: *Heartbeat) anyerror![]u8 {
    var req = try open(client, p, hb);
    defer req.deinit();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try send(&req, p.body, &redirect_buffer, hb);
    hb.beat();
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    if (response.head.status.class() != .success) return reportStatus(alloc, response.head.status, reader);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    _ = reader.streamRemaining(&out.writer) catch |err| return transport(err, hb);
    return out.toOwnedSlice();
}

fn reportStatus(alloc: std.mem.Allocator, status: std.http.Status, reader: *std.Io.Reader) HttpError {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    _ = reader.streamRemaining(&body.writer) catch {};
    std.debug.print("provider API error {d}: {s}\n", .{ @intFromEnum(status), body.written() });
    return switch (status) {
        .unauthorized => error.Unauthorized,
        .too_many_requests => error.RateLimited,
        else => if (status.class() == .server_error) error.ServerError else error.ApiError,
    };
}

test "the stall watchdog: a silent server is a Transport fault within the budget; a talking one is untouched" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A one-connection HTTP "server": either replies with a canned 200 or holds
    // the accepted connection open without sending a byte.
    const Peer = struct {
        fn serve(server: *std.Io.net.Server, io_: std.Io, reply: bool) void {
            const stream = server.accept(io_) catch return;
            defer stream.close(io_);
            if (reply) {
                // Read the whole request first: closing with unread bytes in
                // the receive buffer makes TCP send RST instead of FIN.
                var rbuf: [4096]u8 = undefined;
                var r = stream.reader(io_, &rbuf);
                while (std.mem.indexOf(u8, r.interface.buffered(), "\r\n\r\n{}") == null) r.interface.fillMore() catch return;
                var buf: [256]u8 = undefined;
                var w = stream.writer(io_, &buf);
                w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch return;
                w.interface.flush() catch return;
            } else {
                std.Io.sleep(io_, .fromMilliseconds(10_000), .awake) catch {};
            }
        }
    };

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    // Silent peer: the exchange must be cut and reported as Transport long
    // before the peer's own 10 s, however long the OS would have waited.
    {
        var server = try addr.listen(io, .{});
        defer server.deinit(io);
        var peer = io.async(Peer.serve, .{ &server, io, false });
        defer _ = peer.cancel(io);
        const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
        defer alloc.free(url);

        const started = Heartbeat.nowMs(io);
        try std.testing.expectError(error.Transport, postJson(&client, alloc, .{ .url = url, .body = "{}", .stall_ms = 300 }));
        try std.testing.expect(Heartbeat.nowMs(io) - started < 5_000);
    }

    // Talking peer: the same guard lets a normal exchange through, and stops
    // its watchdog cleanly afterwards.
    {
        var server = try addr.listen(io, .{});
        defer server.deinit(io);
        var peer = io.async(Peer.serve, .{ &server, io, true });
        defer _ = peer.cancel(io);
        const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
        defer alloc.free(url);

        const body = try postJson(&client, alloc, .{ .url = url, .body = "{}", .stall_ms = 5_000 });
        defer alloc.free(body);
        try std.testing.expectEqualStrings("ok", body);
    }
}

test "getJson is the same exchange minus a body: a bodiless GET, no content-type, response returned whole" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // What the server actually received, so the request shape is checked where
    // it is made rather than trusted.
    const Capture = struct { buf: [1024]u8 = undefined, len: usize = 0 };
    const Peer = struct {
        fn serve(server: *std.Io.net.Server, io_: std.Io, seen: *Capture) void {
            const stream = server.accept(io_) catch return;
            defer stream.close(io_);
            var rbuf: [4096]u8 = undefined;
            var r = stream.reader(io_, &rbuf);
            // A GET ends at the blank line: there is no body to wait for.
            while (std.mem.indexOf(u8, r.interface.buffered(), "\r\n\r\n") == null) r.interface.fillMore() catch return;
            const head = r.interface.buffered();
            seen.len = @min(head.len, seen.buf.len);
            @memcpy(seen.buf[0..seen.len], head[0..seen.len]);
            var buf: [256]u8 = undefined;
            var w = stream.writer(io_, &buf);
            w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"models\":[]}") catch return;
            w.interface.flush() catch return;
        }
    };

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    var seen: Capture = .{};
    var peer = io.async(Peer.serve, .{ &server, io, &seen });
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/models?client_version=1", .{server.socket.address.getPort()});
    defer alloc.free(url);

    const body = try getJson(&client, alloc, .{
        .url = url,
        .body = "ignored",
        .authorization = "Bearer t",
        .extra_headers = &.{.{ .name = "originator", .value = "codex_cli_rs" }},
        .stall_ms = 5_000,
    });
    defer alloc.free(body);
    _ = peer.cancel(io);

    try std.testing.expectEqualStrings("{\"models\":[]}", body);
    const request = seen.buf[0..seen.len];
    try std.testing.expect(std.mem.startsWith(u8, request, "GET /models?client_version=1 HTTP/1.1"));
    try std.testing.expect(std.mem.indexOf(u8, request, "authorization: Bearer t") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "originator: codex_cli_rs") != null);
    // Nothing was sent that a bodiless request cannot have.
    try std.testing.expect(std.mem.indexOf(u8, request, "content-type") == null);
    try std.testing.expect(std.mem.indexOf(u8, request, "content-length") == null);
    try std.testing.expect(std.mem.indexOf(u8, request, "ignored") == null);
}

test "reasoning items are spliced back one value each, in order" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginArray();
    try jw.write("head");
    try writeReasoningItems(&jw, alloc, "[{\"type\":\"thinking\",\"thinking\":\"a\",\"signature\":\"s\"},{\"type\":\"redacted_thinking\",\"data\":\"d\"}]");
    try jw.write("tail");
    try jw.endArray();
    try std.testing.expectEqualStrings(
        "[\"head\",{\"type\":\"thinking\",\"thinking\":\"a\",\"signature\":\"s\"},{\"type\":\"redacted_thinking\",\"data\":\"d\"},\"tail\"]",
        out.written(),
    );

    var junk: std.Io.Writer.Allocating = .init(alloc);
    defer junk.deinit();
    var jw2: std.json.Stringify = .{ .writer = &junk.writer };
    try jw2.beginArray();
    try std.testing.expectError(error.CorruptReasoning, writeReasoningItems(&jw2, alloc, "{\"not\":\"an array\"}"));
}
