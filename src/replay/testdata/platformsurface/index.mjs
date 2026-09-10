// The effect surface arrives on the ACTIVATION OBJECT — the ambient
// spellings are gone (#861), and this probe asserts exactly that: the
// received members are objects, the free-variable spellings are
// undefined in every engine.
export default function ({ platform, http }) {
  response.status = 200;
  return {
    surface: { http: typeof http, platform: typeof platform, browser: typeof browser },
  };
}
