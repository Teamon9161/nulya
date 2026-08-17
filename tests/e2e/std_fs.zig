//! The bundled `std` extension's file tools — `read` / `write` / `append` and
//! the on-disk freshness they share (docs/goals/std.md §1.2). Owned by std-c;
//! fixtures come from `std.zig`.

const std = @import("std");
const std_ext = @import("std.zig");

comptime {
    _ = std;
    _ = std_ext;
}
