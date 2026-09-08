#!/usr/bin/env python3
"""Verify (or produce) an eSIM Plus webhook signature: HMAC-SHA256 over `{timestamp}.{raw_body}`.

Use it to check a captured delivery, or to sign a fixture so you can replay a realistic
signed request at your own receiver. Stdlib only, no network.

Usage:
    # confirm the algorithm on the pinned test vector
    python3 verify_webhook.py --self-test

    # verify a captured delivery (body from a file to keep the bytes intact)
    python3 verify_webhook.py --secret whsec_… --timestamp 1754397296 \
        --body-file body.json --signature "sha256=6ffc…"

    # sign a fixture (prints the two headers to replay)
    python3 verify_webhook.py --secret whsec_… --timestamp 1754397296 --body-file body.json

Exit codes:
    0  signature matches (or --self-test passed, or signing succeeded)
    1  signature does NOT match (or --self-test failed)
    4  bad usage

The body MUST be the raw bytes as received. Re-serialising parsed JSON changes bytes and
the signature will not match — read it from the file/stream, never from a parsed object.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import sys

# Pinned vector, shared with the partner-dashboard docs test.
VECTOR_SECRET = "whsec_test_0123456789abcdef"
VECTOR_TIMESTAMP = "1754397296"
VECTOR_BODY = b'{"event":"sms.inbound","id":"01J9Z3M8Q9V2K7X4B6N0R5T1AF"}'
VECTOR_SIGNATURE = "sha256=6ffc1a08991f031e5795f9f583477a762a1f8c86b670ca6bb59a1b72b1500f41"


def sign(raw_body: bytes, timestamp: str, secret: str) -> str:
    signed = timestamp.encode() + b"." + raw_body
    return "sha256=" + hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()


def verify(raw_body: bytes, timestamp: str, signature_header: str, secret: str) -> bool:
    return hmac.compare_digest(sign(raw_body, timestamp, secret), signature_header.strip())


def self_test() -> int:
    produced = sign(VECTOR_BODY, VECTOR_TIMESTAMP, VECTOR_SECRET)
    ok = hmac.compare_digest(produced, VECTOR_SIGNATURE)
    print(f"signed string : {VECTOR_TIMESTAMP}.{VECTOR_BODY.decode()}")
    print(f"produced      : {produced}")
    print(f"expected      : {VECTOR_SIGNATURE}")
    print("PASS — HMAC-SHA256 over `{timestamp}.{raw_body}` reproduces the vector." if ok
          else "FAIL — the algorithm does not reproduce the pinned vector.")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify or produce an X-Esimplus-Signature.")
    parser.add_argument("--self-test", action="store_true", help="check the algorithm on the pinned vector")
    parser.add_argument("--secret", help="the endpoint signing secret (whsec_…)")
    parser.add_argument("--timestamp", help="value of the X-Esimplus-Timestamp header")
    parser.add_argument("--body-file", help="file holding the RAW body bytes; '-' reads stdin")
    parser.add_argument("--signature", help="value of the X-Esimplus-Signature header; omit to sign instead")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    if not (args.secret and args.timestamp and args.body_file):
        print("error: --secret, --timestamp and --body-file are required (or use --self-test)",
              file=sys.stderr)
        return 4

    raw = sys.stdin.buffer.read() if args.body_file == "-" else open(args.body_file, "rb").read()

    if args.signature:
        if verify(raw, args.timestamp, args.signature, args.secret):
            print("MATCH — signature is valid for these raw bytes.")
            return 0
        print("MISMATCH — signature is not valid for these raw bytes.", file=sys.stderr)
        print(f"  expected: {sign(raw, args.timestamp, args.secret)}", file=sys.stderr)
        print(f"  received: {args.signature.strip()}", file=sys.stderr)
        print("  Common cause: the body was re-serialised after parsing. Capture it raw.",
              file=sys.stderr)
        return 1

    print(f"X-Esimplus-Timestamp: {args.timestamp}")
    print(f"X-Esimplus-Signature: {sign(raw, args.timestamp, args.secret)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
