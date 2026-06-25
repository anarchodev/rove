#!/usr/bin/env bash
#
# deploy.sh — deploy the V2 stack to the 3-node production cluster. Two modes
# (docs/v2-production-deploy-plan.md §6):
#
#   ROLLING (default) — zero-downtime update of an ALREADY-FORMED cluster.
#     One host at a time: push binaries, restart cp → worker → front, wait for
#     health, settle (raft rejoin) before the next. Each raft cluster tolerates
#     1 node down, so one-at-a-time keeps quorum the whole way. REFUSES to run
#     if no directory leader is reachable (a virgin cluster — use genesis).
#
#   GENESIS (--genesis) — cold bring-up of a VIRGIN cluster from empty. Pushes
#     binaries to all hosts, starts every CP together so the cold-multi
#     directory group can form quorum + elect, starts workers (self-only) +
#     fronts, then drives `rewind-ops genesis` (register addrs → provision
#     __admin__ born {1} → reconciler grows it to all N → reset/deploy). REFUSES
#     if a directory leader already exists (the cluster is formed — use rolling),
#     unless ROVE_GENESIS_FORCE=1. The 2026-06-24 outage was rolling silently
#     unable to bring a cluster up from empty; this is the split that fixes it.
#
# What NEITHER mode does: push env files / secrets (provisioned out-of-band —
# for genesis the nodes' active EnvironmentFile MUST be the genesis profile,
# scripts/systemd/v2/*.genesis.example: workers self-only, CP cold-multi +
# reconciler on), run sudo (except optional setcap).
#
# Usage:
#   cp scripts/deploy.conf.example ~/.config/rove/deploy.conf  # edit it
#   scripts/deploy.sh                 # rolling: build + test + rolling deploy
#   scripts/deploy.sh --genesis       # genesis: cold bring-up from empty
#   ROVE_SKIP_TESTS=1 scripts/deploy.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── mode: --genesis | --rolling (default), or ROVE_DEPLOY_MODE ─────────
# --dry-run: build + test + read-only preflight + print the plan, then STOP
# before ANY prod mutation (no binary push, no service start/restart, no
# rewind-ops genesis). Safe to run against a live or down cluster.
MODE="${ROVE_DEPLOY_MODE:-rolling}"
DRY_RUN="${ROVE_DRY_RUN:-0}"
for arg in "$@"; do
    case "$arg" in
        --genesis) MODE=genesis ;;
        --rolling) MODE=rolling ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "unknown arg: $arg (want --genesis | --rolling | --dry-run)" >&2; exit 2 ;;
    esac
done
[ "$MODE" = genesis ] || [ "$MODE" = rolling ] || { echo "bad ROVE_DEPLOY_MODE=$MODE" >&2; exit 2; }

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
# Genesis: how long to wait for the cold-multi directory group to elect after
# the CPs are started together (cross-host election is ~1-2s; be generous).
CP_ELECT_TIMEOUT="${ROVE_CP_ELECT_TIMEOUT:-60}"

BINS=(rewind-worker rewind-cp rewind-front)
OUT="$REPO_ROOT/zig-out/bin"

# `systemctl --user` over a non-login ssh session needs the user-bus env.
# Single-quoted so $(id -u) is evaluated on the REMOTE host (a var's value
# is not re-scanned for command substitution when later interpolated).
RUSER_ENV='export XDG_RUNTIME_DIR=/run/user/$(id -u);'

