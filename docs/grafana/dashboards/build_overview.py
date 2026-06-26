#!/usr/bin/env python3
"""Generate rewind-overview.json — the Rewind cluster operator dashboard.

Run: python3 docs/grafana/dashboards/build_overview.py
Produces docs/grafana/dashboards/rewind-overview.json (checked in for PR review;
see docs/grafana/README.md for import). Hand-editing the JSON is fine, but
re-running this regenerates it from one place.

Datasource is a template variable `${datasource}` (type prometheus) so the
dashboard imports cleanly into any Grafana with a Prometheus datasource —
Grafana prompts for it on import.
"""
import json
import os

DS = "${datasource}"
GAUGE = "gauge"
W, H = 24, 7  # full-width panel default
_y = [0]
_id = [0]


def nid():
    _id[0] += 1
    return _id[0]


def row(title):
    p = {"type": "row", "title": title, "collapsed": False,
         "gridPos": {"h": 1, "w": W, "x": 0, "y": _y[0]}, "id": nid(), "panels": []}
    _y[0] += 1
    return p


def _target(expr, legend=None):
    t = {"datasource": {"type": "prometheus", "uid": DS}, "expr": expr,
         "refId": "A", "editorMode": "code", "range": True}
    if legend is not None:
        t["legendFormat"] = legend
    return t


def ts(title, exprs, *, x=0, w=12, h=H, unit="short", desc="", thresholds=None, stack=False):
    """Timeseries panel. `exprs` = list of (expr, legend)."""
    targets = []
    for i, (e, lg) in enumerate(exprs):
        t = _target(e, lg)
        t["refId"] = chr(ord("A") + i)
        targets.append(t)
    fc = {"defaults": {"unit": unit, "custom": {"fillOpacity": 8, "showPoints": "never",
          "stacking": {"mode": "normal" if stack else "none"}}}, "overrides": []}
    if thresholds:
        fc["defaults"]["thresholds"] = {"mode": "absolute", "steps": thresholds}
        fc["defaults"]["custom"]["thresholdsStyle"] = {"mode": "line"}
    p = {"type": "timeseries", "title": title, "description": desc,
         "datasource": {"type": "prometheus", "uid": DS},
         "gridPos": {"h": h, "w": w, "x": x, "y": _y[0]}, "id": nid(),
         "targets": targets, "fieldConfig": fc,
         "options": {"legend": {"displayMode": "table", "placement": "bottom",
                                "calcs": ["last", "max"]}, "tooltip": {"mode": "multi"}}}
    return p


def stat(title, expr, *, x=0, w=6, h=4, unit="short", desc="", steps=None, legend=""):
    fc = {"defaults": {"unit": unit, "thresholds": {"mode": "absolute",
          "steps": steps or [{"color": "green", "value": None}]}}, "overrides": []}
    p = {"type": "stat", "title": title, "description": desc,
         "datasource": {"type": "prometheus", "uid": DS},
         "gridPos": {"h": h, "w": w, "x": x, "y": _y[0]}, "id": nid(),
         "targets": [_target(expr, legend)], "fieldConfig": fc,
         "options": {"colorMode": "background", "graphMode": "area",
                     "reduceOptions": {"calcs": ["lastNotNull"]}, "textMode": "auto"}}
    return p


panels = []


def place(row_panels, height):
    """Advance y past a row of side-by-side panels of the given height."""
    panels.extend(row_panels)
    _y[0] += height


# ── Row 1: top-line health ────────────────────────────────────────────────
panels.append(row("Fleet & serving health"))
place([
    stat("Processes up", 'sum(up{job=~"rewind-.*"})', x=0, w=4, h=4,
         desc="3 worker + 3 cp + 3 front = 9 when whole.",
         steps=[{"color": "red", "value": None}, {"color": "yellow", "value": 7}, {"color": "green", "value": 9}]),
    stat("Directory leader", 'sum(raft_is_leader{job="rewind-cp"})', x=4, w=4, h=4,
         desc="Exactly 1 CP leads the directory group. 0 = the directory wedge.",
         steps=[{"color": "red", "value": None}, {"color": "green", "value": 1}]),
    stat("5xx / sec (5m)", 'sum(rate(http_requests_total{code="5xx"}[5m]))', x=8, w=4, h=4,
         unit="reqps", desc="Server errors across all processes.",
         steps=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.1}, {"color": "red", "value": 1}]),
    stat("Wedge: no-leader groups", "sum(raft_groups_no_leader)", x=12, w=4, h=4,
         desc="Groups with no known leader (worker+cp). 0 healthy.",
         steps=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
    stat("Wedge: unreachable peers", "sum(raftnet_peers_unreachable)", x=16, w=4, h=4,
         desc="Configured raft peers with no outbound conn (the zombie-connect/partition signal).",
         steps=[{"color": "green", "value": None}, {"color": "red", "value": 1}]),
    stat("Mesh connected", "sum(raftnet_peers_connected)", x=20, w=4, h=4,
         desc="Established outbound raft edges (worker 6 + cp 6 = 12 when whole).",
         steps=[{"color": "red", "value": None}, {"color": "green", "value": 12}]),
], 4)
place([
    ts("Request rate by status class", [
        ('sum by (code) (rate(http_requests_total[1m]))', "{{code}}")],
        x=0, w=12, unit="reqps", stack=True,
        desc="The RED rate+error signal (http_requests_total) across all 3 processes."),
    ts("Error ratio % (4xx+5xx of total)", [
        ('100 * sum(rate(http_requests_total{code=~"4xx|5xx"}[5m])) / clamp_min(sum(rate(http_requests_total[5m])), 1)', "error %")],
        x=12, w=12, unit="percent",
        thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 2}, {"color": "red", "value": 5}],
        desc="Share of responses that are 4xx/5xx. Watch 5xx; 4xx can be normal (auth)."),
], H)

