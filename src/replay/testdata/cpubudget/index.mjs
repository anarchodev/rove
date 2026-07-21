// A runaway handler: an accidental infinite loop. Prod interrupts at its CPU
// budget → 504 "handler exceeded cpu budget"; the sim must do the same (a bounded
// wall-clock budget) instead of hanging `rewind test` forever (issue #48).
export default function () {
  let n = 0;
  while (true) { n++; }
  return { n }; // unreachable
}
