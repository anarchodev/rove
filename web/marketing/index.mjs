// marketing tenant — handler-served landing page.
//
// The static-asset path 302s to presigned S3 (deployment-snapshots-plan
// Phase 4) — correct for sub-assets, wrong for a top-level document (the
// browser address bar would land on the S3 URL). So the document itself
// is a handler: compiled, bytecode-cached, served 200 at every path's
// canonical home. Assets can ride _static/* later.
const HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>rewind.js — serverless JavaScript with deterministic replay</title>
<meta name="description" content="rewind.js is a serverless JavaScript platform where handlers are pure functions, effects are recorded, and any production request can be replayed — exactly.">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' rx='3' fill='%23121512'/%3E%3Cpath d='M9 4 L4.5 8 L9 12 Z M13 4 L8.5 8 L13 12 Z' fill='%23ffb454'/%3E%3C/svg%3E">
<style>
  :root {
    --bg: #0f1210;
    --bg-raise: #141815;
    --line: #232a24;
    --ink: #c8cfc4;
    --ink-dim: #79836f;
    --ink-faint: #4a5444;
    --amber: #ffb454;
    --amber-deep: #c97f1e;
    --green: #9ece6a;
    --serif: "Iowan Old Style", "Palatino Linotype", Palatino, Charter, Georgia, serif;
    --mono: ui-monospace, "Cascadia Code", "JetBrains Mono", Menlo, Consolas, monospace;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html { scroll-behavior: smooth; }
  body {
    background:
      radial-gradient(1200px 600px at 70% -10%, #1a1f17 0%, transparent 60%),
      var(--bg);
    color: var(--ink);
    font-family: var(--serif);
    font-size: 17px;
    line-height: 1.6;
    -webkit-font-smoothing: antialiased;
    position: relative;
    overflow-x: hidden;
  }
  /* faint engineering grid + grain */
  body::before {
    content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0;
    background:
      repeating-linear-gradient(0deg, transparent 0 47px, rgba(200,207,196,.035) 47px 48px),
      repeating-linear-gradient(90deg, transparent 0 47px, rgba(200,207,196,.025) 47px 48px);
  }
  body::after {
    content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0; opacity: .5;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2'/%3E%3CfeColorMatrix values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 .04 0'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)'/%3E%3C/svg%3E");
  }
  main, header, footer { position: relative; z-index: 1; }

  .shell { max-width: 1060px; margin: 0 auto; padding: 0 28px; }

  /* ── header ─────────────────────────────────────────────── */
  header { padding: 26px 0 0; }
  .bar { display: flex; align-items: baseline; justify-content: space-between;
         border-bottom: 1px solid var(--line); padding-bottom: 18px; }
  .mark { font-family: var(--mono); font-size: 18px; letter-spacing: .02em;
          color: var(--ink); text-decoration: none; }
  .mark b { color: var(--amber); font-weight: 600; }
  .mark .glyph { color: var(--amber); }
  .status { font-family: var(--mono); font-size: 11.5px; color: var(--ink-dim);
            text-transform: uppercase; letter-spacing: .14em; }
  .status .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%;
                 background: var(--amber); margin-right: 7px;
                 animation: pulse 2.4s ease-in-out infinite; }
  @keyframes pulse { 0%,100% { opacity: 1 } 50% { opacity: .25 } }

  /* ── hero ───────────────────────────────────────────────── */
  .hero { padding: 96px 0 30px; max-width: 760px; }
  .hero h1 {
    font-size: clamp(40px, 6.4vw, 64px);
    line-height: 1.06; font-weight: 500; letter-spacing: -0.015em;
  }
  .hero h1 em { font-style: italic; color: var(--amber); }
  .hero p.lede {
    margin-top: 26px; font-size: 19.5px; max-width: 56ch; color: var(--ink);
  }
  .hero p.lede code {
    font-family: var(--mono); font-size: .82em; color: var(--green);
    background: var(--bg-raise); border: 1px solid var(--line);
    padding: .1em .4em; border-radius: 4px;
  }
  .kicker { font-family: var(--mono); font-size: 12px; letter-spacing: .22em;
            text-transform: uppercase; color: var(--amber-deep); margin-bottom: 22px; }

  /* ── tape deck ──────────────────────────────────────────── */
  .deck { margin: 64px 0 0; border: 1px solid var(--line); border-radius: 10px;
          background: linear-gradient(180deg, var(--bg-raise), #101410);
          box-shadow: 0 30px 80px -30px rgba(0,0,0,.8), inset 0 1px 0 rgba(255,255,255,.035);
          overflow: hidden; }
  .deck-head { display: flex; align-items: center; gap: 14px;
               padding: 11px 18px; border-bottom: 1px solid var(--line);
               font-family: var(--mono); font-size: 12px; color: var(--ink-dim); }
  .deck-head .lights { display: flex; gap: 6px; }
  .deck-head .lights i { width: 9px; height: 9px; border-radius: 50%;
                         background: var(--line); }
  .deck-head .title { letter-spacing: .08em; }
  .deck-head .mode { margin-left: auto; letter-spacing: .18em; color: var(--amber);
                     animation: modecycle 9s steps(1) infinite; }
  .trace { font-family: var(--mono); font-size: 13.5px; line-height: 1.95;
           padding: 22px 22px 16px; color: var(--ink); min-height: 240px; }
  .trace .ln { white-space: pre; overflow: hidden; max-width: 0;
               animation: type 9s steps(60, end) infinite; }
  .trace .ln.c   { color: var(--ink-dim); }
  .trace .ln .k  { color: var(--amber); }
  .trace .ln .v  { color: var(--green); }
  .trace .ln .d  { color: var(--ink-faint); }
  /* per-line reveal offsets inside one shared 9s loop (rewind at 78%) */
  .ln:nth-child(1) { animation-name: t1; }
  .ln:nth-child(2) { animation-name: t2; }
  .ln:nth-child(3) { animation-name: t3; }
  .ln:nth-child(4) { animation-name: t4; }
  .ln:nth-child(5) { animation-name: t5; }
  .ln:nth-child(6) { animation-name: t6; }
  .ln:nth-child(7) { animation-name: t7; }
  @keyframes t1 { 0%,2%  { max-width: 0 } 10%,76% { max-width: 100% } 78%,100% { max-width: 0 } }
  @keyframes t2 { 0%,10% { max-width: 0 } 18%,76% { max-width: 100% } 78%,100% { max-width: 0 } }
  @keyframes t3 { 0%,18% { max-width: 0 } 26%,76% { max-width: 100% } 78%,100% { max-width: 0 } }
  @keyframes t4 { 0%,26% { max-width: 0 } 34%,76% { max-width: 100% } 78%,100% { max-width: 0 } }
  @keyframes t5 { 0%,34% { max-width: 0 } 42%,76% { max-width: 100% } 78%,100% { max-width: 0 } }
  @keyframes t6 { 0%,42% { max-width: 0 } 50%,76% { max-width: 100% } 78%,100% { max-width: 0 } }
  @keyframes t7 { 0%,52% { max-width: 0 } 60%,76% { max-width: 100% } 78%,100% { max-width: 0 } }
  @keyframes modecycle {
    0%, 51%  { content: "PLAY ▶"; color: var(--green); }
    52%, 76% { content: ""; }
    77%, 88% { content: "REW ◀◀"; color: var(--amber); }
    89%,100% { content: "PLAY ▶"; color: var(--green); }
  }
  .deck-head .mode::after { content: "PLAY ▶"; animation: inherit; animation-name: modecycle; }
  .scrub { height: 3px; background: var(--line); position: relative; }
  .scrub i { position: absolute; inset: 0 auto 0 0; width: 0; background: var(--amber);
             animation: scrub 9s linear infinite; }
  @keyframes scrub {
    0% { width: 0 } 76% { width: 100% }
    78% { width: 100%; background: var(--amber) }
    88% { width: 0; background: var(--amber) }
    100% { width: 0 }
  }
  .deck-caption { font-family: var(--mono); font-size: 12px; color: var(--ink-dim);
                  padding: 12px 18px; border-top: 1px solid var(--line);
                  letter-spacing: .04em; }
  .deck-caption b { color: var(--ink); font-weight: 500; }

  @media (prefers-reduced-motion: reduce) {
    .trace .ln, .scrub i, .status .dot, .deck-head .mode { animation: none !important; }
    .trace .ln { max-width: 100% !important; }
    .scrub i { width: 62% }
  }

  /* ── principles ─────────────────────────────────────────── */
  .principles { margin: 110px 0 0; display: grid; gap: 1px; background: var(--line);
                border: 1px solid var(--line); border-radius: 10px; overflow: hidden;
                grid-template-columns: repeat(2, 1fr); }
  .cell { background: var(--bg); padding: 34px 30px 38px; }
  .cell:nth-child(2) { background: var(--bg-raise); }
  .cell:nth-child(3) { background: var(--bg-raise); }
  .cell .no { font-family: var(--mono); font-size: 11.5px; color: var(--amber-deep);
              letter-spacing: .2em; }
  .cell h2 { font-size: 23px; font-weight: 500; margin: 12px 0 12px; letter-spacing: -.01em; }
  .cell p { color: var(--ink-dim); font-size: 16px; max-width: 44ch; }
  .cell p code { font-family: var(--mono); font-size: .82em; color: var(--ink); }
  @media (max-width: 720px) { .principles { grid-template-columns: 1fr } .hero { padding-top: 64px } }

  /* ── status ledger ──────────────────────────────────────── */
  .ledger { margin: 110px 0 0; max-width: 640px; }
  .ledger h3 { font-family: var(--mono); font-size: 12px; letter-spacing: .22em;
               text-transform: uppercase; color: var(--amber-deep); margin-bottom: 18px; }
  .ledger dl { font-family: var(--mono); font-size: 13.5px; border-top: 1px solid var(--line); }
  .ledger .row { display: grid; grid-template-columns: 180px 1fr; gap: 16px;
                 padding: 12px 2px; border-bottom: 1px solid var(--line); }
  .ledger dt { color: var(--ink-dim); }
  .ledger dd { color: var(--ink); }
  .ledger dd .ok { color: var(--green); }
  .ledger dd .soon { color: var(--ink-faint); font-style: italic; }
  .ledger p.note { margin-top: 20px; font-size: 15.5px; color: var(--ink-dim); max-width: 58ch; }
  .ledger p.note b { color: var(--ink); font-weight: 500; }

  /* ── footer ─────────────────────────────────────────────── */
  footer { margin-top: 130px; border-top: 1px solid var(--line); }
  .foot { display: flex; justify-content: space-between; gap: 20px; flex-wrap: wrap;
          padding: 22px 0 48px; font-family: var(--mono); font-size: 12px;
          color: var(--ink-faint); letter-spacing: .06em; }
  ::selection { background: var(--amber); color: #161208; }
</style>
</head>
<body>

<header class="shell">
  <div class="bar">
    <a class="mark" href="/"><span class="glyph">◀◀&hairsp;</span>rewind<b>.js</b></a>
    <span class="status"><span class="dot" aria-hidden="true"></span>pre-launch &middot; recording</span>
  </div>
</header>

<main class="shell">
  <section class="hero">
    <p class="kicker">Serverless JavaScript, deterministically</p>
    <h1>Every request is a <em>recording.</em></h1>
    <p class="lede">
      rewind.js runs your handlers as pure functions: <code>(state, request) → (state, response, effects)</code>.
      Effects are data, every external byte is taped, and any production execution
      can be replayed later — exactly, byte for byte, as many times as it takes to understand it.
    </p>
  </section>

  <section class="deck" aria-label="A request trace being replayed">
    <div class="deck-head">
      <span class="lights" aria-hidden="true"><i></i><i></i><i></i></span>
      <span class="title">trace&nbsp;req_01J8…F3K</span>
      <span class="mode" aria-hidden="true"></span>
    </div>
    <div class="trace" role="img" aria-label="Trace: a checkout request reads the cart from kv, calls a payment API served from the tape, commits an order write through Raft, emits a durable webhook, and returns 200 — identical on every replay.">
      <div class="ln c"><span class="d">$</span> rewind replay req_01J8…F3K</div>
      <div class="ln"><span class="k">▶ POST</span> /checkout            <span class="d">tenant=acme</span></div>
      <div class="ln">  kv.get   cart:u_882        <span class="v">→ 3 items</span></div>
      <div class="ln">  fetch    api.payments.dev  <span class="v">→ 200</span> <span class="d">[from tape, 0ms]</span></div>
      <div class="ln">  kv.put   order:o_4471      <span class="v">→ committed</span> <span class="d">raft idx 88112</span></div>
      <div class="ln">  effect   webhook.send      <span class="v">→ owed</span> <span class="d">(durable)</span></div>
      <div class="ln"><span class="k">◀ 200</span> OK                  <span class="d">identical on every run</span></div>
    </div>
    <div class="scrub" aria-hidden="true"><i></i></div>
    <div class="deck-caption">The second run read the <b>tape</b>, not the network. So did the thousandth.</div>
  </section>

  <section class="principles" aria-label="Principles">
    <div class="cell">
      <span class="no">01 / PURE</span>
      <h2>Handlers are functions, not processes</h2>
      <p>No ambient I/O, no wall clocks, no hidden randomness. A handler maps
         state and a request to new state, a response, and a list of effects.
         That totality is what makes everything else possible.</p>
    </div>
    <div class="cell">
      <span class="no">02 / TAPED</span>
      <h2>Effects are data</h2>
      <p>Every outbound call rides one HTTP primitive and is recorded.
         Durability — webhooks, email, retries — is composed in JavaScript
         on top of it, not baked into the runtime.</p>
    </div>
    <div class="cell">
      <span class="no">03 / COMMITTED</span>
      <h2>Writes survive quorum</h2>
      <p>State lives in a replicated key-value store. When a write returns
         <code>committed</code>, it has been accepted by a Raft majority and
         fsync'd — not buffered, not hoped for.</p>
    </div>
    <div class="cell">
      <span class="no">04 / REPLAYABLE</span>
      <h2>Debugging is time travel</h2>
      <p>Take any production request and step through it again — same inputs,
         same effects, same result. The bug report <em>is</em> the reproduction.</p>
    </div>
  </section>

  <section class="ledger">
    <h3>Status — honestly</h3>
    <dl>
      <div class="row"><dt>platform</dt><dd><span class="ok">serving</span> — this page is a compiled handler on tenant <code>marketing</code></dd></div>
      <div class="row"><dt>replay engine</dt><dd><span class="ok">built</span> — taped requests, deterministic re-execution</dd></div>
      <div class="row"><dt>docs</dt><dd><span class="soon">being written — they'll run on rewind.js too</span></dd></div>
      <div class="row"><dt>signup</dt><dd><span class="soon">not yet — watch this domain</span></dd></div>
    </dl>
    <p class="note">This site is not a render farm of promises. It is a static deployment on the
       platform itself, served through the same front door, the same routing, and the same
       replicated state machinery your code will run on. <b>When you can sign up, it will be real.</b></p>
  </section>
</main>

<footer>
  <div class="shell foot">
    <span>© 2026 Loop46, Inc.</span>
    <span>rewind.js — pure functions · taped effects · replayable state</span>
  </div>
</footer>

</body>
</html>
`;

export default function () {
  const p = request.path.split("?")[0];
  if (p === "/" || p === "/index.html") {
    response.headers = { "content-type": "text/html; charset=utf-8" };
    return HTML;
  }
  response.status = 404;
  response.headers = { "content-type": "text/plain; charset=utf-8" };
  return "nothing here yet - try /\n";
}
