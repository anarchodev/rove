#!/usr/bin/env bash
#
# deploy.sh — rolling zero-downtime deploy of the V2 stack to the 3-node
# production cluster. See docs/v2-production-deploy-plan.md §6.
#
# What it does:
#   1. Builds the 3 V2 binaries (ReleaseFast) and runs the test gate.
#   2. For each host, one at a time: pushes binaries, restarts cp →
#      worker → front, waits for health, lets the node settle (raft
#      rejoin) before moving on. Each raft cluster tolerates 1 node down,
#      so one-at-a-time keeps quorum the whole way.
#
# What it does NOT do: push env files / secrets (provisioned out-of-band),
# run sudo (except optional setcap), or touch the next host until the
# current one is healthy. Aborts the rollout if a node doesn't recover.
#
# Usage:
#   cp scripts/deploy.conf.example ~/.config/rove/deploy.conf  # edit it
#   scripts/deploy.sh                 # build + test + rolling deploy
#   ROVE_SKIP_TESTS=1 scripts/deploy.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Config lives at ~/.config/rove/deploy.conf (survives worktree churn);
# repo-root scripts/deploy.conf is the legacy fallback. Override with
# ROVE_DEPLOY_CONF.
CONF="${ROVE_DEPLOY_CONF:-}"
if [ -z "$CONF" ]; then
    for c in "${XDG_CONFIG_HOME:-$HOME/.config}/rove/deploy.conf" "$REPO_ROOT/scripts/deploy.conf"; do
        [ -f "$c" ] && CONF="$c" && break
    done
fi
# shellcheck disable=SC1090
[ -n "$CONF" ] && [ -f "$CONF" ] && source "$CONF"

: "${ROVE_HOSTS:?set ROVE_HOSTS in scripts/deploy.conf (see deploy.conf.example)}"
SSH="${ROVE_SSH:-ssh}"
RSYNC="${ROVE_RSYNC:-rsync}"
BIN_DIR="${ROVE_BIN_DIR:-.local/bin}"
SETTLE_SECS="${ROVE_SETTLE_SECS:-10}"
SETCAP="${ROVE_SETCAP:-0}"
SKIP_TESTS="${ROVE_SKIP_TESTS:-0}"
HEALTH_TIMEOUT=60

BINS=(rewind rewind-cp rewind-front)
OUT="$REPO_ROOT/zig-out/bin"

# `systemctl --user` over a non-login ssh session needs the user-bus env.
# Single-quoted so $(id -u) is evaluated on the REMOTE host (a var's value
# is not re-scanned for command substitution when later interpolated).
RUSER_ENV='export XDG_RUNTIME_DIR=/run/user/$(id -u);'

