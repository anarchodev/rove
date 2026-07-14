// Cumulative allocation ~32 MiB (64 × 512 KiB dead strings) far exceeds the
// sim's 16 MiB request arena, but the peak live set is ~512 KiB — only the
// current `s` is reachable. It completes because the sim runs the request
// arena in GC mode (issue #70), reclaiming the garbage mid-run, exactly as
// prod's bump→GC retry does. Under a bump arena this would be a false OOM.
export default function () {
  let s = "";
  for (let i = 0; i < 64; i++) {
    s = "x".repeat(1 << 19) + i;
  }
  return { len: s.length };
}
