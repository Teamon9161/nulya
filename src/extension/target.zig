//! The build-target vocabulary: the two words a version's identity records.
//!
//! A compiled version id is `hash(snapshot + compiler + target)`, and `target`
//! is always the two words `<arch>-<os>` — never a full triple, so a version id
//! is one key the store compares byte for byte. The abi half is chosen here:
//!
//!   linux   -> musl   statically linked; no glibc version to match
//!   windows -> gnu    what a native zig build on Windows already uses
//!   macos   -> none   zig's own libSystem stubs; no SDK needed
//!
//! The two words DECIDE the compile: builds recording the same words must issue
//! the same compiler invocation, so `effectiveTriple` gives a build that named
//! no target this host's own triple explicitly.

const std = @import("std");
const builtin = @import("builtin");

/// A closed set: every member is a promise this build can produce that binary.
pub const Arch = enum { x86_64, aarch64 };

pub const Os = enum { linux, windows, macos };

pub const Target = struct {
    arch: Arch,
    os: Os,

    /// The two words, exactly as they enter the version id and the seal.
    pub fn words(self: Target) []const u8 {
        return switch (self.os) {
            inline else => |os| switch (self.arch) {
                inline else => |arch| @tagName(arch) ++ "-" ++ @tagName(os),
            },
        };
    }

    /// What `zig build-exe -target` is given; the abi is this module's choice.
    pub fn zigTriple(self: Target) []const u8 {
        return switch (self.os) {
            inline else => |os| switch (self.arch) {
                inline else => |arch| @tagName(arch) ++ "-" ++ comptime abi(os),
            },
        };
    }

    pub fn exeSuffix(self: Target) []const u8 {
        return exeSuffixFor(self.words());
    }
};

fn abi(comptime os: Os) []const u8 {
    return switch (os) {
        .linux => "linux-musl",
        .windows => "windows-gnu",
        .macos => "macos-none",
    };
}

/// What a build with no `--target` records. Built from `builtin`, not the enums
/// above, so it names whatever this binary actually runs on — including a pair
/// `--target` does not offer.
pub const host: []const u8 = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);

/// The accepted spellings, in the one place a refusal can quote them.
pub const vocabulary = "<arch>-<os>, arch = x86_64 | aarch64, os = linux | windows | macos";

/// Null means "compile natively, pass no `-target` at all". A named target
/// answers with its own triple; an unnamed one with this host's, which is only
/// spellable when the host's pair is in the vocabulary above.
pub fn effectiveTriple(requested: ?Target) ?[]const u8 {
    return tripleFor(requested, host);
}

/// Host words handed in, so the machine-dependent branch is testable.
fn tripleFor(requested: ?Target, host_words: []const u8) ?[]const u8 {
    if (requested) |t| return t.zigTriple();
    const parsed = parse(host_words) catch return null;
    return parsed.zigTriple();
}

/// Unknown either half is a refusal, never a guess: a mistyped target would
/// produce a version whose id says one machine and whose bytes are for another.
pub fn parse(spec: []const u8) error{UnknownTarget}!Target {
    const dash = std.mem.lastIndexOfScalar(u8, spec, '-') orelse return error.UnknownTarget;
    const arch = std.meta.stringToEnum(Arch, spec[0..dash]) orelse return error.UnknownTarget;
    const os = std.meta.stringToEnum(Os, spec[dash + 1 ..]) orelse return error.UnknownTarget;
    return .{ .arch = arch, .os = os };
}

/// A property of the TARGET, not the machine asking: a version cross-built for
/// Windows has `bin/x.exe` wherever it is stored, which is why validation reads
/// it off the seal. Words this module does not know — a host pair outside the
/// enums, or the empty string a data/script version records — answer "no suffix".
pub fn exeSuffixFor(target_words: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, target_words, '-') orelse return "";
    return if (std.mem.eql(u8, target_words[dash + 1 ..], @tagName(Os.windows))) ".exe" else "";
}

test "a target's words are what enters the id, and its triple is what the compiler is told" {
    const linux: Target = .{ .arch = .x86_64, .os = .linux };
    try std.testing.expectEqualStrings("x86_64-linux", linux.words());
    try std.testing.expectEqualStrings("x86_64-linux-musl", linux.zigTriple());
    try std.testing.expectEqualStrings("", linux.exeSuffix());

    const win: Target = .{ .arch = .aarch64, .os = .windows };
    try std.testing.expectEqualStrings("aarch64-windows", win.words());
    try std.testing.expectEqualStrings("aarch64-windows-gnu", win.zigTriple());
    try std.testing.expectEqualStrings(".exe", win.exeSuffix());

    // Round trip: the words a target prints are the words `--target` accepts.
    for ([_]Target{ linux, win, .{ .arch = .aarch64, .os = .macos } }) |t| {
        try std.testing.expectEqual(t, try parse(t.words()));
    }

    try std.testing.expect(std.mem.indexOfScalar(u8, host, '-') != null);
}

test "an unrecognized target is refused rather than guessed at" {
    // A full triple must NOT quietly become `x86_64-linux`: the third word
    // would be dropped from a key the store compares byte for byte.
    for ([_][]const u8{ "x86_64-linux-musl", "x86_64", "linux", "", "x86_64-plan9", "riscv64-linux", "X86_64-LINUX" }) |bad| {
        try std.testing.expectError(error.UnknownTarget, parse(bad));
    }
}

test "a build that names no target still compiles for this host's words, when they are words --target can spell" {
    try std.testing.expectEqualStrings(
        "x86_64-linux-musl",
        tripleFor(.{ .arch = .x86_64, .os = .linux }, "aarch64-macos").?,
    );

    // Unnamed, host inside the vocabulary: the host's triple, not native.
    try std.testing.expectEqualStrings("aarch64-macos-none", tripleFor(null, "aarch64-macos").?);
    try std.testing.expectEqualStrings("x86_64-windows-gnu", tripleFor(null, "x86_64-windows").?);

    // Unnamed, host outside it: native, because `--target` cannot spell this
    // machine's words and it must still build for itself.
    try std.testing.expect(tripleFor(null, "riscv64-linux") == null);

    const parsed_host = parse(host) catch null;
    if (parsed_host) |t| {
        try std.testing.expectEqualStrings(t.zigTriple(), effectiveTriple(null).?);
    } else {
        try std.testing.expect(effectiveTriple(null) == null);
    }
}

test "the exe suffix follows the target, not the machine reading it" {
    try std.testing.expectEqualStrings(".exe", exeSuffixFor("x86_64-windows"));
    try std.testing.expectEqualStrings("", exeSuffixFor("x86_64-linux"));
    try std.testing.expectEqualStrings("", exeSuffixFor(""));
    // A host outside the vocabulary still gets an answer: seals are written by
    // whatever machine built them.
    try std.testing.expectEqualStrings("", exeSuffixFor("riscv64-freebsd"));
}
