#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <campaign-directory> <external-artifact-root>" >&2; exit 64; }
workspace="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$workspace/../.." && pwd)"
campaign="$1"; external="$2"; revision="$(git -C "$repo" rev-parse HEAD)"
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] || { echo "error: M2 evidence requires a clean checkout" >&2; exit 1; }
mkdir -p "$campaign/artifacts" "$external/executables" "$external/packages/android" "$external/packages/VoxCore.xcframework"
android="$workspace/target/m2-evidence/android"
xcframework="$workspace/target/m2-evidence/VoxCore.xcframework"
VOX_CORE_SOURCE_REVISION="$revision" "$workspace/scripts/build-android-cdylibs.sh" release "$android"
VOX_CORE_SOURCE_REVISION="$revision" "$workspace/scripts/build-apple-xcframework.sh" "$xcframework"
cp "$workspace/scripts/inspect-native-packages.py" "$external/executables/native-package-inspector.py"
chmod 755 "$external/executables/native-package-inspector.py"
for abi in arm64-v8a armeabi-v7a x86_64 x86; do
  mkdir -p "$external/packages/android/$abi"
  cp "$android/$abi/libvox_core_uniffi.so" "$external/packages/android/$abi/libvox_core_uniffi.so"
done
for identifier in ios-arm64 ios-arm64_x86_64-simulator; do
  mkdir -p "$external/packages/VoxCore.xcframework/$identifier"
  cp "$xcframework/$identifier/libVoxCoreFFI.a" "$external/packages/VoxCore.xcframework/$identifier/libVoxCoreFFI.a"
done
cp "$xcframework/Info.plist" "$external/packages/VoxCore.xcframework/Info.plist"

# Execute the named production package consumer over the exact retained leaves. It
# emits the current typed candidate receipt; final hosted retention is bound only
# after the raw USTAR archive exists.
python3 "$external/executables/native-package-inspector.py" \
  --android "$external/packages/android" \
  --xcframework "$external/packages/VoxCore.xcframework" \
  --external-root "$external" \
  --output "$workspace/target/m2-evidence/native-package-candidate.json" \
  --source-revision "$revision" \
  --toolchain-manifest "$repo/toolchains/android-wear-shared-core.json" \
  --build-recipe "$workspace/scripts/build-m2-native-evidence.sh"
