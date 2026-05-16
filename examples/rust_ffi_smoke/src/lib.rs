//! Minimal Rust staticlib exercised from Zig, validating the
//! `addSystemCommand(cargo) → linkSystemLibrary(...)` build path
//! before the V2 raft-rs vendoring lands. See
//! `docs/v2-vendoring-spike.md` for the larger context.
//!
//! Three exports cover the surface we care about:
//!   * a primitive-in / primitive-out call (arithmetic),
//!   * a `*const c_char` return (read-only static string), and
//!   * a callback invocation (Rust calls back into a Zig fn pointer),
//! which together match the shape of the eventual raft-rs FFI.

use std::os::raw::c_char;

#[no_mangle]
pub extern "C" fn rust_ffi_smoke_add(a: u64, b: u64) -> u64 {
    a.wrapping_add(b)
}

#[no_mangle]
pub extern "C" fn rust_ffi_smoke_version() -> *const c_char {
    // Null-terminated; lives in .rodata.
    b"0.1.0\0".as_ptr() as *const c_char
}

/// Invoke `cb(ctx, value)` `times` times. Mirrors the raft-rs
/// `process_ready` shape: Rust drives a loop, fires callbacks the
/// Zig side registered.
#[no_mangle]
pub extern "C" fn rust_ffi_smoke_fire(
    times: u32,
    ctx: *mut std::ffi::c_void,
    cb: Option<extern "C" fn(*mut std::ffi::c_void, u32) -> i32>,
) -> i32 {
    let Some(cb) = cb else { return -1 };
    for i in 0..times {
        let rc = cb(ctx, i);
        if rc != 0 {
            return rc;
        }
    }
    0
}
