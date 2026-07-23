// scenario({ packages, app_imports }) makes a first-party `@rewind/*` package
// resolvable OFFLINE (P-Lift, rove#123): the handler `import`s `@rewind/greet`
// by bare specifier, and the sim resolves it through the same PackageResolver
// prod uses — no registry, no cluster. This is the enabler every lifted lib's
// consumer test relies on. Package files carry their source inline (offline
// there is no blob store); `pkg_hash` is the content-addressed `/pkg/<hash>/`
// namespace (any 64-hex is fine here — the engine treats it as opaque).
import { scenario, expect } from "rewind:test";

const GREET_SRC = "export function greet(n){ return \"hello \" + n; }\n";
const HASH = "ab".repeat(32);

const pkgs = [{
  spec: "@rewind/greet",
  version: "1.0.0",
  pkg_hash: HASH,
  files: { "index.mjs": GREET_SRC },
}];

// The imported package resolves + runs.
const r = scenario({ packages: pkgs, app_imports: { "@rewind/greet": HASH } })
  .inbound({ method: "GET", path: "/" });
expect(r.status).toBe(200);
expect(r.body.greeting).toBe("hello world");
