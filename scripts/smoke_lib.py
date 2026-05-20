"""Smoke harness — Python replacement for `scripts/_smoke_helpers.sh`.

Bash smokes use `pkill -f` for cleanup, which (1) silently matches the
wrapper bash itself if the pattern is in argv, (2) leaves stragglers
when the bash script is SIGTERM'd before its EXIT trap fires (e.g.
under `timeout` or interactive Ctrl-C). The Python harness tracks every
spawned process by `Popen` object and runs `Cluster.shutdown` in a
`finally` plus `atexit` so cleanup runs on every exit path — normal
return, exception, signal.

Other improvements over bash:

  - Leader discovery polls with `time.monotonic` instead of fixed
    `sleep 0.2` loops; spurious failures are flagged with the worker
    logs so the operator knows where to look.
  - HTTP calls shell out to `curl` (mirrors bash for h2 + TLS + resolve)
    but capture exit codes + bodies as Python strings, so assertion
    failures print a structured `expected/got` line instead of bare
    grep mismatches.
  - JWT minting and `_system/services-token` parsing are pure Python
    (no `python3 -c` inline embedded in bash quoting).

Conversion pattern: `scripts/ctl_smoke.py` is the reference example.
"""

from __future__ import annotations

import atexit
import base64
import hashlib
import hmac
import json
import os
import platform
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parent.parent
BIN_DIR = REPO_ROOT / "zig-out" / "bin"


# ── env / TLS / S3 prereqs ─────────────────────────────────────────────


def _load_dotenv() -> None:
    """Mirror `_smoke_helpers.sh`'s `.env` source. AWS_* + S3_* live there."""
    env_path = REPO_ROOT / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        # Strip optional surrounding quotes.
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        os.environ.setdefault(k.strip(), v.strip())


def _require_env(*names: str) -> None:
    missing = [n for n in names if not os.environ.get(n)]
    if missing:
        sys.exit(f"error: {', '.join(missing)} not set (need .env at repo root)")


def loop46_data_dir() -> Path:
    """TLS certs + ca-root live here. Mirrors the bash `LOOP46_DATA`."""
    if "LOOP46_DATA" in os.environ:
        return Path(os.environ["LOOP46_DATA"])
    if platform.system() == "Darwin":
        return Path.home() / "Library" / "Application Support" / "loop46"
    xdg = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))
    return Path(xdg) / "loop46"


@dataclass
class TlsBundle:
    cert: Path
    key: Path
    cacert: Path

    @classmethod
    def from_env(cls) -> "TlsBundle":
        d = loop46_data_dir()
        cert = d / "dev-cert.pem"
        key = d / "dev-key.pem"
        cacert = d / "ca-root.pem"
        if not cert.exists() or not key.exists():
            sys.exit(
                f"error: missing TLS at {d}. Run scripts/gen-dev-cert.sh "
                "once to generate dev-cert.pem + dev-key.pem + ca-root.pem "
                "(SANs cover *.rewindjsapp.localhost + *.rewindjscom.localhost)."
            )
        return cls(cert=cert, key=key, cacert=cacert)


# ── process tracking + cleanup ─────────────────────────────────────────


_TRACKED_PROCS: list[subprocess.Popen] = []


def _terminate_all() -> None:
    """SIGTERM every tracked process, wait briefly, then SIGKILL holdouts."""
    for p in _TRACKED_PROCS:
        if p.poll() is None:
            with suppress(ProcessLookupError):
                p.terminate()
    deadline = time.monotonic() + 2.0
    for p in _TRACKED_PROCS:
        remaining = max(0.0, deadline - time.monotonic())
        with suppress(subprocess.TimeoutExpired, ProcessLookupError):
            p.wait(timeout=remaining)
    for p in _TRACKED_PROCS:
        if p.poll() is None:
            with suppress(ProcessLookupError):
                p.kill()


atexit.register(_terminate_all)


def _install_signal_handlers() -> None:
    """Trap SIGINT / SIGTERM so atexit gets to run cleanup before exit."""
    def handler(signum, _frame):
        sys.stderr.write(f"\nsmoke: caught signal {signum}, shutting down\n")
        sys.exit(130 if signum == signal.SIGINT else 143)
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


# ── HTTP helpers (shell to curl, matches bash smokes byte-for-byte) ────


@dataclass
class CurlContext:
    """Resolve-overridden curl invocation. Mirrors the `CURL` bash array."""
    cacert: Path
    resolves: list[tuple[str, int]] = field(default_factory=list)
    """[(host, port), ...] — each entry adds `--resolve host:port:127.0.0.1`."""

    def args(self) -> list[str]:
        out = ["curl", "-sS", "--cacert", str(self.cacert)]
        for host, port in self.resolves:
            out += ["--resolve", f"{host}:{port}:127.0.0.1"]
        return out


@dataclass
class HttpResponse:
    status: int
    body: str
    headers: dict[str, str]


