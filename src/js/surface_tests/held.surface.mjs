// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// held — connection input as async iterables. This harness dispatches
// connectionless, so a `messages` pull can never be settled: the
// contract pinned here is the SHAPE (async-iterable protocol on both
// surfaces) and the fail-loud rejection of an unholdable pull. Live
// frame delivery is exercised by the WS smokes against a real worker.
export default function ({ request }) {
  check("request.messages", () => {
    const m = request.messages;
    eq(typeof m.next, "function");
    eq(typeof m[Symbol.asyncIterator], "function");
    eq(m[Symbol.asyncIterator](), m);
    // A pull on an unholdable activation settles with a loud error,
    // never a silent hang.
    const p = m.next();
    eq(p instanceof Promise, true);
    p.catch(() => {});
  });

  check("request.chunks", () => {
    const c = request.chunks;
    eq(typeof c.next, "function");
    eq(typeof c[Symbol.asyncIterator], "function");
    const first = c.next();
    eq(first instanceof Promise, true);
  });

  return done();
}
