// The effect-global surface the sim base now installs as recorders: http /
// platform / browser (over _system.* that push to the shared effect log).
export default function () {
  response.status = 200;
  return {
    surface: { http: typeof http, platform: typeof platform, browser: typeof browser },
    created: platform.instances.create("acme"), // prod returns undefined; records the effect
    rootRead: platform.root.get("cfg/x"),                // reads the isolated root store
  };
}
