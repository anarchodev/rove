// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// The JS half of the shared-vector gate: assert the mirror
// (interaction_digest.js) produces the same digests the Zig side does, from
// the same element streams. Run with `node src/replay/js/digest_vectors_test.mjs`
// (wired into `zig build replay-digest-vectors`).
//
// A vector mismatch here means the two implementations have drifted, which
// would otherwise surface as an unexplained "replay diverged" on a real
// record — the hardest kind of bug to attribute.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
new Function(readFileSync(join(here, "..", "..", "tape", "js_interaction_digest.js"), "utf-8"))();
const { Digest, foldValue, VERSION } = globalThis.__interactionDigest;

const vec = JSON.parse(readFileSync(join(here, "..", "..", "tape", "testdata", "digest_vectors.json"), "utf-8"));
if (vec.version !== VERSION) {
  console.error(`grammar version mismatch: vectors say ${vec.version}, JS says ${VERSION}`);
  process.exit(1);
}

const apply = (d, [op, ...args]) => {
  switch (op) {
    case "kvRead":       return d.kvRead(args[0], args[1], args[2]);
    case "kvReadRepeat": return d.kvRead(args[0].repeat(args[1]), args[2], args[3]);
    case "kvWrite":      return d.kvWrite(args[0], args[1]);
    case "kvWriteRepeat": return d.kvWrite(args[0].repeat(args[1]), args[2]);
    case "kvDelete":     return d.kvDelete(args[0]);
    // The vector spells the rows to fold, so the file stays readable and the
    // fold function itself is exercised on both sides.
    case "kvPrefixFold": return d.kvPrefix(args[0], args[1], args[2], BigInt("0x" + foldValue(args[3])));
    case "fetch":        return d.fetch(args[0], args[1], args[2]);
    case "wakeArm":      return d.wakeArm(args[0], args[1], args[2]);
    case "streamWrite":  return d.streamWrite(args[0]);
    case "response":     return d.response(args[0], args[1]);
    default: throw new Error("unknown vector element: " + op);
  }
};

let bad = 0;
for (const [name, c] of Object.entries(vec.cases)) {
  const d = new Digest();
  for (const el of c.elements) apply(d, el);
  const got = d.hex();
  const ok = got === c.digest;
  if (!ok) bad++;
  console.log(`  ${ok ? "ok  " : "FAIL"} ${name.padEnd(10)} ${got}${ok ? "" : " != " + c.digest}   (${c.why})`);
}
console.log(bad === 0
  ? "\ninteraction digest: JS mirror agrees with the shared vectors"
  : `\n${bad} vector(s) DIVERGED — the two implementations no longer agree`);
process.exit(bad === 0 ? 0 : 1);
