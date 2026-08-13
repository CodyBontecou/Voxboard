#!/usr/bin/env bash
set -euo pipefail
workspace="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$workspace/../.." && pwd)"
source="$repo/Packages/VoxboardShared/Sources/VoxboardM2Oracle/main.swift"
out="$workspace/tests/fixtures/swift-m2-oracle-v1.json"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
source_sha256="$(shasum -a 256 "$source" | awk '{print $1}')"
VOX_M2_ORACLE_SOURCE_SHA256="$source_sha256" swift run --package-path "$repo/Packages/VoxboardShared" --disable-sandbox VoxboardM2Oracle > "$tmp"
mkdir -p "$(dirname "$out")"
mv "$tmp" "$out"; trap - EXIT
echo "Generated $out from production Swift consumers; producer SHA-256 $source_sha256"
