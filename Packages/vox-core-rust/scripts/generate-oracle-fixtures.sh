#!/usr/bin/env bash
set -euo pipefail
workspace="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$workspace/../.." && pwd)"
source="Packages/VoxboardShared/Sources/VoxboardM2Oracle/main.swift"
out="${1:-$workspace/tests/fixtures/swift-m2-oracle-v1.json}"
mode="${VOX_M2_ORACLE_MODE:-check}"
case "$mode" in check|write) ;; *) echo "error: VOX_M2_ORACLE_MODE must be check or write" >&2; exit 2;; esac
sha() { shasum -a 256 "$repo/$1" | awk '{print $1}'; }

# Oracle output is derived only from a coherent clean commit. Write mode refuses to
# update the tracked fixture directly because doing so would invalidate sourceRevision.
if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=normal)" ]]; then
  echo "error: oracle generation requires a clean tree" >&2
  exit 1
fi
head_revision="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" diff --quiet "$head_revision" --
git -C "$repo" diff --cached --quiet "$head_revision" --

if [[ "$mode" == check ]]; then
  [[ -f "$out" ]] || { echo "error: tracked oracle fixture is missing" >&2; exit 1; }
  revision="$(python3 - "$out" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "rb") as handle:
    value = json.load(handle)
revision = value.get("producer", {}).get("sourceRevision", "")
if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
    raise SystemExit("error: tracked oracle sourceRevision is invalid")
print(revision)
PY
)"
  git -C "$repo" cat-file -e "${revision}^{commit}" 2>/dev/null || {
    echo "error: tracked oracle sourceRevision is not a repository commit" >&2
    exit 1
  }
  git -C "$repo" merge-base --is-ancestor "$revision" "$head_revision" || {
    echo "error: tracked oracle sourceRevision is not an ancestor of HEAD" >&2
    exit 1
  }
  # A fixture-only successor commit is coherent only while every output-affecting
  # source and SwiftPM build input remains byte-identical to sourceRevision.
  git -C "$repo" diff --quiet "$revision" "$head_revision" -- \
    Packages/vox-core-rust/scripts/generate-oracle-fixtures.sh \
    "$source" \
    Packages/VoxboardShared/Package.swift \
    Packages/VoxboardShared/Package.resolved \
    Packages/VoxboardShared/Sources/VoxboardCaptureCore \
    toolchains/android-wear-shared-core.json || {
      echo "error: oracle sources changed after tracked sourceRevision" >&2
      exit 1
    }
else
  revision="$head_revision"
fi

# Bind the complete production target source set. SwiftPM compiles this full set into
# VoxboardCaptureCore, so additions/removals are provenance-significant as well as bytes.
consumers=()
while IFS= read -r path; do
  [[ -n "$path" ]] && consumers+=("$path")
done < <(git -C "$repo" ls-tree -r --name-only "$revision" -- \
  Packages/VoxboardShared/Sources/VoxboardCaptureCore | \
  awk '/\.swift$/ { print }' | LC_ALL=C sort)
[[ ${#consumers[@]} -gt 0 ]] || { echo "error: no production consumers found" >&2; exit 1; }
consumer_list="$(printf '%s\n' "${consumers[@]}")"

swift_identity="$(swift --version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
xcode_identity="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
env_args=(
  "VOX_M2_SOURCE_REVISION=$revision"
  "VOX_M2_ORACLE_SOURCE_SHA256=$(sha "$source")"
  "VOX_M2_PRODUCTION_CONSUMER_PATHS=$consumer_list"
  "VOX_M2_SWIFT_COMPILER_IDENTITY=$swift_identity"
  "VOX_M2_XCODE_IDENTITY=$xcode_identity"
  "VOX_M2_TOOLCHAIN_MANIFEST_SHA256=$(sha toolchains/android-wear-shared-core.json)"
)
for path in "${consumers[@]}"; do
  key="VOX_M2_CONSUMER_SHA256_$(printf '%s' "$path" | sed 's/[^A-Za-z0-9]/_/g')"
  env_args+=("$key=$(sha "$path")")
done
env "${env_args[@]}" \
  swift run --package-path "$repo/Packages/VoxboardShared" --disable-sandbox VoxboardM2Oracle > "$tmp"

if [[ "$mode" == check ]]; then
  cmp "$tmp" "$out"
else
  destination="${VOX_M2_ORACLE_OUTPUT:-}"
  [[ -n "$destination" ]] || {
    echo "error: write mode requires VOX_M2_ORACLE_OUTPUT outside the repository" >&2
    exit 2
  }
  case "$(cd "$(dirname "$destination")" && pwd)/$(basename "$destination")" in
    "$repo"/*) echo "error: write mode output must be outside the repository" >&2; exit 2;;
  esac
  cp "$tmp" "$destination"
  echo "wrote clean-commit oracle candidate to $destination"
fi
