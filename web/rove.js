// rove.js — browser client for the Rove notifications channel.
//
// One concept: notifications. The customer's handler emits events
// server-side (`events.emit({to, type, data})`); the browser
// subscribes here and receives them as they fire. See
// docs/notifications.md for the customer-facing reference and
// recipes (live updates, multi-tab sync, RPC-with-correlation-id).
//
// Drop this file into your app, then:
//
//   <script src="/static/rove.js"></script>
//   <script>
//     const events = await rove.events.subscribe();
//     events.on('order.paid', e => render(e.data));
//   </script>
//
// This library:
//   - mints a session-scoped JWT via /_session/sse-token
//   - opens an EventSource at the returned notifications_url
//   - dispatches incoming events to .on(type, handler) subscribers
//   - resolves .waitFor(type, predicate) promises on a match
//   - refreshes the token before expiry (transparent reconnect)
//   - reconnects with exponential backoff on transient failures
//   - surfaces the platform's `rove:resync` sentinel as a regular
//     event so customers can refetch state after a long disconnect
//
// What it does NOT do:
//   - decide what to do on `rove:resync` — that's customer policy
//   - persist anything (the customer's kv is the source of truth)
//   - filter / route by topic (customers use .on(type) per type)

(function (root) {
    'use strict';

    const TOKEN_PATH = '/_session/sse-token';
    const RESYNC_EVENT = 'rove:resync';
    const RECONNECT_INITIAL_MS = 250;
    const RECONNECT_MAX_MS = 30_000;
    // Refresh the token this many ms before exp. Caps at half the
    // TTL so a short-TTL deployment still gets at least one refresh
    // before exp.
    const TOKEN_REFRESH_LEAD_MS = 5 * 60 * 1000;

    class RoveClient {
        constructor(opts) {
            opts = opts || {};
            this._tokenPath = opts.tokenPath || TOKEN_PATH;
            this._handlers = new Map();   // type → Set<handler>
            this._waiters = [];           // {type, predicate, resolve, reject, timeoutId}
            this._es = null;
            this._reconnectMs = RECONNECT_INITIAL_MS;
            this._refreshTimer = null;
            this._closed = false;
            this._connectingPromise = null;
        }

        // Resolve once the EventSource is open. Idempotent — calling
        // again on an already-connected client returns instantly.
        // Throws if the platform isn't wired (notifications_url
        // missing from the token response).
        async subscribe() {
            if (this._es && this._es.readyState === EventSource.OPEN) return this;
            if (!this._connectingPromise) this._connectingPromise = this._connect();
            await this._connectingPromise;
            this._connectingPromise = null;
            return this;
        }

        on(type, handler) {
            let set = this._handlers.get(type);
            if (!set) {
                set = new Set();
                this._handlers.set(type, set);
                if (this._es) this._wireListener(type);
            }
            set.add(handler);
            return () => set.delete(handler);
        }

        // Wait for the next event of `type` matching `predicate`.
        // Used for the RPC-with-correlation-id pattern: customer
        // initiates an action with a correlation_id, awaits the
        // matching notification, then continues. Times out after
        // `timeoutMs` (default 30s) — caller decides how to recover
        // (usually: GET a kv-backed result endpoint, since the
        // customer's handler also persisted the result).
        waitFor(type, predicate, opts) {
            opts = opts || {};
            const timeoutMs = opts.timeoutMs || 30_000;
            return new Promise((resolve, reject) => {
                const waiter = {
                    type,
                    predicate: predicate || (() => true),
                    resolve,
                    reject,
                    timeoutId: setTimeout(() => {
                        this._waiters = this._waiters.filter(w => w !== waiter);
                        reject(new Error(
                            `rove.events.waitFor(${type}) timed out after ${timeoutMs}ms`));
                    }, timeoutMs),
                };
                this._waiters.push(waiter);
                // Make sure the EventSource is listening for this
                // type. Customers can call waitFor before .on, so we
                // can't assume a listener is wired.
                if (this._es && !this._handlers.has(type)) {
                    this._handlers.set(type, new Set());
                    this._wireListener(type);
                }
            });
        }

        close() {
            this._closed = true;
            if (this._es) { this._es.close(); this._es = null; }
            if (this._refreshTimer) { clearTimeout(this._refreshTimer); this._refreshTimer = null; }
            for (const w of this._waiters) {
                clearTimeout(w.timeoutId);
                w.reject(new Error('rove client closed'));
            }
            this._waiters = [];
        }

        // ── Internal ────────────────────────────────────────────

        async _connect() {
            if (this._closed) throw new Error('rove client closed');
            const r = await fetch(this._tokenPath, { credentials: 'same-origin' });
            if (!r.ok) throw new Error(`token mint failed: ${r.status}`);
            const body = await r.json();
            if (!body.notifications_url) {
                throw new Error(
                    'rove notifications not configured: ' +
                    '/_session/sse-token returned notifications_url=null. ' +
                    'Operator needs to deploy sse-server and set --sse-public-base.');
            }

            const url = body.notifications_url +
                '?token=' + encodeURIComponent(body.token);
            const es = new EventSource(url);
            this._es = es;

            // Re-wire listeners for every type the customer subscribed to
            // before we connected (and after a reconnect).
            for (const type of this._handlers.keys()) this._wireListener(type);
            // Always listen for the platform's resync sentinel.
            this._wireListener(RESYNC_EVENT);

            es.onopen = () => {
                this._reconnectMs = RECONNECT_INITIAL_MS;
            };
            es.onerror = () => {
                // EventSource reconnects on its own for transient
                // failures, but our token may be expired — drop and
                // schedule a refresh-and-reconnect ourselves.
                if (this._closed) return;
                if (es.readyState === EventSource.CLOSED) this._scheduleReconnect();
            };

            // Schedule token refresh.
            const ttlMs = (body.expires_in || 3600) * 1000;
            const lead = Math.min(TOKEN_REFRESH_LEAD_MS, Math.floor(ttlMs / 2));
            const delay = Math.max(60_000, ttlMs - lead);
            this._refreshTimer = setTimeout(() => this._refreshAndReconnect(), delay);

            return new Promise((resolve, reject) => {
                const onOpen = () => { es.removeEventListener('open', onOpen); resolve(); };
                const onErr = () => { es.removeEventListener('error', onErr); reject(new Error('connect failed')); };
                es.addEventListener('open', onOpen);
                es.addEventListener('error', onErr, { once: true });
            });
        }

        _wireListener(type) {
            this._es.addEventListener(type, (e) => this._dispatch(type, e));
        }

        _dispatch(type, e) {
            let data;
            try { data = e.data ? JSON.parse(e.data) : null; }
            catch { data = e.data; }
            const event = { type, id: e.lastEventId || null, data };

            const set = this._handlers.get(type);
            if (set) for (const h of set) {
                try { h(event); }
                catch (err) { console.error('rove handler error:', err); }
            }

            const remaining = [];
            for (const w of this._waiters) {
                if (w.type === type) {
                    let matched = false;
                    try { matched = w.predicate(event); }
                    catch (err) { w.reject(err); clearTimeout(w.timeoutId); continue; }
                    if (matched) { clearTimeout(w.timeoutId); w.resolve(event); continue; }
                }
                remaining.push(w);
            }
            this._waiters = remaining;
        }

        async _refreshAndReconnect() {
            if (this._closed) return;
            if (this._es) { this._es.close(); this._es = null; }
            try {
                await this._connect();
            } catch (err) {
                console.warn('rove token refresh failed:', err);
                this._scheduleReconnect();
            }
        }

        _scheduleReconnect() {
            if (this._closed) return;
            const delay = Math.min(this._reconnectMs, RECONNECT_MAX_MS);
            this._reconnectMs = Math.min(this._reconnectMs * 2, RECONNECT_MAX_MS);
            setTimeout(() => this._refreshAndReconnect(), delay);
        }
    }

    root.rove = root.rove || {};
    root.rove.events = {
        // Open the notifications channel. Resolves to a client
        // exposing .on / .waitFor / .close.
        subscribe(opts) {
            return new RoveClient(opts).subscribe();
        },
        // Lower-level: construct without auto-connecting (lets the
        // caller register handlers before the first event might
        // arrive). Call .subscribe() manually to open.
        client(opts) {
            return new RoveClient(opts);
        },
    };
})(typeof window !== 'undefined' ? window : globalThis);
