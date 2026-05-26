# rewind.js dashboard + replay-shell design brief

This document exists so a design pass — paste it into a fresh
Claude conversation, sketch in HTML/CSS — can produce mockups that
fit the rest of the product without having to re-derive the
context. The brief is intentionally not pixel-prescriptive: it
locks the *purpose* of each page, the *data* each page must show,
and a *visual stance* the whole app should share, but the layout,
typography, motion, and information hierarchy are open.

If you're the design Claude: build the pages as static HTML
prototypes (or component sketches in whichever framework you find
ergonomic). Optimize for the developer reading them, not for
generic dashboard aesthetics. We can wire the production code to
match whatever lands.

If you're the rove Claude: this is a **living** brief — when the
real implementation lands and shapes a decision, update the
relevant section so the next design pass doesn't fight the code.

**Status:** Living brief; some anchors predate the WASM-only replay
shell (commit 8565634), the `web/*/_static/` path move (commits
3c0f456/df83636), and the rewind.js rename.

---

## 1. Product context (the one-paragraph version)

**rewind.js** sells the rove substrate as: *a backend in 30 seconds —
JS handlers, KV store, free static hosting.* The deeper identity:
**purely functional serverless**. Every customer handler is a pure
function of `(request, kv_snapshot)`. Every external effect is a
declarative `Cmd` (webhook.send, email.send, events.emit, etc.)
that resolves asynchronously. Every captured request is replayable
with breakpoints, deterministically, against the same code path
that ran in production.

The dashboard is the developer's window into all of that. It is
also dogfooded — `app.rewindjs.com` is itself an instance, served
the same way customer instances are.

Customer-facing identity primitives the dashboard surfaces:

- **C1** — the developer who signed up.
- **C2** — the developer's end users hitting `{name}.rewindjs.app`.
- **Instance** — a single deployment unit. C1 typically owns one
  (`{name}`) and the special singleton `__admin__` (the dashboard
  itself).
- **Deployment** — an immutable bundle of source + compiled
  bytecode + static assets pinned by content-addressed id.
  Releases shift the `_deploy/current` pointer; previous
  deployments stay reachable for replay of historical requests.
- **Tape** — captured non-determinism (kv reads, Date.now,
  Math.random, crypto.getRandomValues, module resolution, request
  body) attached to every log record. The shape replay consumes.

---

## 2. Audience + tone

- The reader is a working developer. They know what an HTTP
  request looks like. They've seen log dashboards before. Skip
  hand-holding copy.
- The product's hook is "I can step through a real production
  request right now." Every page should make that one click away.
- Density is fine. Empty space without purpose is not. The dev
  audience reads dense tables better than they read cards with
  three-line subtitles.
- One terminal-typeface accent for code / paths / ids is desirable
  but should not overwhelm the chrome. Body sans, monospace for
  IDs and code blocks.

---

## 3. Visual stance (the constraints — keep these stable)

These are the few things the whole app should share so it reads as
one piece. Everything else is open.

- **Light theme is the default.** Dark theme is a follow-up, not a
  toggle in v1.
- **Layout uses a single neutral palette plus one accent.** Pick a
  restrained accent (current code uses muted forest green
  `#2e7d32` for success, brick red `#b00020` for error; a single
  brand-accent for "primary action" / "current selection" is yours
  to pick).
- **No hover-only affordances for primary actions.** Buttons are
  buttons. Rows that open a drawer can have hover hints, but the
  action must be obvious without hover (mobile / keyboard).
- **Mono font for**: instance IDs, request IDs, key names, file
  paths, line numbers, deployment hex ids, hashes, atom values.
- **Sans font for**: page chrome, prose, headings, button labels.
- **Time displays come in two flavors**: a relative form
  ("3m ago", "yesterday") and an absolute ISO/local form in a
  `title="..."` attribute for hover. Pick a renderer once, reuse
  it.
- **Status outcomes have a stable color set across the app**:
  success / warning / error / pending — same colors on instance
  list, log rows, replay headers, anywhere outcome appears.

---

## 4. Existing pages (where the code is today)

The dashboard is a hash-routed SPA served by the `__admin__`
tenant at `app.<public_suffix>/`. The replay shell is served by
the `__replay__` tenant at `replay.<public_suffix>/` and receives
its bundle via `postMessage` from the dashboard tab.
Source: `web/admin/_static/` and `web/replay/_static/`.

### 4.1 `#/login` — login / signup