c_info=$'\033[1;36m'; c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_off=$'\033[0m'
log(){ printf '%s== %s ==%s\n' "$c_info" "$*" "$c_off"; }
ok(){  printf '%s   ✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn(){ printf '%s   ! %s%s\n' "$c_err" "$*" "$c_off"; }
die(){ printf '%sFATAL: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
[ "$DRY_RUN" = 1 ] && log "DRY-RUN — build + test + read-only preflight only; no prod mutation"

SSH_PROBE="$SSH -o ConnectTimeout=8 -o BatchMode=yes"

# ── 1. Build + test gate (shared) ─────────────────────────────────────
# Genesis also needs rewind-ops (the operator drives the membership bring-up
# through it); it runs locally, so it is built but not pushed to the hosts.
BUILD_BINS=("${BINS[@]}")
[ "$MODE" = genesis ] && BUILD_BINS+=(rewind-ops)
log "Building V2 binaries (ReleaseFast): ${BUILD_BINS[*]}"
( cd "$REPO_ROOT" && zig build "${BUILD_BINS[@]}" -Doptimize=ReleaseFast ) \
    || die "build failed"
for b in "${BUILD_BINS[@]}"; do [ -x "$OUT/$b" ] || die "missing build output: $OUT/$b"; done
ok "built ${BUILD_BINS[*]}"

if [ "$SKIP_TESTS" = 1 ]; then
    printf '%s   ! skipping tests (ROVE_SKIP_TESTS=1)%s\n' "$c_err" "$c_off"
else
    log "Test gate"
    ( cd "$REPO_ROOT" && zig build v2-test ) || die "v2-test failed — not deploying"
    ( cd "$REPO_ROOT" && zig build test )    || die "zig build test failed — not deploying"
    ok "tests green"
fi

# ── health probes (run on-host over ssh; private ports aren't public) ──
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

# True (0) iff SOME CP member currently answers /_cp/leader 200 — i.e. the
# directory raft has an elected leader. `/_cp/leader` is 200 ONLY on the
# directory leader (the HA discovery probe); a follower answers 503 with no
# leader hint, so this MUST scan the whole CP membership (ROVE_CLUSTER_HOSTS,
# defaulting to ROVE_HOSTS) — the leader can sit on a node we're not deploying.
# Single pass, no wait. A bounded connect timeout keeps a down member from
# hanging the probe.
directory_leader_present(){
    local h
    for h in ${ROVE_CLUSTER_HOSTS:-$ROVE_HOSTS}; do
        if $SSH_PROBE "$h" "curl -fsS -m5 -o /dev/null http://localhost:9090/_cp/leader" 2>/dev/null; then
            LEADER_VIA="$h"; return 0
        fi
    done
    return 1
}

# cp readiness for the ROLLING path. Ready =
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
        if directory_leader_present; then ok "directory leader present (via $LEADER_VIA)"; return 0; fi
        t=$((t+2)); [ "$t" -lt "$HEALTH_TIMEOUT" ] || die "directory raft has no leader after ${HEALTH_TIMEOUT}s (probed: ${ROVE_CLUSTER_HOSTS:-$ROVE_HOSTS})"
        sleep 2
    done
}

# Push the 3 binaries to one host (stage + atomic-rename: a half-copied or a
# running executable is never the one exec'd — rename is ETXTBSY-safe, the old
# inode lives until the next restart execs).
push_binaries(){
    local host="$1" b
    for b in "${BINS[@]}"; do
        $RSYNC -az "$OUT/$b" "$host:$BIN_DIR/.$b.new" || die "$host: rsync $b failed"
    done
    $SSH "$host" "set -e; cd \"\$HOME/$BIN_DIR\"; for b in ${BINS[*]}; do chmod 0755 \".\$b.new\"; mv -f \".\$b.new\" \"\$b\"; done" \
        || die "$host: binary install failed"
    if [ "$SETCAP" = 1 ]; then
        $SSH "$host" "sudo setcap cap_net_bind_service=+ep \"\$HOME/$BIN_DIR/rewind-front\"" \
            || die "$host: setcap failed (ROVE_SETCAP=1)"
    fi
    ok "$host: binaries in place"
}

# ── 2a. GENESIS: cold bring-up from empty ─────────────────────────────
if [ "$MODE" = genesis ]; then
    : "${ROVE_GENESIS_ENV:?genesis needs ROVE_GENESIS_ENV — path to the rewind-ops --env file (ROVE_CP_URL_INTERNAL, ROVE_WORKER_URLS, REWIND_MOVE_SECRET, REWIND_ROOT_TOKEN, REWIND_ADMIN_DOMAIN, ROVE_CLUSTER, ROVE_GENESIS_NODES). See scripts/systemd/v2/*.genesis.example + rewind-ops genesis.}"
    [ -f "$ROVE_GENESIS_ENV" ] || die "ROVE_GENESIS_ENV not found: $ROVE_GENESIS_ENV"

    log "GENESIS mode — cold bring-up of: $ROVE_HOSTS"

    # ── Read-only preflight (runs in both dry-run and real) ───────────
    log "Preflight: validate genesis env + node reachability/state"
    # Required vars in the rewind-ops --env file. Check presence only (never
    # print values — secrets live here).
    for v in ROVE_GENESIS_NODES ROVE_CP_URL_INTERNAL ROVE_WORKER_URLS REWIND_MOVE_SECRET REWIND_ROOT_TOKEN REWIND_ADMIN_DOMAIN; do
        grep -qE "^[[:space:]]*$v=" "$ROVE_GENESIS_ENV" || die "ROVE_GENESIS_ENV ($ROVE_GENESIS_ENV) is missing $v"
    done
    ok "genesis env has all required vars"
    gnodes=$(grep -E "^[[:space:]]*ROVE_GENESIS_NODES=" "$ROVE_GENESIS_ENV" | head -1 | cut -d= -f2-)
    printf '   ROVE_GENESIS_NODES = %s\n' "$gnodes"
    # Per-host: ssh reachable + current service state (a clean genesis wants the
    # services DOWN; flag any that are active — they will be restarted, which on
    # populated data is not a cold genesis).
    profile_warn=0
    for host in $ROVE_HOSTS; do
        $SSH_PROBE "$host" true 2>/dev/null || die "$host: unreachable over ssh"
        local_active=""
        for svc in cp worker front; do
            st=$($SSH "$host" "$RUSER_ENV systemctl --user is-active rewind-$svc.service 2>/dev/null" 2>/dev/null || true)
            [ "$st" = active ] && local_active="$local_active $svc"
        done
        if [ -n "$local_active" ]; then
            warn "$host: reachable — but ACTIVE services:$local_active (expected all-down for a cold genesis)"
        else
            ok "$host: reachable, services down (clean genesis target)"
        fi
        # Worker env PROFILE check: bootstrap-1-grow needs workers SELF-ONLY, so
        # REWIND_VOTERS / REWIND_PEERS must be ABSENT from the active worker env.
        # If they're set (the rolling/cold-multi profile), the worker boots
        # cold-multi and the genesis flow's born-{1}+grow assumptions don't hold.
        vset=$($SSH "$host" 'grep -lE "^[[:space:]]*(REWIND_VOTERS|REWIND_PEERS)=" ~/.config/rove/common.env ~/.config/rove/node.env 2>/dev/null | tr "\n" " "' 2>/dev/null || true)
        if [ -n "$vset" ]; then
            warn "$host: REWIND_VOTERS/REWIND_PEERS set in [$vset] — this is the ROLLING (cold-multi) worker profile, NOT genesis self-only. Switch to the genesis profile (scripts/systemd/v2/common.env.genesis.example) before a real genesis."
            profile_warn=1
        else
            # Self-only: the worker can't derive its raft listen addr from
            # REWIND_PEERS, so REWIND_RAFT_ADDR must be set (node.env.genesis).
            if $SSH "$host" 'grep -qE "^[[:space:]]*REWIND_RAFT_ADDR=" ~/.config/rove/node.env ~/.config/rove/common.env 2>/dev/null'; then
                ok "$host: worker env is self-only + REWIND_RAFT_ADDR set (genesis profile)"
            else
                warn "$host: worker is self-only but REWIND_RAFT_ADDR is UNSET — a genesis worker can't pick its raft listen addr. Add REWIND_RAFT_ADDR=<ip>:8501 to node.env."
                profile_warn=1
            fi
        fi
    done
    [ "$profile_warn" = 1 ] && warn "ONE OR MORE NODES are on the rolling worker profile — genesis will likely mis-form __admin__ until they're switched to self-only."
    # Preview the leader guard (does NOT mutate). A leader present means the
    # cluster is already formed → genesis would refuse (unless FORCE).
    if directory_leader_present; then
        warn "directory leader ALREADY present (via $LEADER_VIA) — genesis would REFUSE (need ROVE_GENESIS_FORCE=1 after a wipe)"
    else
        ok "no directory leader present — virgin/down cluster (genesis target)"
    fi

    if [ "$DRY_RUN" = 1 ]; then
        log "DRY-RUN plan (genesis) — would, in order:"
        echo "   1. push rewind-{worker,cp,front} to: $ROVE_HOSTS"
        echo "   2. restart rewind-cp on ALL hosts together → wait for the cold-multi directory leader (≤${CP_ELECT_TIMEOUT}s)"
        echo "   3. restart rewind-worker (self-only) + rewind-front on each host; health-gate each"
        echo "   4. run: $OUT/rewind-ops genesis --env $ROVE_GENESIS_ENV"
        echo "      (register node addrs → provision __admin__ {1} → reconciler grows to N → reset/deploy)"
        echo "   PRECONDITION reminder: each node's active EnvironmentFile must be the GENESIS profile"
        echo "   (workers self-only: no REWIND_VOTERS/REWIND_PEERS; CP cold-multi + REWIND_CP_RECONCILE_MEMBERSHIP=1)."
        log "DRY-RUN complete — no prod mutation performed"
        exit 0
    fi

    # Guard: never genesis a cluster that already has a leader (it is formed;
    # genesis would split-brain it / fight the existing membership). Rolling is
    # the right tool. Escape hatch for a deliberate re-genesis after a wipe.
    if directory_leader_present; then
        if [ "${ROVE_GENESIS_FORCE:-0}" = 1 ]; then
            printf '%s   ! directory leader already present (via %s) — proceeding anyway (ROVE_GENESIS_FORCE=1)%s\n' "$c_err" "$LEADER_VIA" "$c_off"
        else
            die "a directory leader already exists (via $LEADER_VIA) — the cluster is formed. Use rolling (scripts/deploy.sh), or ROVE_GENESIS_FORCE=1 to override (only after a deliberate data wipe)."
        fi
    fi

    log "Push binaries to all hosts"
    for host in $ROVE_HOSTS; do push_binaries "$host"; done

    # Start every CP TOGETHER so the cold-multi directory group reaches quorum.
    # A rolling (one-at-a-time) start can't: a lone CP with REWIND_CP_VOTERS=1,2,3
    # has no peers up to elect with. `restart` starts a stopped unit too, so this
    # works whether the nodes were down or partially up.
    log "Start all CP nodes together (cold-multi directory group)"
    for host in $ROVE_HOSTS; do
        $SSH "$host" "$RUSER_ENV systemctl --user restart rewind-cp.service" || die "$host: cp start failed"
        ok "$host: cp started"
    done
    log "Wait for the directory group to elect (cold-multi, ~1-2s cross-host)"
    t=0
    until directory_leader_present; do
        t=$((t+2)); [ "$t" -lt "$CP_ELECT_TIMEOUT" ] || die "directory group did NOT elect within ${CP_ELECT_TIMEOUT}s — check rewind-cp logs (REWIND_CP_VOTERS/PEERS set? reachable on :9101? REWIND_RAFT_NET_DEBUG=1 for the dial trace)"
        sleep 2
    done
    ok "directory leader present (via $LEADER_VIA) — cold-multi CP genesis succeeded"

    log "Start workers (self-only) + fronts on all hosts"
    for host in $ROVE_HOSTS; do
        $SSH "$host" "$RUSER_ENV systemctl --user restart rewind-worker.service" || die "$host: worker start failed"
        wait_health "$host" worker "http://localhost:8443/_system/health"
        $SSH "$host" "$RUSER_ENV systemctl --user restart rewind-front.service"  || die "$host: front start failed"
        wait_health "$host" front
    done

    # Drive the operator-side membership bring-up: register addrs → provision
    # __admin__ (born {1}) → reconciler grows it to all N → reset/deploy. This
    # is the tested bootstrap-1-grow path (rewind-ops genesis); deploy.sh just
    # stood the processes up for it.
    log "Run rewind-ops genesis (register → provision __admin__ → grow → reset)"
    "$OUT/rewind-ops" genesis --env "$ROVE_GENESIS_ENV" || die "rewind-ops genesis failed — see output above"

    log "GENESIS complete — cluster formed, __admin__ grown + deploy-capable"
    ok "next: provision tenants + publish bundles; future updates use rolling (scripts/deploy.sh)"
    exit 0
fi

# ── 2b. ROLLING: zero-downtime update of a formed cluster ─────────────
# Guard: rolling restarts one node at a time and gates each on a directory
# leader — it CANNOT bring a cluster up from empty (a lone cold-multi CP never
# reaches quorum, so wait_cp_ready would hang then die). The 2026-06-24 outage
# was exactly this silent failure. Refuse early with a clear pointer to genesis.
log "Pre-flight: directory leader must be reachable (rolling updates a formed cluster)"
if ! directory_leader_present; then
    die "no directory leader reachable on ${ROVE_CLUSTER_HOSTS:-$ROVE_HOSTS} — this looks like a VIRGIN or fully-down cluster. Rolling cannot cold-start it; use: scripts/deploy.sh --genesis"
fi
ok "directory leader present (via $LEADER_VIA)"

if [ "$DRY_RUN" = 1 ]; then
    log "DRY-RUN plan (rolling) — for each host in order ($ROVE_HOSTS): push binaries, restart cp→worker→front, health-gate, settle ${SETTLE_SECS}s"
    log "DRY-RUN complete — no prod mutation performed"
    exit 0
fi

log "Rolling deploy to: $ROVE_HOSTS"
for host in $ROVE_HOSTS; do
    log "[$host] push binaries"
    push_binaries "$host"

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
