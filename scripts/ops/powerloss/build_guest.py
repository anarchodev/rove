#!/usr/bin/env python3
"""Assemble the power-loss guest initramfs: busybox + dmsetup + kernel modules
+ the REAL rewind-worker with every shared library it needs."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mkcpio import build

ROVE = os.environ.get("ROVE", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..")))
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.environ.get("PL_CACHE", os.path.expanduser("~/.cache/rove-powerloss"))

def libs_for(*binaries):
    """Every .so a binary loads, plus the loader, by absolute host path."""
    out = {}
    for b in binaries:
        for line in subprocess.run(["ldd", b], capture_output=True, text=True).stdout.splitlines():
            line = line.strip()
            if "=>" in line:
                path = line.split("=>", 1)[1].strip().split(" (")[0]
            elif line.startswith("/"):
                path = line.split(" (")[0]
            else:
                continue
            if path and os.path.exists(path):
                out[os.path.realpath(path)] = path  # real file, canonical name
    return out

def main():
    worker = f"{ROVE}/zig-out/bin/rewind-worker"
    curl = subprocess.run(["which", "curl"], capture_output=True, text=True).stdout.strip()
    entries = [
        ("dev", "dir", 0o755, None), ("proc", "dir", 0o755, None),
        ("sys", "dir", 0o755, None), ("bin", "dir", 0o755, None),
        ("sbin", "dir", 0o755, None), ("lib", "dir", 0o755, None),
        ("lib64", "dir", 0o755, None), ("mods", "dir", 0o755, None),
        ("data", "dir", 0o755, None), ("etc", "dir", 0o755, None),
        ("etc/ssl", "dir", 0o755, None), ("etc/ssl/certs", "dir", 0o755, None),
        ("usr", "dir", 0o755, None), ("usr/lib", "dir", 0o755, None),
        ("usr/lib/x86_64-linux-gnu", "dir", 0o755, None),
        ("bin/busybox", "file", 0o755, open(f"{CACHE}/busybox", "rb").read()),
        ("bin/sh", "link", 0o777, "busybox"),
        ("sbin/dmsetup", "file", 0o755, open(f"{CACHE}/dmx/sbin/dmsetup", "rb").read()),
        ("lib/ld-musl-x86_64.so.1", "file", 0o755, open(f"{CACHE}/dmx/lib/ld-musl-x86_64.so.1", "rb").read()),
        ("lib/libdevmapper.so.1.02", "file", 0o755, open(f"{CACHE}/dmx/lib/libdevmapper.so.1.02", "rb").read()),
        ("bin/rewind-worker", "file", 0o755, open(worker, "rb").read()),
        ("bin/curl", "file", 0o755, open(curl, "rb").read()),
        ("init", "file", 0o755, open(f"{HERE}/init-powerloss.sh", "rb").read()),
    ]
    for m in ("virtio_blk", "failover", "net_failover", "virtio_net", "dm-mod", "dm-flakey"):
        p = f"{CACHE}/mods/{m}.ko"
        if os.path.exists(p):
            entries.append((f"mods/{m}.ko", "file", 0o644, open(p, "rb").read()))
    # CA bundle: the worker talks HTTPS to S3 from inside the guest.
    for ca in ("/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt"):
        if os.path.exists(ca):
            entries.append(("etc/ssl/certs/ca-certificates.crt", "file", 0o644, open(ca, "rb").read()))
            break
    entries.append(("etc/resolv.conf", "file", 0o644, b"nameserver 10.0.2.3\n"))
    entries.append(("etc/hosts", "file", 0o644, b"127.0.0.1 localhost admin.localhost\n"))

    seen = set()
    for real, name in libs_for(worker, curl).items():
        dst = name.lstrip("/")
        if dst in seen:
            continue
        seen.add(dst)
        entries.append((dst, "file", 0o755, open(real, "rb").read()))
    # Every parent directory any entry needs, created before it — cpio has no
    # mkdir -p, and a file whose directory is absent is silently not unpacked
    # (which surfaces later as "cannot open shared object file").
    dirs = {e[0]: e for e in entries if e[1] == "dir"}
    for path, kind, _, _ in list(entries):
        parts = path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d and d not in dirs:
                dirs[d] = (d, "dir", 0o755, None)
    entries = (sorted(dirs.values(), key=lambda e: e[0].count("/"))
               + [e for e in entries if e[1] != "dir"])
    n = build(entries, f"{HERE}/initramfs-pl.gz")
    print(f"guest built: {len(entries)} entries, {n/1e6:.1f} MB uncompressed")

main()
