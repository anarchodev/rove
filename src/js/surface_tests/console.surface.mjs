// console — the request-log quartet. Output lands in the per-request
// log buffer (not observable from JS), so the pinnable contract is:
// accepts any arg shapes, coerces, returns undefined, never throws.
export default function () {
  check("console.log", () => {
    eq(console.log("plain", 42, { a: 1 }, null, undefined), undefined);
    eq(console.log(), undefined);
  });
  check("console.warn", () => {
    eq(console.warn("w", [1, 2]), undefined);
  });
  check("console.error", () => {
    eq(console.error(new Error("boom")), undefined);
  });
  check("console.info", () => {
    eq(console.info("i"), undefined);
  });
  check("console.debug", () => {
    eq(console.debug("d"), undefined);
  });
  return done();
}
