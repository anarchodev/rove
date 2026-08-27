// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
// config — deploy-time configuration, read-only (rove#830: the only door to
// `_config/`). The surface harness runs with no deployment, so every name
// reads absent; the door's shape and its null contract are what this pins.
export default function ({ kv }) {
  check("config.get", () => {
    eq(config.get("oauth/google"), null); // nothing deployed → null, never a throw
    eq(config.get(""), null);             // an empty name is a name nothing has
  });

  // The kv spelling of the namespace is the handler's own keyspace — writing
  // it does not create config, and the door cannot see it. The two surfaces
  // are disjoint by construction.
  check("config.get", () => {
    kv.set("_config/oauth/google", "not-config");
    eq(config.get("oauth/google"), null);
    eq(kv.get("_config/oauth/google"), "not-config");
  });

  return done();
}
