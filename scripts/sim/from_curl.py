#!/usr/bin/env python3
"""curl -> world.json scaffold — the cheapest on-ramp to `sim`.

A curl command already encodes the *inbound* half of a world (method / path /
host / headers / body) — the part that's annoying to hand-write and that agents
already reach for. This converts one into a `world.json` request surface; the
*outbound* half (kv reads, fetch responses) is then discovered by running `sim`
and filling the `holes` it reports. So the whole loop is:

    rewind sim  <(from_curl "curl -X POST https://shop.x/checkout -d '{...}'")  --source-dir .
    # → read holes → add kv / fetches → re-run

Pass --scenario to emit a scenario stub (empty `fetches`) for the saga driver.
Recognises the common flags (copy-as-curl from browser devtools works):
  -X/--request, -H/--header, -d/--data[-raw|-binary|-ascii], --json, -b/--cookie,
  -u/--user, -A/--user-agent, -e/--referer, --url. Noise flags (-s -v -k -L
  --compressed -o …) are ignored.
"""
import base64, json, shlex, sys
from urllib.parse import urlsplit

_TAKES_ARG = {"-X", "--request", "-H", "--header", "-d", "--data", "--data-raw",
              "--data-binary", "--data-ascii", "--json", "-b", "--cookie", "-u",
              "--user", "-A", "--user-agent", "-e", "--referer", "--url", "-o",
              "--output", "-A", "-m", "--max-time", "--connect-timeout"}


def parse_curl(cmd):
    toks = shlex.split(cmd)
    if toks and toks[0] == "curl":
        toks = toks[1:]
    method, url, headers, data, is_json = None, None, {}, [], False
    i = 0
    while i < len(toks):
        t = toks[i]
        val = toks[i + 1] if (t in _TAKES_ARG and i + 1 < len(toks)) else None
        if t in ("-X", "--request"):
            method = val; i += 2; continue
        if t in ("-H", "--header"):
            if ":" in val:
                k, v = val.split(":", 1); headers[k.strip().lower()] = v.strip()
            i += 2; continue
        if t in ("-d", "--data", "--data-raw", "--data-binary", "--data-ascii"):
            data.append(val); i += 2; continue
        if t == "--json":
            data.append(val); is_json = True; i += 2; continue
        if t in ("-b", "--cookie"):
            headers["cookie"] = val; i += 2; continue
        if t in ("-u", "--user"):
            headers["authorization"] = "Basic " + base64.b64encode(val.encode()).decode()
            i += 2; continue
        if t in ("-A", "--user-agent"):
            headers["user-agent"] = val; i += 2; continue
        if t in ("-e", "--referer"):
            headers["referer"] = val; i += 2; continue
        if t == "--url":
            url = val; i += 2; continue
        if t in _TAKES_ARG:            # a recognised-but-ignored arg-taking flag
            i += 2; continue
        if t.startswith("-"):          # an ignored bare flag (-s, -v, -k, …)
            i += 1; continue
        url = t; i += 1                # positional → the URL

    if url is None:
        raise SystemExit("from_curl: no URL found in the curl command")
    if is_json:
        headers.setdefault("content-type", "application/json")
    if method is None:
        method = "POST" if data else "GET"

    u = urlsplit(url if "://" in url else "https://" + url)
    path = u.path or "/"
    if u.query:
        path += "?" + u.query

    body = "&".join(data) if data else None
    # If the body is JSON, carry it as a JSON value so world.json stays readable
    # (world.zig re-stringifies it to the byte string the handler parses).
    if body is not None and "json" in headers.get("content-type", ""):
        try:
            body = json.loads(body)
        except ValueError:
            pass

    req = {"method": method, "path": path, "host": u.netloc}
    if headers:
        req["headers"] = headers
    if body is not None:
        req["body"] = body
    return req


def main():
    scenario = "--scenario" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--scenario"]
    entry = "index.mjs"
    if "--entry" in args:
        k = args.index("--entry"); entry = args[k + 1]; del args[k:k + 2]
    cmd = args[0] if args else sys.stdin.read()
    req = parse_curl(cmd)
    world = {"entry": entry, "activation": "inbound", "request": req,
             "kv": {}, "missPolicy": "resolve", "seed": 0}
    if scenario:
        world.update({"kind": "scenario", "fetches": [], "scheduler": {"mode": "seed"}})
    json.dump(world, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
