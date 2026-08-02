// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// http — held outbound subscriptions. In this harness there is no
// fetch accumulator, so the transport never fires; the pinnable
// contract is the id shape, option validation, and cancel's no-op.
export default function () {
  check("http.subscribe", () => {
    const id = http.subscribe({
      url: "https://upstream.example/feed",
      on: "ingest",
      ctx: { cursor: null },
      maxChunkBytes: 1024,
      maxTotalBytes: 4096,
    });
    ok(typeof id === "string" && id.startsWith("ftch_"),
       "subscription id is the ftch_ form: " + id);
    // Retired option spellings fail loud, not silently ignored.
    throws(() => http.subscribe({ url: "https://x.example", on_chunk: "m" }),
           /was renamed/);
    // The callback target is required.
    throws(() => http.subscribe({ url: "https://x.example" }),
           /`on_chunk` \(module path\) is required/);
    // Missing url throws (message is currently the unhelpful
    // "[uninitialized]" — the shim always passes an options object,
    // so the native's nicer arg error is unreachable).
    throws(() => http.subscribe());
  });

  check("http.cancelSubscription", () => {
    const id = http.subscribe({ url: "https://upstream.example/feed", on: "ingest" });
    eq(http.cancelSubscription(id), undefined); // cooperative, engine-null → no-op
    eq(http.cancelSubscription("ftch_deadbeef"), undefined);
    throws(() => http.cancelSubscription(123), /`id` must be a string/);
  });

  return done();
}
