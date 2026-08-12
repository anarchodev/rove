// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `request.tag` validation, as ONE implementation shared by the offline
// engines (rove#505). Sibling of `kv_guards.js`; read its header for why the
// rules are shared while the data is generated and the attachment is not.
//
// This one existed FOUR times — the worker in Zig, the sim's prelude, the
// arena's epilogue in rewind-apps, each hand-copied — and the copies had
// already parted ways on the tag-count message: prod and the sim say
// "too many tags (max 4 per request)", the arena said "at most 4 tags per
// activation". A handler that catches the error and reads `message` saw
// different text depending on which engine ran it, which is precisely the
// kind of difference replay exists to not have.
//
// Messages are part of the contract, so they live here rather than being
// restated per engine. The worker keeps its own Zig copy — enforcement at
// the native is the un-bypassable point — and the guard-parity lint checks
// the two agree.
//
// ## Required data globals (generated from `rove-reserved` by each builder)
//
//   __TAG_MAX      number  tags per activation
//   __TAG_KEY_MAX  number  key bytes
//   __TAG_VAL_MAX  number  value bytes
//
// ## Required helper
//
//   __utf8Len      from `kv_guards.js`, which every builder splices first.
//   Byte counts, not code units: a two-byte key is two bytes toward the cap
//   in every engine, and measuring `.length` would let a multi-byte key past
//   a cap the worker enforces in bytes.

// Validates one (key, value) pair. Throws on the first rule broken, in the
// worker's order — a pair breaking two rules must report the same one
// everywhere. Capacity is NOT checked here: whether a call adds a tag or
// replaces one is engine state, so `__tagGuardCapacity` is called separately
// by whoever owns the list.
const __tagGuardPair = (k, v, argc) => {
  if (argc < 2 || typeof k !== "string" || typeof v !== "string") {
    throw new TypeError("request.tag(key, value) requires two string arguments");
  }
  const kb = __utf8Len(k), vb = __utf8Len(v);
  if (kb < 1 || kb > __TAG_KEY_MAX) throw new TypeError("request.tag: key length must be 1.." + __TAG_KEY_MAX + " bytes");
  if (k[0] === "_") throw new TypeError("request.tag: keys starting with '_' are reserved");
  if (!/^[a-z0-9_]+$/.test(k)) throw new TypeError("request.tag: key must match [a-z0-9_]");
  if (vb < 1 || vb > __TAG_VAL_MAX) throw new TypeError("request.tag: value length must be 1.." + __TAG_VAL_MAX + " bytes");
  for (let i = 0; i < v.length; i++) {
    if (v.charCodeAt(i) < 0x20) throw new TypeError("request.tag: value must not contain control characters");
  }
};

// Called only when a call would ADD a tag — re-tagging an existing key
// updates in place and is always allowed, in every engine.
const __tagGuardCapacity = (count) => {
  if (count >= __TAG_MAX) {
    throw new TypeError("request.tag: too many tags (max " + __TAG_MAX + " per request)");
  }
};
