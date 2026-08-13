#!/usr/bin/env bash
set -euo pipefail
workspace="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$workspace/../.." && pwd)"
source="Packages/VoxboardShared/Sources/VoxboardM2Oracle/main.swift"
out="${1:-$workspace/tests/fixtures/swift-m2-oracle-v1.json}"
sha() { shasum -a 256 "$repo/$1" | awk '{print $1}'; }
revision="${VOX_M2_SOURCE_REVISION:-$(git -C "$repo" rev-parse HEAD)}"
swift_identity="$(swift --version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
xcode_identity="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
VOX_M2_SOURCE_REVISION="$revision" \
VOX_M2_ORACLE_SOURCE_SHA256="$(sha "$source")" \
VOX_M2_CAPTURE_PATH_PLANNER_SHA256="$(sha Packages/VoxboardShared/Sources/VoxboardCaptureCore/CapturePathPlanner.swift)" \
VOX_M2_CAPTURE_MARKDOWN_RENDERER_SHA256="$(sha Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureMarkdownRenderer.swift)" \
VOX_M2_CAPTURE_ENTRY_TEMPLATE_RENDERER_SHA256="$(sha Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureEntryTemplateRenderer.swift)" \
VOX_M2_MARKDOWN_DOCUMENT_EDITOR_SHA256="$(sha Packages/VoxboardShared/Sources/VoxboardCaptureCore/MarkdownDocumentEditor.swift)" \
VOX_M2_SWIFT_COMPILER_IDENTITY="$swift_identity" \
VOX_M2_XCODE_IDENTITY="$xcode_identity" \
VOX_M2_TOOLCHAIN_MANIFEST_SHA256="$(sha toolchains/android-wear-shared-core.json)" \
swift run --package-path "$repo/Packages/VoxboardShared" --disable-sandbox VoxboardM2Oracle > "$tmp"
if [[ "${VOX_M2_ORACLE_CHECK:-0}" == "1" ]]; then
  cmp "$tmp" "$out"
else
  mv "$tmp" "$out"
  trap - EXIT
fi
