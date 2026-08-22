//! A session's frozen header — the first line of its ledger file (DESIGN §3.4).
//!
//! Three readers in this package need it: which persona a session is wearing
//! (`defs.wornPersona`), what model the parent runs on (`main.parentIdentity`),
//! and which of a delegation's tools declare themselves read-only
//! (`runner.readonlyToolNames`). One implementation, because the interesting
//! part is a NUMBER and it must not be guessed three times:
//!
//! Since `session new --prompt` freezes per-session system prompts into the
//! header by value (DESIGN §5.6), a header line is as long as the text a person
//! wrote — the kernel caps a system prompt at 2 MB. A fixed stack buffer smaller
//! than that does not truncate: `Reader.takeDelimiter` returns
//! `error.StreamTooLong` and reads NOTHING, so a caller that treats an error as
//! "no header" silently loses the whole answer. That is what makes it dangerous
//! — a slightly longer persona turns a working delegation into one whose every
//! tool call is refused, with nothing in any log to say why.

const std = @import("std");

/// Comfortably above the kernel's own `prompt.max_system_prompt_bytes` (2 MB)
/// plus the rest of a header. Allocated once per read in a one-shot process.
pub const max_header_bytes: usize = 4 << 20;

/// The header line of `<session>`, or null when there is no readable one.
/// Caller owns nothing: the slice lives in `alloc`.
pub fn read(alloc: std.mem.Allocator, io: std.Io, session_id: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(alloc, ".nulya/sessions/{s}.jsonl", .{session_id}) catch return null;
    defer alloc.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const buf = alloc.alloc(u8, max_header_bytes) catch return null;
    defer alloc.free(buf);
    var reader = file.reader(io, buf);
    const line = (reader.interface.takeDelimiter('\n') catch return null) orelse return null;
    return alloc.dupe(u8, line) catch null;
}

/// The header parsed, for the readers that want fields out of it.
pub fn object(alloc: std.mem.Allocator, io: std.Io, session_id: []const u8) ?std.json.ObjectMap {
    const line = read(alloc, io, session_id) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return null;
    return switch (parsed.value) {
        .object => |o| o,
        else => null,
    };
}
