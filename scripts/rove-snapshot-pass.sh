#!/usr/bin/env bash
# Periodic backup pass. Triggered by rove-snapshot.timer.
#
# Runs on every node in a cluster but only the leader actually
# captures — followers skip silently after a sub-millisecond curl.
# Leader-only avoids 3× duplicate manifests in S3 (content-addressed
# blobs would dedup but manifests don't).
#
# Reads env from ~/.config/rove/{common,loop46}.env via the systemd
# unit's EnvironmentFile. Locally needs:
#   DATA_DIR        the worker's --data-dir (read; loop46 snapshot
#                   re-VACUUMs every tenant)
#   HTTP_LISTEN     host:port the worker is bound to; we hit
#                   https://127.0.0.1:PORT/_system/leader (TLS check
#                   skipped, the cert's SAN is for the public
#                   hostname and we're loopback)
#   BIN             path to the loop46 binary (default ~/.local/bin/loop46)
#
# Plus all the S3 env vars in common.env — the CLI reads BLOB_BACKEND
# / S3_* / AWS_* directly. SNAPSHOT_S3_KEY_PREFIX optional.

set -euo pipefail

: "${DATA_DIR:?DATA_DIR not set; check ~/.config/rove/loop46.env}"
: "${HTTP_LISTEN:?HTTP_LISTEN not set; check ~/.config/rove/loop46.env}"
BIN="${BIN:-$HOME/.local/bin/loop46}"

# Extract the port from HTTP_LISTEN (host:port). The leader probe is
# loopback-only so we deliberately ignore the host portion.
PORT="${HTTP_LISTEN##*:}"

# 1) Am I leader?
code=$(curl --silent --insecure --max-time 5 \
    --output /dev/null --write-out '%{http_code}' \
    "https://127.0.0.1:${PORT}/_system/leader" || echo "000")

case "$code" in
    200)
        echo "snapshot: this node is leader, capturing"
        ;;
    503)
        echo "snapshot: not leader (HTTP 503), skipping"
        exit 0
        ;;
    *)
        # 000 (curl failed) / 5xx / other. Don't capture — the
        # cluster is in a weird state and we don't want a half-
        # written snapshot or duplicate captures across nodes.
        echo "snapshot: leader probe returned $code, skipping this pass" >&2
        exit 0
        ;;
esac

# 2) Capture. Output goes to journald via the unit; the CLI prints
# `captured snapshot <snap_id>` on success so the operator can find
# it in `journalctl --user -u rove-snapshot.service`.
exec "$BIN" snapshot --data-dir "$DATA_DIR"
