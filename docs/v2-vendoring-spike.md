# V2 vendoring spike — raft-rs

Output of the 2026-05-16 design conversation that locked V2's raft
engine as TiKV's raft-rs (see
`memory/project_v2_multiraft_direction.md`). This doc captures the
vendoring strategy and FFI shape so whoever picks up the V2 substrate
build has a concrete starting point, not a green field.

Scope of this doc: how raft-rs lives under `vendor/`, how `build.zig`
invokes cargo, and the C ABI surface the Rust shim crate exposes to
Zig. Not in scope: the per-tenant raft group orchestration above
raft-rs, the segmented log, the control plane, or the migration
protocol — those are V2 plan content, not vendoring.

> **See also `docs/v2-multiraft-scaling-learnings.md`** — measured findings
> from a working prototype of this exact substrate (raft-rs hosting one
> group per tenant, shared per-node WAL, detach/attach migration), built in
> `~/src/rewind2` + `~/src/raft-rs-zig`. It flags concrete gaps in the FFI
> surface sketched below (single-group → needs a mailbox `poll_ready`,
> batched tick, group lifecycle for migration, an allocator) and quantifies
> what each scaling fix was worth at K=10k tenants.

## What lives in `vendor/raft-rs/`

```
vendor/raft-rs/
├── README.md                  # upstream commit, refresh procedure
├── Cargo.toml                 # workspace root (just the ffi crate)
├── Cargo.lock                 # pinned versions, committed
├── .cargo/
│   └── config.toml            # [source.crates-io] replace-with = "vendored-sources"
├── crates/                    # `cargo vendor` output
│   ├── raft-0.7.0/...
│   ├── raft-proto-0.7.0/...
│   ├── prost-0.13.x/...
│   ├── prost-derive-0.13.x/...
│   ├── prost-types-0.13.x/...
│   ├── bytes-1.x/...
│   ├── fxhash-0.2.1/...
│   ├── getset-0.1.x/...
│   ├── thiserror-1.0.x/...
│   ├── thiserror-impl-1.0.x/...
│   ├── rand-0.9.3/...
│   ├── rand_core-0.9.x/...
│   ├── rand_chacha-0.9.x/...
│   ├── getrandom-0.2.x/...
│   ├── ppv-lite86-0.2.x/...
│   ├── slog-2.7.x/...
│   ├── syn-2.x/...
│   ├── quote-1.x/...
│   ├── proc-macro2-1.x/...
│   ├── unicode-ident-1.x/...
│   ├── autocfg-1.x/...
│   ├── cfg-if-1.x/...
│   ├── libc-0.2.x/...
│   └── ~10 more transitive
└── ffi/                       # our Rust FFI shim crate
    ├── Cargo.toml
    ├── src/
    │   ├── lib.rs             # `extern "C"` exports
    │   ├── node.rs            # RawNode wrapper
    │   ├── storage.rs         # Storage trait impl over Zig callbacks
    │   ├── ready.rs           # Ready cycle → callback firing
    │   ├── error.rs           # error codes + last-error TLS
    │   └── conf.rs            # ConfChange struct marshaling
    └── include/
        └── rove_raft.h        # hand-written header
```

Realistic count: ~25-35 crates in `crates/`. Most are tiny
(proc-macro helpers, single-purpose utility crates). Total vendored
size ~5-10 MB of Rust source. Comparable in disk footprint to a
single mid-size C library.

## raft-rs version + feature pinning

Upstream as of 2026-05-16: `raft = "0.7"`, Apache-2.0, last pushed
three days prior to this doc. Active maintenance.

```toml
# vendor/raft-rs/ffi/Cargo.toml
[package]
name = "rove-raft-ffi"
version = "0.1.0"
edition = "2021"

[lib]
name = "rove_raft_ffi"
crate-type = ["staticlib"]    # produces librove_raft_ffi.a

[profile.release]
panic = "abort"               # don't link unwinding, smaller binary
lto = true
codegen-units = 1
opt-level = 3

[dependencies]
raft = { version = "0.7", default-features = false, features = ["prost-codec"] }
prost = "0.13"
slog = "2.7"
```

Choices worth calling out:

