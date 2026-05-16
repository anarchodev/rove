// First-instance provisioning. Reached after a successful OIDC login
// when the authenticated account owns no instance yet (app.js routes
// here). Identity is the server-verified id_token `sub`; the only
// input is the instance name (auth-domain-plan §4.7 "3-6 part 2").

import { ApiError } from "../api.js";

export function render(root, { goto, api }) {
  const wrap = document.createElement("div");
  wrap.className = "login";
  wrap.innerHTML = `
    <h1>Name your instance</h1>
    <p>You're signed in. Pick a name for your first instance.</p>
    <form class="provision-form">
      <label>
        <span>Instance name</span>
        <input type="text" name="name" autocomplete="off" required
               minlength="1" maxlength="64"
               pattern="[A-Za-z0-9_-]+"
               title="letters, digits, dashes, underscores"
               spellcheck="false">
      </label>
      <button type="submit">Create instance</button>
      <p class="error" hidden></p>
    </form>
  `;
  const form = wrap.querySelector(".provision-form");
  const nameInput = form.querySelector("input[name=name]");
  const submit = form.querySelector("button[type=submit]");
  const err = form.querySelector(".error");

  function showError(msg) {
    err.textContent = msg;
    err.hidden = false;
  }

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    err.hidden = true;
    const name = nameInput.value.trim();
    if (!name) {
      showError("Enter an instance name.");
      return;
    }
    submit.disabled = true;
    try {
      await api.provisionInstance(name);
      goto("#/instances");
    } catch (e) {
      if (e instanceof ApiError) {
        if (e.status === 409) showError("That name isn't available — try another.");
        else if (e.status === 400) showError("Invalid name (letters, digits, dashes, underscores).");
        else if (e.status === 403) showError("Account instance limit reached.");
        else showError(`Provisioning failed (${e.status}).`);
      } else {
        showError(`Provisioning failed: ${e.message}`);
      }
      submit.disabled = false;
    }
  });

  nameInput.focus();
  root.appendChild(wrap);
}
