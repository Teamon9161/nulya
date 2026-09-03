//! One-shot OpenSSH password delivery without putting the password in argv,
//! environment variables, files, or SSH's stdin (which is the remote framing
//! channel). The host holds the bytes behind a loopback listener; the fixed
//! askpass helper is this same executable in a narrowly selected startup mode.

const std = @import("std");

pub const marker_env = "NULYA_SSH_ASKPASS";
pub const max_password_bytes: usize = 4096;
const token_bytes = 32;
/// How many connections one broker will answer before it stops listening. A
/// bound on a loop, not a policy: the ladder that opens a channel needs a
/// handful, and nothing legitimate needs many.
const max_serves: usize = 32;
const max_marker_bytes = 6 + token_bytes * 2;

pub const Broker = struct {
    io: std.Io,
    server: std.Io.net.Server,
    token: [token_bytes]u8,
    password: []const u8,
    marker_buf: [max_marker_bytes]u8 = undefined,
    marker_len: usize = 0,
    future: ?std.Io.Future(void) = null,

    pub fn init(io: std.Io, password: []const u8) !Broker {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var broker: Broker = .{
            .io = io,
            .server = try address.listen(io, .{}),
            .token = undefined,
            .password = password,
        };
        io.random(&broker.token);
        broker.marker_len = (std.fmt.bufPrint(
            &broker.marker_buf,
            "{d}:{x}",
            .{ broker.server.socket.address.getPort(), broker.token },
        ) catch unreachable).len;
        return broker;
    }

    pub fn start(self: *Broker) void {
        self.future = self.io.async(serve, .{self});
    }

    pub fn marker(self: *const Broker) []const u8 {
        return self.marker_buf[0..self.marker_len];
    }

    pub fn deinit(self: *Broker) void {
        if (self.future) |*future| _ = future.cancel(self.io);
        self.server.deinit(self.io);
        std.crypto.secureZero(u8, &self.token);
        self.* = undefined;
    }

    fn serve(self: *Broker) void {
        // A process that guesses the ephemeral port but not the token may cause
        // a refused connection, never disclosure. Leave a few attempts so that
        // such a race cannot steal a legitimate askpass exchange.
        //
        // Serving does NOT stop at the first success: opening a channel can take
        // several ssh invocations (find the agent, install one, connect again),
        // and a person who typed a password once must not be asked again halfway
        // through. The bound counts every accept, so the loop still ends.
        var attempts: usize = 0;
        while (attempts < max_serves) : (attempts += 1) {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            var read_buf: [256]u8 = undefined;
            var reader = stream.reader(self.io, &read_buf);
            const line = reader.interface.takeDelimiterExclusive('\n') catch continue;
            var supplied: [token_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &supplied);
            const decoded = std.fmt.hexToBytes(&supplied, line) catch continue;
            if (decoded.len != token_bytes or !std.crypto.timing_safe.eql([token_bytes]u8, supplied, self.token)) continue;

            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(self.io, &write_buf);
            writer.interface.writeAll(self.password) catch return;
            writer.interface.writeByte('\n') catch return;
            writer.interface.flush() catch return;
        }
    }
};

/// Startup mode used when OpenSSH executes `SSH_ASKPASS`. The marker contains
/// only a loopback endpoint and a random capability; the password itself is
/// read from the broker and written only to askpass stdout.
pub fn runHelper(io: std.Io, marker: []const u8) !u8 {
    const colon = std.mem.indexOfScalar(u8, marker, ':') orelse return 1;
    const port = std.fmt.parseInt(u16, marker[0..colon], 10) catch return 1;
    const token = marker[colon + 1 ..];
    if (token.len != token_bytes * 2) return 1;

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return 1;
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(token);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var read_buf: [512]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var stdout_buf: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const password = reader.interface.takeDelimiterExclusive('\n') catch return 1;
    try stdout.interface.writeAll(password);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
    return 0;
}

test "broker marker discloses no password, and it answers every authenticated ask" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const secret = "not-in-marker-91";

    var broker = try Broker.init(io, secret);
    defer broker.deinit();
    try std.testing.expect(std.mem.indexOf(u8, broker.marker(), secret) == null);
    broker.start();

    const colon = std.mem.indexOfScalar(u8, broker.marker(), ':').?;
    const port = try std.fmt.parseInt(u16, broker.marker()[0..colon], 10);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(broker.marker()[colon + 1 ..]);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    try std.testing.expectEqualStrings(secret, try reader.interface.takeDelimiterExclusive('\n'));

    // A second ask is answered too: opening one channel can take several ssh
    // invocations, and the person typed the password once.
    const again = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer again.close(io);
    var write_buf2: [256]u8 = undefined;
    var writer2 = again.writer(io, &write_buf2);
    try writer2.interface.writeAll(broker.marker()[colon + 1 ..]);
    try writer2.interface.writeByte('\n');
    try writer2.interface.flush();
    var read_buf2: [256]u8 = undefined;
    var reader2 = again.reader(io, &read_buf2);
    try std.testing.expectEqualStrings(secret, try reader2.interface.takeDelimiterExclusive('\n'));
}
