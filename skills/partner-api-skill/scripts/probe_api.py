#!/usr/bin/env python3
"""Probe an eSIM Plus Partner API token: does it authenticate, and what can it reach?

Read-only. Every request is a GET against a listing endpoint, so nothing is bought,
charged or configured. Stdlib only.

Usage:
    python3 probe_api.py --token "$ESIMPLUS_PARTNER_TOKEN"
    python3 probe_api.py --token … --base-url https://staging.example/api/partner/v1
    python3 probe_api.py --token … --json

Exit codes:
    0  the token authenticated (see the report for per-group reachability)
    2  authentication failed (401/403 — the domain code is printed)
    3  the API was unreachable, or answered something unparseable
    4  bad usage (no token)
"""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

DEFAULT_BASE_URL = "https://api.esimplus.net/api/partner/v1"

# (group, path) — read-only endpoints, ordered cheapest first.
PROBES: list[tuple[str, str]] = [
    ("profile", "/partner/profile"),
    ("catalog", "/phone-numbers/countries"),
    ("numbers", "/phone-numbers?perPage=1"),
    ("bulk", "/phone-numbers/bulk?perPage=1"),
    ("tags", "/tags"),
    ("sms", "/sms?perPage=1"),
    ("wallet", "/wallet"),
    ("discounts", "/discount-levels"),
    # Dashboard-only: a partner:api token is EXPECTED to get 403/1327 here.
    ("settings (dashboard-only)", "/settings/api-tokens"),
]

AUTH_CODES = {1301: "partner not found", 1302: "unauthenticated", 1303: "partner disabled"}


def ssl_context() -> ssl.SSLContext:
    """Default trust store, falling back to certifi — a python.org install often has no CA bundle."""
    ctx = ssl.create_default_context()
    if not (ctx.cert_store_stats().get("x509_ca") or 0):
        try:
            import certifi  # noqa: PLC0415 — optional, only when the system store is empty
        except ImportError:
            return ctx
        ctx.load_verify_locations(cafile=certifi.where())
    return ctx


def request(url: str, token: str, timeout: float) -> tuple[int, dict | None, str | None]:
    """GET url. Returns (status, parsed_json_or_None, transport_error_or_None)."""
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "esimplus-partner-api-probe/1.0",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl_context()) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as exc:  # 4xx/5xx still carry a body
        raw = exc.read()
        status = exc.code
    except Exception as exc:  # URLError, socket.timeout, ssl errors
        return 0, None, f"{type(exc).__name__}: {exc}"

    try:
        return status, json.loads(raw.decode("utf-8") or "null"), None
    except (UnicodeDecodeError, json.JSONDecodeError):
        return status, None, f"non-JSON body ({len(raw)} bytes)"


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe an eSIM Plus Partner API token (read-only).")
    parser.add_argument("--token", default=os.environ.get("ESIMPLUS_PARTNER_TOKEN", ""),
                        help="partner:api token; defaults to $ESIMPLUS_PARTNER_TOKEN")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help=f"default {DEFAULT_BASE_URL}")
    parser.add_argument("--timeout", type=float, default=15.0, help="per-request timeout, seconds")
    parser.add_argument("--json", action="store_true", dest="as_json", help="machine-readable output")
    args = parser.parse_args()

    if not args.token:
        print("error: no token (pass --token or set ESIMPLUS_PARTNER_TOKEN)", file=sys.stderr)
        return 4

    base = args.base_url.rstrip("/")
    results: list[dict] = []
    transport_failures = 0
    auth_failure: dict | None = None

    for group, path in PROBES:
        status, body, err = request(base + path, args.token, args.timeout)
        code = body.get("code") if isinstance(body, dict) else None
        message = body.get("message") if isinstance(body, dict) else None
        results.append({"group": group, "path": path, "status": status,
                        "code": code, "message": message, "error": err})

        if status == 0:
            transport_failures += 1
        elif code in AUTH_CODES and auth_failure is None:
            auth_failure = {"code": code, "status": status, "message": message}

    if args.as_json:
        print(json.dumps({"baseUrl": base, "probes": results}, indent=2))
    else:
        print(f"Base URL: {base}\n")
        width = max(len(g) for g, _ in PROBES)
        for r in results:
            if r["status"] == 0:
                verdict = f"UNREACHABLE  {r['error']}"
            elif 200 <= r["status"] < 300:
                verdict = f"ok           {r['status']}"
            else:
                detail = f"code {r['code']}" if r["code"] else "no domain code (envelope B)"
                verdict = f"{r['status']:<12} {detail} — {r['message']}"
            print(f"  {r['group']:<{width}}  {verdict}")
        print()

    if transport_failures == len(PROBES):
        hint = ""
        if any("CERTIFICATE_VERIFY_FAILED" in (r["error"] or "") for r in results):
            hint = (" This Python has no usable CA bundle: run its "
                    "'Install Certificates.command', or `pip install certifi`.")
        print("Every request failed at the transport layer — check the host, DNS and egress."
              + hint, file=sys.stderr)
        return 3
    if auth_failure:
        print(f"Authentication failed: code {auth_failure['code']} "
              f"({AUTH_CODES.get(auth_failure['code'], 'auth error')}) — {auth_failure['message']}",
              file=sys.stderr)
        return 2

    if not args.as_json:
        settings = next(r for r in results if r["group"].startswith("settings"))
        if settings["code"] == 1327:
            print("Token authenticates and behaves like a partner:api integration token "
                  "(403/1327 on /settings/* is expected).")
        elif 200 <= (settings["status"] or 0) < 300:
            print("Token reaches /settings/* — this is a partner:dashboard SESSION token, "
                  "short-lived (24h). Use a partner:api token for an integration.")
        provider_hint = next((r for r in results if r["group"] == "catalog"), None)
        if provider_hint and 200 <= (provider_hint["status"] or 0) < 300:
            print("Catalog is reachable; an extra upstream-provider key on a catalog item "
                  "would mean the optional add-on ability is granted for this token.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