def curl(
    ctx: CurlContext,
    url: str,
    *,
    method: str = "GET",
    headers: Optional[dict[str, str]] = None,
    data: Optional[bytes | str] = None,
    timeout: float = 30.0,
) -> HttpResponse:
    args = ctx.args() + ["-D", "-", "-o", "-", "-X", method]
    if headers:
        for k, v in headers.items():
            args += ["-H", f"{k}: {v}"]
    if data is not None:
        if isinstance(data, str):
            data = data.encode()
        args += ["--data-binary", "@-"]
    args.append(url)
    proc = subprocess.run(
        args,
        input=data if data is not None else b"",
        capture_output=True,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"curl {method} {url} exited {proc.returncode}: "
            f"{proc.stderr.decode(errors='replace')}"
        )
    # `-D -` interleaves headers before body on stdout. Split on the
    # blank line that separates them. With redirects, multiple header
    # blocks; take the last.
    raw = proc.stdout
    split = raw.rfind(b"\r\n\r\n")
    if split < 0:
        return HttpResponse(status=0, body=raw.decode(errors="replace"), headers={})
    header_block = raw[:split].decode(errors="replace")
    body = raw[split + 4 :].decode(errors="replace")
    lines = header_block.splitlines()
    status_line = next(
        (l for l in reversed(lines) if l.startswith("HTTP/")), ""
    )
    status = 0
    parts = status_line.split(" ", 2)
    if len(parts) >= 2 and parts[1].isdigit():
        status = int(parts[1])
    headers_out: dict[str, str] = {}
    for line in lines:
        if not line.startswith("HTTP/") and ":" in line:
            k, _, v = line.partition(":")
            headers_out[k.strip().lower()] = v.strip()
    return HttpResponse(status=status, body=body, headers=headers_out)


# ── OIDC relying-party login (admin is a pure RP, Fork B) ──────────────


def _sid_cookie(resp: "HttpResponse") -> Optional[str]:
    m = re.search(r"__Host-rove_sid=[^;]+", resp.headers.get("set-cookie", ""))
    return m.group(0) if m else None


def idp_login(
    cc: "CurlContext",
    *,
    email: str,
    app_origin: str,
    auth_base: str,
) -> str:
    """Drive the full OIDC relying-party handshake as `email` and
    return the app `__Host-rove_sid` cookie for authenticated admin
    calls. Operator-ness (is_root) is decided server-side by the
    `_admin/operator/*` allowlist — the flow is identical either way.

    `cc` must --resolve both the app (admin) host and the IdP host.
    `app_origin` = https://app.<sfx>:<port>; `auth_base` =
    https://auth.<sfx>:<port>. Mirrors the browser: app /_rp/login →
    IdP /authorize → /login(POST, dev magic_link) → verify → /authorize
    → app /_rp/callback → poll until the async completion lands.
    """
    def _abs(base: str, loc: str) -> str:
        return loc if loc.startswith("http") else base + loc

    # 1. app /_rp/login → 302 to the IdP /authorize (mints app sid).
    r = curl(cc, app_origin + "/_rp/login?return_to="
                 + urllib.parse.quote("/#/instances"))
    if r.status != 302:
        raise RuntimeError(f"/_rp/login {r.status}: {r.body[:200]}")
    app_cookie = _sid_cookie(r)
    if not app_cookie:
        raise RuntimeError(f"/_rp/login minted no app sid: {r.headers}")
    authorize = r.headers["location"]

    # 2. IdP /authorize, no IdP session → 302 to /login (mints auth sid).
    r = curl(cc, authorize)
    if r.status != 302:
        raise RuntimeError(
            f"/authorize#1 {r.status}: {r.body[:200]}\n  authorize={authorize}")
    auth_cookie = _sid_cookie(r)
    if not auth_cookie:
        raise RuntimeError("/authorize#1 minted no auth sid")
    login_loc = _abs(auth_base, r.headers["location"])
    return_to = urllib.parse.parse_qs(
        urllib.parse.urlparse(login_loc).query)["return_to"][0]

    # 3. POST IdP /login (dev: no resend key → magic_link in JSON).
    r = curl(cc, auth_base + "/login", method="POST",
             headers={"content-type": "application/x-www-form-urlencoded",
                      "Cookie": auth_cookie},
             data="email=" + urllib.parse.quote(email)
                  + "&return_to=" + urllib.parse.quote(return_to))
    if r.status != 200:
        raise RuntimeError(f"/login POST {r.status}: {r.body[:200]}")
    magic_link = json.loads(r.body)["magic_link"]

    # 4. Follow the magic link (carry auth sid) → binds the IdP
    #    session, 302s back to /authorize.
    r = curl(cc, magic_link, headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"/login/verify {r.status}: {r.body[:200]}")

    # 5. /authorize again (now authenticated) → 302 to app /_rp/callback.
    r = curl(cc, _abs(auth_base, r.headers["location"]),
             headers={"Cookie": auth_cookie})
    if r.status != 302:
        raise RuntimeError(f"/authorize#2 {r.status}: {r.body[:200]}")
    callback = r.headers["location"]

    # 6. app /_rp/callback (carry app sid) → 202 poll page; this fires
    #    the async token exchange + jwks verify completion chain.
    r = curl(cc, callback, headers={"Cookie": app_cookie})
    if r.status != 202:
        raise RuntimeError(f"/_rp/callback {r.status}: {r.body[:200]}")

    # 7. Poll until the background completion writes _rp/sess/{sid}.
    last = ""
    for _ in range(160):
        r = curl(cc, app_origin + "/_rp/poll", headers={"Cookie": app_cookie})
        last = r.body
        if r.status == 200:
            try:
                if json.loads(r.body).get("authed"):
                    return app_cookie
            except Exception:
                pass
        time.sleep(0.25)
    raise RuntimeError(f"RP login never completed for {email}: {last[:200]}")


