// Token-entry page. POSTs to /v1/login; the server mints a session
// cookie on success. If the token is wrong, surface the 401 so the
// user can retry — we don't need to clean up any client-side state
// because there is none to clean (no localStorage token anymore).

import { ApiError } from "../api.js";

export function render(root, { goto, api }) {
  const wrap = document.createElement("div");
  wrap.className = "login";
  wrap.innerHTML = `
    <h1>rove admin</h1>
    <p>Paste the bootstrap root token issued to js-worker.</p>
    <form class="login-form">
      <label>
        <span>Token</span>
        <input type="password" name="token" autocomplete="off" required minlength="64" maxlength="64" spellcheck="false">
      </label>
      <button type="submit">Sign in</button>
      <p class="error" hidden></p>
    </form>
  `;

  const form = wrap.querySelector("form");
  const input = form.querySelector("input[name=token]");
  const submit = form.querySelector("button[type=submit]");
  const errorBox = form.querySelector(".error");
  input.focus();

  function showError(msg) {
    errorBox.textContent = msg;
    errorBox.hidden = false;
  }

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    errorBox.hidden = true;
    const token = input.value.trim();
    if (token.length !== 64) {
      showError("Token must be 64 hex characters.");
      return;
    }
    submit.disabled = true;
    try {
      await api.login(token);
      goto("#/instances");
    } catch (err) {
      if (err instanceof ApiError && err.status === 401) {
        showError("Server rejected the token.");
      } else {
        showError(`Sign-in failed: ${err.message}`);
      }
      submit.disabled = false;
    }
  });

  root.appendChild(wrap);
}