File: `web/admin/_static/pages/login.js`

Two-mode landing:

- **Sign in** — paste an opaque session token. Calls `/v1/login`,
  redirects to `#/instances`.
- **Sign up** — name + email. Calls `/v1/signup`. In dev (no email
  backend), the response carries `magic_link` inline; in prod it's
  emailed. Clicking the magic link redeems via `/v1/auth?mt=<hex>`,
  sets the session cookie, redirects to `#/instances`.

What design can do: prettier copy, better empty-state framing of
why the user is here, marketing-quality "you'll be live in 30
seconds" guarantee. The two-mode toggle pattern can change.

### 4.2 `#/instances` — instance list + admin actions

File: `web/admin/_static/pages/instances.js`

What's there:

- Tenant list (id, domain aliases, age, action: delete).
- Form: **Create instance** (id only).
- Form: **Assign domain** (host → instance_id).

What it doesn't yet have but should: live status per instance
(last request timestamp, error rate, deployment id), a one-click
"open in dashboard" path, search/filter at scale.

### 4.3 `#/instance/<id>` — per-instance dashboard

File: `web/admin/_static/pages/instance.js`. Three tabs:

#### 4.3.1 Logs tab

Recent request log, newest-first. Each row:

| time (rel) | dep_id | method | path | status | duration | outcome | actions |

Actions per row:
- **Replay** — opens the WASM scrubber in a new tab.
- **⎘** — copy request id.

Row click opens a side drawer with the full record JSON, console
log, exception text, response headers.

Pagination is cursor-based ("Load older"). No search yet.

What design can do: filter chips (status, outcome, dep_id, method),
inline expanded view rather than (or in addition to) the drawer,
a sparkline of recent error rate at the top.

#### 4.3.2 KV tab

Two-pane KV browser:

- Left: key list with prefix search.
- Right: editor for the selected key's value. Save / Delete /
  Refresh.

Pagination on the key list. New key uses the same form.

What design can do: better tree-style prefix navigation
(`_deploy/`, `_static/`, `session/...` etc.), value-type inference
(JSON pretty-print vs raw bytes), diff view on save, a way to
filter by prefix without re-typing.

#### 4.3.3 Code tab

Per-file editor (CodeMirror). The left pane lists current
deployment's handler files; the editor saves to a draft and
"Deploy" creates a new release.

What design can do: clearer separation between "currently
deployed" and "draft I'm editing," a history strip (previous
deployments + ability to roll back, since each deployment id is
content-addressed and reachable forever via files-server's
`/<inst>/deployments/<hex>`), a static-asset uploader for the
`_static/*` paths.

### 4.4 Replay shell

The replay shell lives at `replay.<suffix>/` under the `__replay__`
tenant.

#### 4.4.1 `/` — WASM scrubber

Files: `web/replay/_static/index.html` + `web/replay/_static/wasm-app.mjs`
+ `web/replay/_static/rtap.mjs` + `web/replay/_static/cursor.mjs`
(CursorEngine) + `web/replay/_static/qjs_arena_wasm.{js,wasm}`.
Boots arenajs compiled to WebAssembly and runs the captured handler
through the SAME engine that ran it in production. The runtime
exposes a trace stream (`FUNC_ENTER` / `FUNC_EXIT` / `LINE` /
`THROW`) and a stack walker (`host_state` returns frame snapshots
with args / locals / closure-referenced vars). The page renders a
call-tree timeline (left rail = modules, middle = timeline, right =
output) with source view, variable panel, and stepping controls.

**Landed** (design can treat as present):

- **Source view** — third column showing `bundle.modules[entry].source`
  with line numbers, syntax highlighting; current-line cursor that
  follows the selected timeline event.
- **Variable panel** — fourth column showing the captured stack
  snapshot (one collapsible block per frame with args + locals +
  closure vars). Updates when a timeline row is clicked.
- **Drill toggle** — switch between SCAN mode (function-level
  timeline) and DRILL mode (per-line). The data is the same wire
  format; UI just renders denser.
- **Stepping** — step-into / step-over / step-out; works by
  re-running from start with a different stop predicate.

**Still open** (design opportunities — see
[`replay-wasm-plan.md`](replay-wasm-plan.md) §8 for the
implementation-side roadmap):

- **Breakpoints** — gutter clicks on source lines; the next replay
  rerun stops there.
