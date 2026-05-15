// scripts/replay_shell_smoke.mjs
//
// Playwright-driven smoke test for the WASM replay shell at
// web/replay/wasm.html. Self-contained: spawns its own static HTTP
// server against web/replay/, drives chromium headless through two
// paths (no-opener empty state + synthetic-bundle populated state),
// and tears the server down on exit.
//
// Setup (one-time):
//
//   mkdir -p ~/.cache/playwright-rove
//   cd ~/.cache/playwright-rove
//   npm i playwright
//   npx playwright install chromium
//
// Run from anywhere:
//
//   node scripts/replay_shell_smoke.mjs
//
// Or with a non-default playwright install location:
//
//   PLAYWRIGHT_DIR=/path/to/dir node scripts/replay_shell_smoke.mjs
//
// The smoke is independent of the dev cluster — it doesn't touch
// loop46, files-server, or any Zig binary. It exercises the
// front-end's rendering paths against synthetic fixtures so we
// catch chrome / wiring regressions without needing the full
// cluster bringup. Cluster-integration smokes (driving real
// recordings end-to-end) belong in a future companion script.
//
// Exit code 0 = all checks pass; 1 = one or more failed; 2 = setup
// missing (playwright not installed).

import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve } from "node:path";
import { homedir } from "node:os";
import { connect } from "node:net";

// ── playwright resolution ─────────────────────────────────────────────
//
// ES-module `import()` doesn't consult NODE_PATH, so we try standard
// resolution first (works if playwright is in a sibling node_modules)
// then fall back to an absolute-file-URL import from the conventional
// setup location at ~/.cache/playwright-rove.

const PW_HOME = process.env.PLAYWRIGHT_DIR
    || resolve(homedir(), ".cache", "playwright-rove");

async function tryImport(spec) {
    try { return await import(spec); } catch { return null; }
}

const pw =
    await tryImport("playwright") ||
    await tryImport(pathToFileURL(resolve(PW_HOME, "node_modules", "playwright", "index.mjs")).href);

if (!pw) {
    console.error("playwright is not installed. One-time setup:");
    console.error("  mkdir -p " + PW_HOME);
    console.error("  cd " + PW_HOME);
    console.error("  npm i playwright && npx playwright install chromium");
    console.error("Then re-run: node " + process.argv[1]);
    process.exit(2);
}
const { chromium } = pw;

// ── Paths + URLs ─────────────────────────────────────────────────────
const SCRIPT_DIR  = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT   = resolve(SCRIPT_DIR, "..");
// The static server serves the deployed `_static/` subdir so URL
// paths match what production files-server resolves under `_static/`
// (a request for `/wasm.html` ↔ `_static/wasm.html` on disk).
const REPLAY_DIR  = resolve(REPO_ROOT, "web/replay/_static");

const PORT   = Number(process.env.REPLAY_SMOKE_PORT) || 8731;
const ORIGIN = `http://127.0.0.1:${PORT}`;
const TARGET = `${ORIGIN}/`;

// ── Pass/fail counter shared across checks ───────────────────────────
let pass = 0, fail = 0;
const ok  = (m) => { console.log("\x1b[32m✓\x1b[0m " + m); pass++; };
const bad = (m) => { console.error("\x1b[31m✗\x1b[0m " + m); fail++; };

async function assertSelectors(page, selectors) {
    for (const sel of selectors) {
        try {
            await page.waitForSelector(sel, { timeout: 2000 });
            ok("selector " + sel);
        } catch {
            bad("missing selector " + sel);
        }
    }
}

// ── Static server lifecycle ──────────────────────────────────────────
async function waitForPort(port, host = "127.0.0.1", timeoutMs = 5000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const ok = await new Promise((res) => {
            const s = connect({ port, host }, () => { s.end(); res(true); });
            s.on("error", () => res(false));
        });
        if (ok) return;
        await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error(`port ${port} did not open within ${timeoutMs}ms`);
}

