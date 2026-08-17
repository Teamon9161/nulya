//! `append` — STUB. Owned by std-c (fs) in docs/goals/std.md; the real
//! implementation replaces this file wholesale. Until then every call answers
//! "not implemented" so the dispatch, build and e2e smoke can be proven.

const std = @import("std");
const rpc = @import("rpc.zig");

pub fn run(ctx: *const rpc.Ctx, args: std.json.ObjectMap) anyerror!rpc.Outcome {
    _ = args;
    return rpc.refuse(ctx.alloc, "append is not implemented yet", .{});
}
