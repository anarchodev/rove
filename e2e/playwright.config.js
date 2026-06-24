import { defineConfig, devices } from "@playwright/test";

// E2E tests run against the live production platform by default
// (auth.rewindjs.com / app.rewindjs.com). Override via env — see
// .env.example. There is no webServer to spawn: the target is remote.
export default defineConfig({
  testDir: "./tests",
  // Prod network + a magic-link email round-trip is slow; be patient.
  timeout: 120_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  // Each run sends a real email and mints a real session — never hammer
  // prod with retries. Re-run by hand if something is genuinely flaky.
  retries: 0,
  workers: 1,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
  ],
});
