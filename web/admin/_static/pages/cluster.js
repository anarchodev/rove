// Operator cluster-management page (#/cluster) — the GUI twin of the
// `rewind-ops` CLI. Operator-only (is_root): provision / move / host / plan
// drive the control plane through the admin app's /v1/cp/* chokepoints (the
// worker attaches the move-secret server-side — no CP secret in the browser,
// step3-auth-plan.md B4), and a status panel reads placement + plan via the
// /v1/cp/route|plan reads. A non-operator session is bounced to #/instances.

import { ApiError } from "../api.js";

export function render(root, { goto, api }) {
  const wrap = document.createElement("div");
  wrap.className = "cluster-page";
  root.appendChild(wrap);

  // Gate on is_root before showing any operator surface. (app.js already
  // requires a session; this adds the operator check.)
  (async () => {
    let who;
    try { who = await api.whoami(); } catch { who = null; }
    if (!who) { goto("#/login"); return; }
    if (!who.is_root) {
      wrap.innerHTML = `
        <h1>Cluster</h1>
        <p class="error">Operator access required.</p>
        <p><a href="#/instances">← back to instances</a></p>`;
      return;
    }
    mount();
  })();

  function mount() {
    wrap.innerHTML = `
      <h1>Cluster management</h1>
      <p class="muted">Operator control plane — the GUI twin of
        <code>rewind-ops</code>. Moves repoint live routing; use with care.</p>
      <p class="error" hidden></p>

      <section class="cluster-status">
        <h2>Status</h2>
        <form class="status-form">
          <label><span>Route for host</span>
            <input name="host" placeholder="acme.example.com" spellcheck="false"></label>
          <button type="submit">Look up</button>
          <label><span>Plan for tenant</span>
            <input name="tenant" placeholder="acme" spellcheck="false"></label>
          <button type="button" class="plan-lookup">Look up plan</button>
        </form>
        <pre class="status-out muted">—</pre>
      </section>

      <section class="cluster-ops">
        <h2>Provision</h2>
        <form class="op-provision">
          <input name="tenant" placeholder="tenant" spellcheck="false" required>
          <input name="cluster" placeholder="cluster id" spellcheck="false" required>
          <input name="host" placeholder="host (optional)" spellcheck="false">
          <button type="submit">Provision</button>
        </form>

        <h2>Move</h2>
        <form class="op-move">
          <input name="tenant" placeholder="tenant" spellcheck="false" required>
          <input name="cluster" placeholder="destination cluster" spellcheck="false" required>
          <label class="inline"><input type="checkbox" name="live"> live</label>
          <button type="submit">Move</button>
        </form>

        <h2>Host alias</h2>
        <form class="op-host">
          <input name="host" placeholder="host" spellcheck="false" required>
          <input name="tenant" placeholder="tenant" spellcheck="false" required>
          <button type="submit">Add host</button>
        </form>

        <h2>Plan</h2>
        <form class="op-plan">
          <input name="tenant" placeholder="tenant" spellcheck="false" required>
          <input name="plan" placeholder='{"tier":"pro"}' spellcheck="false" required>
          <button type="submit">Set plan</button>
        </form>
      </section>
    `;

    const err = wrap.querySelector(".error");
    const statusOut = wrap.querySelector(".status-out");
    function showError(msg) { err.textContent = msg; err.hidden = false; }
    function clearError() { err.hidden = true; }
    function show(obj) { statusOut.textContent = JSON.stringify(obj, null, 2); }

    function failMsg(e) {
      if (e instanceof ApiError) {
        if (e.status === 403) return "Operator access required.";
        if (e.status === 401) { goto("#/login"); return "Session expired."; }
        return `Failed (${e.status}): ${typeof e.body === "string" ? e.body : JSON.stringify(e.body)}`;
      }
      return `Failed: ${e.message}`;
    }

    // Wire a form: gather named inputs, run `fn(values)`, render result.
    function wireForm(sel, fn, { confirm: confirmMsg = null } = {}) {
      const form = wrap.querySelector(sel);
      form.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        clearError();
        const v = {};
        for (const inp of form.querySelectorAll("input")) {
          v[inp.name] = inp.type === "checkbox" ? inp.checked : inp.value.trim();
        }
        if (confirmMsg && !window.confirm(confirmMsg(v))) return;
        const btn = form.querySelector("button[type=submit]");
        btn.disabled = true;
        try { show(await fn(v)); }
        catch (e) { showError(failMsg(e)); }
        finally { btn.disabled = false; }
      });
    }

    // Status lookups.
    const statusForm = wrap.querySelector(".status-form");
    statusForm.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      clearError();
      const host = statusForm.querySelector("input[name=host]").value.trim();
      if (!host) { showError("Enter a host."); return; }
      try { show(await api.clusterRoute(host)); }
      catch (e) { showError(failMsg(e)); }
    });
    wrap.querySelector(".plan-lookup").addEventListener("click", async () => {
      clearError();
      const tenant = statusForm.querySelector("input[name=tenant]").value.trim();
      if (!tenant) { showError("Enter a tenant."); return; }
      try { show(await api.clusterPlan(tenant)); }
      catch (e) { showError(failMsg(e)); }
    });

    // Control ops.
    wireForm(".op-provision", (v) =>
      api.cpProvision(v.tenant, v.cluster, v.host || undefined));
    wireForm(".op-move", (v) =>
      api.cpMove(v.tenant, v.cluster, { live: v.live }),
      { confirm: (v) => `Move ${v.tenant} → ${v.cluster}${v.live ? " (LIVE)" : ""}?` });
    wireForm(".op-host", (v) => api.cpHost(v.host, v.tenant));
    wireForm(".op-plan", (v) => {
      let plan;
      try { plan = JSON.parse(v.plan); }
      catch { throw new Error("plan must be valid JSON"); }
      return api.cpPlan(v.tenant, plan);
    });
  }
}