async function startStaticServer() {
    const server = spawn(
        "python3",
        ["-m", "http.server", String(PORT), "--bind", "127.0.0.1", "--directory", REPLAY_DIR],
        { stdio: ["ignore", "ignore", "ignore"] },
    );
    server.on("exit", (code) => {
        if (code !== null && code !== 0 && !server.__expectedExit) {
            console.error(`static server exited unexpectedly (code ${code})`);
        }
    });
    await waitForPort(PORT);
    return server;
}

function stopStaticServer(server) {
    if (!server) return;
    server.__expectedExit = true;
    server.kill("SIGTERM");
}

// ── Synthetic bundle for the populated path ──────────────────────────
//
// Shape matches what the dashboard sends in production (see
// web/replay/app.js for the live producer). Tape blobs are empty;
// the synthetic handler is pure JS with no kv / fetch / date access
// so the deterministic re-execution doesn't need captured tapes.

const FIXTURE = {
    request:        { method: "POST", path: "/api/checkout", host: "acme.app.example.com" },
    response:       { status: 202, outcome: "ok", exception: null },
    deployment_id:  "dep_aaae3d8c1f4d",
    recording_id:   "rec_aaae3d8c1f4d",
    entry_path:     "src/index.mjs",
    modules: [
        {
            path: "src/index.mjs",
            source:
`// Entry handler — inline, no imports (so this smoke doesn't depend
// on arenajs's relative-import resolver). The other modules in the
// bundle exist to populate the rail; they don't need to be invoked
// for the trace stream to have content.
function processItem(x) { return x * 2; }
function compute(items, taxRate) {
  const label = "subtotal";
  let subtotal = 0;
  for (const item of items) {
    subtotal += processItem(item);
  }
  return { [label]: subtotal, total: subtotal * (1 + taxRate) };
}
compute([10, 20, 30], 0.0875);
`,
        },
        {
            path: "src/lib/processCheckout.mjs",
            source:
`export function processCheckout(total, validUser) {
  if (!validUser) throw new Error("invalid user");
  return { status: 202, total };
}
`,
        },
        {
            path: "src/util/validate.mjs",
            source:
`export function isValidEmail(e) {
  return /^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(e);
}
`,
        },
    ],
    tape_blobs: {},
};

// ── Path 1: empty / no-opener ────────────────────────────────────────
async function checkEmptyState(ctx) {
    console.log("\n— empty / no-opener path —");
    const page = await ctx.newPage();
    page.setViewportSize({ width: 1440, height: 900 });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));

    await page.goto(TARGET, { waitUntil: "domcontentloaded" });
    ok("page reachable");

    await assertSelectors(page, [
        ".replay",
        ".appbar__brand",
        ".brand-mark",
        ".stack",
        ".replay__modules .mod-tree",
        ".replay__source .code",
        ".stream__list",
        ".transport__controls .drill-group",
        ".scrubber__track",
        ".vars",
    ]);

    try {
        await page.waitForSelector("#appbar-meta .badge--error", { timeout: 3000 });
        ok("error badge surfaced (no-opener case)");
    } catch {
        bad("expected #appbar-meta .badge--error within 3s");
    }

    const total    = await page.locator(".transport__controls button").count();
    const disabled = await page.locator(".transport__controls button[disabled]").count();
    if (total > 0 && disabled === total) ok(`all ${total} transport buttons disabled`);
    else                                 bad(`expected all transport disabled; got ${disabled}/${total}`);

    if (errors.length === 0) ok("no page-level JS errors");
    else                     bad("page errors: " + errors.join(" | "));

    await page.screenshot({ path: "/tmp/replay-shell-empty.png" });
    ok("screenshot → /tmp/replay-shell-empty.png");
    await page.close();
}

// ── Path 2: populated via fake opener ────────────────────────────────
//
// Loads a same-origin "opener" page first (the static server's
// directory listing at /), installs the bundle handshake handler on
// it, then window.open()s the replay shell as a popup. The opener
// responds to replay:ready with the synthetic FIXTURE.

