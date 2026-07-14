// Cumulative allocation ~256 MiB (256 × 1 MiB dead strings) far exceeds the
// sim's 100 MiB request arena, but the peak live set is ~1 MiB — only the
// current `s` is reachable. It completes because the sim runs the request
// arena in GC mode (issue #70), reclaiming the garbage mid-run, exactly as
// prod's bump→GC retry does. Under a bump arena this would be a false OOM.
// Same shape as prod's own bump/GC discriminator handler.
export default function () {
  let s = "";
  for (let i = 0; i < 256; i++) {
    s = "x".repeat(1 << 20) + i;
  }
  return { len: s.length };
}
