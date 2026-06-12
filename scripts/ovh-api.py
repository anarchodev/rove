#!/usr/bin/env python3
"""ovh-api.py — minimal signed OVHcloud API client (stdlib only).

Drives the OVH control API (vRack attach, server/NIC inventory, task
polling) without the manager UI. Credentials come from the environment —
keep them in the git-ignored `.env.ovh` at the repo root and source it:

    set -a; . ./.env.ovh; set +a

  OVH_ENDPOINT      eu | ca | us, or a full base URL (default eu).
                    Use the region your OVH manager account lives in.
  OVH_APP_KEY       application key      } minted together at
  OVH_APP_SECRET    application secret   } https://<region>.api.ovh.com/createToken/
  OVH_CONSUMER_KEY  consumer key         }

Usage:
    scripts/ovh-api.py GET  /me
    scripts/ovh-api.py GET  /vrack
    scripts/ovh-api.py GET  /dedicated/server
    scripts/ovh-api.py POST /vrack/pn-XXXX/dedicatedServerInterface '{"dedicatedServerInterface":"<uuid>"}'

The body (3rd arg) is sent byte-for-byte as given; the OVH signature is
computed over exactly those bytes.
"""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

ENDPOINTS = {
    "eu": "https://eu.api.ovh.com/1.0",
    "ca": "https://ca.api.ovh.com/1.0",
    "us": "https://api.us.ovhcloud.com/1.0",
}


def pretty(raw: str) -> str:
    try:
        return json.dumps(json.loads(raw), indent=2)
    except ValueError:
        return raw


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    method, path = sys.argv[1].upper(), sys.argv[2]
    body = sys.argv[3] if len(sys.argv) > 3 else ""

    endpoint = os.environ.get("OVH_ENDPOINT", "eu")
    base = ENDPOINTS.get(endpoint, endpoint).rstrip("/")
    try:
        app_key = os.environ["OVH_APP_KEY"]
        app_secret = os.environ["OVH_APP_SECRET"]
        consumer_key = os.environ["OVH_CONSUMER_KEY"]
    except KeyError as e:
        print(f"missing {e.args[0]} — source .env.ovh first (see header)", file=sys.stderr)
        return 2

    url = base + path
    with urllib.request.urlopen(base + "/auth/time", timeout=10) as r:
        now = r.read().decode().strip()

    raw = "+".join([app_secret, consumer_key, method, url, body, now])
    sig = "$1$" + hashlib.sha1(raw.encode()).hexdigest()

    req = urllib.request.Request(
        url,
        data=body.encode() if body else None,
        method=method,
        headers={
            "X-Ovh-Application": app_key,
            "X-Ovh-Consumer": consumer_key,
            "X-Ovh-Timestamp": now,
            "X-Ovh-Signature": sig,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(pretty(r.read().decode()))
            return 0
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} {e.reason}", file=sys.stderr)
        print(pretty(e.read().decode()))
        return 1


if __name__ == "__main__":
    sys.exit(main())