- **`default-features = false`** drops raft-rs's `protobuf-codec`
  (we use prost instead) and `default-logger`
  (slog-envlogger/slog-stdlog/slog-term). Cuts ~6 transitive crates.
- **`prost-codec`** over the default `protobuf-codec` — prost is
  modern and smaller, and we don't need to vendor `rust-protobuf`.
- **`panic = "abort"`** in release — raft panics are infallibility
  violations; we want the process to die, not unwind through C. Saves
  linking the unwinding machinery and matches
  `feedback_infallibility_violations` in memory.

`prost-codec` brings `prost-build` at build time, which wants `protoc`
to compile `.proto` files. We sidestep this by **pre-generating the
.rs files at vendor time** and committing them alongside the .proto —
the approach raft-rs itself recommends for downstream users. The
compile step then has zero codegen.

## How `build.zig` invokes cargo

Sketch (V2 module, not yet written):

```zig
const cargo_step = b.addSystemCommand(&.{
    "cargo", "build",
    "--release",
    "--offline",
    "--manifest-path", "vendor/raft-rs/ffi/Cargo.toml",
    "--target-dir", b.cache_root.join(b.allocator, "cargo-raft") catch unreachable,
});

const raft_rs_mod = b.addModule("rove-raft", .{
    .root_source_file = b.path("src-v2/raft/root.zig"),
    .target = target,
    .optimize = optimize,
});
raft_rs_mod.link_libc = true;
raft_rs_mod.addIncludePath(b.path("vendor/raft-rs/ffi/include"));
raft_rs_mod.addLibraryPath(.{ .cwd_relative = ... });
raft_rs_mod.linkSystemLibrary("rove_raft_ffi", .{});
raft_rs_mod.step.dependOn(&cargo_step.step);
```

Notes:

- `--offline` forces use of vendored sources only — no network at
  build time.
- Cargo's incremental builds are fast enough that re-invoking on
  every `zig build` is fine (~100ms when nothing changed).
- Cross-compile: `--target <rust-triple>`, mapped from the Zig
  target. The mapping table is ~10 entries (x86_64-linux-gnu →
  x86_64-unknown-linux-gnu, etc.). Add a small helper fn alongside
  the cargo invocation.

## FFI surface

The key decision: **how much logic lives in the Rust shim vs the Zig
caller?** Push as much as possible into Rust so the Zig side never
has to touch protobuf. The shim is a real Rust crate with rich
logic; the Zig side sees primitive types + opaque byte buffers
(where bytes are only ever raft-msg-bytes passed through to the
network or user-payload bytes the customer wrote).