# ── JWT mint (matches the bash `WRONG_JWT` recipe) ─────────────────────


def _b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def mint_jwt(secret_hex: str, payload: dict, *, alg: str = "HS256") -> str:
    """HS256 JWT with the same shape worker / files-server / log-server expect.

    `secret_hex` is the hex-encoded shared secret (what `gen_jwt_secret` in
    bash produced). `payload` is dict-ified; caller supplies `exp` etc.
    """
    if alg != "HS256":
        raise NotImplementedError(alg)
    header = json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    # IMPORTANT: compact separators — the worker's `hasCap` searches for
    # the literal substring `"caps":[`, so dumps' default `, ` spacing
    # produces a 401. See memory/feedback_python_jwt_compact_json.md.
    body = json.dumps(payload, separators=(",", ":")).encode()
    signing_input = (_b64u(header) + "." + _b64u(body)).encode()
    sig = hmac.new(bytes.fromhex(secret_hex), signing_input, hashlib.sha256).digest()
    return signing_input.decode() + "." + _b64u(sig)


def gen_jwt_secret() -> str:
    """32-byte hex secret; suitable for `LOOP46_SERVICES_JWT_SECRET`."""
    return secrets.token_hex(32)


# ── cluster ────────────────────────────────────────────────────────────


@dataclass
class ClusterAddrs:
    http: list[str]
    raft: list[str]
    data_dirs: list[Path]
    public_suffix: str   # customer tenant wildcard (rewindjsapp.localhost)
    system_suffix: str   # system surfaces — admin/replay (rewindjscom.localhost)
    admin_host: str
    files_addr: str
    log_addr: str
    custom_cert_dir: Optional[str] = None  # --custom-cert-dir (per-host SNI)

    @property
    def peers_csv(self) -> str:
        return ",".join(self.raft)

    def http_port(self, idx: int) -> int:
        return int(self.http[idx].rsplit(":", 1)[1])

    @property
    def files_port(self) -> int:
        return int(self.files_addr.rsplit(":", 1)[1])

    @property
    def log_port(self) -> int:
        return int(self.log_addr.rsplit(":", 1)[1])


