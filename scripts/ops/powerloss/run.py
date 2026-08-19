#!/usr/bin/env python3
"""Power-loss crash-consistency validation for the rove WAL (rove#103).

`raft_soak_prod.py` proves crash RECOVERY: SIGKILL a node, it comes back with
every acked write. It cannot prove crash CONSISTENCY, and says so in its own
docstring — a SIGKILL does not drop the page cache, so the kernel still
flushes everything the process had written. What stays untested is fsync
ORDERING: whether an acknowledged write was really on the platter, or merely
in a cache that a power cut would have emptied.

This runs the REAL `rewind-worker` on a device that can lose power.

## Why a VM, and why dm-flakey inside it

Neither half is optional:

  - The host cannot do this. Device-mapper is unreachable from the dev
    container (`dmsetup` cannot open /dev/mapper/control), there is no
    losetup and no mkfs, so there is nowhere to build a lying block device.
  - QEMU alone does not model power loss. Guest writes reach the HOST page
    cache immediately, so killing QEMU loses nothing — the host kernel still
    writes them out. A `-snapshot` overlay loses everything instead, which is
    equally wrong.

So the guest builds a dm-flakey device over its virtual disk and, at the
chosen instant, reloads the table with `drop_writes`: the device keeps
answering reads and keeps returning success for writes and flushes, while
silently discarding everything. That is what a PSU failure looks like to the
layer above.

`--noflush --nolockfs` on the suspend is load-bearing. A plain suspend
quiesces the device and freezes the filesystem, which flushes the page cache
to the platter before the table swap — and then nothing is lost, the negative
control survives, and the run proves nothing while appearing to pass.

## What each run asserts

  1. NEGATIVE CONTROL — a file written and never fsynced must be ABSENT after
     the cut. If it survives, the cut dropped nothing and the run is VOID, not
     passing. This is checked first and fails the run on its own.
  2. ⭐ every write the worker ACKNOWLEDGED (204) before the cut must be
     readable after the reboot. The ack list leaves the guest by serial port
     as it happens, into a file on the host — the one channel a power cut
     cannot reach.
  3. the worker must come back up at all against the post-cut data dir.

Usage:
    scripts/ops/powerloss/run.py                 # one cut
    scripts/ops/powerloss/run.py --repeat 10     # a soak, randomized cut times
    scripts/ops/powerloss/run.py --value-bytes 65536 --writes 2000
                                                 # >64 MiB of WAL, forcing
                                                 # segment rolls (C3)

Needs: qemu + KVM, S3 env (`set -a; . ./.env; set +a`), and
`zig build rewind-worker rewind-ops` first.
"""
from __future__ import annotations

import argparse, os, random, re, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROVE = HERE.parents[2]
CACHE = Path(os.environ.get("PL_CACHE", os.path.expanduser("~/.cache/rove-powerloss")))
ROOT_TOKEN = "pl-nonprod-root-token-0123456789abcdef"
MOVE_SECRET = "rewindmovesecretpadding0123456789abcdef0"


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def claim_namespace(prefix: str) -> None:
    """Every rove service refuses to start against an unmarked object store.
    Claimed from the HOST because the guest has no rewind-ops — and because
    doing it once keeps the guest's job to the thing under test."""
    env = {**os.environ, "S3_KEY_PREFIX_BASE": prefix}
    ops = [str(ROVE / "zig-out/bin/rewind-ops"), "storage-namespace",
           "--env", "/nonexistent-so-only-the-process-env-is-read"]
    if sh(ops, env=env).returncode != 0:
        r = sh(ops + ["--adopt"], env=env)
        if r.returncode != 0:
            raise SystemExit(f"could not claim {prefix}: {r.stdout}{r.stderr}")


def qemu_args(disk: Path, phase: str, envargs: str) -> list[str]:
    return [
        "qemu-system-x86_64", "-accel", "kvm",
        # -cpu host is required: rove's binaries are built for the host CPU,
        # and QEMU's default model traps on the first unsupported opcode.
        "-cpu", "host", "-machine", "q35", "-m", "3072", "-smp", "4",
        "-nographic", "-no-reboot",
        "-kernel", str(CACHE / "vmlinuz"), "-initrd", str(HERE / "initramfs-pl.gz"),
        "-drive", f"file={disk},format=raw,if=virtio,cache=writeback",
        "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
        "-append", f"console=ttyS0 quiet panic=1 phase={phase} {envargs}",
    ]


