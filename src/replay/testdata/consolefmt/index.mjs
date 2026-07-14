// Logs the formatter contract's edge shapes; the test asserts the exact
// message text the worker would write to the live request log
// (globals/console.js `fmt` ≡ the epilogue's `__fmtLog`).
export default function () {
  console.log({ a: 1 }, [1, 2], 42, null, undefined);
  const c = {};
  c.self = c;
  console.log(c);
  console.warn("retrying", 2);
  console.warn({ retry: true });
  console.error();
  return "ok";
}
