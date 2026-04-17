// Instance list page. Shows every registered tenant with its domain
// aliases, plus forms to create an instance, assign a domain, and
// delete an instance. All state comes from two reads against the
// tenant API; mutations re-fetch.

import { ApiError } from "../api.js";

export function render(root, { goto, api }) {
  const wrap = document.createElement("div");
  wrap.className = "instances";
  wrap.innerHTML = `
    <header class="page-header">
      <h1>Instances</h1>
      <button type="button" class="logout">Sign out</button>
    </header>
    <p class="error" hidden></p>

    <section class="forms">
      <form class="create-form">
        <h2>Create instance</h2>
        <label>
          <span>Instance ID</span>
          <input name="id" required pattern="[A-Za-z0-9_-]{1,64}" placeholder="e.g. acme">
        </label>
        <button type="submit">Create</button>
      </form>

      <form class="assign-form">
        <h2>Assign domain</h2>
        <label>
          <span>Host</span>
          <input name="host" required placeholder="acme.example.com">
        </label>
        <label>
          <span>Instance</span>
          <select name="instance_id" required></select>
        </label>
        <button type="submit">Assign</button>
      </form>
    </section>

    <section>
      <h2>Tenants</h2>
      <table class="instance-table">
        <thead>
          <tr><th>ID</th><th>Domains</th><th></th></tr>
        </thead>
        <tbody></tbody>
      </table>
    </section>
  `;

  const errorBox = wrap.querySelector(".error");
  const tbody = wrap.querySelector(".instance-table tbody");
  const selectInstance = wrap.querySelector("select[name=instance_id]");
  const createForm = wrap.querySelector(".create-form");
  const assignForm = wrap.querySelector(".assign-form");
  const logoutBtn = wrap.querySelector(".logout");

  function showError(msg) {
    errorBox.textContent = msg;
    errorBox.hidden = false;
  }
  function clearError() {
    errorBox.hidden = true;
    errorBox.textContent = "";
  }

  async function reload() {
    clearError();
    let instancesRes, domainsRes;
    try {
      [instancesRes, domainsRes] = await Promise.all([
        api.listInstances(),
        api.listDomains(),
      ]);
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        api.clearToken();
        goto("#/login");
        return;
      }
      showError(`Load failed: ${err.message}`);
      return;
    }

    const ids = (instancesRes.instances ?? []).map((i) => i.id);
    const domainsByInstance = new Map();
    for (const d of domainsRes.domains ?? []) {
      if (!domainsByInstance.has(d.instance_id)) domainsByInstance.set(d.instance_id, []);
      domainsByInstance.get(d.instance_id).push(d.host);
    }

    tbody.replaceChildren();
    for (const id of ids) {
      const tr = document.createElement("tr");

      const idCell = document.createElement("td");
      const idLink = document.createElement("a");
      idLink.href = `#/instance/${encodeURIComponent(id)}`;
      idLink.textContent = id;
      idCell.appendChild(idLink);
      tr.appendChild(idCell);

      const domainCell = document.createElement("td");
      const domains = domainsByInstance.get(id) ?? [];
      if (domains.length === 0) {
        const em = document.createElement("em");
        em.textContent = "(none)";
        domainCell.appendChild(em);
      } else {
        domainCell.textContent = domains.join(", ");
      }
      tr.appendChild(domainCell);

      const actionCell = document.createElement("td");
      actionCell.className = "actions";
      const delBtn = document.createElement("button");
      delBtn.type = "button";
      delBtn.textContent = "Delete";
      delBtn.addEventListener("click", () => onDelete(id));
      actionCell.appendChild(delBtn);
      tr.appendChild(actionCell);

      tbody.appendChild(tr);
    }

    selectInstance.replaceChildren();
    for (const id of ids) {
      const opt = document.createElement("option");
      opt.value = id;
      opt.textContent = id;
      selectInstance.appendChild(opt);
    }
  }

  async function onCreate(ev) {
    ev.preventDefault();
    clearError();
    const data = new FormData(createForm);
    const id = String(data.get("id") ?? "").trim();
    if (!id) return;
    try {
      await api.createInstance(id);
      createForm.reset();
      await reload();
    } catch (err) {
      showError(`Create failed: ${err.message}`);
    }
  }

  async function onAssign(ev) {
    ev.preventDefault();
    clearError();
    const data = new FormData(assignForm);
    const host = String(data.get("host") ?? "").trim();
    const instance_id = String(data.get("instance_id") ?? "").trim();
    if (!host || !instance_id) return;
    try {
      await api.assignDomain(host, instance_id);
      assignForm.reset();
      await reload();
    } catch (err) {
      showError(`Assign failed: ${err.message}`);
    }
  }

  async function onDelete(id) {
    if (!confirm(`Delete instance "${id}"? This cannot be undone via the UI.`)) return;
    clearError();
    try {
      await api.deleteInstance(id);
      await reload();
    } catch (err) {
      showError(`Delete failed: ${err.message}`);
    }
  }

  createForm.addEventListener("submit", onCreate);
  assignForm.addEventListener("submit", onAssign);
  logoutBtn.addEventListener("click", () => {
    api.clearToken();
    goto("#/login");
  });

  root.appendChild(wrap);
  reload();
}
