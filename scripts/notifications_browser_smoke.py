#!/usr/bin/env python3
"""Headless Chromium runner for the notifications browser-in-the-loop
smoke. Launches Chromium with --host-resolver-rules='MAP * 127.0.0.1'
and --ignore-certificate-errors so it can reach the smoke's loopback
cluster + accept the dev TLS cert. Navigates to the test page, waits
for the page-side rove.js correlation-id flow to update `#status` to
`ok` (or `fail: …`), then exits 0/1 and prints the captured `#result`.

The page itself is served by the customer handler the smoke deploys —
this runner doesn't know what the test does, just observes the
outcome. Browser console messages are forwarded to stderr for
debuggability.
"""

import argparse
import asyncio
import sys

from playwright.async_api import async_playwright


async def run(url: str, timeout_ms: int) -> int:
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                # Map every hostname to 127.0.0.1 — the smoke's tenant
                # subdomains (acme.loop46.localhost, sse.loop46.localhost,
                # …) aren't in real DNS.
                "--host-resolver-rules=MAP * 127.0.0.1",
                "--ignore-certificate-errors",
                # Disable Chromium's "you appear to be offline" fallback,
                # which can interpose if name resolution flakes.
                "--disable-features=NetworkServiceInProcess2",
            ],
        )
        try:
            ctx = await browser.new_context(ignore_https_errors=True)
            page = await ctx.new_page()
            page.on(
                "console",
                lambda m: print(
                    f"[browser console] {m.type}: {m.text}", file=sys.stderr
                ),
            )
            page.on(
                "pageerror",
                lambda err: print(f"[browser pageerror] {err}", file=sys.stderr),
            )
            page.on(
                "requestfailed",
                lambda req: print(
                    f"[browser requestfailed] {req.method} {req.url}: {req.failure}",
                    file=sys.stderr,
                ),
            )
            page.on(
                "response",
                lambda r: print(
                    f"[browser response] {r.status} {r.request.method} {r.url}",
                    file=sys.stderr,
                ),
            )

            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=timeout_ms)
            except Exception as exc:
                print(f"[runner] page.goto failed: {exc}", file=sys.stderr)
                return 1
            # The page-side script flips #status to "ok" on success or
            # "fail: <reason>" on failure. Wait for either.
            try:
                await page.wait_for_function(
                    """() => {
                        const s = document.getElementById('status');
                        if (!s) return false;
                        const t = s.textContent.trim();
                        return t === 'ok' || t.startsWith('fail');
                    }""",
                    timeout=timeout_ms,
                )
            except Exception as exc:
                # Dump current page state to help diagnose hangs.
                print(
                    f"[runner] wait_for_function failed: {exc}",
                    file=sys.stderr,
                )
                try:
                    html = await page.content()
                    print(
                        f"[runner] page.content() at timeout (first 2KB):",
                        file=sys.stderr,
                    )
                    print(html[:2048], file=sys.stderr)
                except Exception as inner:
                    print(f"[runner] page.content() failed too: {inner}", file=sys.stderr)
                return 1
            status = (await page.text_content("#status") or "").strip()
            result = (await page.text_content("#result") or "").strip()
            if status == "ok":
                print("PASS")
                if result:
                    print(result)
                return 0
            print(f"FAIL browser status: {status}", file=sys.stderr)
            if result:
                print(f"--- #result ---\n{result}", file=sys.stderr)
            return 1
        finally:
            await browser.close()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="test page URL")
    ap.add_argument(
        "--timeout-ms",
        type=int,
        default=30_000,
        help="overall test timeout (default 30s)",
    )
    args = ap.parse_args()
    sys.exit(asyncio.run(run(args.url, args.timeout_ms)))


if __name__ == "__main__":
    main()