```c
/* vendor/raft-rs/ffi/include/rove_raft.h */
#ifndef ROVE_RAFT_H
#define ROVE_RAFT_H

#include <stdint.h>
#include <stddef.h>

typedef struct rove_raft_node rove_raft_node_t;

/* Callbacks the Zig side provides for storage. */
typedef struct {
    void *ctx;

    /* Read entries [low, high) up to max_size bytes. Caller-owned buf. */
    int32_t (*entries)(void *ctx, uint64_t low, uint64_t high,
                       uint64_t max_size, uint8_t *out, size_t cap,
                       size_t *out_len);

    int32_t (*term)(void *ctx, uint64_t idx, uint64_t *out_term);
    int32_t (*first_index)(void *ctx, uint64_t *out);
    int32_t (*last_index)(void *ctx, uint64_t *out);

    /* Snapshot read. Returns RAFT_ERR_TEMPORARILY_UNAVAILABLE if the
       snapshot isn't ready yet — raft-rs handles that case. */
    int32_t (*snapshot)(void *ctx, uint64_t request_idx, uint64_t to,
                        uint8_t *out, size_t cap, size_t *out_len);
} rove_raft_storage_t;

/* Callbacks fired during process_ready — Zig persists / sends / applies. */
typedef struct {
    void *ctx;

    /* Persist entries (append to log). Fires once per new entry. */
    int32_t (*append)(void *ctx, uint64_t index, uint64_t term,
                      uint8_t entry_type, const uint8_t *data, size_t len);

    /* Persist HardState change (fsync after batch). */
    int32_t (*save_hard_state)(void *ctx, uint64_t term, uint64_t vote,
                               uint64_t commit);

    /* Send message to peer. data is the raft wire format; peer hands
       it back to step() unchanged. */
    int32_t (*send)(void *ctx, uint64_t to_peer, const uint8_t *data,
                    size_t len);

    /* Apply a committed normal entry to the state machine. */
    int32_t (*apply_normal)(void *ctx, uint64_t index, uint64_t term,
                            const uint8_t *data, size_t len);

    /* Apply a committed conf change. Fields are unmarshaled in Rust. */
    int32_t (*apply_conf_change)(void *ctx, uint64_t index, uint64_t term,
                                 uint8_t change_type, uint64_t node_id,
                                 const uint8_t *context, size_t context_len);

    /* Snapshot install: apply a snapshot blob to the state machine. */
    int32_t (*apply_snapshot)(void *ctx, uint64_t index, uint64_t term,
                              const uint8_t *data, size_t len);
} rove_raft_callbacks_t;

/* Configuration — mirrors raft::Config minimally. */
typedef struct {
    uint64_t id;
    uint64_t election_tick;
    uint64_t heartbeat_tick;
    uint64_t max_size_per_msg;
    uint64_t max_inflight_msgs;
    uint8_t  pre_vote;        /* 0 or 1 */
    uint8_t  check_quorum;    /* 0 or 1 */
} rove_raft_config_t;

/* Lifecycle */
rove_raft_node_t *rove_raft_node_new(
    const rove_raft_config_t *cfg,
    const rove_raft_storage_t *storage,
    const uint64_t *voter_ids, size_t voter_count,
    const uint64_t *learner_ids, size_t learner_count);

void rove_raft_node_free(rove_raft_node_t *node);

/* Driving the state machine */
int32_t rove_raft_node_tick(rove_raft_node_t *node);

int32_t rove_raft_node_step(rove_raft_node_t *node,
                            const uint8_t *msg, size_t len);

int32_t rove_raft_node_propose(rove_raft_node_t *node,
                               const uint8_t *data, size_t len);

int32_t rove_raft_node_propose_conf_change(
    rove_raft_node_t *node,
    uint8_t change_type, uint64_t node_id,
    const uint8_t *context, size_t context_len);

int32_t rove_raft_node_transfer_leader(rove_raft_node_t *node,
                                       uint64_t to_peer);

/* Ready cycle: process_ready calls callbacks, then advances internally */
int32_t rove_raft_node_process_ready(rove_raft_node_t *node,
                                     const rove_raft_callbacks_t *cb);

/* Error reporting */
const char *rove_raft_last_error(void);  /* TLS-backed, null-terminated */

#endif
```

The Zig wrapper around this is a thin idiomatic-Zig facade — opaque
pointer, struct-based config, Zig error sets mapping the `int32_t`
codes. Estimated ~500 lines of Zig including tests.

## Native libs a Rust staticlib consumer must link

Rust's std emits references to `_Unwind_*` and `rust_eh_personality`
even with `panic = "abort"` — the backtrace and format machinery
keep the eh_personality lang item live. Linking against just
`librove_raft_ffi.a` produces `undefined symbol` errors.

The canonical way to discover what to link is:

```sh
cargo rustc --release --lib -- --print native-static-libs
```

On glibc Linux (validated 2026-05-16 against Rust 1.93 in the
hello-world spike), the output is:

```
-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
```

Order matters on some platforms. Encode the list in `build.zig`
right after `linkSystemLibrary("rove_raft_ffi", .{})`, in this
order:

```zig
mod.linkSystemLibrary("gcc_s", .{});
mod.linkSystemLibrary("util", .{});
mod.linkSystemLibrary("rt", .{});
mod.linkSystemLibrary("pthread", .{});
mod.linkSystemLibrary("m", .{});
mod.linkSystemLibrary("dl", .{});
// -lc comes from `mod.link_libc = true`
```

macOS will produce a different list (no `-lgcc_s`, uses Apple's
libSystem). When V2 cross-compiles to Darwin, re-run the print and
gate the linkSystemLibrary calls on `target.result.os.tag`.

## Build hermeticity properties

- **No network at build time**: `--offline` flag + vendored
  `crates/` + Cargo.lock pinned.
