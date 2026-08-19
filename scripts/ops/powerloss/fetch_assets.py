#!/usr/bin/env python3
"""Download the guest's parts. Cached — run once per machine.

Everything here is fetched rather than built because the host cannot help:
there is no kernel under /boot, no loop devices, no mkfs, and no cpio. The
guest is assembled from three upstream binaries and the rove tree itself.
"""
from __future__ import annotations

import os, subprocess, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.environ.get("PL_CACHE", os.path.expanduser("~/.cache/rove-powerloss"))

BUSYBOX = "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
ALPINE = "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64"
# Debian's CLOUD kernel: the installer kernel has the same modules, but this
# one is the flavour meant for VMs. Both build virtio modular, so the modules
# are extracted below either way.
KERNEL_DEB = ("https://deb.debian.org/debian/pool/main/l/linux/"
              "linux-image-6.18.15+deb13-cloud-amd64-unsigned_6.18.15-1~bpo13+1_amd64.deb")
KVER = "6.18.15+deb13-cloud-amd64"
# insmod does no dependency resolution, so the ORDER here is the load order.
MODULES = ["drivers/block/virtio_blk", "net/core/failover", "drivers/net/net_failover",
           "drivers/net/virtio_net", "drivers/md/dm-mod", "drivers/md/dm-flakey"]


def get(url: str, dest: str) -> str:
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    print(f"  fetch {os.path.basename(dest)}", flush=True)
    with urllib.request.urlopen(url, timeout=180) as r, open(dest, "wb") as f:
        f.write(r.read())
    return dest


def main() -> int:
    os.makedirs(f"{CACHE}/mods", exist_ok=True)
    bb = get(BUSYBOX, f"{CACHE}/busybox")
    os.chmod(bb, 0o755)

    # dmsetup + its musl loader: the guest needs device-mapper userspace, and
    # Alpine ships the only readily-extractable static-ish build.
    os.makedirs(f"{CACHE}/dmx", exist_ok=True)
    for pkg in ("device-mapper-2.03.23-r3", "device-mapper-libs-2.03.23-r3", "musl-1.2.5-r3"):
        apk = get(f"{ALPINE}/{pkg}.apk", f"{CACHE}/{pkg}.apk")
        # An .apk is a gzipped tar with a signature member tar refuses to
        # parse; the payload still extracts, so the exit status is ignored.
        subprocess.run(["tar", "-xzf", apk, "-C", f"{CACHE}/dmx"],
                       stderr=subprocess.DEVNULL)

    deb = get(KERNEL_DEB, f"{CACHE}/kernel.deb")
    if not os.path.exists(f"{CACHE}/vmlinuz"):
        os.makedirs(f"{CACHE}/ck", exist_ok=True)
        subprocess.run(["ar", "x", os.path.abspath(deb)], cwd=f"{CACHE}/ck", check=True)
        data = next(f for f in os.listdir(f"{CACHE}/ck") if f.startswith("data.tar"))
        subprocess.run(["tar", "-xf", data], cwd=f"{CACHE}/ck", check=True)
        subprocess.run(["cp", f"{CACHE}/ck/boot/vmlinuz-{KVER}", f"{CACHE}/vmlinuz"], check=True)
    for m in MODULES:
        out = f"{CACHE}/mods/{os.path.basename(m)}.ko"
        if not os.path.exists(out):
            src = f"{CACHE}/ck/usr/lib/modules/{KVER}/kernel/{m}.ko.xz"
            with open(out, "wb") as f:
                subprocess.run(["xz", "-dc", src], stdout=f, check=True)
    print(f"assets ready in {CACHE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
