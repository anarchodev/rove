// config_mirror_smoke probe — exposes the contents of
// `_config/oauth/google` as JSON so the smoke can verify that the
// deploy-time mirror copied the file's bytes into kv.
//
// GET → 200 with the raw JSON string from the kv row.
//   404 if the row is absent (mirror didn't run, file missing, etc.)

export default function () {
  const raw = kv.get("_config/oauth/google");
  if (raw == null) {
    response.status = 404;
    return "no _config/oauth/google row";
  }
  response.status = 200;
  response.headers = { "content-type": "application/json" };
  return raw;
}