# ── Row 2: wedge signals ──────────────────────────────────────────────────
panels.append(row("⚠ Wedge signals (the incidents this month lacked)"))
place([
    ts("raft_groups_no_leader (by job/instance)", [
        ('max by (job, instance) (raft_groups_no_leader)', "{{job}} {{instance}}")],
        x=0, w=12, thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
        desc="Groups this node neither leads nor knows a leader for. Brief on election; SUSTAINED > 0 = the wedge."),
    ts("raftnet_peers_unreachable (by job/instance)", [
        ('max by (job, instance) (raftnet_peers_unreachable)', "{{job}} {{instance}}")],
        x=12, w=12, thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
        desc="configured - connected outbound raft edges. The cross-host zombie-connect/partition signal."),
], H)

# ── Row 3: consensus ──────────────────────────────────────────────────────
panels.append(row("Raft / consensus"))
place([
    ts("raft groups (total vs led)", [
        ('sum by (instance) (raft_groups{job="rewind-worker"})', "groups {{instance}}"),
        ('sum by (instance) (raft_groups_led{job="rewind-worker"})', "led {{instance}}")],
        x=0, w=8, desc="Worker tenant groups per node (born fully replicated) and how many each leads."),
    ts("leadership acquisitions /min (spurious-election signal)", [
        ('sum by (instance) (rate(raft_leadership_acquisitions_total[5m]) * 60)', "{{instance}}")],
        x=8, w=8, unit="short", desc="follower→leader edges. ~flat at steady state; rising = election timeout too tight."),
    ts("heartbeat RTT (mean, µs)", [
        ('sum by (instance) (rate(raft_heartbeat_rtt_us_sum[5m])) / clamp_min(sum by (instance) (rate(raft_heartbeat_rtt_us_count[5m])), 1)', "{{instance}}")],
        x=16, w=8, unit="µs", desc="Broadcast time; the election timeout must sit well above this."),
], H)

# ── Row 4: control plane ──────────────────────────────────────────────────
panels.append(row("Control plane (CP reconciler)"))
place([
    ts("reconcile passes /min", [
        ('sum by (instance) (rate(cp_reconcile_passes_total[5m]) * 60)', "{{instance}}")],
        x=0, w=12, desc="Reconciler liveness. ~0 in cold-multi (reconciler off); non-zero only for deliberate DR ops."),
    ts("conf-change proposals (total vs FAILED)", [
        ('sum(cp_reconcile_confchange_total)', "proposed"),
        ('sum(cp_reconcile_confchange_failed_total)', "FAILED")],
        x=12, w=12, thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
        desc="FAILED climbing while membership doesn't advance = a stuck conf-change (the {1,2} wedge)."),
], H)

# ── Row 5: front door ─────────────────────────────────────────────────────
panels.append(row("Front door (edge)"))
place([
    ts("active proxy flows / WS tunnels (leak canary)", [
        ('sum by (instance) (front_proxy_flows_active)', "flows {{instance}}"),
        ('sum by (instance) (front_proxy_tunnels_active)', "tunnels {{instance}}")],
        x=0, w=8, desc="In-flight proxied flows. Tracks load; a monotonic climb at idle is a leak."),
    ts("active h2 sessions (front)", [
        ('sum by (instance) (h2_conn_active_size{job="rewind-front"})', "{{instance}}")],
        x=8, w=8, desc="Live downstream client connections per front."),
    ts("connection-setup stress (front)", [
        ('sum by (instance) (rate(io_recv_enobufs_total{job="rewind-front"}[5m]))', "enobufs {{instance}}"),
        ('sum by (instance) (rate(io_admission_denied_total{job="rewind-front"}[5m]))', "admission_denied {{instance}}")],
        x=16, w=8, unit="cps", thresholds=[{"color": "green", "value": None}, {"color": "yellow", "value": 0.01}],
        desc="ENOBUFS / admission denials — connection-setup collapse (was log-only)."),
], H)

# ── Row 6: worker data plane / storage ────────────────────────────────────
panels.append(row("Worker data plane & storage"))
place([
    ts("requests parked on raft commit", [
        ('sum by (instance) (h2_raft_pending_size)', "{{instance}}")],
        x=0, w=8, desc="Requests waiting for their write to commit. A rising floor = commit stall."),
    ts("kvexp txn commits / rollbacks per sec", [
        ('sum(rate(kvexp_txn_commit_total[1m]))', "commit"),
        ('sum(rate(kvexp_txn_rollback_total[1m]))', "rollback")],
        x=8, w=8, unit="ops", desc="Speculative-overlay commits (quorum) vs rollbacks (fault/timeout)."),
    ts("durabilize failures (S3/storage health)", [
        ('sum(increase(kvexp_durabilize_failed_total[5m]))', "fail/5m")],
        x=16, w=8, thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}],
        desc="Durabilize (fold-to-storage) failures — the closest signal to S3/blob degradation today."),
], H)

dashboard = {
    "__inputs": [],
    "title": "Rewind — Cluster Overview",
    "uid": "rewind-overview",
    "tags": ["rewind"],
    "timezone": "",
    "schemaVersion": 39,
    "version": 1,
    "refresh": "30s",
    "time": {"from": "now-3h", "to": "now"},
    "templating": {"list": [{
        "name": "datasource", "type": "datasource", "query": "prometheus",
        "current": {}, "hide": 0, "label": "Datasource",
    }]},
    "panels": panels,
}

out = os.path.join(os.path.dirname(__file__), "rewind-overview.json")
with open(out, "w") as f:
    json.dump(dashboard, f, indent=2)
    f.write("\n")
print(f"wrote {out} ({len(panels)} panels)")
