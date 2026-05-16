// Login is the OIDC relying-party handshake — no token/signup form.
// We navigate the whole page to `/_rp/login`, which 302s to the
// __auth__ IdP; after the magic-link round-trip oidc.rp completes
// the session in the background and its poll page returns the
// browser here (auth-domain-plan §4.7 "3-6 part 2").

export function render(root) {
  const dest = "/_rp/login?return_to=" + encodeURIComponent("/#/instances");
  const wrap = document.createElement("div");
  wrap.className = "login";
  wrap.innerHTML =
    "<h1>rove admin</h1>" +
    "<p>Redirecting to sign in…</p>" +
    '<p><a class="rp-login-link"></a></p>';
  // href via property (no markup injection), then label it.
  const a = wrap.querySelector(".rp-login-link");
  a.href = dest;
  a.textContent = "Continue to sign in";
  root.appendChild(wrap);
  // `replace` so Back doesn't trap the user on this interstitial.
  window.location.replace(dest);
}