- **Side-effect inspector** — visualize every `webhook.send` /
  `email.send` / `events.emit` the handler queued, since this is
  the differentiator (these never executed inline; they're listed
  in the response context).

---

## 5. Pages that don't exist yet but should

These are gaps the product needs filled. Each is an open canvas
beyond the minimum data shape listed.

### 5.1 Marketing site at the apex

`rewindjs.com` is for marketing only — no auth, no API. It needs:

- A hero that conveys "purely functional serverless" + "step
  through your production requests" without sounding like every
  other serverless landing page.
- A live `<iframe>` showing the WASM scrubber stepping through a
  canned sample request. This is the "show, don't tell" pitch.
- A signup CTA that drops the user into `app.rewindjs.com/#/login`
  in signup mode.
- Pricing — a section is fine, real pricing TBD.
- Docs link to a dedicated docs site or a `/docs` subpath.

### 5.2 Onboarding / first-deploy flow

After magic-link redemption, the user lands at `#/instances`. The
better landing is a guided one-shot: "your API is at
`{name}.rewindjs.app/`, here's the starter code, click 'open in
code editor' to start editing." Possibly inline with `#/instances`
for returning users.

### 5.3 Domains page

The current `#/instances` page mixes "list tenants" with "assign a
domain". For users with multiple custom domains, a separate
`#/instance/<id>/domains` (or a top-level `#/domains`) page is
better:

- All registered domain aliases for an instance.
- Wildcard suffix (`{id}.rewindjs.app`) shown as the always-on
  default.
- "Add domain" + cert / DNS hints.

Data lives in the root store under `domain/{host}`. Backend API:
`tenant.assignDomain`, `tenant.listDomains`.

### 5.4 Secrets / config page

The product decision was *no env API* (see `PLAN.md` §2.2) —
secrets are just KV entries under whatever prefix the customer
chose. But a dashboard convention for hiding "looks-like-a-secret"
values would be nice:

- Mask values matching `_config/*`, `secrets/*`, `_secret/*` (or
  whatever).
- "Reveal" toggle per row.
- Default-mask + click-to-reveal so over-the-shoulder readers
  don't accidentally see them.

This is a UI flag on the existing KV tab, not a new storage shape.

### 5.5 Scheduled tasks / cron

rewind.js has a `schedule.upsert(id, when, payload)` primitive. There's
no UI today. What it should show:

- Active schedules (id, next-fire, cron expression if any, target
  handler).
- Recent fires (id, fired-at, status, response).
- Manual cancel.

Data lives in `schedules.db` (cluster-wide store). Records ride
raft envelopes 8/9/10/11.

### 5.6 Webhooks / http.send dashboard

`webhook.send` and `http.send` are the Cmd primitives for outbound
HTTP. Each send is captured in the log as a side-effect record on
the request that issued it. UI needs:

- List of recent sends across the instance (target host, status,
  duration, request_id that issued it).
- Click → expand to see request body, response body, headers,
  retry history.
- Filter by target host / by failing-only / by issuing handler.

Data lives in tenant's log records (the `webhook_*` and `http_*`
event entries on each captured request).

### 5.7 Email log

`email.send` is captured similarly. Same shape as webhooks but
filtered to email sends — recipient address, subject, status from
the provider (Resend), bounce reason if any.

### 5.8 Live event stream / SSE preview

The platform mints a `__Host-rove_sid` cookie for every browser
hitting a tenant; `events.emit(session_id, event)` pushes to that
session.
The dashboard could expose a "tail the live event stream for this
instance" mode — useful when building real-time features.

### 5.9 Account / billing / settings

Pre-launch stub at minimum:

- Account: email on file, change-email flow, sign-out from all
  sessions.
- Billing: not implemented yet, page is a placeholder.
- API tokens: list of long-lived bearer tokens (the fallback path
  for external clients per PLAN §2.2). Create / revoke. Show
  secret once on creation.

### 5.10 Status / health (operator-facing, secondary)

Not a customer-facing page exactly. The metric exporter is at
`/_system/metrics` (Prometheus text). A dashboard view of the
useful metrics — leader id, raft commit lag, h2 queue depths,
kvexp durabilize rate — would help during incidents. Could live
behind a root-token gate.

---

## 6. Data shapes (so mockups don't lie)

These are the canonical shapes the design should bind to. Real
endpoints are in `web/admin/api.js`; canonical Zig sources in
parens.

### LogRecordSummary (one row in the logs tab)

