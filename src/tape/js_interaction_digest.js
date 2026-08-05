// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// The interaction digest, JS side — the mirror of
// src/tape/interaction_digest.zig. Read that file for what the digest is
// for and, more importantly, for what is deliberately excluded from it.
//
// Two implementations of one hash is exactly the shape that has bitten this
// codebase before (a latin1 codec that diverged from the native one on every
// non-ASCII byte; a kv.prefix signature that disagreed between two callers).
// So neither side is the reference: `testdata/digest_vectors.json` is, and
// both sides assert against it.
//
// Bytes, not characters: the Zig side folds UTF-8 bytes, so this encodes
// before hashing. A key with any non-ASCII character would otherwise hash
// differently here — the same trap as the codec, in a place where the symptom
// would be an unexplained fidelity mismatch rather than mangled text.
(function () {
  if (globalThis.__interactionDigest) return;

  const OFFSET = 0xcbf29ce484222325n;
  const PRIME = 0x100000001b3n;
  const MASK = (1n << 64n) - 1n;
  const VERSION = 2;
  // Must equal MAX_INLINE_KEY in interaction_digest.zig, and be measured in
  // BYTES — a char-length check diverges on any non-ASCII key.
  const MAX_INLINE_KEY = 320;

  const enc = new TextEncoder();

  const fold = (seed, bytes) => {
    let h = seed;
    for (let i = 0; i < bytes.length; i++) {
      h = (h ^ BigInt(bytes[i])) & MASK;
      h = (h * PRIME) & MASK;
    }
    return h;
  };

  const foldValue = (s) => fold(OFFSET, typeof s === "string" ? enc.encode(s) : s);
  const tooLong = (s) => enc.encode(String(s)).length > MAX_INLINE_KEY;
  const hex16 = (h) => h.toString(16).padStart(16, "0");

  class InteractionDigest {
    constructor() {
      this.h = fold(OFFSET, new Uint8Array([VERSION]));
    }
    line(l) {
      this.h = fold(this.h, enc.encode(l));
      this.h = fold(this.h, enc.encode("\n"));
    }
    // Each element mirrors the Zig spelling exactly, including the
    // lowercase-hex formatting of folded values and the overlong-key
    // fallback — a key too long to spell inline still folds to something
    // deterministic rather than vanishing.
    kvRead(key, found, value) {
      if (tooLong(key)) return this.overlong("r", key);
      this.line(`r ${key} ${found ? 1 : 0} ${(found ? foldValue(value) : 0n).toString(16)}`);
    }
    kvPrefix(prefix, found, count, rowsFold) {
      if (tooLong(prefix)) return this.overlong("p", prefix);
      this.line(`p ${prefix} ${found ? 1 : 0} ${count} ${rowsFold.toString(16)}`);
    }
    kvWrite(key, value) {
      if (tooLong(key)) return this.overlong("w", key);
      this.line(`w ${key} ${foldValue(value).toString(16)}`);
    }
    kvDelete(key) {
      if (tooLong(key)) return this.overlong("d", key);
      this.line(`d ${key}`);
    }
    fetch(method, url, body) {
      this.line(`f ${method} ${foldValue(url).toString(16)} ${foldValue(body ?? "").toString(16)}`);
    }
    wakeArm(kind, arg, exportName) {
      if (tooLong(arg)) return this.overlong("a", String(arg));
      this.line(`a ${kind} ${arg} ${exportName}`);
    }
    streamWrite(bytes) {
      const b = typeof bytes === "string" ? enc.encode(bytes) : bytes;
      this.line(`s ${b.length} ${foldValue(b).toString(16)}`);
    }
    // A privileged lifecycle op. Cross-store READS have no method here: they
    // fold as ordinary kv elements under the `__rove_store/…` key, which is
    // exactly what the offline facade already produces.
    platformOp(op, a1, a2) {
      this.line(`o ${op} ${foldValue(a1 ?? "").toString(16)} ${foldValue(a2 ?? "").toString(16)}`);
    }
    response(status, body) {
      this.line(`x ${status} ${foldValue(body ?? "").toString(16)}`);
    }
    overlong(tag, key) {
      this.line(`${tag}! ${foldValue(key).toString(16)}`);
    }
    hex() {
      return hex16(this.h);
    }
  }

  globalThis.__interactionDigest = {
    VERSION,
    Digest: InteractionDigest,
    foldValue: (s) => foldValue(s).toString(16),
  };
})();
