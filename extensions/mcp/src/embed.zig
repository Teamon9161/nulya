//! This package's own source, as the bytes a generated package carries.
//!
//! A generated server package IS this program with a `server.json` beside it, so
//! the generator ships its own tree rather than a second implementation. The
//! list is exhaustive on purpose: a file missing here is a generated draft that
//! does not compile, and the compiler cannot notice because the draft is written
//! at run time.

pub const File = struct {
    /// Its name inside the generated draft's `src/`.
    name: []const u8,
    bytes: []const u8,
};

pub const files = [_]File{
    .{ .name = "main.zig", .bytes = @embedFile("main.zig") },
    .{ .name = "client.zig", .bytes = @embedFile("client.zig") },
    .{ .name = "embed.zig", .bytes = @embedFile("embed.zig") },
    .{ .name = "gen.zig", .bytes = @embedFile("gen.zig") },
    .{ .name = "rpc.zig", .bytes = @embedFile("rpc.zig") },
    .{ .name = "server.zig", .bytes = @embedFile("server.zig") },
};
