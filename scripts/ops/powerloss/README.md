# Power-loss crash-consistency validation (rove#103)

`scripts/smoke/raft_soak_prod.py` proves crash **recovery**: SIGKILL a node,
it comes back with every acked write. It cannot prove crash **consistency**,
and says so in its own docstring — a SIGKILL does not drop the page cache, so
the kernel still writes out everything the process had produced.

What that leaves untested is fsync **ordering**: whether an acknowledged write
was really on the platter, or merely in a cache a power cut would have emptied.

This runs the real `rewind-worker` on a device that can lose power.

```
set -a; . ./.env; set +a
zig build rewind-worker rewind-ops
scripts/ops/powerloss/run.py                  # one cut
scripts/ops/powerloss/run.py --repeat 10      # a soak, randomized cut times
scripts/ops/powerloss/run.py --writes 2000 --value-bytes 65536
                                              # >64 MiB of WAL → segment rolls
```

## Why a VM, and why dm-flakey inside it

Neither half is optional, and both are easy to get subtly wrong.

**The host cannot do this.** Device-mapper is unreachable from the dev
container — `dmsetup` cannot open `/dev/mapper/control` even as root — and
there is no `losetup`, no `mkfs`, and no `cpio`. There is nowhere to build a
lying block device, which is why the issue sat unstarted rather than unworked.

**QEMU alone does not model power loss.** Guest writes reach the *host* page
cache immediately, so killing QEMU loses nothing: the host kernel still writes
them out. `-snapshot` goes wrong the other way and discards everything,
including what was fsynced. Either way the result is meaningless.

So the guest builds a `dm-flakey` device over its virtual disk and, at the
chosen instant, reloads the table with `drop_writes`. From then on the device
keeps serving reads and keeps returning **success** for writes and flushes,
while silently discarding them. That is what a PSU failure looks like to the
layer above.

### The two flags that decide whether the test means anything

```
dmsetup suspend --noflush --nolockfs pl
```

A plain `suspend` quiesces the device: it flushes outstanding I/O and freezes
the filesystem, which syncs it. Everything in the page cache reaches the
platter *before* the table swap, nothing is lost, and the run passes while
proving nothing. The first working version of this harness did exactly that —
the negative control survived, which is how it was caught.

## What a run asserts

1. **Negative control** — a file written and never fsynced must be **ABSENT**
   after the cut. If it survives, the cut dropped nothing, and the round is
   **VOID**, not passing. Checked first, and fails the round on its own.
2. ⭐ **Every write the worker acknowledged (204) before the cut must be
   readable after the reboot.** The ack list leaves the guest over the serial
   port as it happens, into a file on the host — the one channel the simulated
   power cut cannot reach. Comparing that against what the rebooted worker
   serves is the whole test.
3. The worker must come back up at all against the post-cut data dir.

Acks printed *after* the cut are ignored rather than asserted: there the
device is lying to a worker that did everything right.

## Coverage, stated honestly

- **C1/C2 (fsync ordering)** — covered. An acked write is one the worker
  fsynced, and the cut discards anything that had not reached the platter.
- **C3 (segment-roll durability)** — covered only when a run actually rolls a
  segment, which needs >64 MiB of WAL: `--writes 2000 --value-bytes 65536`.
  The verify phase prints `WALFILES`, so a roll is visible in the output
  (`raft-wal.000001` alongside the active `raft-wal`). A cut landing *during*
  a roll is a matter of timing, which is what `--repeat` with randomized cut
  times is for.
- **Single node.** Quorum replication is already covered by
  `raft_soak_prod.py`; the fsync question this answers is per-node.

## Guest assembly

Downloaded once into `~/.cache/rove-powerloss` (`fetch_assets.py`), because
the host has nothing to build from — no kernel under `/boot`, no loop devices,
no `mkfs`, no `cpio`:

| piece | source | why |
|---|---|---|
| kernel | Debian cloud `.deb` | virtio and dm are **modules** even here, so they are extracted and `insmod`ed in dependency order |
| busybox | busybox.net static build | `mkfs.ext2`, `mount`, `sh` |
| dmsetup + musl loader | Alpine `.apk`s | the guest needs device-mapper userspace |
| `rewind-worker` + curl + 36 libs | this checkout | the real binary, unmodified |

`mkcpio.py` writes the initramfs directly (newc format) since there is no
`cpio` on the host.

## Traps worth knowing before changing this

- **`-cpu host` is required.** rove's binaries are built for the host CPU;
  QEMU's default model traps on the first unsupported opcode, which surfaces
  as `trap invalid opcode` and reads like a corrupt binary.
- **Bring `lo` up.** A bare initramfs leaves loopback down, the worker's
  listener is unreachable, and curl reports status `000` — which reads like a
  dead server rather than a missing route.
- **`ulimit -n`.** The worker's default fd budget is too small under
  busybox's inherited 1024 and fails as `UserFdQuotaExceeded`.
- **Claim the storage namespace first.** Every rove service refuses to start
  against an unmarked object store; `run.py` does it from the host.
