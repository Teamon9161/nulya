//! The one out for a sentence a Zig error cannot carry.
//!
//! An error is a name: `RemoteChannelLost` cannot say which machine, which
//! version, or which command fixes it. A `Diag` is where that sentence goes,
//! chosen by the shell layer and never by the kernel — the default reports
//! nothing, so a library path that acquires one stays silent until someone
//! hands it a destination. `io` is passed at report time, so a sink is
//! stateless and owns no lifetime outliving whatever copied it.

const std = @import("std");

pub const Diag = struct {
    ptr: ?*anyopaque = null,
    reportFn: ?*const fn (ptr: ?*anyopaque, io: std.Io, line: []const u8) void = null,

    pub fn report(self: Diag, io: std.Io, line: []const u8) void {
        const f = self.reportFn orelse return;
        f(self.ptr, io, line);
    }

    /// The same, formatted. Silent when there is no sink, so a caller pays no
    /// allocation for a line nobody reads; a line too long for `buf` is
    /// reported truncated rather than dropped.
    pub fn reportFmt(self: Diag, io: std.Io, comptime fmt: []const u8, args: anytype) void {
        if (self.reportFn == null) return;
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        self.report(io, line);
    }
};

/// The sink every CLI path uses: stderr, so a command whose stdout is a
/// protocol (`session step`'s line protocol, `remote check --json`) keeps it
/// pure while still being able to say what it is doing.
pub const to_stderr: Diag = .{ .reportFn = writeStderrLine };

fn writeStderrLine(_: ?*anyopaque, io: std.Io, line: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, line) catch {};
}

test "a diag with no sink reports nothing and formats nothing" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const silent: Diag = .{};
    silent.report(threaded.io(), "dropped");
    silent.reportFmt(threaded.io(), "{s}", .{"dropped"});
}

test "a sink sees what was reported, formatted or not" {
    const Sink = struct {
        var seen: std.ArrayList(u8) = .empty;
        fn write(_: ?*anyopaque, _: std.Io, line: []const u8) void {
            seen.appendSlice(std.testing.allocator, line) catch {};
        }
    };
    defer Sink.seen.deinit(std.testing.allocator);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const loud: Diag = .{ .reportFn = Sink.write };
    loud.report(threaded.io(), "one;");
    loud.reportFmt(threaded.io(), "{s} {d}", .{ "two", 2 });
    try std.testing.expectEqualStrings("one;two 2", Sink.seen.items);
}
