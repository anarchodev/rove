//! Panic helper for infallibility violations.
//!
//! Use at sites where an operation can only fail under disk failure, OOM,
//! framework bug, or data corruption — i.e. continuing would let local state
//! diverge from what we've told clients or replicated through raft. Hard
//! abort gives operators a stack trace and lets the supervisor restart and
//! raft re-elect a healthy leader.
//!
//! See `feedback_infallibility_violations` in CLAUDE memory for the
//! classification rule. Soft-handling these (5xx, log.warn, silent skip)
//! is the worst possible failure mode: silent divergence with no operator
//! signal.

const std = @import("std");

/// Format a banner with site + structured context, write it directly to
/// fd 2 (no buffered writer in the way), then abort. Direct posix.write
/// instead of std.debug.print so output is guaranteed to land before the
/// abort signal even if some upstream writer's buffer would otherwise
/// swallow it.
pub fn invariantViolated(
    comptime site: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "\n" ++
        "================================================================\n" ++
        "ROVE INVARIANT VIOLATED — aborting\n" ++
        "  site: " ++ site ++ "\n" ++
        "  ctx:  " ++ fmt ++ "\n" ++
        "================================================================\n",
        args,
    ) catch buf[0..0];
    _ = std.posix.write(2, msg) catch {};
    std.process.abort();
}
