// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Connection input as async iterables (`src/js/held.zig`): `request.
// messages` (WebSocket frames) and `request.chunks` (the inbound body),
// patched onto the shared request prototype request.js builds. Each
// `messages` pull is one `_system.held.nextInput()` promise the worker
// settles with the next inbound frame ({value:{opcode,bytes,text},
// done:false}) or end-of-input ({done:true} at client close); on an
// activation that cannot be held the pull rejects loudly. `chunks` is
// the one body surface on every delivery mode — today the engine
// buffers bodies before the handler runs (or routes to the `onChunk`
// export flow), so it yields the buffered payload as ONE chunk then
// ends; a streamed per-chunk mode rides the same shape when its
// dispatch decision lands.
//
// Evaluated as a global script after request.js (it patches the proto)
// and before `_harden.js` deletes `_system`.
(function () {
  "use strict";
  const proto = globalThis.__rove_request_proto;
  const sys = _system.held;

  /**
   * The connection's inbound frames as an async iterable — the
   * iterable flow (`docs/architecture/websockets.md`): a WS module
   * with no `onMessage` export runs its default once at connection
   * open and consumes frames in place.
   *
   * One pending pull at a time (a second concurrent `next()` rejects);
   * frames arriving while the handler is mid-commit or awaiting
   * something else queue in arrival order on the connection's input
   * gate. The loop ends at client close.
   *
   * @name request.messages
   * @type {AsyncIterable<{opcode:number,bytes:Uint8Array,text:string}>}
   * @example
   * export default async () => {
   *   for await (const m of request.messages) stream.write("echo:" + m.text);
   *   return "";
   * };
   */
  Object.defineProperty(proto, "messages", {
    configurable: true,
    get: function () {
      const it = {
        next: function () {
          return sys.nextInput();
        },
      };
      it[Symbol.asyncIterator] = function () {
        return it;
      };
      return it;
    },
  });

  /**
   * The inbound body as an async iterable — one shape on every
   * delivery mode. A buffered body yields once ({bytes, text,
   * final:true}) then ends; a payload-less activation iterates as
   * empty.
   *
   * @name request.chunks
   * @type {AsyncIterable<{bytes:Uint8Array,text:string,final:boolean}>}
   * @example
   * export default async () => {
   *   let n = 0;
   *   for await (const c of request.chunks) n += c.bytes.length;
   *   return String(n);
   * };
   */
  Object.defineProperty(proto, "chunks", {
    configurable: true,
    get: function () {
      const self = this;
      // STREAMED inbound (rove#931): the body crossed the size cap, so it
      // was never buffered — each `next()` pulls the runtime for the next
      // sink chunk (the `request.messages` pattern, one pull at a time),
      // ending at `{done:true}` when the body finishes. A frame arriving
      // while the handler is mid-await queues on the input gate.
      if (self.__rove_streamed) {
        const it = {
          next: function () {
            return sys.nextInput();
          },
        };
        it[Symbol.asyncIterator] = function () {
          return it;
        };
        return it;
      }
      // BUFFERED body (≤ cap): the whole payload is in hand — yield it as
      // one chunk, then end. Uniform surface across both delivery modes.
      const state = { served: false };
      const it = {
        next: function () {
          if (state.served || self.bytes === undefined) return Promise.resolve({ done: true });
          state.served = true;
          return Promise.resolve({
            value: { bytes: self.bytes, text: self.text, final: true },
            done: false,
          });
        },
      };
      it[Symbol.asyncIterator] = function () {
        return it;
      };
      return it;
    },
  });
})();
