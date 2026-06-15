# Observability

> 🟢 **As-built reference.** Operator telemetry (metrics + traces to Grafana
> Cloud), aimed at oncall — not at customers. The customer-facing request-log /
> replay store is [`deployment-and-logs.md`](deployment-and-logs.md). Why (the
> two-sink split + the no-`tenant_id`-label rule): [decisions.md §7](../decisions.md).
>
> Status as of 2026-05-13: pre-implementation. Today's surface is a
> single `/_system/metrics` endpoint on the worker (the io/h2/raft
> conservation+depth series in §1, plus ~15 kvexp_* counters and two
> kvexp_*_duration_seconds histograms added by the kvexp re-vendor —
> commit 4ea5dd0; root-token gated, postmortem-investigation shaped)
> — see §1 for the inventory. Nothing scrapes it.

## 0. Goal + non-goals

**Goal:** ship enough operator telemetry to launch rewind.js and run an
on-call rotation against Grafana Cloud (free tier: Prometheus + Loki +
Tempo).

**The load-bearing constraint** (decided 2026-05-13, persisted in
auto-memory as `project_observability_split`): **customer request logs
do not go to Grafana.** They live in the per-tenant replay store
([`deployment-and-logs.md`](deployment-and-logs.md) — S3-direct,
page-encrypted at rest, addressable by request_id). Grafana Cloud holds
operator-shaped signals only.
`tenant_id` and `request_id` ride as **trace exemplars or low-cardinality
structured-log fields**, never as Prometheus labels. The reasons:

- Page-encrypted product data can't be sent to a third-party in plaintext.
- The replay store already holds the bytes; double-shipping inflates the bill.
- Per-tenant labels explode Grafana Cloud's active-series count
  (which is what they charge on).
- Loki on per-request payloads at our request volume is the wrong tool.

**The pivot model** (what makes the split usable): when on-call sees a
p99 spike for tenant X at 14:03 in Grafana, the histogram sample's
exemplar carries `trace_id`, `tenant_id`, `request_id` — click → Tempo
trace → deep-link to the replay viewer. Exemplars are how the two
universes stay joined.

**Non-goals:**
- Per-tenant Prometheus metrics of any shape.
- Customer-facing dashboards (those are admin-UI surfaces fed from the
  replay store, not Grafana).
- A homegrown TSDB / push gateway.
- In-process span aggregation. When we ship traces, they go straight to
  OTLP via the Grafana Agent.
- Histogram series for every counter. Counters + `rate()` is almost
  always enough; reserve histograms for SLI-shaped latency/size signals.

## 1. Current surface (inventory, 2026-05-13)

Single emitter at `/_system/metrics` (`src/js/worker_dispatch.zig:576`,
routed at `:434`). Auth: root-bearer or services-JWT — the same gate as
the rest of `/_system/*`. Format: Prometheus text v0.0.4. Stated
purpose in the doc-comment: *"not a dashboard — making the math visible
[so the next investigator can read the imbalance at a glance]."*
Pattern is conservation-pair counters + pipeline-depth gauges, born of
the io-buffer-leak postmortem. Plus a kvexp engine block
(kvexp_put_total / _get_total / _txn_commit_total / _durabilize_total /
… and kvexp_durabilize_duration_seconds +
kvexp_snapshot_open_duration_seconds histograms) added with the kvexp
cutover.

