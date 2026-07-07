// stream — connection output. Without a held socket (this harness
// dispatches connectionless) both calls are documented inert no-ops;
// that inertness IS the pinnable contract here. Live chunk emission
// is exercised by the streaming smokes against a real worker.
export default function () {
  check("stream.start", () => {
    eq(stream.start(), undefined);
    eq(stream.start(), undefined); // idempotent when inert
  });

  check("stream.write", () => {
    eq(stream.write("data: hello\n\n"), undefined);
    eq(stream.write(new Uint8Array([1, 2, 3])), undefined);
  });

  return done();
}
