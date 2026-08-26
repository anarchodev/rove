// config.get ≡ prod: reads the deployed config, null for a file the
// deployment does not carry, and stays disjoint from the handler's own
// `_config/…`-spelled kv rows.
import { scenario, expect } from "rewind:test";

const s = scenario({
  kv: { "_config/oauth/google": '{"client_id":"fixture-client"}' },
});
const r = s.inbound({ path: "/" });
expect(r.status).toBe(200);
expect(JSON.parse(r.body.present).client_id).toBe("fixture-client");
expect(r.body.absent).toBe(null);
// The door still serves the DEPLOYED value after the handler wrote the kv
// spelling — and the kv row is the handler's own.
expect(JSON.parse(r.body.doorAfterWrite).client_id).toBe("fixture-client");
expect(r.body.kvSpelling).toBe("not-config");