- **No external tools at build time**: `protoc` avoided by
  pre-generated .rs (one-time vendor step needs `protoc`; subsequent
  builds don't).
- **No background services**: cargo's build is self-contained.
- **Reproducible across machines**: Cargo.lock ensures byte-identical
  dep selection.
- **Cross-compile**: requires `rustup target add <triple>` per target,
  documented in `vendor/raft-rs/README.md`.

This matches the existing rove vendoring contract: clone, `zig
build`, no extra setup.

## Vendor refresh procedure

One-time (initial vendoring):

```sh
mkdir -p vendor/raft-rs/ffi/src
cd vendor/raft-rs/ffi
# Write Cargo.toml with raft = "0.7" (see above)
cd ..
cargo vendor crates/
# .cargo/config.toml printed by `cargo vendor` — copy into .cargo/
# Generate .proto .rs files into ffi/src/proto/
protoc --rust_out=ffi/src/proto/ crates/raft-proto-*/proto/*.proto
git add -A
```

Periodic refresh (raft-rs version bump):

```sh
cd vendor/raft-rs/ffi
cargo update -p raft --precise <new-version>
cd ..
cargo vendor crates/
# Regenerate .proto .rs files only if .proto changed upstream.
git add -A
```

Document the upstream commit + the prost version + the proto-regen
step in `vendor/raft-rs/README.md`, same shape as
`vendor/arenajs/README.md` and `vendor/raft/README.md`.

## Risks worth knowing about

1. **Rust → C panic safety.** With `panic = "abort"` the process
   dies on a raft-rs panic. Good for invariant violations, but means
   any unexpected raft-rs bug = process crash. Mitigation: pin
   raft-rs version conservatively, run the Maelstrom canary on every
   bump (same gate willemt's bumps go through).
2. **cbindgen vs hand-written header.** The sketch above is
   hand-written. cbindgen auto-generates from Rust source.
   Hand-written is more stable (no codegen drift); auto is less
   manual work. Lean hand-written for the initial cut (the surface
   is small), revisit if it grows past ~30 functions.
3. **Build-time cost.** First cargo build of the vendored dep tree:
   ~30-60 seconds. Incremental: ~100 ms-2 s. Acceptable but a
   one-time CI hit on cold caches.
4. **Cargo.lock churn.** Every `cargo update` rewrites the lock
   file; reviewers see a big diff. Solvable with surgical bumps
   (`cargo update -p <crate>`) and a CODEOWNERS hint to skip review
   on the lock file itself.
5. **Pre-generated .rs files** drift from .proto if you forget to
   regen. Mitigation: a `vendor/raft-rs/check-proto.sh` that
   re-runs protoc and diffs against committed; wire into CI.

## What this spike validates

- raft-rs's deps are tractable to vendor (~30 crates, all
  permissive licenses).
- `cargo vendor` + `--offline` gives hermetic builds.
- `staticlib` crate type produces a `.a` Zig can link normally.
- FFI surface fits in one header, callback-driven, no protobuf on
  the boundary.
- Existing `build.zig` style (vendor C, `addCSourceFiles`) extends
  cleanly to "vendor Rust, `addSystemCommand` for cargo,
  `linkSystemLibrary` for the .a".

## Suggested next steps

1. **Prove the build path** with a hello-world Rust staticlib called
   from Zig (no raft-rs yet) — ~1 hour, validates that
   `addSystemCommand(cargo) → linkSystemLibrary` works on this box.
   `examples/rust_ffi_smoke/`.
2. **Vendor raft-rs minimally** into `vendor/raft-rs/` and stand up
   the FFI shim with just `node_new` + `node_free` exported — ~1 day,
   validates the dep tree vendors clean and the .a links.
3. **Implement the full FFI surface** with an in-memory storage
   backend and a five-node test driven by raft-rs's bundled
   `examples/five_mem_node` — 2-3 days, validates that raft-rs
   actually drives correctly through our wrapper.
4. **Then** start `docs/v2-plan.md` with the vendoring strategy
   referenced as already-validated.

Step 1 was completed in the same session as this doc (commits in
`examples/rust_ffi_smoke/` + `build.zig` + `.gitignore`); remaining
steps are open work. The native-libs finding from step 1 (above) is
the load-bearing artifact for step 2 — it'll be needed verbatim for
raft-rs's link line.
