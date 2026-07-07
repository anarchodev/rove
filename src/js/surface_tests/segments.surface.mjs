// segments — sealed-segment append log: hot kv tail + blob history.
// append/logs/hot-get are pure kv; the sealed paths compose blob.*
// (observable as the fetch they issue / the fail-loud contract).
const PAD = "00000000000000000000";
function pad(n) {
  const d = String(n);
  return PAD.slice(d.length) + d;
}

export default function () {
  check("segments.append", () => {
    eq(segments.append("room-7", "first"), 0);
    eq(segments.append("room-7", "second"), 1); // monotonic per log
    eq(kv.get("_seg/room-7/h/" + pad(0)), "first");
    eq(kv.get("_seg/room-7/n"), "2");
    throws(() => segments.append("bad log!", "v"), /log must match/);
    throws(() => segments.append("room-7", { a: 1 }), /value must be a string/);
  });

  check("segments.logs", () => {
    segments.append("audit-2026", "a");
    const page = segments.logs();
    eq(page, { logs: ["audit-2026", "room-7"], cursor: null }); // byte order
    const p1 = segments.logs(undefined, 1);
    eq(p1.logs, ["audit-2026"]);
    ok(typeof p1.cursor === "string", "paging cursor");
    eq(segments.logs(p1.cursor, 1).logs, ["room-7"]);
  });

  check("segments.get", () => {
    eq(segments.get("room-7", 0), "first");            // hot: synchronous
    eq(segments.get("room-7", 99), null);               // no such record
    throws(() => segments.get("room-7", -1), /seq must be a non-negative integer/);
    // Sealed record: index row says a blob covers seq 0..1. Without
    // {on} the sealed read is a documented hard error; with it, the
    // blob fetch goes out and get() returns undefined (finish in the
    // {on} export).
    const hash = crypto.sha256("fake segment");
    kv.set("_seg/cold/s/" + pad(0), JSON.stringify({ hash: hash, first_seq: 0, last_seq: 1, count: 2 }));
    throws(() => segments.get("cold", 1), /record is sealed — pass \{ on \}/);
    eq(segments.get("cold", 1, { on: "onSeg" }), undefined);
  });

  check("segments.record", () => {
    // Only meaningful on a segments.get resume; inbound is not one.
    throws(() => segments.record(), /not a segments\.get resume/);
  });

  check("segments.seal", () => {
    eq(segments.seal("room-7"), 0);                    // below default min=64: no-op
    const n = segments.seal("room-7", { min: 1 });     // fires the durable PUT
    eq(n, 2);
    // The PUT is blob.put — its owed marker is the observable half.
    const payload = JSON.stringify({ v: 1, log: "room-7", first_seq: 0, values: ["first", "second"] });
    const marker = JSON.parse(kv.get("_blob/owed/" + crypto.sha256(payload)));
    eq(marker.on_result, "__system/segments_onsealed");
    eq(marker.context, { log: "room-7", first_seq: 0, last_seq: 1, count: 2 });
    // max caps rows per call.
    segments.append("caps", "a");
    segments.append("caps", "b");
    eq(segments.seal("caps", { min: 1, max: 1 }), 1);
    throws(() => segments.seal("bad log!"), /log must match/);
  });

  return done();
}
