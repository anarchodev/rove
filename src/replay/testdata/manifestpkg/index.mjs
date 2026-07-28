// Consumes first-party packages declared ONLY in manifest.json — `rewind test`
// auto-resolves them from the embedded first-party set (src/replay/first_party.zig)
// with no inline scenario packages. Exercises a direct leaf import (@rewind/jwt),
// a direct object-default import (@rewind/oidc), and the transitive edge
// (oidc internally imports @rewind/jwt — so oidc loading proves jwt resolved
// through the package's own encapsulated imports, not app_imports).
import jwt from "@rewind/jwt";
import oidc from "@rewind/oidc";

export default function () {
  return JSON.stringify({
    jwt: typeof jwt.decode === "function" && typeof jwt.verify === "function",
    oidc: typeof oidc.rp === "function" && typeof oidc.provider === "function",
  });
}
