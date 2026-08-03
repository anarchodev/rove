#!/usr/bin/env bash
#
# nightly.sh — the smoke suite's standing appointment (#363 class 10).
#
# The suite rotted once because running it depended on someone remembering
# (rove#355: weeks of invisible breakage, five live production bugs on the
# first re-run). This script is the "something that runs it": a systemd user
# timer (scripts/smoke/systemd/) fires it nightly; it builds origin/main in a
# DEDICATED checkout, runs the full suite, diffs against the committed
# baseline, and comments on the standing GitHub issue when — and only when —
# something is newly broken, or the nightly itself could not run. Silence is
# only ever "nothing new".
#
# A dedicated checkout, not the working tree: the dev checkout is routinely
# mid-edit (parallel sessions), and a gate that tests uncommitted state
# answers a different question than "is origin/main healthy".
#
# Alerts go to ONE standing issue (rove#373) so the history reads as a
# thread. The baseline is refreshed MANUALLY (see README.md) — this script
# never rewrites it.
#
# Environment (all defaulted for the dev box):
#   ROVE_NIGHTLY_DIR    dedicated checkout      (~/src/rove-nightly)
#   ROVE_SMOKE_ENV      S3 credentials file     (~/src/rove/.env)
#   REWIND_APPS_DIR     first-party app sources (~/src/rewind-apps)
#   SMOKE_JOBS          run_all --jobs          (8)
#   SMOKE_ISSUE         standing GH issue       (373)
#   SMOKE_FILTER        run_all --filter        (unset = full suite; used by
#                       the self-test in README.md, never by the timer)
set -uo pipefail

# Timer/unit contexts have no login profile: rustup's cargo (the arenajs
# build) and anything in ~/.local/bin must be found without one.
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

NIGHTLY_DIR="${ROVE_NIGHTLY_DIR:-$HOME/src/rove-nightly}"
# Run artifacts live BESIDE the checkout, not inside it: the checkout must
# stay clonable-from-empty and hard-resettable without excludes.
RUNS_DIR="$NIGHTLY_DIR-runs"
ENV_FILE="${ROVE_SMOKE_ENV:-$HOME/src/rove/.env}"
export REWIND_APPS_DIR="${REWIND_APPS_DIR:-$HOME/src/rewind-apps}"
JOBS="${SMOKE_JOBS:-8}"
ISSUE="${SMOKE_ISSUE:-373}"
# HTTPS, not SSH: the timer fires with no login session, so there is no
# ssh-agent to authenticate a fetch — and none is needed, the repo is
# public. (The alert path's `gh` uses its own stored token.)
REMOTE_URL="https://github.com/anarchodev/rove.git"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUNS_DIR/$STAMP"

log() { printf '[nightly] %s\n' "$*"; }

# Every failure path lands here: a nightly that cannot run must say so —
# a silent no-op is indistinguishable from coverage (the exact rot this
# script exists to prevent). Comment body on stdin.
alert() {
    local title="$1"
    {
        echo "**$title** — nightly $STAMP on $(hostname)"
        echo
        cat
        echo
        echo "logs: \`$RUN_DIR\` (dev box)"
    } | gh issue comment "$ISSUE" --repo anarchodev/rove --body-file - \
        || log "ALERT DELIVERY FAILED: $title (gh comment errored — check auth)"
}

die() {
    log "FATAL: $1"
    printf '%s\n' "${2:-no further detail}" | alert "nightly could not run: $1"
    exit 1
}

mkdir -p "$RUN_DIR"

# ── Fresh checkout of origin/main ────────────────────────────────────
if [ ! -d "$NIGHTLY_DIR/.git" ]; then
    git clone "$REMOTE_URL" "$NIGHTLY_DIR" >"$RUN_DIR/git.log" 2>&1 \
        || die "clone failed" "$(tail -20 "$RUN_DIR/git.log")"
fi
cd "$NIGHTLY_DIR"
git remote set-url origin "$REMOTE_URL"
git fetch origin main >"$RUN_DIR/git.log" 2>&1 \
    && git reset --hard origin/main >>"$RUN_DIR/git.log" 2>&1 \
    && git clean -fd --exclude=.env >>"$RUN_DIR/git.log" 2>&1 \
    || die "checkout update failed" "$(tail -20 "$RUN_DIR/git.log")"
SHA="$(git rev-parse --short HEAD)"
log "at origin/main ($SHA)"

[ -f "$ENV_FILE" ] || die "S3 env file missing" "$ENV_FILE not found"
cp "$ENV_FILE" .env

# ── Build (default install for the example servers + the shipped set) ─
log "building"
zig build >"$RUN_DIR/build.log" 2>&1 \
    && zig build rewind-worker rewind-cp rewind-front rewind-logs rewind-ops >>"$RUN_DIR/build.log" 2>&1 \
    || die "build failed at $SHA" "$(tail -30 "$RUN_DIR/build.log")"

# ── Run + baseline diff ──────────────────────────────────────────────
set -a; . ./.env; set +a
FILTER_ARGS=()
[ -n "${SMOKE_FILTER:-}" ] && FILTER_ARGS=(--filter "$SMOKE_FILTER")
log "running suite (--jobs $JOBS)"
if python3 scripts/smoke/run_all.py --jobs "$JOBS" "${FILTER_ARGS[@]}" \
    --json "$RUN_DIR/result.json" \
    --baseline scripts/smoke/smoke-baseline.json \
    --logs "$RUN_DIR/logs" >"$RUN_DIR/run.log" 2>&1; then
    log "no new failures vs baseline (at $SHA) — no alert"
else
    # Non-zero = NEWLY BROKEN vs baseline (run_all's contract), or the
    # runner itself fell over — either way, say so.
    tail -40 "$RUN_DIR/run.log" | alert "newly broken vs baseline at $SHA"
    log "regression reported to issue #$ISSUE"
fi

# Keep the last 14 runs' artifacts.
ls -1dt "$RUNS_DIR"/*/ 2>/dev/null | tail -n +15 | xargs -r rm -rf 2>/dev/null || true
log "done"