```ts
{
  request_id: string,         // 16-hex
  received_ns: number,        // ns since unix epoch
  duration_ns: number,
  method: string,             // "GET" | "POST" | ...
  path: string,               // "/whatever?fn=handler"
  host: string,
  status: number,             // 200 / 4xx / 5xx
  outcome: "ok" | "handler_error" | "kv_error"
         | "no_deployment" | "timeout" | "fault",
  deployment_id: number,      // u64
}
```

### LogRecordFull (drawer + replay bundle source)

```ts
LogRecordSummary & {
  console: string,            // captured console.log output
  exception: string,          // empty on success
  tapes: {                    // all base64 strings, may be null
    seed: number,               // §9: per-request PRNG seed (u64)
    kv_tape_b64?: string,
    date_tape_b64?: string,
    module_tree_b64?: string,
    request_body_b64?: string,
    request_body_truncated?: boolean,
    // No response_body field — replay re-produces the response
    // deterministically from (request body + tapes + source).
    // Math.random / crypto.* draw from the per-context PRNG
    // seeded by `seed`; no dedicated tape channels (§9).
  },
}
```

### ReplayBundle (what the replay shell receives)

See `web/admin/api.js::composeReplayBundle`. The shape the design
needs to assume:

```ts
{
  request_id, deployment_id, received_ns, duration_ns,
  request: { method, path, host, body_bytes, body_truncated },
  response: { status, outcome, console, exception },
  entry_path: string,         // e.g. "index.mjs"
  entry_source: string,
  modules: Array<{
    path: string, hash: string, source: string
  }>,
  tape_blobs: {
    kv?: Uint8Array,
    date?: Uint8Array,
    math_random?: Uint8Array,
    crypto_random?: Uint8Array,
  },
  historical_manifest_missing: boolean,  // true if the deploy was GC'd
}
```

### Instance

```ts
{
  id: string,                 // "acme", "__admin__"
  domains: Array<{ host: string, instance_id: string }>,
}
```

### KvEntry

```ts
{ key: string, value: string }    // both utf-8 strings today
```

### Deployment

`GET /<inst>/deployments/<hex>` returns:

```ts
{
  id: number,
  parent_id: number | null,
  entries: Array<{
    path: string,
    hash: string,
    kind: "handler" | "static",
    content_type?: string,
  }>,
}
```

---

## 7. What you don't need to design

- The wire protocols (HTTP/2 + JSON for the dashboard APIs are
  fixed).
- The auth model (cookies on `app.<suffix>`, signed via the
  worker's session table; the design just consumes "am I logged
  in" state).
- The replay wire format (RTAP — defined in `src/tape/root.zig`
  and parsed by `web/replay/rtap.mjs`; design consumes the
  decoded shape).
- The trace event ABI for the WASM scrubber (kinds + binary
  layouts pinned in `replay-wasm-plan.md` §5).

Design is welcome to propose extensions to these — flag them
explicitly in the mockup notes and the rove side will follow up.

---

## 8. Recommended starting points (in order)

If you want a list of next deliverables in priority order:

1. **Replay-WASM side-effect inspector + breakpoints** (4.4.1). The
   remaining open items; source view + variable panel + stepping are
   landed. Get these right and the pitch is complete.
2. **Logs tab visual refresh** (4.3.1) — the page the most
   customer time is spent on; sparkline + filter chips would land
   well.
3. **Marketing apex** (5.1). Right now there's nothing there.
4. **Domains page** (5.3) and **Secrets convention** (5.4) — small
   wins that clean up `#/instances`'s overloaded form section.
5. **Webhook + email dashboards** (5.6, 5.7) — these need the
   underlying side-effect log shape exposed, but the UI work is
   straightforward once the data is on the wire.

Items 6+ (schedules, SSE, account, status) are post-launch.

---

## 9. How to hand designs back

Output static HTML files (one per page) plus a single shared
stylesheet. If you write JS, keep it framework-free or use
already-vendored libs (CodeMirror is present for the code editor).
Drop the files in a sibling `web/admin-prototype/` (or
`web/replay-prototype/`) so the production paths under
`web/{admin,replay}/` stay untouched until a design is approved
for landing.

When a design is approved, the rove-side claude will port it into
the production paths. The platform reads these from disk at
bootstrap (`--web-root` on files-server-standalone, currently
`web/` in dev), so the swap is "edit files, restart
files-server-standalone, refresh browser" — no `zig build`.
