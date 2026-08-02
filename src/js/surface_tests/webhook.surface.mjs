// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// webhook.send — durable outbound HTTP, composed from kv markers +
// the internal fetch + durable scheduled wakes. In-process the fetch
// is a buffered Cmd; what's observable is the marker row, the
// schedule entry it arms, the id derivation, and the option contract.
export default function () {
  check("webhook.send", () => {
    // Immediate fire: marker + crash-recovery watchdog wake.
    const id = webhook.send("https://hooks.example.test/x", {
      body: JSON.stringify({ event: "order.paid" }),
      headers: { "x-custom": "1" },
      on: "hooks/onDelivered",
      ctx: { order: 7 },
    });
    ok(typeof id === "string" && id.length > 0, "id: " + id);
    const marker = JSON.parse(kv.get("_send/owed/" + id));
    eq(marker.url, "https://hooks.example.test/x");
    eq(marker.method, "POST");
    eq(marker.body, JSON.stringify({ event: "order.paid" }));
    eq(marker.headers, { "x-custom": "1" });
    eq(marker.attempts, 0);
    eq(marker.max_attempts, 5);
    eq(marker.on_result, "hooks/onDelivered");
    eq(marker.context, { order: 7 });
    // The watchdog rides the durable scheduler (the private _system.sched,
    // not an ambient global) under the idempotency key "_send/{id}" — inspect
    // its `_sched/by_id/` row directly.
    const wake = JSON.parse(kv.get("_sched/by_id/" + crypto.sha256b64url("_send/" + id)) || "null");
    ok(wake !== null, "watchdog wake missing");
    eq(wake.target, "__system/webhook_fire");

    // Idempotency key: deterministic 43-char base64url id; same key,
    // same id (last write wins on the marker).
    const a = webhook.send("https://hooks.example.test/y", { key: "reminder/7", body: "a" });
    const b = webhook.send("https://hooks.example.test/y", { key: "reminder/7", body: "b" });
    eq(a, b);
    ok(a.length === 43 && /^[A-Za-z0-9_-]+$/.test(a), "key-derived id shape: " + a);
    eq(JSON.parse(kv.get("_send/owed/" + a)).body, "b");

    // Scheduled fire: no immediate fetch — the wake carries the fire.
    const s = webhook.send("https://hooks.example.test/z", { in: "5m", key: "later/1" });
    const sw = JSON.parse(kv.get("_sched/by_id/" + crypto.sha256b64url("_send/" + s)) || "null");
    ok(sw !== null && sw.target === "__system/webhook_fire", "scheduled wake missing");
    ok(BigInt(sw.when_ns) > BigInt(Date.now()) * 1000000n, "fire time not in the future");

    // maxAttempts override lands in the marker.
    const m = webhook.send("https://hooks.example.test/m", { key: "m/1", maxAttempts: 2 });
    eq(JSON.parse(kv.get("_send/owed/" + m)).max_attempts, 2);

    // Fail-loud contract.
    throws(() => webhook.send({ url: "https://x.test" }), /`url` must be a string/);
    throws(() => webhook.send("https://x.test", "opts"), /opts must be an object/);
    throws(() => webhook.send("https://x.test", { handle: "h" }), /`handle` was renamed/);
    throws(() => webhook.send("https://x.test", { body: new Uint8Array(2) }), /`body` must be a string/);
    throws(() => webhook.send("https://x.test", { in: {} }), /expected a number/);
  });
  return done();
}
