#!/bin/sh
set -eu
workspace_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temp=$(mktemp -d "${TMPDIR:-/tmp}/vox-bindings.XXXXXX")
trap 'rm -rf "$temp"' EXIT HUP INT TERM
"$workspace_root/scripts/generate-swift-bindings.sh" "$temp/swift"
"$workspace_root/scripts/generate-kotlin-bindings.sh" "$temp/kotlin"
diff -ru "$workspace_root/generated/swift" "$temp/swift"
diff -ru "$workspace_root/generated/kotlin" "$temp/kotlin"
echo "UniFFI 0.32.0 Swift and Kotlin bindings are byte-identical"
