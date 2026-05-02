// Story 1 leaderboard demo — the Firebase-pain comparison from
// PLAN §10.17. Five-ish lines of platform code does what would be
// a Firebase project, three IAM consoles, a Firestore collection
// rule, a Cloud Function trigger, and a Cloud Run deploy elsewhere.
//
// GET /api  → top 10 scores as JSON.
// POST /api → submit a `{name, score}` row; idempotent on name
//             (re-submitting overwrites the previous entry).
// All other paths fall through to `_static/index.html` (the page).

const NAME_RE = /^[a-z0-9_-]{1,32}$/i;

export default function () {
  if (request.method === "POST") {
    const body = JSON.parse(request.body || "{}");
    const name = String(body.name || "").trim();
    const score = parseInt(body.score, 10);
    if (!NAME_RE.test(name)) {
      response.status = 400;
      return { error: "name must be 1-32 alphanumeric characters" };
    }
    if (!Number.isFinite(score) || score < 0 || score > 999_999_999) {
      response.status = 400;
      return { error: "score must be a non-negative integer" };
    }
    kv.set(`score/${name}`, String(score));
    response.status = 201;
    return { ok: true, name, score };
  }
  return kv.prefix("score/", "", 100)
    .map((r) => ({ name: r.key.slice("score/".length), score: parseInt(r.value, 10) }))
    .sort((a, b) => b.score - a.score)
    .slice(0, 10);
}