def analyse(cut_log: str, verify_log: str) -> tuple[bool, list[str]]:
    acked, seen_cut = [], False
    for line in cut_log.splitlines():
        if line.strip() == "CUT":
            seen_cut = True
        m = re.match(r"ACK (pl/\d+)", line.strip())
        # Acks printed AFTER the cut are the device lying, not a durability
        # claim — the worker fsynced and was told it succeeded. Not asserted.
        if m and not seen_cut:
            acked.append(m.group(1))
    present = {}
    for line in verify_log.splitlines():
        m = re.match(r"READ (pl/\d+) = (.*)$", line.strip())
        if m:
            present[m.group(1)] = m.group(2).strip()
    sentinel = next((l.split(" ", 1)[1].strip() for l in verify_log.splitlines()
                     if l.startswith("SENTINEL")), "?")
    walfiles = next((l.split(" ", 1)[1].strip() for l in verify_log.splitlines()
                     if l.startswith("WALFILES")), "")
    lost = [k for k in acked if not present.get(k)]
    notes = [f"acked before the cut: {len(acked)}",
             f"survived: {len(acked) - len(lost)}",
             f"negative control: sentinel={sentinel}",
             f"wal: {walfiles or '(none listed)'}"]
    if "VERIFY-ABORT" in verify_log or "WORKER up" not in verify_log:
        notes.append("the worker did NOT come back up after the cut")
        return False, notes
    if sentinel != "ABSENT":
        notes.append("VOID — the cut dropped nothing, so nothing here is evidence")
        return False, notes
    if lost:
        notes.append(f"LOST {len(lost)} acknowledged writes: {lost[:8]}")
        return False, notes
    return True, notes


def one_round(args, n: int) -> bool:
    prefix = f"powerloss-{os.getpid()}-{n}/"
    claim_namespace(prefix)
    disk = HERE / f"pl-disk-{os.getpid()}.img"
    sh(["qemu-img", "create", "-f", "raw", str(disk), args.disk_size])
    cut_after = args.cut_after if args.cut_after else round(random.uniform(3, 12), 1)
    envargs = " ".join(f"ENV_{k}={v}" for k, v in {
        "S3_ENDPOINT": os.environ["S3_ENDPOINT"], "S3_BUCKET": os.environ["S3_BUCKET"],
        "S3_REGION": os.environ.get("S3_REGION", ""),
        "AWS_ACCESS_KEY_ID": os.environ["AWS_ACCESS_KEY_ID"],
        "AWS_SECRET_ACCESS_KEY": os.environ["AWS_SECRET_ACCESS_KEY"],
        "S3_KEY_PREFIX_BASE": prefix,
        "REWIND_ROOT_TOKEN": ROOT_TOKEN, "REWIND_MOVE_SECRET": MOVE_SECRET,
        "PL_WRITES": args.writes, "PL_VALUE_BYTES": args.value_bytes,
        "PL_CUT_AFTER_S": cut_after,
    }.items())

    print(f"round {n}: cut at t+{cut_after}s, {args.writes} writes "
          f"x {args.value_bytes}B", flush=True)
    cut = subprocess.run(qemu_args(disk, "cut", envargs), capture_output=True,
                         text=True, timeout=args.timeout).stdout
    ver = subprocess.run(qemu_args(disk, "verify", envargs), capture_output=True,
                         text=True, timeout=args.timeout).stdout
    ok, notes = analyse(cut, ver)
    for note in notes:
        print(f"    {note}")
    print(f"  {'ok  ' if ok else 'FAIL'} round {n}", flush=True)
    if not ok:
        (HERE / f"pl-fail-{n}-cut.log").write_text(cut)
        (HERE / f"pl-fail-{n}-verify.log").write_text(ver)
        print(f"    logs: {HERE}/pl-fail-{n}-*.log")
    disk.unlink(missing_ok=True)
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--writes", type=int, default=400)
    ap.add_argument("--value-bytes", type=int, default=0)
    ap.add_argument("--cut-after", type=float, default=0.0,
                    help="seconds before the cut (default: randomized per round, "
                         "which is what gives a soak its coverage of roll/fsync timings)")
    ap.add_argument("--disk-size", default="2G")
    ap.add_argument("--timeout", type=int, default=1800)
    args = ap.parse_args()

    if not os.environ.get("S3_ENDPOINT"):
        raise SystemExit("S3 env not set — `set -a; . ./.env; set +a` first")
    if not (ROVE / "zig-out/bin/rewind-worker").exists():
        raise SystemExit("zig-out/bin/rewind-worker missing — `zig build rewind-worker` first")
    if not os.path.exists("/dev/kvm"):
        raise SystemExit("/dev/kvm missing — this needs KVM")

    subprocess.run([sys.executable, str(HERE / "fetch_assets.py")], check=True)
    subprocess.run([sys.executable, str(HERE / "build_guest.py")], check=True,
                   env={**os.environ, "ROVE": str(ROVE), "PL_CACHE": str(CACHE)})

    failed = 0
    for n in range(1, args.repeat + 1):
        if not one_round(args, n):
            failed += 1
    print()
    if failed:
        print(f"FAIL — {failed}/{args.repeat} round(s) did not hold")
        return 1
    print(f"PASS — {args.repeat} power cut(s): every acknowledged write survived, "
          f"and each run proved the cut dropped un-fsynced data. ⭐")
    return 0


if __name__ == "__main__":
    sys.exit(main())
