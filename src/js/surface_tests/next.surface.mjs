// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// next — the park verb. The descriptor is checked in the body; the
// module then ACTUALLY ends held, so the harness reading this report
// from the continuation's ctx_json is itself the ctx-threading proof.
export default function ({ next }) {
  check("next()", () => {
    const d = next({ a: 1 });
    ok(d !== null && typeof d === "object", "park descriptor is an object");
    eq(d.path, "");        // self — resume this module's conventional export
    eq(d.ctx, JSON.stringify({ a: 1 })); // ctx rides pre-serialized
    eq(next().ctx, "null"); // ctx optional — absent serializes as "null"
  });

  return next(JSON.parse(done()));
}