async function checkPopulatedState(ctx) {
    console.log("\n— populated path / synthetic bundle —");

    const opener = await ctx.newPage();
    await opener.goto(ORIGIN + "/", { waitUntil: "domcontentloaded" });

    await opener.evaluate((fixture) => {
        window.__fixture__ = fixture;
        window.addEventListener("message", (e) => {
            if (e.data?.kind === "replay:ready") {
                e.source.postMessage(
                    { kind: "replay:bundle", bundle: window.__fixture__ },
                    e.origin,
                );
            }
        });
    }, FIXTURE);

    const [popup] = await Promise.all([
        ctx.waitForEvent("page"),
        opener.evaluate((url) => window.open(url, "replayShell"), TARGET),
    ]);
    await popup.setViewportSize({ width: 1440, height: 900 });

    const errors = [];
    popup.on("pageerror", (e) => errors.push(e.message));
    await popup.waitForLoadState("domcontentloaded");

    // Source-state goes terminal after the handler runs. Two-wave
    // render: appbar / modules first (pre-WASM), events / scrubber
    // after handler exit.
    try {
        await popup.waitForFunction(() => {
            const s = document.getElementById("source-state");
            return s && /completed|exited/.test(s.textContent || "");
        }, { timeout: 15_000 });
        ok("source-state reached terminal");
    } catch {
        bad("source-state never reached terminal — handler hung or failed silently");
    }

    const crumbTxt = (await popup.locator("#appbar-crumb").innerText()).trim();
    if (crumbTxt.includes("acme") && crumbTxt.includes("rec_"))
        ok("appbar crumb: " + JSON.stringify(crumbTxt));
    else
        bad("appbar crumb missing tenant/rec: " + JSON.stringify(crumbTxt));

    const badgeTxt = (await popup.locator("#appbar-meta .badge").first().innerText()).trim();
    if (badgeTxt === "202") ok("outcome badge: 202");
    else                    bad("outcome badge wrong: " + JSON.stringify(badgeTxt));

    const modCount = await popup.locator("#mod-tree .mod-tree__item").count();
    if (modCount === 3) ok("modules rail has 3 entries");
    else                bad(`modules rail count: ${modCount} (expected 3)`);

    const currentText = (await popup.locator(".mod-tree__item.is-current").innerText()).trim();
    if (currentText.includes("index.mjs"))
        ok("entry module flagged is-current");
    else
        bad("entry module not marked is-current: " + JSON.stringify(currentText));

    const headerTxt = (await popup.locator("#source-header").innerText()).trim();
    if (headerTxt.includes("index.mjs")) ok("source header: " + JSON.stringify(headerTxt));
    else                                  bad("source header missing entry: " + JSON.stringify(headerTxt));

    const gutterLines = await popup.locator(".code__gutter .ln").count();
    if (gutterLines >= 10) ok(`source gutter rendered ${gutterLines} lines`);
    else                   bad(`source gutter only ${gutterLines} lines (expected ≥ 10)`);

    // Syntax highlighting applied (the fixture's source has keywords,
    // strings, numbers, and comments — all four tok-* classes should
    // appear at least once).
    for (const cls of ["tok-kw", "tok-str", "tok-num", "tok-comm"]) {
        const n = await popup.locator(`.code__body .${cls}`).count();
        if (n > 0) ok(`syntax tokens: ${cls} × ${n}`);
        else       bad(`expected at least one .${cls} in source body`);
    }

    const evCount = await popup.locator("#event-stream .ev").count();
    if (evCount > 0) ok(`event stream has ${evCount} entries`);
    else             bad("event stream rendered no entries");

    const tickCount = await popup.locator("#scrubber-ticks .scrubber__tick").count();
    if (tickCount > 0) ok(`scrubber has ${tickCount} ticks`);
    else               bad("scrubber has no ticks");

    // Clean exit ⇒ no captured throw ⇒ stack breadcrumb shows its
    // "exited cleanly" placeholder.
    const stackTxt = (await popup.locator("#stack-frames").innerText()).trim();
    if (stackTxt.includes("exited cleanly"))
        ok("stack breadcrumb: " + JSON.stringify(stackTxt));
    else
        bad("stack breadcrumb missing exit placeholder: " + JSON.stringify(stackTxt));

    // Step buttons enable based on playhead position. Clean-exit
    // fixture parks the playhead at the end, so reverse controls are
    // live and forward controls are disabled.
    const stepBackDisabled = await popup.locator('button[aria-label="Step back"]').isDisabled();
    const stepLineDisabled = await popup.locator('button[aria-label="Step line"]').isDisabled();
    if (!stepBackDisabled) ok("step-back enabled (playhead at end has somewhere to go back)");
    else                   bad("step-back disabled at end-of-run — expected enabled");
    if (stepLineDisabled)  ok("step-line disabled (already at end)");
    else                   bad("step-line enabled at end-of-run — expected disabled");

    // Step-back moves the playhead. Verify via the source header
    // (which tracks the playhead's current line) rather than the
    // transport time — the transport time uses visible-scan
    // granularity (FUNC_ENTER + THROW), so stepping back through an
    // internal FUNC_EXIT or LINE event leaves it unchanged. The
    // source line updates on every step.
    const headerBefore = (await popup.locator("#source-header").innerText()).trim();
    await popup.locator('button[aria-label="Step back"]').click();
    await popup.waitForFunction(
        (prev) => {
            const h = document.getElementById("source-header");
            return h && h.innerText.trim() !== prev;
        },
        headerBefore,
        { timeout: 2000 },
    ).then(
        () => ok("step-back advances the playhead (source header changed)"),
        () => bad("step-back did not change source header: was " + JSON.stringify(headerBefore)),
    );

    // Jump-to-start lands on event 1 of N.
    await popup.locator('button[aria-label="Jump to start"]').click();
    const startTxt = (await popup.locator("#transport-time").innerText()).replace(/\s+/g, " ").trim();
    if (/^event 1 of \d+$/.test(startTxt)) ok("jump-to-start lands on event 1: " + JSON.stringify(startTxt));
    else                                   bad("jump-to-start unexpected: " + JSON.stringify(startTxt));

    // Module-click navigation: clicking a non-current module in the
    // rail should swap the source viewport and move the is-current
    // marker.
    await popup.locator("#mod-tree .mod-tree__item")
        .filter({ hasText: "processCheckout" })
        .click();
    await popup.waitForFunction(() => {
        const h = document.getElementById("source-header");
        return h && h.textContent.includes("processCheckout");
    }, { timeout: 2000 }).then(
        () => ok("clicking module switches source viewport"),
        () => bad("source viewport did not switch on module click"),
    );
    const newCurrent = (await popup.locator(".mod-tree__item.is-current").innerText()).trim();
    if (newCurrent.includes("processCheckout"))
        ok("is-current moved to clicked module");
    else
        bad("is-current did not move: " + JSON.stringify(newCurrent));

    if (errors.length === 0) ok("no page-level JS errors");
    else                     bad("page errors: " + errors.join(" | "));

    await popup.screenshot({ path: "/tmp/replay-shell-populated.png" });
    ok("screenshot → /tmp/replay-shell-populated.png");

    await popup.close();
    await opener.close();
}