@dataclass
class Cluster:
    """3-node cluster + optional files-server / log-server / schedule-server.

    Usage:
        with Cluster.spawn(tag="my_smoke", http_base=8197, ...) as c:
            c.discover_leader()
            c.mint_services_token()
            ...

    `__exit__` SIGTERMs every spawned process; `atexit` does the same
    as a backstop in case the context manager is bypassed.
    """

    tag: str
    addrs: ClusterAddrs
    tls: TlsBundle
    root_token: str
    services_jwt_secret: str
    workers: list[subprocess.Popen] = field(default_factory=list)
    files_server: Optional[subprocess.Popen] = None
    log_server: Optional[subprocess.Popen] = None
    schedule_server: Optional[subprocess.Popen] = None
    leader_idx: Optional[int] = None
    services_jwt: Optional[str] = None
    log_base: Optional[str] = None
    files_base: Optional[str] = None
    log_dir: Path = field(default_factory=lambda: Path("/tmp"))
    bind_host: str = "127.0.0.1"

    @classmethod
    def alloc_addrs(
        cls,
        *,
        tag: str,
        http_base: int,
        raft_base: int,
        files_port: int,
        log_port: int,
        public_suffix: str = "rewindjsapp.localhost",
        system_suffix: str = "rewindjscom.localhost",
        custom_cert_dir: Optional[str] = None,
    ) -> ClusterAddrs:
        return ClusterAddrs(
            http=[f"127.0.0.1:{http_base + i}" for i in range(3)],
            raft=[f"127.0.0.1:{raft_base + i}" for i in range(3)],
            data_dirs=[Path(f"/tmp/rove-{tag}-{i}") for i in range(3)],
            public_suffix=public_suffix,
            system_suffix=system_suffix,
            # Admin is a system surface → derived from system_suffix,
            # never the customer public_suffix (the two-domain split).
            admin_host=f"app.{system_suffix}",
            files_addr=f"127.0.0.1:{files_port}",
            log_addr=f"127.0.0.1:{log_port}",
            custom_cert_dir=custom_cert_dir,
        )

    @classmethod
    def spawn(
        cls,
        *,
        tag: str,
        http_base: int,
        raft_base: int,
        files_port: int = 0,
        log_port: int = 0,
        public_suffix: str = "rewindjsapp.localhost",
        system_suffix: str = "rewindjscom.localhost",
        custom_cert_dir: Optional[str] = None,
        workers_per_node: int = 2,
        seed_manifest: Optional[dict | Path] = None,
        seed_extra_args: Optional[list[str]] = None,
        worker_extra_args: Optional[list[str]] = None,
        root_token: Optional[str] = None,
        admin_origin_per_node: bool = False,
        admin_api_domain: Optional[str] = None,
        with_log_files_bases: bool = True,
        bind_host: str = "127.0.0.1",
        tls_bundle: Optional["TlsBundle"] = None,
    ) -> "Cluster":
        """Spawn 3-node loop46 cluster.

        - `seed_manifest`: dict or Path to manifest JSON; runs `loop46 seed`
          against every data dir before workers start.
        - `worker_extra_args`: appended to every worker's argv.
        - `root_token`: override LOOP46_ROOT_TOKEN (defaults to a fresh
          random 32-hex secret); pass an explicit one when the smoke
          script bakes the token into curl commands.
        - `admin_origin_per_node`: stamp `--admin-origin https://{admin_host}:{port}`
          on each worker (admin-API-on-public-suffix mode used by
          cookie_auth/admin smokes).
        - `admin_api_domain`: pass `--admin-api-domain {value}` to enable
          subdomain-scoped admin API.
        - `with_log_files_bases`: pass `--log-public-base` + `--files-public-base`;
          skip for smokes that don't run standalones.
        - `files_port` / `log_port`: zero → arbitrary unused port (still
          allocated but no standalone spawned by default).
        """
        _load_dotenv()
        _require_env(
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "S3_BUCKET",
            "S3_ENDPOINT",
            "S3_REGION",
        )
        _install_signal_handlers()

        tls = tls_bundle if tls_bundle is not None else TlsBundle.from_env()
        bin_loop46 = BIN_DIR / "loop46"
        if not bin_loop46.exists():
            sys.exit(f"error: {bin_loop46} missing — run 'zig build install' first")

        addrs = cls.alloc_addrs(
            tag=tag,
            http_base=http_base,
            raft_base=raft_base,
            files_port=files_port,
            log_port=log_port,
            public_suffix=public_suffix,
            system_suffix=system_suffix,
            custom_cert_dir=custom_cert_dir,
        )
        for d in addrs.data_dirs:
            if d.exists():
                shutil.rmtree(d)

        # Per-smoke S3 prefix mirrors `_smoke_helpers.sh` so reruns
        # hit the warm-S3 fast path.
        binhash = "nobin"
        fs_bin = BIN_DIR / "files-server-standalone"
        if fs_bin.exists():
            binhash = hashlib.sha256(fs_bin.read_bytes()).hexdigest()[:12]
        dev_id = f"{socket.gethostname()}-{os.getuid()}-{binhash}"
        os.environ.setdefault(
            "S3_KEY_PREFIX_BASE", f"smoke-{tag}-{dev_id}/"
        )

        # Stash JWT secret + root token into the parent process env so
        # every subsequent spawned process inherits them (workers,
        # files-server, log-server, schedule-server). The bash smokes
        # `export`ed these for the same reason.
        os.environ["LOOP46_SERVICES_JWT_SECRET"] = gen_jwt_secret()
        if root_token is None:
            root_token = secrets.token_hex(16)
        os.environ["LOOP46_ROOT_TOKEN"] = root_token
        env = os.environ

        c = cls(
            tag=tag,
            addrs=addrs,
            tls=tls,
            root_token=root_token,
            services_jwt_secret=env["LOOP46_SERVICES_JWT_SECRET"],
            bind_host=bind_host,
        )

        # Seed every data dir if a manifest was supplied.
        if seed_manifest is not None:
            if isinstance(seed_manifest, Path):
                seed_path = seed_manifest
            else:
                seed_path = Path(f"/tmp/{tag}-seed.json")
                seed_path.write_text(json.dumps(seed_manifest))
            for d in addrs.data_dirs:
                d.mkdir(parents=True, exist_ok=True)
                args = [
                    str(bin_loop46), "seed",
                    "--data-dir", str(d),
                    "--manifest", str(seed_path),
                ] + (seed_extra_args or [])
                subprocess.run(args, check=True, env=env, capture_output=True)

        # `bind_host` rewrites the loopback host in the --http /
        # files-server --listen / log-server --listen strings the
        # workers pass to their listening sockets. Internal probing
        # (discover_leader, mint_services_token, etc.) keeps
        # dialing 127.0.0.1 — `addrs.http[i]` stays loopback so
        # cross-node raft peers + the harness itself can still reach
        # the cluster from this host.
        def listen_addr(internal: str) -> str:
            if bind_host == "127.0.0.1":
                return internal
            _, _, port = internal.rpartition(":")
            return f"{bind_host}:{port}"

        # Spawn workers.
        for i in range(3):
            log_path = c.log_dir / f"{tag}-worker-{i}.out"
            args = [
                str(bin_loop46), "worker",
                "--node-id", str(i),
                "--peers", addrs.peers_csv,
                "--listen", addrs.raft[i],
                "--http", listen_addr(addrs.http[i]),
                "--data-dir", str(addrs.data_dirs[i]),
                "--public-suffix", public_suffix,
                "--system-suffix", system_suffix,
                "--tls-cert", str(tls.cert),
                "--tls-key", str(tls.key),
                "--workers", str(workers_per_node),
                # Match the bash default RAFT_TIMING_FLAGS.
                "--election-timeout-ms", "200",
                "--heartbeat-ms", "50",
            ]
            if custom_cert_dir:
                args += ["--custom-cert-dir", custom_cert_dir]
            if with_log_files_bases:
                # Hostname form (logs.{public_suffix}, files.{public_suffix})
                # rather than 127.0.0.1:port — keeps the TLS SAN matching
                # the cert and matches what production deployments emit.
                args += [
                    "--log-public-base", f"https://logs.{public_suffix}:{addrs.log_port}",
                    "--files-public-base", f"https://files.{public_suffix}:{addrs.files_port}",
                ]
            if admin_origin_per_node:
                port = http_base + i
                args += ["--admin-origin", f"https://{addrs.admin_host}:{port}"]
            if admin_api_domain:
                args += ["--admin-api-domain", admin_api_domain]
            args += worker_extra_args or []
            f = open(log_path, "wb")
            p = subprocess.Popen(args, env=env, stdout=f, stderr=subprocess.STDOUT)
            c.workers.append(p)
            _TRACKED_PROCS.append(p)
        return c

    # ── Context manager ────────────────────────────────────────────────

    def __enter__(self) -> "Cluster":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.shutdown()

    def stop_node(self, idx: int) -> None:
        """SIGTERM node `idx`'s worker process and wait for exit."""
        p = self.workers[idx]
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                p.kill()

    def start_node(self, idx: int, *, extra_args: Optional[list[str]] = None,
                   override_args: Optional[list[str]] = None,
                   log_suffix: str = "") -> None:
        """Spawn a fresh worker process for node `idx` and replace the
        Popen entry in `self.workers`. Used by failover / snap-catchup
        smokes that take a node down and back up.

        `override_args` (if set) replaces the entire argv tail after
        `worker` — useful for learner-promote-style restarts that need
        a different --peers / --node-id shape.
        """
        bin_loop46 = BIN_DIR / "loop46"
        log_path = self.log_dir / f"{self.tag}-worker-{idx}{log_suffix}.out"
        if override_args is not None:
            args = [str(bin_loop46), "worker"] + override_args
        else:
            args = [
                str(bin_loop46), "worker",
                "--node-id", str(idx),
                "--peers", self.addrs.peers_csv,
                "--listen", self.addrs.raft[idx],
                "--http", self.addrs.http[idx],
                "--data-dir", str(self.addrs.data_dirs[idx]),
                "--public-suffix", self.addrs.public_suffix,
                "--system-suffix", self.addrs.system_suffix,
                "--tls-cert", str(self.tls.cert),
                "--tls-key", str(self.tls.key),
                "--workers", "1",
                "--election-timeout-ms", "200",
                "--heartbeat-ms", "50",
            ] + (
                ["--custom-cert-dir", self.addrs.custom_cert_dir]
                if self.addrs.custom_cert_dir else []
            ) + (extra_args or [])
        f = open(log_path, "ab")
        p = subprocess.Popen(args, env=os.environ, stdout=f, stderr=subprocess.STDOUT)
        if idx < len(self.workers):
            self.workers[idx] = p
        else:
            self.workers.append(p)
        _TRACKED_PROCS.append(p)

    def shutdown(self) -> None:
        for p in (self.files_server, self.log_server, self.schedule_server):
            if p is not None and p.poll() is None:
                with suppress(ProcessLookupError):
                    p.terminate()
        for p in self.workers:
            if p.poll() is None:
                with suppress(ProcessLookupError):
                    p.terminate()
        deadline = time.monotonic() + 2.0
        for p in self.workers + [
            x
            for x in (self.files_server, self.log_server, self.schedule_server)
            if x is not None
        ]:
            remaining = max(0.0, deadline - time.monotonic())
            with suppress(subprocess.TimeoutExpired, ProcessLookupError):
                p.wait(timeout=remaining)
            if p.poll() is None:
                with suppress(ProcessLookupError):
                    p.kill()

    # ── Curl context ───────────────────────────────────────────────────

    def curl_ctx(self, *extra_hosts: str) -> CurlContext:
        """A CurlContext that resolves admin + every tenant subdomain + the
        standalones to 127.0.0.1 on the right ports."""
        resolves: list[tuple[str, int]] = [
            (f"files.{self.addrs.public_suffix}", self.addrs.files_port),
            (f"logs.{self.addrs.public_suffix}", self.addrs.log_port),
        ]
        for i in range(3):
            p = self.addrs.http_port(i)
            resolves.append((self.addrs.admin_host, p))
            for host in extra_hosts:
                resolves.append((host, p))
        return CurlContext(cacert=self.tls.cacert, resolves=resolves)

    # ── Leader discovery ───────────────────────────────────────────────

    def discover_leader(self, *, timeout_s: float = 15.0) -> int:
        """Poll each node's /_system/leader; return the leader's index."""
        deadline = time.monotonic() + timeout_s
        ctx = self.curl_ctx()
        while time.monotonic() < deadline:
            for i in range(3):
                p = self.addrs.http_port(i)
                url = f"https://{self.addrs.admin_host}:{p}/_system/leader"
                try:
                    r = curl(
                        ctx,
                        url,
                        headers={"Authorization": f"Bearer {self.root_token}"},
                        timeout=2.0,
                    )
                except (subprocess.TimeoutExpired, RuntimeError):
                    continue
                if r.status == 200:
                    self.leader_idx = i
                    return i
            time.sleep(0.2)
        # Dump worker tails so the operator can see WHY no leader.
        for i in range(3):
            log_path = self.log_dir / f"{self.tag}-worker-{i}.out"
            if log_path.exists():
                sys.stderr.write(f"--- worker {i} log (last 30 lines) ---\n")
                with log_path.open() as f:
                    lines = f.readlines()[-30:]
                sys.stderr.writelines(lines)
        raise RuntimeError(f"no leader elected within {timeout_s}s")

    def leader_port(self) -> int:
        if self.leader_idx is None:
            raise RuntimeError("call discover_leader() first")
        return self.addrs.http_port(self.leader_idx)

    def admin_origin(self) -> str:
        return f"https://{self.addrs.admin_host}:{self.leader_port()}"

    # ── Admin OIDC (Fork B): the admin surface is a pure OIDC RP.
    # Smokes that drive admin RPCs seed the RP config + an operator
    # allowlist via these two helpers (the rove-loop46-serve.sh prod
    # channel) and authenticate with a real RP handshake. ──

    def auth_base(self) -> str:
        return f"https://auth.{self.addrs.system_suffix}:{self.leader_port()}"

    def admin_oidc_kv(self, *operator_emails: str) -> list[str]:
        """`--bootstrap-kv` args seeding `_oidc/rp/default` (admin RP
        config, host-derived) + an `_admin/operator/{sha256(email)}`
        allowlist entry per operator. Call AFTER `discover_leader`
        (needs the leader port). Pass to `spawn_files_server(extra_args=…)`.
        """
        rp_cfg = json.dumps({
            "issuer": self.auth_base(),
            "client_id": "admin-dashboard",
            "redirect_uri": f"{self.admin_origin()}/_rp/callback",
            "post_login": "/",
            "operator_prefix": "_admin/operator/",
        }, separators=(",", ":"))
        args = ["--bootstrap-kv", "_oidc/rp/default=" + rp_cfg]
        for em in operator_emails:
            h = hashlib.sha256(em.encode()).hexdigest()
            args += ["--bootstrap-kv", f"_admin/operator/{h}="]
        return args

    def oidc_login(self, cc: "CurlContext", email: str) -> str:
        """Full OIDC RP handshake as `email`; returns the app session
        cookie for authenticated admin calls. is_root iff `email` was
        seeded via `admin_oidc_kv`. `cc` must --resolve the IdP host
        (`auth.{system_suffix}`) — pass it to `curl_ctx`."""
        return idp_login(
            cc,
            email=email,
            app_origin=self.admin_origin(),
            auth_base=self.auth_base(),
        )

    # ── Standalones (files-server, log-server) ─────────────────────────

    def spawn_files_server(
        self,
        *,
        cors_origin: Optional[str] = None,
        leader_url: Optional[str] = None,
        extra_args: Optional[list[str]] = None,
        startup_timeout_s: float = 2.0,
    ) -> None:
        bin_path = BIN_DIR / "files-server-standalone"
        log_path = self.log_dir / f"{self.tag}-files-server.out"
        env = os.environ.copy()
        if leader_url is not None:
            env["LOOP46_LEADER_CACERT"] = str(self.tls.cacert)
            host_port = leader_url.split("://", 1)[1]
            env["LOOP46_LEADER_RESOLVE"] = f"{host_port}:127.0.0.1"
        files_listen = self.addrs.files_addr
        if self.bind_host != "127.0.0.1":
            files_listen = f"{self.bind_host}:{self.addrs.files_port}"
        args = [
            str(bin_path),
            "--data-dir", str(self.addrs.data_dirs[self.leader_idx]),
            "--listen", files_listen,
            "--tls-cert", str(self.tls.cert),
            "--tls-key", str(self.tls.key),
        ]
        if cors_origin:
            args += ["--cors-origin", cors_origin]
        if leader_url:
            args += ["--leader-url", leader_url]
            # --web-root points at the source tree the bootstrap reads
            # admin/ and replay/ source from. The smokes run from the
            # repo root, so `web` is always next to the script.
            args += ["--web-root", str(REPO_ROOT / "web")]
        args += extra_args or []
        f = open(log_path, "wb")
        self.files_server = subprocess.Popen(
            args, env=env, stdout=f, stderr=subprocess.STDOUT
        )
        _TRACKED_PROCS.append(self.files_server)
        self._wait_for_log(log_path, "listening on", startup_timeout_s, "files-server")
        if leader_url:
            self._wait_for_log(log_path, "__replay__ deploy", 15.0, "files-server bootstrap")

    def spawn_log_server(
        self,
        *,
        cors_origin: Optional[str] = None,
        startup_timeout_s: float = 2.0,
    ) -> None:
        bin_path = BIN_DIR / "log-server-standalone"
        log_path = self.log_dir / f"{self.tag}-log-server.out"
        log_listen = self.addrs.log_addr
        if self.bind_host != "127.0.0.1":
            log_listen = f"{self.bind_host}:{self.addrs.log_port}"
        args = [
            str(bin_path),
            "--data-dir", str(self.addrs.data_dirs[self.leader_idx]),
            "--listen", log_listen,
            "--poll-interval-ms", "100",
            "--tls-cert", str(self.tls.cert),
            "--tls-key", str(self.tls.key),
        ]
        if cors_origin:
            args += ["--cors-origin", cors_origin]
        f = open(log_path, "wb")
        self.log_server = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT)
        _TRACKED_PROCS.append(self.log_server)
        self._wait_for_log(log_path, "listening on", startup_timeout_s, "log-server")

    def _wait_for_log(
        self,
        log_path: Path,
        needle: str,
        timeout_s: float,
        what: str,
    ) -> None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                contents = log_path.read_text(errors="replace")
            except FileNotFoundError:
                contents = ""
            if needle in contents:
                return
            time.sleep(0.1)
        sys.stderr.write(
            f"{what}: didn't see '{needle}' in {log_path} within {timeout_s}s\n"
            f"--- {log_path} ---\n"
        )
        sys.stderr.write(log_path.read_text(errors="replace"))
        raise RuntimeError(f"{what} startup timeout")

    # ── Services-token mint ────────────────────────────────────────────

    def mint_services_token(self) -> None:
        ctx = self.curl_ctx()
        r = curl(
            ctx,
            f"{self.admin_origin()}/_system/services-token",
            headers={"Authorization": f"Bearer {self.root_token}"},
        )
        if r.status != 200:
            raise RuntimeError(
                f"/_system/services-token returned {r.status}: {r.body}"
            )
        parsed = json.loads(r.body)
        self.services_jwt = parsed["token"]
        self.log_base = parsed.get("log_url")
        self.files_base = parsed.get("files_url")

    # ── Files-server convenience ────────────────────────────────────────

    def files_url(self) -> str:
        return f"https://files.{self.addrs.public_suffix}:{self.addrs.files_port}"

    def log_url(self) -> str:
        return f"https://logs.{self.addrs.public_suffix}:{self.addrs.log_port}"

    def upload_source(self, tenant: str, path: str, content: bytes | str) -> None:
        """POST {files_url}/{tenant}/upload with X-Rove-Path."""
        if isinstance(content, str):
            content = content.encode()
        r = curl(
            self.curl_ctx(f"{tenant}.{self.addrs.public_suffix}"),
            f"{self.files_url()}/{tenant}/upload",
            method="POST",
            headers={
                "Authorization": f"Bearer {self.services_jwt}",
                "X-Rove-Path": path,
            },
            data=content,
        )
        if r.status != 204:
            raise RuntimeError(f"upload {tenant}/{path}: {r.status} {r.body}")

    def upload_static(self, tenant: str, path: str, content: bytes | str, content_type: str) -> None:
        """POST {files_url}/{tenant}/upload-static."""
        if isinstance(content, str):
            content = content.encode()
        r = curl(
            self.curl_ctx(f"{tenant}.{self.addrs.public_suffix}"),
            f"{self.files_url()}/{tenant}/upload-static",
            method="POST",
            headers={
                "Authorization": f"Bearer {self.services_jwt}",
                "X-Rove-Path": path,
                "X-Rove-Content-Type": content_type,
            },
            data=content,
        )
        if r.status != 204:
            raise RuntimeError(f"upload-static {tenant}/{path}: {r.status} {r.body}")

    def deploy(self, tenant: str) -> str:
        """POST {files_url}/{tenant}/deploy → returns dep_id (decimal string)."""
        r = curl(
            self.curl_ctx(f"{tenant}.{self.addrs.public_suffix}"),
            f"{self.files_url()}/{tenant}/deploy",
            method="POST",
            headers={"Authorization": f"Bearer {self.services_jwt}"},
        )
        if r.status != 200:
            raise RuntimeError(f"deploy {tenant}: {r.status} {r.body}")
        dep_id = r.body.strip()
        if not dep_id:
            raise RuntimeError(f"deploy {tenant}: empty body")
        return dep_id

    def release(self, tenant: str, dep_id: str | int) -> None:
        """POST /_system/release — flip `_deploy/current` to `dep_id`."""
        r = curl(
            self.curl_ctx(),
            f"{self.admin_origin()}/_system/release",
            method="POST",
            headers={
                "Authorization": f"Bearer {self.root_token}",
                "Content-Type": "application/json",
            },
            data=f'{{"tenant_id":"{tenant}","dep_id":{dep_id}}}',
        )
        if r.status != 204:
            raise RuntimeError(f"release {tenant}/{dep_id}: {r.status} {r.body}")

    def deploy_handlers(self, tenant: str, files: dict[str, str]) -> str:
        """Upload + deploy + release in one shot. Returns dep_id."""
        for path, content in files.items():
            self.upload_source(tenant, path, content)
        dep_id = self.deploy(tenant)
        self.release(tenant, dep_id)
        return dep_id

    def put_file(self, tenant: str, path: str, content: bytes | str, *, content_type: str = "application/javascript") -> str:
        """PUT {files_url}/{tenant}/file/{path} — single-file commit shortcut.
        Returns dep_id from the response body (201 status)."""
        if isinstance(content, str):
            content = content.encode()
        r = curl(
            self.curl_ctx(f"{tenant}.{self.addrs.public_suffix}"),
            f"{self.files_url()}/{tenant}/file/{path}",
            method="PUT",
            headers={
                "Authorization": f"Bearer {self.services_jwt}",
                "Content-Type": content_type,
            },
            data=content,
        )
        if r.status != 201:
            raise RuntimeError(f"PUT file {tenant}/{path}: {r.status} {r.body}")
        return r.body.strip()

    def respawn_files_server(self, **kwargs) -> None:
        """Kill the current files-server and start a new one (with possibly
        different args, e.g. --bootstrap-kv). Re-mints services_jwt
        automatically because the old token may have expired."""
        if self.files_server is not None and self.files_server.poll() is None:
            self.files_server.terminate()
            try:
                self.files_server.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.files_server.kill()
            self.files_server = None
        self.spawn_files_server(**kwargs)
        self.mint_services_token()

    def wait_for_handler(
        self,
        tenant: str,
        path: str = "/",
        *,
        expected_status: int = 200,
        expected_body_prefix: Optional[str] = None,
        timeout_s: float = 5.0,
        method: str = "GET",
        headers: Optional[dict[str, str]] = None,
    ) -> HttpResponse:
        """Poll a tenant handler until it stops returning 503 (no_deployment).

        Phase 2's deployment loader is async — the release POST returns 204
        as soon as the kv write replicates through raft, but the worker's
        snapshot swap happens on the loader thread. Polling avoids the
        flakes the bash smokes had with a fixed `sleep 2`.
        """
        cc = self.curl_ctx(f"{tenant}.{self.addrs.public_suffix}")
        url = f"https://{tenant}.{self.addrs.public_suffix}:{self.leader_port()}{path}"
        deadline = time.monotonic() + timeout_s
        last: HttpResponse = HttpResponse(status=0, body="", headers={})
        while time.monotonic() < deadline:
            last = curl(cc, url, method=method, headers=headers or {})
            if last.status == expected_status:
                if expected_body_prefix is None or last.body.startswith(expected_body_prefix):
                    return last
            elif last.status != 503:
                # Stop polling on a non-deployment-related failure.
                return last
            time.sleep(0.1)
        return last

    # ── Assertion helper ───────────────────────────────────────────────


def expect_eq(label: str, expected, actual) -> None:
    if expected != actual:
        sys.stderr.write(f"FAIL {label}: expected '{expected}', got '{actual}'\n")
        sys.exit(1)
    print(f"ok  {label}")


def expect_status(label: str, expected: int, resp: HttpResponse) -> None:
    if resp.status != expected:
        sys.stderr.write(
            f"FAIL {label}: expected status {expected}, got {resp.status}\n"
            f"--- body ---\n{resp.body}\n"
        )
        sys.exit(1)
    print(f"ok  {label}")
