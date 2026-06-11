// Replay-side `request` reconstruction — the consumer of the
// `request_reads` tape channel (read-taping; src/tape/root.zig).
//
// `buildRequestEpilogue` returns a JS source string the caller APPENDS
// to the entry module's source before `arena_run_module`. Appended
// lines never shift the original line numbers, so the trace timeline
// stays aligned with the deployed source. The epilogue:
//
//   - rebuilds `globalThis.request` with the SAME lazy-accessor shape
//     the worker installs (src/js/globals.zig installRequest): header
//     getters from the recorded name set, values from the recorded
//     reads; body / cookies / ip accessors; `unmaskedIp()` method;
//   - throws a loud REPLAY-DIVERGENCE error when the handler reads
//     anything the capture tape didn't record (never a silent
//     undefined — an unrecorded read means the handler is
//     nondeterministic relative to the capture, or capture is buggy);
//   - stamps a fresh `globalThis.response`;
//   - invokes the activation's export through `__arena_entry_ns()`
//     (the arenajs reactor's entry-module namespace accessor — the
//     only way to reach an anonymous `export default` from appended
//     code) and parks the result on `globalThis.__replay_result`.
//
// Shared by the browser shell (wasm-app.mjs) and the node smoke
// driver (scripts/replay_wasm_smoke.mjs) — one epilogue builder, one
// behavior.

import { READ_KIND_HEADER_NAMES, READ_KIND_HEADER_VALUE, READ_KIND_BODY_READ, READ_KIND_IP_MASKED, READ_KIND_IP_RAW } from "./rtap.mjs";

const _decoder = new TextDecoder("utf-8", { fatal: false });
const _encoder = new TextEncoder();

function _toBase64(bytes) {
    const b = typeof bytes === "string" ? _encoder.encode(bytes) : bytes;
    let bin = "";
    for (let i = 0; i < b.length; i += 0x8000) {
        bin += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
    }
    return btoa(bin);
}

/// The export an activation kind invokes — mirrors
/// `rpc_dispatch.defaultExportForKind` (src/js/rpc_dispatch.zig).
export function exportForActivation(activation) {
    switch (activation) {
        case "wake_batch":
        case "kv_wake":
        case "timer":           return "onWake";
        case "disconnect":      return "onDisconnect";
        case "ws_message":      return "onMessage";
        case "inbound_headers": return "onHeaders";
        case "inbound_chunk":   return "onChunk";
        default:                return "default";
    }
}

/// Fold a parsed `request_reads` entry list (rtap.mjs decode shape:
/// `{kind, name, value}`) into the lookup tables the epilogue embeds.
export function foldRequestReads(entries) {
    const out = {
        names: [],            // header_names JSON, parsed
        values: {},           // header name → recorded value
        bodyRead: false,
        ipMasked: null,       // {value} when recorded ("" ⇒ null returned)
        ipRaw: null,
    };
    for (const e of entries || []) {
        switch (e.kind) {
            case READ_KIND_HEADER_NAMES:
                try { out.names = JSON.parse(e.value); } catch { out.names = []; }
                break;
            case READ_KIND_HEADER_VALUE:
                out.values[e.name] = e.value;
                break;
            case READ_KIND_BODY_READ:
                out.bodyRead = true;
                break;
            case READ_KIND_IP_MASKED:
                out.ipMasked = { value: e.value };
                break;
            case READ_KIND_IP_RAW:
                out.ipRaw = { value: e.value };
                break;
        }
    }
    return out;
}