c_info=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
log(){ printf '%s== %s ==%s\n' "$c_info" "$*" "$c_off"; }
ok(){  printf '%s   ✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
die(){ printf '%sFATAL: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

# ── 1. Build + test gate ──────────────────────────────────────────────
log "Building V2 binaries (ReleaseFast)"
( cd "$REPO_ROOT" && zig build rewind rewind-cp rewind-front -Doptimize=ReleaseFast ) \
    || die "build failed"
for b in "${BINS[@]}"; do [ -x "$OUT/$b" ] || die "missing build output: $OUT/$b"; done
ok "built ${BINS[*]}"

if [ "$SKIP_TESTS" = 1 ]; then
    printf '%s   ! skipping tests (ROVE_SKIP_TESTS=1)%s\n' "$c_err" "$c_off"
else
    log "Test gate"
    ( cd "$REPO_ROOT" && zig build v2-test ) || die "v2-test failed — not deploying"
    ( cd "$REPO_ROOT" && zig build test )    || die "zig build test failed — not deploying"
    ok "tests green"
fi

# ── health probe (runs on-host over ssh; private ports aren't public) ──
# wait_health <host> <service> [readiness_url]
wait_health(){
    # Two `local` statements: in one statement bash word-expands every
    # argument BEFORE any assignment lands, so `unit="rewind-$svc…"` would
    # read the caller's (unset) svc — set -u aborts. Bit us on the first
    # real roll.
    local host="$1" svc="$2" url="${3:-}" t=0
    local unit="rewind-$svc.service"
    # The worker is h2c-ONLY (accept_http1=false) — a plain HTTP/1.1 curl
    # never connects a stream. Found on the first real prod roll.
    local curl_flags="-fsS -m5 -o /dev/null"
    [ "$svc" = worker ] && curl_flags="$curl_flags --http2-prior-knowledge"
    # liveness: unit is active
    until $SSH "$host" "$RUSER_ENV systemctl --user is-active --quiet '$unit'"; do
        t=$((t+1)); [ "$t" -lt "$HEALTH_TIMEOUT" ] || die "$host: $unit not active after ${HEALTH_TIMEOUT}s"
        sleep 1
    done
    # readiness: endpoint answers (cp/worker only; front is liveness-only)
    if [ -n "$url" ]; then
        until $SSH "$host" "curl $curl_flags '$url'"; do
            t=$((t+2)); [ "$t" -lt "$HEALTH_TIMEOUT" ] || die "$host: $svc not ready ($url) after ${HEALTH_TIMEOUT}s"
            sleep 2
        done
    fi
    ok "$host: $svc healthy"
}

# cp readiness. `/_cp/leader` is 200 ONLY on the directory leader (it's
# the HA discovery probe) — a restarted node that rejoins as a FOLLOWER
# answers 503 forever, so gating a node on its own 200 deadlocks the
# roll (bit us on the first real one). Ready =
#   (a) the local CP answers HTTP at all (any status: serving), and
#   (b) SOME node answers 200 (the directory raft has a leader).
wait_cp_ready(){
    local host="$1" t=0
    until $SSH "$host" "curl -s -m5 -o /dev/null http://localhost:9090/_cp/leader"; do
        t=$((t+2)); [ "$t" -lt "$HEALTH_TIMEOUT" ] || die "$host: cp not serving after ${HEALTH_TIMEOUT}s"
        sleep 2
    done
    ok "$host: cp serving"
    t=0
    while :; do
        local h
        for h in $ROVE_HOSTS; do
            if $SSH "$h" "curl -fsS -m5 -o /dev/null http://localhost:9090/_cp/leader" 2>/dev/null; then
                ok "directory leader present (via $h)"
                return 0
            fi
        done
        t=$((t+2)); [ "$t" -lt "$HEALTH_TIMEOUT" ] || die "directory raft has no leader after ${HEALTH_TIMEOUT}s"
        sleep 2
    done
}

# ── 2. Rolling deploy, one host fully before the next ─────────────────
log "Rolling deploy to: $ROVE_HOSTS"
for host in $ROVE_HOSTS; do
    log "[$host] push binaries"
    # Stage then atomic-rename so a half-copied binary is never executed.
    for b in "${BINS[@]}"; do
        $RSYNC -az "$OUT/$b" "$host:$BIN_DIR/.$b.new" || die "$host: rsync $b failed"
    done
    # Atomic rename (not copy-into): replacing a running executable by
    # rename is ETXTBSY-safe — the old inode lives until the restart execs.
    $SSH "$host" "set -e; cd \"\$HOME/$BIN_DIR\"; for b in ${BINS[*]}; do chmod 0755 \".\$b.new\"; mv -f \".\$b.new\" \"\$b\"; done" \
        || die "$host: binary install failed"
    if [ "$SETCAP" = 1 ]; then
        $SSH "$host" "sudo setcap cap_net_bind_service=+ep \"\$HOME/$BIN_DIR/rewind-front\"" \
            || die "$host: setcap failed (ROVE_SETCAP=1)"
    fi
    ok "$host: binaries in place"

    log "[$host] restart cp → worker → front"
    $SSH "$host" "$RUSER_ENV systemctl --user restart rewind-cp.service"     || die "$host: cp restart failed"
    wait_health "$host" cp
    wait_cp_ready "$host"
    $SSH "$host" "$RUSER_ENV systemctl --user restart rewind-worker.service" || die "$host: worker restart failed"
    wait_health "$host" worker "http://localhost:8443/_system/health"
    $SSH "$host" "$RUSER_ENV systemctl --user restart rewind-front.service"  || die "$host: front restart failed"
    wait_health "$host" front

    log "[$host] settle ${SETTLE_SECS}s (raft rejoin) before next host"
    sleep "$SETTLE_SECS"
    ok "$host: done"
done

# NOTE: until the third voter exists, restarting either of the 2 live
# nodes drops raft below quorum for the restart window — writes stall
# briefly and resume on rejoin. Zero-downtime claims start at 3 nodes.
log "Rolling deploy complete — all nodes updated + healthy"
