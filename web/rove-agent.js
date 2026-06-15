// rove-agent.js — in-page browser-agent SDK for Rove.
//
// Lets an LLM "brain" see and drive the customer's OWN web app on the
// user's behalf. This script is the *hands and eyes*: it builds an
// enriched DOM/accessibility snapshot, executes ref-targeted actions
// via synthetic events, and renders an always-visible "agent active"
// indicator + kill switch. The *brain* lives server-side in the
// customer's handler (which calls an LLM), or — later — in the user's
// own local Claude via MCP. Either way the protocol below is identical.
//
// Scope is deliberately SAME-ORIGIN ONLY: an agent acting inside the
// customer's own page is roughly equivalent to JS the customer can
// already run there, so there is no new trust boundary, no install,
// and no cross-origin reach. See docs/decisions.md (browser.* scope).
//
//   <script src="/static/rove-agent.js"></script>
//   <script>
//     const agent = rove.agent.start({
//       endpoint: '/_agent',           // WS path on your handler
//       goal: 'Help the user check out',
//       confirm: async (action) => confirm(action.prompt), // optional
//     });
//     // ... agent.stop() to tear down.
//   </script>
//
// Perception is structural by DEFAULT (DOM + geometry + occlusion) —
// cheap, reliable, and enough to operate an app. Pixel screenshots are
// an OPT-IN tier (getDisplayMedia) added separately for visual
// diagnosis. The session id carried on every frame lets the brain
// later correlate browser state with server-side replay (the "why").

