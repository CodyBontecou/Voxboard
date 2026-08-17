#!/usr/bin/env python3
"""Generate governed canonical M2 benchmark controls and synthetic stream bytes."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

DOMAIN = b"vox-m2-synthetic-stream-byte-v1\0"
MAX_STREAM_BYTES = 256 * 1024 * 1024
BLOCK_BYTES = 1024 * 1024
PURPOSES = ("warmup", "latency", "aggregateCoverage", "resource")


def canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def stream_byte(seed_sha256: str) -> int:
    try:
        seed = bytes.fromhex(seed_sha256)
    except ValueError as error:
        raise SystemExit("seed must be lowercase SHA-256") from error
    if len(seed) != 32 or seed_sha256 != seed_sha256.lower():
        raise SystemExit("seed must be lowercase SHA-256")
    return hashlib.sha256(DOMAIN + seed).digest()[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed-sha256", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--purpose", choices=PURPOSES, required=True)
    parser.add_argument("--stream-bytes", type=int, required=True)
    parser.add_argument("--control-output", type=Path, required=True)
    parser.add_argument("--input-output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.stream_bytes <= MAX_STREAM_BYTES:
        raise SystemExit("stream byte count is outside 1..268435456")
    if re.fullmatch(r"[a-z][a-z0-9-]{1,63}", args.run_id) is None:
        raise SystemExit("run ID is invalid")
    value = stream_byte(args.seed_sha256)
    control = {
        "operation": "newNoteTextLink",
        "profileVersion": "apple-parity-v1",
        "purpose": args.purpose,
        "runID": args.run_id,
        "streamBytes": args.stream_bytes,
        "syntheticSeedSha256": args.seed_sha256,
    }
    args.control_output.parent.mkdir(parents=True, exist_ok=True)
    args.input_output.parent.mkdir(parents=True, exist_ok=True)
    args.control_output.write_bytes(canonical(control))
    block = bytes([value]) * min(BLOCK_BYTES, args.stream_bytes)
    remaining = args.stream_bytes
    with args.input_output.open("wb") as output:
        while remaining:
            count = min(remaining, len(block))
            output.write(block[:count])
            remaining -= count
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
