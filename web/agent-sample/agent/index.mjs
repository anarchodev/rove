// Reference browser-agent handler — the server-side "brain" for the
// in-page SDK (web/rove-agent.js). It runs entirely inside the held
// WebSocket chain:
//
//   onMessage(snapshot)  → think(): on.fetch the LLM, park with next()
//   onLLM(fetch result)  → browser.act(next action), park again
//   page executes, auto-sends a fresh snapshot → onMessage(snapshot) …
//
// Nothing here is platform magic — it composes the four primitives:
//   • browser.*  — frame the page's snapshot, send actions (the shim)
//   • on.fetch   — call the LLM with the CUSTOMER's own key (vendor
//                  wiring lives here, not in the shim)
//   • kv         — durable per-session loop state (goal + transcript)
//   • next()     — hold the connection across LLM round-trips
//
// Swap the `on.fetch` block for any model; the rest is model-agnostic.
// The LLM endpoint/key/model are read from `_config/*` so an operator
// (or the smoke harness) can point this at a stub.

const SYSTEM_PROMPT =
  "You drive a web UI on the user's behalf. Each turn you receive a " +
  "structural snapshot of the page: one line per element as " +
  "`[ref] role \"name\" = value (state)`. Choose exactly ONE tool call " +
  "to make progress toward the goal, targeting elements by their ref. " +
  "When the goal is complete, reply with a short text message and NO " +
  "tool call.";

// Customer-configured policy: actions touching an element whose
// accessible name matches this get gated behind a user confirmation
// (browser.confirm → the SDK shows an approve/deny prompt).
const DESTRUCTIVE_RE =
  /\b(delete|remove|pay|buy|purchase|checkout|confirm|submit|send|transfer)\b/i;

const MAX_TRANSCRIPT = 24; // bound kv growth (see trim())

// ── Activation: one inbound WS frame from the page ──────────────────
export function onMessage() {
  const frame = browser.message(request);
  const ctx = request.ctx || {};
  if (!frame) return next(ctx);

  switch (frame.t) {
    case "hello": {
      // New run: reset the transcript, stash the goal.
      const sid = frame.sid;
      kv.set(`agent/${sid}/goal`, frame.goal || "");
      kv.delete(`agent/${sid}/msgs`);
      browser.status("connected");
      return next({ sid }); // the page sends its first snapshot next
    }
    case "snapshot":
      return think(frame, ctx);

    case "screenshot":
      // The pixels the brain asked for came back — feed them to the model.
      return onShot(frame, ctx);

    case "confirm_result": {
      const sid = ctx.sid;
      if (frame.approved && ctx.pending_action) {
        browser.act(ctx.pending_action);
        return next({ sid, pending_tool_id: ctx.confirm_tool_id });
      }
      // Denied: ask the page for a fresh snapshot and tell the model on
      // the next turn that its action was rejected.
      browser.status("action cancelled");
      browser.act({ op: "snapshot", id: ctx.confirm_tool_id });
      return next({ sid, pending_tool_id: ctx.confirm_tool_id, denied: true });
    }

    case "result":
      // The action ran; the page auto-sends a fresh snapshot which
      // re-enters think(). Nothing to do on the bare result.
      return next(ctx);

    case "bye":
      return "bye"; // terminal — release the chain

    default:
      return next(ctx); // forward-compat: ignore unknown frames
  }
}

