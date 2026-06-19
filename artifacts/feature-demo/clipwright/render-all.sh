#!/usr/bin/env bash
set -euo pipefail

CLIPWRIGHT_DIR="/Users/codybontecou/projects/AppShowcase/AppShowcase"
ROOT="/Users/codybontecou/projects/Voxboard"
PATCH="$ROOT/artifacts/feature-demo/clipwright-watch-device-preset.patch"

cd "$CLIPWRIGHT_DIR"
PATCHED=0
if ! swift run -c release clipwright devices --json | grep -q 'apple-watch-ultra-3'; then
  git apply "$PATCH"
  PATCHED=1
fi
cleanup() {
  if [[ "$PATCHED" == "1" ]]; then
    git checkout -- Sources/ClipwrightCore/Catalogs.swift
  fi
}
trap cleanup EXIT

for spec in "$ROOT"/artifacts/feature-demo/clipwright/specs/*.clipwright.json; do
  base=$(basename "$spec" .clipwright.json)
  swift run -c release clipwright validate "$spec"
  swift run -c release clipwright render "$spec" --out "$ROOT/artifacts/feature-demo/clipwright/renders/$base.mp4" --json-logs
  swift run -c release clipwright thumbnail "$spec" --time 1.2 --out "$ROOT/artifacts/feature-demo/clipwright/thumbnails/$base-t1.png"
done
