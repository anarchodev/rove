// browser — the in-page agent SDK's server half. Mostly pure frame
// shaping/parsing; the senders ride stream.write (inert without a
// held page — they no-op, matching the connection-output surface).
export default function () {
  check("browser.message", () => {
    // Not a ws_message activation → null.
    eq(browser.message(), null);
  });

  check("browser.act", () => eq(browser.act({ id: 1, op: "click", ref: "12" }), undefined));
  check("browser.status", () => {
    eq(browser.status("thinking…"), undefined);
    eq(browser.status(null), undefined); // coerces to ""
  });
  check("browser.confirm", () => eq(browser.confirm({ id: 2, prompt: "Buy?", action: { op: "click", ref: "9" } }), undefined));
  check("browser.done", () => eq(browser.done("finished"), undefined));

  check("browser.render", () => {
    const snap = {
      url: "https://app.test/cart",
      title: "Cart",
      elements: [
        { ref: "1", role: "button", name: "Buy", state: { disabled: true } },
        { ref: "2", role: "textbox", name: "Qty", value: "3", state: { required: true } },
        { ref: "3", tag: "div", visible: false },
      ],
    };
    eq(browser.render(snap),
      'url: https://app.test/cart\ntitle: Cart\n[1] button "Buy" (disabled)\n[2] textbox "Qty" = "3" (required)\n[3] div (offscreen)');
    // A bare elements array renders without the url/title header.
    eq(browser.render([{ ref: "1", role: "link", name: "Home" }]), '[1] link "Home"');
    eq(browser.render(null), "");
  });

  check("browser.tools", () => {
    const base = browser.tools();
    eq(base.map((t) => t.op), ["click", "type", "scroll", "navigate", "snapshot"]);
    const withShots = browser.tools({ screenshots: true });
    eq(withShots[withShots.length - 1].op, "screenshot");
    const withReplay = browser.tools({ replay: true });
    eq(withReplay[withReplay.length - 1].op, "getReplay");
  });

  check("browser.getReplay", () => {
    // Refuses without an {on} callback, and without a tenant (the
    // in-process test activation carries none).
    eq(browser.getReplay(), false);
    eq(browser.getReplay({ on: "onReplay" }), false);
  });

  check("browser.replayResult", () => {
    // Reads the ambient request body; the standard test body parses
    // but carries no records.
    eq(browser.replayResult(), { records: [], next_cursor: null });
  });

  check("browser.renderReplay", () => {
    eq(browser.renderReplay({ records: [] }), "No recent server-side activity for this session.");
    eq(browser.renderReplay(null), "No recent server-side activity for this session.");
    const out = browser.renderReplay({
      records: [{ request_id: 9, method: "POST", path: "/x", status: 200, outcome: "ok", duration_ns: 2500000 }],
    });
    eq(out, "Recent server activations (newest first):\n#9 POST /x → 200 ok (3ms)");
  });

  check("browser.image", () => {
    eq(browser.image({ t: "snapshot" }), null);       // not a screenshot frame
    eq(browser.image(null), null);
    eq(browser.image({ t: "screenshot", ok: false, error: "denied" }), { ok: false, error: "denied" });
    eq(browser.image({ t: "screenshot", ok: false }), { ok: false, error: "screenshot failed" });
    const data = btoa("png-bytes");
    const img = browser.image({ t: "screenshot", ok: true, data: data });
    eq(img.ok, true);
    eq(img.mime, "image/jpeg");                       // default
    eq(img.data, data);
    eq(new TextDecoder().decode(img.bytes), "png-bytes");
  });

  return done();
}