| metric | type | what it tells you |
|---|---|---|
| `io_recv_completions_total` | counter | recv CQEs that carried data — buffers consumed from the registered ring |
| `io_recv_buffers_returned_total{src="drain"}` | counter | buffers returned via the read-drain path |
| `io_recv_buffers_returned_total{src="deinit"}` | counter | buffers returned via cleanup-on-deinit |
| `io_recv_outstanding` | gauge | `completions − returned`; must stay below `buf_count` |
| `io_recv_buf_count` | gauge | registered ring capacity (`--buf-count`) |
| `io_recv_enobufs_total` | counter | recv completions the kernel couldn't satisfy |
| `io_admission_denied_total` | counter | accept refused due to admission-budget cap |
| `h2_request_out_size` | gauge | requests received, awaiting dispatch |
| `h2_raft_pending_size` | gauge | requests parked on raft commit |
| `h2_response_in_size` | gauge | responses ready to dispatch back |
| `h2_response_out_size` | gauge | responses in-flight on the send path |
| `h2_conn_active_size` | gauge | active h2 sessions |
| `h2_conn_tls_handshake_size` | gauge | connections still in TLS handshake |
| `h2_io_connections_size` | gauge | raw tcp conns owned by io layer |
| `raft_is_leader` | gauge | 1 if this node leads ≥1 tenant group, else 0 (V2 leadership is per-group) |
| `kvexp_put_total` | counter | kvexp engine put operations |
| `kvexp_get_total` | counter | kvexp engine get operations |
| `kvexp_txn_commit_total` | counter | kvexp engine transaction commits |
| `kvexp_durabilize_total` | counter | kvexp engine durabilize calls |
| *(~15 kvexp_* counters total — commit 4ea5dd0)* | counter | various kvexp engine operation counts |
| `kvexp_durabilize_duration_seconds` | histogram | kvexp durabilize latency (`_bucket{le=…}` / `_sum` / `_count`, in seconds) |
| `kvexp_snapshot_open_duration_seconds` | histogram | kvexp snapshot open latency (`_bucket{le=…}` / `_sum` / `_count`, in seconds) |

**What's good about this surface (keep + adopt):**

- The **pipeline-depth gauges** (`h2_*_size`) identify *which phase* of
  the pipeline is stalling — strictly better than a generic
  "active_streams" number. The phased plan below uses these in place
  of the typical USE-method gauges.
- The **conservation-pair pattern** (every `consumed` paired with its
  `returned{src=...}` and a `outstanding` gauge for the delta) is a
  habit worth reusing for new instrumentation. Anything resource-poolish
  (db handles, fd-backed buffers, JS contexts, blob-fetch slots) gets
  the same shape.
- `io_admission_denied_total` already operationalizes the
  "fail loud on resource exhaustion" principle.

**Limitations of today's surface:**

- Worker-only. Files-server, log-server, sse-server expose nothing.
- No `node_id` / `worker_id` labels — a fleet scrape can't distinguish
  nodes, much less workers within a node.
- No rove_*-shaped histograms; the only histograms today are the two
  kvexp_*_duration_seconds engine histograms. No request/handler latency
  SLIs.
- No raft signals beyond `is_leader` (no term, commit index, apply
  lag, follower lag, proposal counts, propose→commit latency).
- No blob backend, schedule server, snapshot, or JS-runtime metrics.
- Root-token auth — handing that to a scraper is unacceptable.

## 2. Cross-cutting prerequisites (P0)

These aren't "the metrics" — they're the substrate. Without them, every
later phase rebuilds the same plumbing. P0 is one focused PR (auth +
labels) and one design pass (histogram primitive + exemplar format
choice).

### 2.1 Scrape auth model

Extend the existing services-JWT pattern with a `scrape` cap. The
Grafana Agent / Alloy holds a long-lived JWT minted at deploy time;
the `/_system/metrics` handler accepts root-bearer **or** services-JWT
with `caps: ["scrape"]`. Revocable via the JWT secret rotation that
already exists.

Rejected alternatives:
- Unauthenticated second listener on an internal-only port: another
  port to manage, another set of firewall rules, leaks if the
  internal boundary moves.
- Static API key: another secret-handling story to invent.

### 2.2 Node + worker labels

Stamp `node_id="..."` and `worker_id="..."` on every series in
`handleMetrics`. `node_id` from `LOOP46_NODE_ID` env (already required
by raft); `worker_id` from the existing per-thread index. Trivial
string-interp in the existing `w.print` calls. From this point on,
every new metric inherits these labels.

Grafana Cloud's `external_labels` should additionally stamp `cluster`
and `region`. Those are scrape-side, not emitted by the worker.

### 2.3 Histogram primitive

Build `metrics.zig` shared across the workspace with one type:

```zig
pub fn Histogram(comptime buckets: []const f64) type { ... }
```

Implementation: bucketed `Atomic(u64)` + `_sum` + `_count`, emitted as
`*_bucket{le="..."} N`. Default bucket set (geometric, sub-second
through 10s) covers every SLI we'll add in P1/P2:

```
[0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
```

Same buckets across all sub-second SLIs so one set of recording rules
covers them. Blob ops get a longer tail (geometric out to 60s).

NB: a private bucketed-histogram emitter (`writeKvexpHistogram`, fixed
nanosecond bucket bounds from `kv_mod.KvexpHistogram`) already exists in
`worker_dispatch.zig` — the shared `metrics.zig` should generalize/absorb
it, not introduce a parallel primitive.

