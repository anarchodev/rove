//! The ONE nghttp2 `@cImport` for the h2 module. Every file that touches
//! nghttp2 types must import THIS (`@import("nghttp2_c.zig").c`) — a
//! second `@cImport` block would produce distinct, incompatible pointer
//! types for the same C structs.
pub const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});