/// Build the epilogue source.
///
///   record       — the LogRecord fields ({method, path, host}); the
///                  query string is derived by splitting `path` on `?`.
///   requestReads — parsed `request_reads` entries (rtap.mjs shape),
///                  or null/[] for records captured with no reads.
///   bodyBytes    — Uint8Array | null: the bundle's request_body
///                  bytes. Only consulted when the tape says the
///                  handler read the body. ≤16 KB read bodies ride
///                  inline in the record; larger ones live behind the
///                  trigger_payload BodyRef and are NOT fetched here
///                  yet (the epilogue returns "" for them — same
///                  pre-existing bundle limitation as before).
///   exportName   — the export the activation invokes ("default",
///                  "onChunk", "onHeaders", ...). Defaults "default".
///   binaryBody   — true for chunk activations (`inbound_chunk` /
///                  `fetch_chunk`): live `request.body` is a
///                  Uint8Array of arbitrary bytes (the chunk IS the
///                  Msg, always recorded — never read-elided), so the
///                  replay body must be byte-exact binary too.
export function buildRequestEpilogue({ record = {}, requestReads = null, bodyBytes = null, exportName = "default", binaryBody = false } = {}) {
    const reads = foldRequestReads(requestReads);

    const rawPath = record.path || "/";
    const q = rawPath.indexOf("?");
    const data = {
        method: record.method || "GET",
        path: q >= 0 ? rawPath.slice(0, q) : rawPath,
        query: q >= 0 ? rawPath.slice(q + 1) : null,
        host: record.host || "",
        names: reads.names,
        values: reads.values,
        // Captured body bytes imply readability: capture elides the
        // body of any record whose handler never read it, so present
        // bytes mean "was read" even when the marker entry is absent
        // (chunk activations record the payload structurally, not
        // via the getter).
        bodyRead: reads.bodyRead || bodyBytes != null,
        body: binaryBody || bodyBytes == null
            ? null
            : (typeof bodyBytes === "string" ? bodyBytes : _decoder.decode(bodyBytes)),
        bodyB64: binaryBody && bodyBytes != null ? _toBase64(bodyBytes) : null,
        ipMasked: reads.ipMasked,
        ipRaw: reads.ipRaw,
        fn: exportName,
    };

    // JSON is JS-literal-safe except the two line separators.
    const json = JSON.stringify(data)
        .replace(/\u2028/g, "\\u2028")
        .replace(/\u2029/g, "\\u2029");

    return (
        "\n;(() => {\n" +
        "  const D = " + json + ";\n" +
        "  const miss = (what) => { throw new Error(\"REPLAY DIVERGENCE: \" + what + \" was read by the handler but is not on the capture tape — the handler observed an input the original run never read\"); };\n" +
        // The bare arena has no console; handlers that log would
        // ReferenceError. Live console output is already on the
        // LogRecord, so replay's console is a no-op sink.
        "  if (typeof console === \"undefined\") globalThis.console = { log() {}, warn() {}, error() {}, info() {}, debug() {} };\n" +
        "  const headers = {};\n" +
        "  for (const n of D.names) Object.defineProperty(headers, n, {\n" +
        "    enumerable: true, configurable: true,\n" +
        "    get() { if (!(n in D.values)) miss(\"header '\" + n + \"'\"); return D.values[n]; },\n" +
        "  });\n" +
        "  const request = { method: D.method, path: D.path, host: D.host, query: D.query, headers };\n" +
        "  Object.defineProperty(request, \"body\", { enumerable: true, configurable: true,\n" +
        "    get() {\n" +
        "      if (!D.bodyRead) miss(\"request.body\");\n" +
        "      let v;\n" +
        "      if (D.bodyB64 != null) {\n" +  // chunk activations: byte-exact Uint8Array
        "        const bin = atob(D.bodyB64);\n" +
        "        v = new Uint8Array(bin.length);\n" +
        "        for (let i = 0; i < bin.length; i++) v[i] = bin.charCodeAt(i);\n" +
        "      } else { v = D.body ?? \"\"; }\n" +
        "      Object.defineProperty(request, \"body\", { enumerable: true, configurable: true, writable: true, value: v });\n" +
        "      return v;\n" +
        "    } });\n" +
        "  Object.defineProperty(request, \"cookies\", { enumerable: true, configurable: true,\n" +
        "    get() {\n" +
        "      const out = {};\n" +
        "      if (D.names.includes(\"cookie\")) {\n" +
        "        const cv = headers.cookie;\n" +  // recorded-read check rides the header getter
        "        for (const part of cv.split(\";\")) {\n" +
        "          const eq = part.indexOf(\"=\");\n" +
        "          if (eq < 0) continue;\n" +
        "          const name = part.slice(0, eq).trim();\n" +
        "          if (name) out[name] = part.slice(eq + 1).trim();\n" +
        "        }\n" +
        "      }\n" +
        "      Object.defineProperty(request, \"cookies\", { enumerable: true, configurable: true, writable: true, value: out });\n" +
        "      return out;\n" +
        "    } });\n" +
        "  Object.defineProperty(request, \"ip\", { enumerable: true, configurable: true,\n" +
        "    get() { if (!D.ipMasked) miss(\"request.ip\"); return D.ipMasked.value || null; } });\n" +
        "  request.unmaskedIp = function () { if (!D.ipRaw) miss(\"request.unmaskedIp()\"); return D.ipRaw.value || null; };\n" +
        "  globalThis.request = request;\n" +
        "  globalThis.response = { status: 200, headers: {}, cookies: [] };\n" +
        "  const ns = __arena_entry_ns();\n" +
        "  if (typeof ns[D.fn] !== \"function\") throw new Error(\"replay: entry module has no '\" + D.fn + \"' export\");\n" +
        "  globalThis.__replay_result = ns[D.fn]();\n" +
        "})();\n"
    );
}
