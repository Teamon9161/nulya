//! The bundled `std` extension's search tools — `grep` / `glob` and the
//! gitignore-aware walk under them (docs/goals/std.md §1.3). Owned by std-d;
//! fixtures come from `std.zig`.

const std = @import("std");
const std_ext = @import("std.zig");

comptime {
    _ = std;
    _ = std_ext;
}
