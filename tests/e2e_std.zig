//! The bundled `std` extension group of the end-to-end suite (`zig build
//! e2e-std`), one test binary of its own so it runs beside the other two.
//!
//! Six file/search tools in one compiled package — built,
//! activated, reached by `ext run`; `read`'s self-pagination and freshness
//! stubs, `write` / `append` refusing to touch a file the session has not read
//! (state on disk under the session's scratch dir, none outside a session),
//! `edit`'s exact match, teaching refusals and the freshness it records for its
//! own change, `grep`'s smart-case / per-file cap / paging / gitignore, `glob`'s
//! mtime order — and a tool's stdout reaching the caller verbatim, its stderr
//! and non-zero exit reaching it as a failed call.
//!
//!   e2e/std.zig          fixtures + smoke
//!   e2e/std_fs.zig       read / write / append / edit + freshness
//!   e2e/std_search.zig   grep / glob

comptime {
    _ = @import("e2e/support.zig");
    _ = @import("e2e/std.zig");
    _ = @import("e2e/std_fs.zig");
    _ = @import("e2e/std_search.zig");
}
