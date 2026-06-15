// `browser.*` — server-side surface for the in-page browser-agent SDK
// (web/rove-agent.js). The customer's handler receives the page's WS
// frames as `onMessage` activations and replies with `stream.write`;
// this shim is the thin, ergonomic layer over that protocol so the
// handler doesn't hand-roll frame JSON.
//
// It is the "hands/eyes wiring", NOT the brain: the LLM call stays the
// customer's own `on.fetch`/`webhook.send` (their key), and durable
// loop state stays the customer's `kv`. Kept deliberately
// vendor-neutral — `tools()` returns a generic action schema the
// customer adapts to whatever model they drive (the reference handler
// shows the Claude wiring), mirroring the `webhook.send` rule that
// vendor specifics live in customer code, not the primitive.
//
// Scope is same-origin only by construction: the page SDK enforces it
// and the handler only ever talks to its own connections.
//
// Protocol (must match web/rove-agent.js):
//   page → handler : hello | snapshot | result | confirm_result | bye
//   handler → page : act | status | confirm | done
//
// Evaluated as a global script (no module/exports) after the native
// bindings install. IIFE-wrapped: a bare top-level definition corrupts
// the arenajs base-snapshot freeze (see docs/decisions.md §4.4 and the
// regression test in globals.zig).

(function () {
  // Ship one frame to the held page. `stream.write` is commit-gated and
  // inert on a connectionless activation (no socket) — so calling a
  // sender outside a held `onMessage`/inbound chain simply no-ops,
  // matching the rest of the connection-output surface.
  function send(frame) {
    stream.write(JSON.stringify(frame));
  }

  /**
   * Server-side helpers for driving the in-page agent SDK.
   * @namespace browser
   */
  globalThis.browser = {
    /**
     * Decode an inbound agent frame from an `onMessage` activation.
     * Returns the parsed object (`{t, ...}`), or `null` if this
     * activation is not a parseable agent frame.
     *
     * @param {object} request - The handler's `request`.
     * @returns {object|null}
     */
    message(request) {
      const a = request && request.activation;
      if (!a || a.kind !== "ws_message") return null;
      let raw = a.data;
      if (raw == null) return null;
      if (typeof raw !== "string") {
        // Agent frames are JSON text frames; binary is unexpected.
        if (typeof TextDecoder === "undefined") return null;
        try { raw = new TextDecoder().decode(raw); } catch (_) { return null; }
      }
      try { return JSON.parse(raw); } catch (_) { return null; }
    },

    /**
     * Tell the page to perform one action. `action` is `{op, ...}` where
     * `op` is one of the ops from {@link browser.tools}: `click` /
     * `type` / `scroll` / `navigate` / `snapshot`. Include an `id` to
     * correlate the page's `result` frame.
     *
     * @param {object} action - e.g. `{id, op:"click", ref:"12"}`.
     * @returns {void}
     */
    act(action) {
      send(Object.assign({ t: "act" }, action));
    },

    /**
     * Update the page's "agent active" indicator text.
     * @param {string} text
     * @returns {void}
     */
    status(text) {
      send({ t: "status", text: String(text == null ? "" : text) });
    },

    /**
     * Ask the user to approve an action before the page performs it. The
     * page replies with a `confirm_result` frame (`{id, approved}`),
     * which the handler reads via {@link browser.message}. Use for
     * destructive / high-stakes actions (submit, purchase, delete).
     *
     * @param {object} req - `{id, prompt, action}`.
     * @returns {void}
     */
    confirm(req) {
      send(Object.assign({ t: "confirm" }, req));
    },

    /**
     * Signal the agent run is finished and optionally show a final
     * message. Leaves the connection open (the user dismisses via the
     * SDK's kill switch).
     *
     * @param {string} [message]
     * @returns {void}
     */
    done(message) {
      send({ t: "done", message: message == null ? undefined : String(message) });
    },

    /**
     * Render a `snapshot` frame into compact, LLM-friendly text — one
     * line per element: `[ref] role "name" = value (state)`. Pixel-free
     * and token-cheap; this is the default perception channel. Accepts
     * either the whole snapshot frame or its `elements` array.
     *
     * @param {object|Array} snap - A `snapshot` frame or its elements.
     * @returns {string}
     */
    render(snap) {
      const els = Array.isArray(snap) ? snap : (snap && snap.elements) || [];
      const lines = [];
      if (!Array.isArray(snap) && snap) {
        if (snap.url) lines.push("url: " + snap.url);
        if (snap.title) lines.push("title: " + snap.title);
      }
      for (let i = 0; i < els.length; i++) {
        const e = els[i];
        const parts = ["[" + e.ref + "]", e.role || e.tag];
        if (e.name) parts.push(JSON.stringify(e.name));
        if (e.value) parts.push("= " + JSON.stringify(e.value));
        const st = [];
        if (e.state) {
          if (e.state.disabled) st.push("disabled");
          if (e.state.checked != null) st.push(e.state.checked ? "checked" : "unchecked");
          if (e.state.expanded != null) st.push(e.state.expanded ? "expanded" : "collapsed");
          if (e.state.required) st.push("required");
        }
        if (e.visible === false) st.push("offscreen");
        if (e.occluded) st.push("occluded");
        if (st.length) parts.push("(" + st.join(",") + ")");
        lines.push(parts.join(" "));
      }
      return lines.join("\n");
    },

    /**
     * The vendor-neutral action schema the page can execute. Adapt these
     * to your model's tool-call format (the reference handler shows the
     * Claude adaptation). Returned as plain data so it works with any
     * LLM surface.
     *
     * @returns {Array<{op:string, desc:string, params:object}>}
     */
    tools() {
      return [
        { op: "click", desc: "Click an element by its snapshot ref.",
          params: { ref: "string — element ref from the snapshot" } },
        { op: "type", desc: "Type text into an editable element.",
          params: { ref: "string — element ref", text: "string — text to enter" } },
        { op: "scroll", desc: "Scroll an element into view, or the page if no ref.",
          params: { ref: "string? — element ref", dy: "number? — pixels to scroll if no ref" } },
        { op: "navigate", desc: "Navigate to a same-origin path (cross-origin is rejected).",
          params: { path: "string — same-origin URL or path" } },
        { op: "snapshot", desc: "Request a fresh page snapshot.", params: {} },
      ];
    },
  };
})();