(function (root) {
    'use strict';

    const RECONNECT_INITIAL_MS = 250;
    const RECONNECT_MAX_MS = 30_000;
    const SNAPSHOT_MAX_ELEMENTS = 400;   // bound the frame size
    const TEXT_CAP = 240;                // cap any single text field
    const REF_ATTR = 'data-rove-ref';

    class AgentClient {
        constructor(opts) {
            opts = opts || {};
            this._endpoint = opts.endpoint || '/agent';
            this._tokenPath = opts.tokenPath || null; // optional mint step
            this._goal = opts.goal || null;
            this._root = opts.captureRoot || document.body;
            this._confirm = opts.confirm || null;     // async (action) => bool
            this._onStatus = opts.onStatus || null;

            // A client-generated correlation id. The handler maps it to
            // the authoritative rove session; both flow on every frame
            // so the brain can later pull this session's replay.
            this._sid = (root.crypto && root.crypto.randomUUID)
                ? root.crypto.randomUUID()
                : 's-' + Math.abs(hashStr(String(navigator.userAgent) + location.href));

            this._ws = null;
            this._seq = 0;            // monotonic snapshot sequence
            this._refSeq = 0;         // ref allocator
            this._reconnectMs = RECONNECT_INITIAL_MS;
            this._closed = false;
            this._ui = null;
        }

        // ── Public ──────────────────────────────────────────────

        start() {
            this._renderIndicator();
            this._connect();
            return this;
        }

        // Kill switch: stop the agent, drop the socket, remove the UI.
        // Idempotent and final — call start() on a new client to resume.
        stop(reason) {
            if (this._closed) return;
            this._closed = true;
            this._send({ t: 'bye', sid: this._sid, reason: reason || 'stopped' });
            if (this._ws) { try { this._ws.close(); } catch (_) {} this._ws = null; }
            this._removeIndicator();
        }

        // ── Connection ──────────────────────────────────────────

        async _connect() {
            if (this._closed) return;
            try {
                let url = this._wsUrl(this._endpoint);
                if (this._tokenPath) {
                    const r = await fetch(this._tokenPath, { credentials: 'same-origin' });
                    if (!r.ok) throw new Error(`token mint failed: ${r.status}`);
                    const body = await r.json();
                    if (body.token) url += (url.includes('?') ? '&' : '?') +
                        'token=' + encodeURIComponent(body.token);
                }
                const ws = new WebSocket(url);
                this._ws = ws;
                ws.onopen = () => {
                    this._reconnectMs = RECONNECT_INITIAL_MS;
                    this._setStatus('connected');
                    this._send({
                        t: 'hello', sid: this._sid, goal: this._goal,
                        url: location.href, title: document.title,
                        viewport: { w: innerWidth, h: innerHeight },
                    });
                    // Prime the loop with the initial page state.
                    this._sendSnapshot();
                };
                ws.onmessage = (e) => this._onFrame(e.data);
                ws.onclose = () => { if (!this._closed) this._scheduleReconnect(); };
                ws.onerror = () => { /* close handler drives reconnect */ };
            } catch (err) {
                console.warn('rove-agent connect failed:', err);
                this._scheduleReconnect();
            }
        }

        _scheduleReconnect() {
            if (this._closed) return;
            this._setStatus('reconnecting…');
            const delay = Math.min(this._reconnectMs, RECONNECT_MAX_MS);
            this._reconnectMs = Math.min(this._reconnectMs * 2, RECONNECT_MAX_MS);
            setTimeout(() => this._connect(), delay);
        }

        _wsUrl(path) {
            if (/^wss?:\/\//.test(path)) return path;
            const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
            return proto + '//' + location.host +
                (path.startsWith('/') ? path : '/' + path);
        }

        _send(obj) {
            if (this._ws && this._ws.readyState === WebSocket.OPEN) {
                this._ws.send(JSON.stringify(obj));
            }
        }

        // ── Inbound frames from the brain ───────────────────────

        async _onFrame(data) {
            let msg;
            try { msg = JSON.parse(data); } catch { return; }
            switch (msg.t) {
                case 'act':    return this._onAct(msg);
                case 'status': return this._setStatus(msg.text || '');
                case 'confirm': return this._onConfirm(msg);
                case 'done':   return this._onDone(msg);
                default:       return; // forward-compat: ignore unknown
            }
        }

        async _onAct(msg) {
            // Some ops are pure perception requests (no DOM mutation).
            if (msg.op === 'snapshot') {
                this._sendSnapshot();
                this._send({ t: 'result', sid: this._sid, id: msg.id, ok: true });
                return;
            }
            let ok = true, error = null;
            try {
                this._execAction(msg);
            } catch (err) {
                ok = false; error = String(err && err.message || err);
            }
            this._send({ t: 'result', sid: this._sid, id: msg.id, ok, error });
            // After any mutating action, return fresh state so the brain
            // sees the consequence of what it just did.
            this._sendSnapshot();
        }

        _onDone(msg) {
            this._setStatus(msg.message || 'done');
            // Leave the connection open; the brain may continue. The
            // user can dismiss via the kill switch.
        }

        async _onConfirm(msg) {
            let approved = true;
            const action = { id: msg.id, prompt: msg.prompt, action: msg.action };
            if (this._confirm) {
                try { approved = !!(await this._confirm(action)); }
                catch { approved = false; }
            } else {
                approved = await this._defaultConfirm(action);
            }
            this._send({ t: 'confirm_result', sid: this._sid, id: msg.id, approved });
        }

        // ── Actions (synthetic events, same-origin) ─────────────

        _execAction(msg) {
            const el = msg.ref != null ? this._byRef(msg.ref) : null;
            switch (msg.op) {
                case 'click': {
                    if (!el) throw new Error('click: unknown ref ' + msg.ref);
                    el.scrollIntoView({ block: 'center', inline: 'center' });
                    fireMouse(el, 'pointerdown');
                    fireMouse(el, 'mousedown');
                    if (typeof el.focus === 'function') el.focus();
                    fireMouse(el, 'pointerup');
                    fireMouse(el, 'mouseup');
                    el.click();
                    return;
                }
                case 'type': {
                    if (!el) throw new Error('type: unknown ref ' + msg.ref);
                    if (typeof el.focus === 'function') el.focus();
                    setFieldValue(el, msg.text != null ? String(msg.text) : '');
                    return;
                }
                case 'scroll': {
                    if (el) el.scrollIntoView({ block: 'center' });
                    else root.scrollBy(0, msg.dy || innerHeight * 0.8);
                    return;
                }
                case 'navigate': {
                    // SAME-ORIGIN ONLY — the core safety invariant.
                    const dest = new URL(msg.path, location.href);
                    if (dest.origin !== location.origin)
                        throw new Error('navigate blocked: cross-origin ' + dest.origin);
                    location.assign(dest.href);
                    return;
                }
                default:
                    throw new Error('unknown op: ' + msg.op);
            }
        }

        _byRef(ref) {
            return this._root.querySelector(`[${REF_ATTR}="${cssEscape(String(ref))}"]`);
        }

        // ── Perception: enriched DOM snapshot ───────────────────

        _sendSnapshot() {
            const elements = this._snapshot();
            this._send({
                t: 'snapshot', sid: this._sid, seq: ++this._seq,
                url: location.href, title: document.title,
                viewport: { w: innerWidth, h: innerHeight,
                            sx: scrollX, sy: scrollY },
                elements,
            });
        }

        _snapshot() {
            const sel = [
                'a[href]', 'button', 'input', 'select', 'textarea',
                '[role]', '[tabindex]', '[contenteditable=""]',
                '[contenteditable="true"]', '[onclick]',
                'h1', 'h2', 'h3', 'label', '[aria-label]',
            ].join(',');
            const seen = new Set();
            const out = [];
            const nodes = this._root.querySelectorAll(sel);
            for (let i = 0; i < nodes.length && out.length < SNAPSHOT_MAX_ELEMENTS; i++) {
                const el = nodes[i];
                if (seen.has(el)) continue;
                seen.add(el);
                const rect = el.getBoundingClientRect();
                // Skip zero-area nodes entirely (decorative / detached).
                if (rect.width === 0 && rect.height === 0) continue;
                const vis = isVisible(el, rect);
                out.push({
                    ref: this._refOf(el),
                    tag: el.tagName.toLowerCase(),
                    role: roleOf(el),
                    name: accName(el),
                    value: fieldValue(el),
                    type: el.getAttribute && el.getAttribute('type') || undefined,
                    state: stateOf(el),
                    rect: { x: Math.round(rect.x), y: Math.round(rect.y),
                            w: Math.round(rect.width), h: Math.round(rect.height) },
                    visible: vis,
                    // Occlusion: is the element actually the hit-target at
                    // its own center? Catches "covered by a modal / sticky
                    // header" — a big share of "visual" bugs, pixel-free.
                    occluded: vis ? isOccluded(el, rect) : undefined,
                });
            }
            return out;
        }

        _refOf(el) {
            let ref = el.getAttribute(REF_ATTR);
            if (!ref) { ref = String(++this._refSeq); el.setAttribute(REF_ATTR, ref); }
            return ref;
        }

        // ── Indicator + kill switch (non-disableable rail) ──────

        _renderIndicator() {
            if (this._ui) return;
            const box = document.createElement('div');
            box.setAttribute('data-rove-agent-ui', '');
            box.style.cssText = [
                'position:fixed', 'right:16px', 'bottom:16px', 'z-index:2147483647',
                'display:flex', 'align-items:center', 'gap:10px',
                'padding:8px 12px', 'border-radius:10px',
                'font:13px/1.2 system-ui,sans-serif', 'color:#fff',
                'background:#1f2937', 'box-shadow:0 4px 16px rgba(0,0,0,.3)',
            ].join(';');
            const dot = document.createElement('span');
            dot.style.cssText = 'width:8px;height:8px;border-radius:50%;background:#34d399;flex:none';
            const label = document.createElement('span');
            label.textContent = '🤖 Agent active';
            const status = document.createElement('span');
            status.style.cssText = 'opacity:.7';
            const stop = document.createElement('button');
            stop.textContent = 'STOP';
            stop.style.cssText = [
                'margin-left:4px', 'padding:4px 10px', 'border:0', 'border-radius:6px',
                'background:#ef4444', 'color:#fff', 'font-weight:600', 'cursor:pointer',
            ].join(';');
            stop.onclick = () => this.stop('user');
            box.append(dot, label, status, stop);
            document.body.appendChild(box);
            this._ui = { box, status };
        }

        _removeIndicator() {
            if (this._ui && this._ui.box) this._ui.box.remove();
            this._ui = null;
        }

        _setStatus(text) {
            if (this._ui && this._ui.status) this._ui.status.textContent = text;
            if (this._onStatus) { try { this._onStatus(text); } catch (_) {} }
        }

        _defaultConfirm(action) {
            // Minimal built-in modal so confirmation works with zero
            // customer wiring. Customers override via opts.confirm.
            return new Promise((resolve) => {
                const ok = root.confirm
                    ? root.confirm(action.prompt || 'Allow the agent to perform this action?')
                    : true;
                resolve(ok);
            });
        }
    }

    // ── Module-private helpers ──────────────────────────────────

    function roleOf(el) {
        const explicit = el.getAttribute && el.getAttribute('role');
        if (explicit) return explicit;
        const tag = el.tagName.toLowerCase();
        if (tag === 'a' && el.hasAttribute('href')) return 'link';
        if (tag === 'button') return 'button';
        if (tag === 'select') return 'combobox';
        if (tag === 'textarea') return 'textbox';
        if (tag === 'input') {
            const t = (el.getAttribute('type') || 'text').toLowerCase();
            if (t === 'checkbox') return 'checkbox';
            if (t === 'radio') return 'radio';
            if (t === 'button' || t === 'submit') return 'button';
            return 'textbox';
        }
        if (/^h[1-6]$/.test(tag)) return 'heading';
        return tag;
    }

    function accName(el) {
        // A pragmatic accessible-name approximation (not full spec).
        const aria = el.getAttribute && el.getAttribute('aria-label');
        if (aria) return cap(aria);
        const labelledby = el.getAttribute && el.getAttribute('aria-labelledby');
        if (labelledby) {
            const parts = labelledby.split(/\s+/)
                .map((id) => { const n = document.getElementById(id); return n ? n.textContent : ''; })
                .join(' ').trim();
            if (parts) return cap(parts);
        }
        if (el.labels && el.labels.length) return cap(el.labels[0].textContent.trim());
        const ph = el.getAttribute && el.getAttribute('placeholder');
        if (ph) return cap(ph);
        const alt = el.getAttribute && el.getAttribute('alt');
        if (alt) return cap(alt);
        const title = el.getAttribute && el.getAttribute('title');
        if (title) return cap(title);
        const txt = (el.textContent || '').replace(/\s+/g, ' ').trim();
        if (txt) return cap(txt);
        return undefined;
    }

    function fieldValue(el) {
        const tag = el.tagName.toLowerCase();
        if (tag === 'input' || tag === 'textarea' || tag === 'select') {
            const t = (el.getAttribute('type') || '').toLowerCase();
            if (t === 'password') return undefined; // never exfiltrate secrets
            return el.value != null ? cap(String(el.value)) : undefined;
        }
        return undefined;
    }

    function stateOf(el) {
        const s = {};
        if (el.disabled) s.disabled = true;
        if (el.checked != null && (el.type === 'checkbox' || el.type === 'radio'))
            s.checked = !!el.checked;
        const exp = el.getAttribute && el.getAttribute('aria-expanded');
        if (exp != null) s.expanded = exp === 'true';
        const sel = el.getAttribute && el.getAttribute('aria-selected');
        if (sel != null) s.selected = sel === 'true';
        if (el.required) s.required = true;
        return Object.keys(s).length ? s : undefined;
    }

    function isVisible(el, rect) {
        if (rect.width <= 0 || rect.height <= 0) return false;
        const cs = getComputedStyle(el);
        if (cs.display === 'none' || cs.visibility === 'hidden') return false;
        if (parseFloat(cs.opacity || '1') === 0) return false;
        // Fully outside the viewport counts as not-currently-visible
        // (still in the snapshot, flagged so the brain can scroll).
        if (rect.bottom < 0 || rect.top > innerHeight) return false;
        if (rect.right < 0 || rect.left > innerWidth) return false;
        return true;
    }

    function isOccluded(el, rect) {
        const cx = Math.min(innerWidth - 1, Math.max(0, rect.left + rect.width / 2));
        const cy = Math.min(innerHeight - 1, Math.max(0, rect.top + rect.height / 2));
        const hit = document.elementFromPoint(cx, cy);
        if (!hit) return true;
        return !(hit === el || el.contains(hit) || hit.contains(el));
    }

    function setFieldValue(el, text) {
        const tag = el.tagName.toLowerCase();
        if (tag === 'input' || tag === 'textarea') {
            // Use the native setter so frameworks (React, etc.) observe
            // the change rather than ignoring a direct .value assignment.
            const proto = tag === 'textarea'
                ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value');
            if (setter && setter.set) setter.set.call(el, text);
            else el.value = text;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return;
        }
        if (el.isContentEditable) {
            el.textContent = text;
            el.dispatchEvent(new InputEvent('input', { bubbles: true }));
            return;
        }
        throw new Error('type: element is not editable');
    }

    function fireMouse(el, type) {
        const r = el.getBoundingClientRect();
        const ev = new MouseEvent(type, {
            bubbles: true, cancelable: true, view: root,
            clientX: r.left + r.width / 2, clientY: r.top + r.height / 2,
        });
        el.dispatchEvent(ev);
    }

    function cap(s) {
        s = String(s);
        return s.length > TEXT_CAP ? s.slice(0, TEXT_CAP) + '…' : s;
    }

    function cssEscape(s) {
        if (root.CSS && root.CSS.escape) return root.CSS.escape(s);
        return s.replace(/["\\]/g, '\\$&');
    }

    function hashStr(s) {
        let h = 0;
        for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
        return h;
    }

    root.rove = root.rove || {};
    root.rove.agent = {
        // Start the agent: render the indicator, open the connection,
        // and begin the snapshot→act loop. Returns a controller with
        // .stop(). Same-origin only.
        start(opts) { return new AgentClient(opts).start(); },
        // Lower-level: construct without connecting (register handlers /
        // inspect config first), then call .start().
        client(opts) { return new AgentClient(opts); },
    };
})(typeof window !== 'undefined' ? window : globalThis);
