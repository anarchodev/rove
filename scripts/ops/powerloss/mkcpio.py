#!/usr/bin/env python3
"""Minimal newc cpio writer — the host has no `cpio`, and an initramfs is the
only way to hand the guest a userspace without a distro image or a loop mount.
"""
import gzip, os, sys

MAGIC = b"070701"
_ino = [1]

def _hdr(name: bytes, mode: int, size: int, nlink: int = 1) -> bytes:
    _ino[0] += 1
    f = [_ino[0], mode, 0, 0, nlink, 0, size, 0, 0, 0, 0, len(name) + 1, 0]
    return MAGIC + b"".join(b"%08X" % v for v in f) + name + b"\0"

def _pad(b: bytes) -> bytes:
    return b + b"\0" * (-len(b) % 4)

def build(entries, out_path):
    """entries: list of (path, kind, mode, data). kind in {'file','dir','link'}"""
    blob = b""
    for path, kind, mode, data in entries:
        name = path.encode()
        if kind == "dir":
            blob += _pad(_hdr(name, 0o040000 | mode, 0, 2))
        elif kind == "link":
            tgt = data.encode()
            blob += _pad(_hdr(name, 0o120000 | mode, len(tgt))) + _pad(tgt)
        else:
            blob += _pad(_hdr(name, 0o100000 | mode, len(data))) + _pad(data)
    blob += _pad(_hdr(b"TRAILER!!!", 0, 0, 1))
    with gzip.open(out_path, "wb", compresslevel=1) as f:
        f.write(blob)
    return len(blob)