// ── Path 3: throw case ───────────────────────────────────────────────
//
// Fixture whose entry throws inside a nested call. Stack breadcrumb
// should populate with the call chain at the throw, next-error
// button should enable, and the source viewport should jump to the
// throw line.

const FIXTURE_THROW = {
    request:        { method: "POST", path: "/api/decline", host: "acme.app.example.com" },
    response:       { status: 500, outcome: "handler_error", exception: "PaymentError" },
    deployment_id:  "dep_throw1234",
    recording_id:   "rec_throw1234abcd",
    entry_path:     "src/index.mjs",
    modules: [
        {
            path: "src/index.mjs",
            source:
`function declineCharge() {
  throw new Error("card_declined");
}
function processCheckout() {
  declineCharge();
}
processCheckout();
`,
        },
    ],
    tape_blobs: {},
};

async function checkThrowState(ctx) {
    console.log("\n— throw path / handler throws —");
    const opener = await ctx.newPage();
    await opener.goto(ORIGIN + "/", { waitUntil: "domcontentloaded" });
    await opener.evaluate((fixture) => {
        window.__fixture__ = fixture;
        window.addEventListener("message", (e) => {
            if (e.data?.kind === "replay:ready") {
                e.source.postMessage(
                    { kind: "replay:bundle", bundle: window.__fixture__ },
                    e.origin,
                );
            }
        });
    }, FIXTURE_THROW);

    const [popup] = await Promise.all([
        ctx.waitForEvent("page"),
        opener.evaluate((url) => window.open(url, "replayThrow"), TARGET),
    ]);
    await popup.setViewportSize({ width: 1440, height: 900 });
    await popup.waitForLoadState("domcontentloaded");

    try {
        await popup.waitForFunction(() => {
            const s = document.getElementById("source-state");
            return s && /completed|exited/.test(s.textContent || "");
        }, { timeout: 15_000 });
        ok("source-state reached terminal");
    } catch {
        bad("source-state never reached terminal");
    }

    // Stack breadcrumb populated with frames at the throw.
    const stackFrames = await popup.locator("#stack-frames .stack__frame").count();
    if (stackFrames >= 2)
        ok(`stack breadcrumb has ${stackFrames} frames`);
    else
        bad(`stack breadcrumb has only ${stackFrames} frames (expected ≥ 2)`);

    // Current (last) frame's :line should carry the c-error tint.
    const errLineCount = await popup.locator("#stack-frames .stack__frame.is-current .c-error").count();
    if (errLineCount > 0) ok("throw-line tinted c-error in current frame");
    else                  bad("expected c-error on the current frame's :line");

    // Source viewport should jump to the throw line.
    const sourceHeader = (await popup.locator("#source-header").innerText()).trim();
    if (sourceHeader.includes("line"))
        ok("source header shows throw line: " + JSON.stringify(sourceHeader));
    else
        bad("source header missing throw line: " + JSON.stringify(sourceHeader));

    // Next-error button enabled.
    const nextErrorDisabled = await popup.locator("#next-error-btn").getAttribute("disabled");
    if (nextErrorDisabled === null) ok("next-error button enabled");
    else                            bad("next-error button still disabled despite throw");

    // Variables drawer populated via engine.inspectAt — the throw
    // happens inside declineCharge, whose top-of-stack frame should
    // appear in the drawer's section title and produce at least one
    // kv row (the closure-visible function declarations).
    try {
        await popup.waitForFunction(() => {
            const body = document.querySelector(".vars__body");
            if (!body) return false;
            const txt = body.innerText || "";
            return /declineCharge|processCheckout|<eval>/i.test(txt)
                && !/loading…/.test(txt);
        }, { timeout: 5000 });
        const varsTxt = (await popup.locator(".vars__body").innerText()).replace(/\s+/g, " ").trim();
        ok("variables drawer populated: " + JSON.stringify(varsTxt.slice(0, 120)));
    } catch {
        const varsTxt = await popup.locator(".vars__body").innerText().catch(() => "");
        bad("variables drawer never populated within 5s: " + JSON.stringify(varsTxt.trim()));
    }

    await popup.screenshot({ path: "/tmp/replay-shell-throw.png" });
    ok("screenshot → /tmp/replay-shell-throw.png");

    await popup.close();
    await opener.close();
}

// ── Main ─────────────────────────────────────────────────────────────
let server;
let browser;
try {
    server = await startStaticServer();
    browser = await chromium.launch();
    const ctx = await browser.newContext();
    await checkEmptyState(ctx);
    await checkPopulatedState(ctx);
    await checkThrowState(ctx);
} catch (err) {
    bad("uncaught: " + (err.stack || err.message || err));
} finally {
    if (browser) await browser.close();
    stopStaticServer(server);
}

console.log(`\n${pass} pass · ${fail} fail`);
process.exit(fail === 0 ? 0 : 1);
