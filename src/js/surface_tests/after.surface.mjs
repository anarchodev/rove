// after — connection wake triggers. This activation is dispatched
// without a wake accumulator (the connectionless shape), so ms/kv are
// inert-undefined per the documented model — but argument validation
// still fires first, and after.fetch still mints its ftch_ id.
export default function () {
  check("after.ms", () => {
    eq(after.ms(30_000), undefined);
    eq(after.ms(1, { on: "onTimeout" }), undefined);
    throws(() => after.ms(), /ms must be > 0/); // undefined → NaN → the >0 gate
    throws(() => after.ms(0), /ms must be > 0/);
    throws(() => after.ms(-5), /ms must be > 0/);
  });

  check("after.kv", () => {
    eq(after.kv("rooms/1/"), undefined);
    eq(after.kv("jobs/", { on: "onJob" }), undefined);
    throws(() => after.kv(42), /requires a string prefix/);
  });

  check("after.fetch", () => {
    const id = after.fetch("https://api.example.test/slow", { on: "onSlow" });
    ok(typeof id === "string" && id.startsWith("ftch_"),
       "fetch id is the ftch_ form: " + id);
    // Distinct calls mint distinct ids.
    ok(id !== after.fetch("https://api.example.test/slow", { on: "onSlow" }));
    // Defaults accepted: opts optional entirely.
    ok(after.fetch("https://api.example.test/x").startsWith("ftch_"));
    throws(() => after.fetch(), /requires a url string/);
    // Retired option spellings fail loud.
    throws(() => after.fetch("https://x.example", { timeout_ms: 5 }), /was renamed/);
    throws(() => after.fetch("https://x.example", { to: "m" }), /was renamed/);
  });

  check("after.cancel", () => {
    const id = after.fetch("https://api.example.test/slow", { on: "onSlow" });
    eq(after.cancel(id), undefined);           // accepts the ftch_ form
    eq(after.cancel("deadbeef"), undefined);   // bare hex tolerated, no-op
    throws(() => after.cancel(7), /`id` must be a string/);
  });

  return done();
}
