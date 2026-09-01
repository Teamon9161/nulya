//! `nulya journal append|read` — the append-only JSONL discipline of
//! `journals/journal.zig` (lease-serialized append, crash-tail repair) exposed
//! as a CLI verb, so an extension that cannot `import` `src/` need not
//! hand-roll it.
//!
//!   * `append <path>` reads exactly one record from STDIN (never argv: a
//!     Windows command line caps out around 32 KiB), requires one line of
//!     valid JSON with no embedded newline, and appends it — or writes not one
//!     byte. No `--stamp`: an `at` field belongs to the caller's schema.
//!   * `read <path>` prints back every COMPLETE line, dropping a torn tail. A
//!     missing file is not a missing FACT: no output, exit 0.
//!
//! Both verbs pass `cwd = "."` and the caller's raw `path` as `file_rel`,
//! relative or absolute: `Dir.createFile` / `Dir.createDirPath` on `Dir.cwd()`
//! accept an absolute sub_path, so one code path serves both spellings.

const std = @import("std");
const journal = @import("../journals/journal.zig");
const common = @import("common.zig");
const printErr = common.printErr;
const printErrFmt = common.printErrFmt;
const printRaw = common.printRaw;

/// Caps what `append` reads from stdin, so a caller that pipes the wrong file
/// in gets a fast refusal instead of an unbounded read.
const max_record_bytes: usize = 1 << 20;

pub fn dispatchJournal(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) return common.usageSection(io, common.journal_usage);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "append")) return journalAppend(alloc, io, rest);
    if (std.mem.eql(u8, sub, "read")) return journalRead(alloc, io, rest);
    try printErr(io, "unknown `journal` subcommand; try append|read\n");
    return 1;
}

fn journalAppend(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try printErr(io, "usage: nulya journal append <path>   (the record is read from stdin)\n");
        return 1;
    }
    const path = args[0];

    var in_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const raw = reader.interface.allocRemaining(alloc, .limited(max_record_bytes)) catch |err| switch (err) {
        error.StreamTooLong => {
            try printErr(io, "journal append: stdin exceeds the 1 MiB record limit\n");
            return 1;
        },
        else => return err,
    };
    defer alloc.free(raw);

    // A trailing newline is how a record normally arrives; anything left after
    // stripping it is the record, and an embedded newline there means stdin was
    // never one line to begin with.
    const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
    if (trimmed.len == 0) {
        try printErr(io, "journal append: stdin is empty\n");
        return 1;
    }
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) {
        try printErr(io, "journal append: a record is one line; stdin has an embedded newline\n");
        return 1;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch {
        try printErr(io, "journal append: stdin is not valid JSON\n");
        return 1;
    };
    defer parsed.deinit();

    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{trimmed});
    defer alloc.free(line);
    journal.appendLine(io, ".", path, line) catch |err| {
        try printErrFmt(alloc, io, "journal append: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    return 0;
}

fn journalRead(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try printErr(io, "usage: nulya journal read <path>\n");
        return 1;
    }
    const path = args[0];

    const bytes = journal.readAll(alloc, io, ".", path) catch |err| {
        try printErrFmt(alloc, io, "journal read: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer if (bytes) |b| alloc.free(b);
    // Missing file = no facts yet: empty output, exit 0.
    if (bytes) |b| try printRaw(io, b);
    return 0;
}
