// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// Injected before every surface-test module (surface_tests.zig
// prepends this file verbatim). Module-scoped — nothing leaks onto
// globalThis. A test module exercises its namespace through
// check(...) and returns done() from its default export.

const __covers = [];
const __failures = [];

/** Claim a canonical surface name (see _reflect.mjs for the grammar)
 *  without running an assertion — for names whose behavior a sibling
 *  check already exercised. */
function cover(name) {
  __covers.push(name);
}

/** Claim `label` and run `fn`; a throw records a failure (with the
 *  label) instead of aborting the module, so one broken method still
 *  reports the rest of the namespace. */
function check(label, fn) {
  cover(label);
  try {
    fn();
  } catch (e) {
    __failures.push(label + ": " + ((e && e.message) || String(e)));
  }
}

/** Deep-equality via JSON round-trip — right for the plain-data
 *  values this surface deals in. */
function eq(got, want) {
  const jg = JSON.stringify(got);
  const jw = JSON.stringify(want);
  if (jg !== jw) throw new Error("expected " + jw + ", got " + jg);
}

function ok(cond, msg) {
  if (!cond) throw new Error(msg || "expected truthy");
}

/** Assert `fn` throws; with `re`, the message must match — pinning
 *  the documented fail-loud contract, not just "it threw". */
function throws(fn, re) {
  let msg = null;
  try {
    fn();
  } catch (e) {
    msg = String((e && e.message) || e);
  }
  if (msg === null) throw new Error("expected a throw");
  if (re && !re.test(msg)) {
    throw new Error("threw, but wrong message: " + msg);
  }
}

/** The module's return value — the harness parses this. */
function done() {
  return JSON.stringify({ covers: __covers, failures: __failures });
}