// ── Decide the next action: call the LLM with the current view ──────
function think(frame, ctx) {
  const sid = frame.sid || ctx.sid;
  const goal = kv.get(`agent/${sid}/goal`) || "";
  const view = "Page:\n" + browser.render(frame);

  // Remember ref → name for this snapshot so we can apply the
  // destructive-action policy when the model picks a ref.
  const refs = {};
  for (const e of frame.elements || []) if (e.name) refs[e.ref] = e.name;

  // Did a screenshot the brain requested just land (threaded by onShot on
  // the chain ctx)? If so, the tool_result for that call is the IMAGE (plus
  // the fresh structural view for grounding) — the model sees the pixels it
  // asked for. onLLM does the durable blob.put (think() stays read-only).
  const pendingShot = ctx.shot || null;

  // Claude requires the turn after a tool_use to LEAD with a matching
  // tool_result; the first turn is a plain user message. We build it but
  // do NOT persist here — this activation stays READ-ONLY so on.fetch can
  // bind from the held WS chain (a writing frame can't). onLLM persists the
  // user turn + refs on resume (durable-brain / ephemeral-hands).
  let userTurn;
  if (pendingShot && pendingShot.tool_id) {
    let content;
    if (pendingShot.data) {
      content = [
        { type: "image",
          source: { type: "base64", media_type: pendingShot.mime, data: pendingShot.data } },
        { type: "text", text: view },
      ];
    } else {
      content = "Screenshot unavailable: " + (pendingShot.error || "unknown") + ".\n" + view;
    }
    userTurn = {
      role: "user",
      content: [{ type: "tool_result", tool_use_id: pendingShot.tool_id, content }],
    };
  } else if (ctx.pending_tool_id) {
    const note = ctx.denied ? "User DENIED the previous action. " : "";
    userTurn = {
      role: "user",
      content: [{ type: "tool_result", tool_use_id: ctx.pending_tool_id, content: note + view }],
    };
  } else {
    userTurn = { role: "user", content: `Goal: ${goal}\n\n${view}` };
  }
  return callLLM(sid, userTurn, {
    sid, user_turn: userTurn, refs,
    // onLLM (a write activation) stores the pixels durably; think() is
    // read-only so it can't.
    record_shot: pendingShot && pendingShot.data
      ? { mime: pendingShot.mime, data: pendingShot.data } : null,
  });
}

// ── The page returned a screenshot the brain requested ──────────────
// The LLM turn that carries the pixels into the model MUST be issued from
// a read-only frame (a binding on.fetch can't come from one that writes),
// so onShot doesn't call the model itself: it threads the pixels forward
// on the chain ctx and bounces through a fresh snapshot. think() (read-
// only) then sends the image as the screenshot tool_result; onLLM does the
// durable blob.put. No kv needed — the held WS chain threads ctx across
// frames (request.ctx), same as a fetch resume.
function onShot(frame, ctx) {
  const sid = ctx.sid;
  const img = browser.image(frame);
  const shot = (img && img.ok)
    ? { tool_id: ctx.pending_tool_id, mime: img.mime, data: img.data }
    : { tool_id: ctx.pending_tool_id, error: (img && img.error) || "unknown" };
  browser.status(img && img.ok ? "looking at the screen…" : "screenshot unavailable");
  browser.act({ op: "snapshot" });
  return next({ sid, pending_tool_id: ctx.pending_tool_id, refs: ctx.refs || {}, shot });
}

// ── Shared LLM turn: hold the chain, call the model, wake onLLM ──────
// READ-ONLY (no kv writes) so the on.fetch can bind to the held WS chain.
function callLLM(sid, userTurn, parkCtx) {
  const msgs = load(sid);
  const screenshots = kv.get("_config/screenshots") === "1";
  browser.status("thinking…");

  const endpoint = kv.get("_config/llm_endpoint") || "https://api.anthropic.com/v1/messages";
  const key = kv.get("_config/anthropic_api_key") || "";
  const model = kv.get("_config/llm_model") || "claude-opus-4-8";

  // Connection-scoped: binds to THIS held WS chain; the result wakes
  // onLLM while we still hold the socket. The key is the CUSTOMER's.
  on.fetch(
    endpoint,
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model,
        max_tokens: 1024,
        system: SYSTEM_PROMPT,
        // Offer the pixel-screenshot tool only when the operator enabled
        // it (and the page SDK was started with screenshots:true).
        tools: claudeTools(screenshots),
        messages: msgs.concat([userTurn]),
      }),
      timeout_ms: 30_000,
    },
    { to: "onLLM" },
  );
  return next(parkCtx);
}

