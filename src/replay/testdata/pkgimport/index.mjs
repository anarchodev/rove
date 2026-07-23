// A handler that imports a first-party `@rewind/*` package by bare specifier —
// the shape every lifted lib's consumer takes (P-Lift, rove#123). Proves the
// offline test harness resolves `@scope/pkg` packages declared inline on the
// scenario (`scenario({ packages, app_imports })`) through the SAME
// PackageResolver prod uses at deploy.
import { greet } from "@rewind/greet";

export default function () {
  return { greeting: greet("world") };
}