### 2.4 Exemplar plumbing

The pivot enabler. Switch the metrics endpoint's `Content-Type` to
OpenMetrics text (`application/openmetrics-text; version=1.0.0;
charset=utf-8`) and attach exemplars to histogram samples:

```
rove_http_request_duration_seconds_bucket{le="0.1"} 423 # {trace_id="...",tenant_id="...",request_id="..."} 0.087 1715600000
```

Histogram primitive carries one exemplar slot per bucket, overwritten
on each new sample (Prometheus-standard "last value wins"). The cost
is one atomic store on the hot path; the value is the trace_id /
tenant_id / request_id pointer.

P0 lands the format change with empty exemplars. The slot fills in
once §2.5 ships.

### 2.5 Tracing seam

Generate a 128-bit `trace_id` per inbound request (we already have
`request_id`). Propagate `traceparent` (W3C trace context) on outgoing
`http.send`. Don't ship spans yet — just thread the ID through the
request lifecycle so exemplars can carry it.

Spans-to-OTLP is a Phase 2 follow-on; the seam in P0 is the ID
generator + the field on the per-request record.

## 3. Phase 1 — "wake oncall" minimum

The signals that let an on-call know something is on fire. Low
cardinality, low code surface, no histograms required (counters and
gauges only). One PR per subsystem; they can land in any order after
P0.

| metric | type | source | labels |
|---|---|---|---|
| `rove_build_info` | gauge=1 | rewind.js main | version, commit, zig_version |
| `rove_panics_total` | counter | `std.builtin.Panic` shim | subsystem |
| `rove_raft_apply_lag_entries` | gauge | rove-kv (commit_index − last_applied) | — |
| `rove_raft_leader_changes_total` | counter | rove-kv (bump on raft\_become\_leader) | — |
| `rove_raft_proposals_total` | counter | apply.zig propose path | outcome ∈ {committed, rejected, timeout} |
| `rove_http_requests_total` | counter | h2 send path | route\_class, status\_class, method |
| `rove_blob_op_errors_total` | counter | rove-blob | backend, op, kind |
| `rove_schedule_timer_drift_sum` + `_count` | summary-ish | schedule-server thread | — |

**`route_class` rules:** small enum, **not** the customer's dynamic
route. Buckets: `handler` (any customer request), `_system/*`,
`_admin/*`, `_files/*`. Anything route-template-dynamic is aggregated
into `handler`.

**`status_class` rules:** `1xx` / `2xx` / `3xx` / `4xx` / `5xx`. Five
values.

**Existing gauges to keep emitting unchanged:** every `h2_*_size`, every
`io_recv_*`, `io_admission_denied_total`, `raft_is_leader`. Per the
"don't revert diagnostic state" memory.

### 3.1 Phase 1 alert candidates

The on-call rotation's starting set. Calibrate thresholds post-deploy:

1. `increase(rove_panics_total[5m]) > 0` — should always be 0
2. `rate(rove_raft_leader_changes_total[5m]) > 0.2` — more than 1
   change per 5min sustained
3. `rove_raft_apply_lag_entries > 1000 for 2m`
4. `sum(rate(rove_http_requests_total{status_class="5xx"}[5m])) /
   sum(rate(rove_http_requests_total[5m])) > 0.01`
5. `rate(rove_blob_op_errors_total[5m]) > 0`
6. Pipeline-depth saturation: `h2_request_out_size` or
   `h2_raft_pending_size` above threshold for N minutes (thresholds
   are SO\_REUSEPORT + worker count + backpressure dependent — set
   from observed steady-state, not a priori)

## 4. Phase 2 — SLI completeness

Histograms with exemplars. This is the phase where the
"p99 spike → trace → replay viewer" pivot actually works end-to-end.
Pre-req: §2.3 histogram primitive and §2.4 exemplar plumbing landed.

| metric | exemplar carries |
|---|---|
| `rove_http_request_duration_seconds{route_class, status_class}` | trace_id, tenant_id, request_id |
| `rove_js_handler_duration_seconds{outcome}` (ok/threw/timeout/oom) | same |
| `rove_raft_propose_to_commit_seconds` | trace_id only |
| `rove_blob_op_seconds{backend, op}` | trace_id only |
| `rove_h2_tls_handshake_seconds` | — (no request context yet) |
| `rove_schedule_timer_drift_seconds` (upgraded from P1 summary) | trace_id of triggering envelope |