// ── Activation: the LLM responded ───────────────────────────────────
export function onLLM() {
  const ctx = request.ctx || {};
  const sid = ctx.sid;
  // Bound-fetch surface (handler-shape §7): the response bytes ride
  // `request.body` (a Uint8Array for a bound fetch), with `request.status`
  // / `request.done` at the top level. There is no `request.result`.
  if (!request.done || (request.status || 0) >= 400) {
    browser.status("LLM error " + (request.status || "?"));
    return next({ sid });
  }
  let raw = request.body;
  if (raw && typeof raw !== "string") raw = new TextDecoder().decode(raw);
  let body;
  try { body = JSON.parse(raw || "{}"); } catch (_) { body = {}; }
  const msgs = load(sid);
  if (ctx.user_turn) msgs.push(ctx.user_turn); // persist now (think() was read-only)
  // think() attached the screenshot as the tool_result; store the pixels
  // content-addressed now (the durable record + replay), a write think()
  // couldn't do while issuing the LLM fetch read-only.
  if (ctx.record_shot) recordShot(sid, ctx.record_shot);
  msgs.push({ role: "assistant", content: body.content });
  save(sid, msgs);

  const tu = (body.content || []).find((b) => b && b.type === "tool_use");
  if (!tu) {
    // No tool call → the model is done; surface its text.
    const text = (body.content || [])
      .filter((b) => b.type === "text")
      .map((b) => b.text)
      .join(" ")
      .trim();
    browser.done(text || "Done.");
    return next({ sid });
  }

  // Tool name IS the op; the input carries ref/text/path.
  const action = Object.assign({ op: tu.name, id: tu.id }, tu.input || {});

  // Policy gate: confirm before acting on a destructive-looking element.
  const refs = ctx.refs || {};
  const name = (action.ref != null && refs[action.ref]) || "";
  if (DESTRUCTIVE_RE.test(name)) {
    browser.confirm({ id: tu.id, prompt: `Allow “${tu.name}” on “${name}”?`, action });
    return next({ sid, confirm_tool_id: tu.id, pending_action: action });
  }

  browser.act(action);
  // Forward refs so a screenshot result (which brings no fresh snapshot)
  // can still apply the destructive-action policy on the next turn.
  return next({ sid, pending_tool_id: tu.id, refs });
}

// ── Activation: the page's connection dropped ───────────────────────
export function onDisconnect() {
  // The live tab is ephemeral; durable transcript stays in kv so a
  // reconnect can resume. Nothing to tear down here.
  return "bye";
}

// ── helpers ─────────────────────────────────────────────────────────

// Adapt the shim's vendor-neutral tool list to Claude's tool schema.
// Inference: `?` in a param description → optional; "number" → number.
// `screenshots` toggles the opt-in pixel-capture tool.
function claudeTools(screenshots) {
  return browser.tools({ screenshots: !!screenshots }).map((t) => {
    const properties = {};
    const required = [];
    for (const pname of Object.keys(t.params)) {
      const spec = t.params[pname];
      properties[pname] = { type: /number/.test(spec) ? "number" : "string", description: spec };
      if (!/\?/.test(spec)) required.push(pname);
    }
    return { name: t.op, description: t.desc, input_schema: { type: "object", properties, required } };
  });
}

function load(sid) {
  try { return JSON.parse(kv.get(`agent/${sid}/msgs`) || "[]"); }
  catch (_) { return []; }
}

function save(sid, msgs) {
  kv.set(`agent/${sid}/msgs`, JSON.stringify(trim(msgs)));
}

// Store a screenshot content-addressed and index it in the durable
// step-log (idempotent — same pixels → same hash). `shot` is
// `{mime, data}` with `data` a base64 string. Non-fatal on failure: the
// model still gets the inline pixels; this is the record, not perception.
function recordShot(sid, shot) {
  try {
    const hash = blob.put(base64url.decode(shot.data), { content_type: shot.mime });
    kv.set(`agent/${sid}/shots/${hash}`, JSON.stringify({ hash, mime: shot.mime }));
  } catch (_) {}
}

// Keep the transcript bounded. Drop from the front but never strip a
// leading tool_result (it would orphan the prior assistant tool_use and
// the API rejects it) — walk forward to the next plain user turn.
function trim(msgs) {
  if (msgs.length <= MAX_TRANSCRIPT) return msgs;
  let start = msgs.length - MAX_TRANSCRIPT;
  while (start < msgs.length) {
    const m = msgs[start];
    const leadsWithToolResult =
      Array.isArray(m.content) && m.content[0] && m.content[0].type === "tool_result";
    if (m.role === "user" && !leadsWithToolResult) break;
    start++;
  }
  return msgs.slice(start);
}