Also: ship the **Grafana Agent / Alloy config** under
`docs/grafana/alloy.river` (or equivalent) so the scrape-side story is
reproducible. Endpoints, the `scrape` cap JWT path, external_labels for
`cluster` / `region`. Dashboards land as JSON exports in
`docs/grafana/dashboards/` so they're reviewable in PRs.

## 5. Phase 3 — saturation, cost, capacity

Doesn't page anyone but matters for capacity planning + S3 bill
tracking. Pure additions — no new primitives needed beyond what P0/P2
provide.

| metric | what it answers |
|---|---|
| `rove_blob_egress_bytes_total{backend, op}` | the S3 bill driver |
| `rove_kv_apply_duration_seconds{envelope_type}` | which envelope is slow; sanity for [[project_kv_batched_dispatch]] |
| `rove_kv_dispatch_queue_depth{worker_id}` | continuation of the batched-dispatch story |
| `rove_kv_dispatch_batch_size{worker_id}` (histogram) | batch effectiveness |
| `rove_kv_db_size_bytes{kind}` (root/schedules/app_aggregate) | growth tracking; **never per-tenant** |
| `rove_snapshot_create_seconds` / `_install_seconds` / `_bytes` | instrument the [[project_snap_catchup_state]] machinery |
| `rove_snapshot_age_seconds` | implies raft-log bloat if it grows |
| `rove_raft_log_entries`, `rove_raft_term`, `rove_raft_commit_index` | the "show me what raft is doing" board |
| `rove_raft_follower_lag_entries{peer}` | per-peer (peer count is 3–5) |
| `rove_io_uring_sq_depth{worker_id}` | saturation, paired with submit/complete counters |

`{kind}` values for `rove_kv_db_size_bytes` are fixed: `root`,
`schedules`, `app_aggregate`. The third is a **sum across all
per-tenant app.db files** — never one series per tenant.

## 6. Phase 4 — other surfaces

Lift `handleMetrics` into a shared `metrics.zig` module so files-server,
log-server, and sse-server each expose their own `/metrics`. The
schedule-server thread shares worker-0's endpoint (same process).

Each standalone gets:

- **Common:** `rove_http_requests_total`, `rove_http_request_duration_seconds`, `rove_panics_total`, `rove_build_info`.
- **files-server:** `rove_files_server_compile_seconds` (histogram), `rove_files_server_uploads_total{outcome}`, `rove_files_server_deploys_total{outcome}`.
- **log-server:** `rove_log_server_query_seconds` (histogram, exemplars), `rove_log_server_query_bytes_scanned_total{backend}` — the S3 list/get amplification signal.

## 7. Sequencing

If observability is on the launch critical path:

1. **One PR** — §2.1 scrape auth + §2.2 node/worker labels. Unblocks
   scraping. Small.
2. **One PR per Phase 1 subsystem** (raft, http, blob, schedule,
   panics/build_info). Independent; mergeable in any order. Each is
   small.
3. **Grafana Cloud setup + alert rules** in parallel with (2).
   Dashboards committed as JSON.
4. **Histogram primitive + exemplar plumbing** (§2.3 + §2.4 + §2.5) as
   a single Phase 2 unblock PR. The single largest engineering item in
   the plan — warrants a separate design pass.
5. Phase 2 metrics on top.
6. Phase 3 + Phase 4 — only after launch experience tells us which
   gap actually hurt.

Phase 1 is roughly a week of focused work; the calibration + alert
tuning takes longer than the instrumentation. Phase 2's exemplar
plumbing is the highest-leverage chunk in the plan — it's what makes
the operator/customer split actually usable.

## 8. Out of scope (do not build, even on request)

- **Per-tenant labels on any Prometheus metric.** Covered above; the
  load-bearing constraint.
- **Customer-facing dashboards in Grafana.** Customers see usage via
  the admin UI, which reads the replay store.
- **A homegrown TSDB / push gateway.** Pull-scrape from Grafana Agent
  works fine at our scale.
- **In-process span aggregation.** Push spans straight to OTLP via
  Agent when we ship them.
- **Per-counter histogram series.** Almost every counter we want a
  latency view on should already be in §4 as an explicit histogram;
  don't multiply.
