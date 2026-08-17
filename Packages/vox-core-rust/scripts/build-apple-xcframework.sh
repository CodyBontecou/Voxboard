#!/bin/sh
set -eu
workspace_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); repo_root=$(CDPATH= cd -- "$workspace_root/../.." && pwd)
output=${1:-"$workspace_root/target/apple/VoxCore.xcframework"}; target_dir=${CARGO_TARGET_DIR:-"$workspace_root/target/apple-build"}
[ "$(uname -s)" = Darwin ] || { echo "error: Apple build requires macOS" >&2; exit 1; }
xcodebuild -version | grep -Fx 'Xcode 26.6' >/dev/null; xcodebuild -version | grep -Fx 'Build version 17F113' >/dev/null
swift --version 2>&1 | grep -F 'Apple Swift version 6.3.3' >/dev/null
toolchain=1.97.1; rustc=$(rustup which --toolchain "$toolchain" rustc); bin=$(dirname -- "$rustc"); cargo="$bin/cargo"
revision=${VOX_CORE_SOURCE_REVISION:-$(git -C "$repo_root" rev-parse HEAD)}
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
 env -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS CARGO_INCREMENTAL=0 CARGO_TARGET_DIR="$target_dir" IPHONEOS_DEPLOYMENT_TARGET=17.6 PATH="$bin:$PATH" RUSTC="$rustc" SOURCE_DATE_EPOCH=0 ZERO_AR_DATE=1 VOX_CORE_SOURCE_REVISION="$revision" \
 "$cargo" build --manifest-path "$workspace_root/Cargo.toml" --locked --release --package vox-core-uniffi --target "$target"
done
parent=$(dirname -- "$output"); mkdir -p "$parent"; temp=$(mktemp -d "$parent/.vox-xcframework.XXXXXX"); trap 'rm -rf "$temp"' EXIT HUP INT TERM
headers="$temp/Headers"; mkdir -p "$headers"
cp "$workspace_root/generated/swift/VoxCoreFFI.h" "$headers/VoxCoreFFI.h"
cp "$workspace_root/generated/swift/VoxCoreFFI.modulemap" "$headers/module.modulemap"
mkdir -p "$temp/device" "$temp/simulator"
"$workspace_root/scripts/merge-apple-staticlib.sh" ios "$target_dir/aarch64-apple-ios/release/libvox_core_uniffi.a" "$temp/device/libVoxCoreFFI.a"
"$workspace_root/scripts/merge-apple-staticlib.sh" ios-simulator "$target_dir/aarch64-apple-ios-sim/release/libvox_core_uniffi.a" "$temp/simulator/arm64.a"
"$workspace_root/scripts/merge-apple-staticlib.sh" ios-simulator "$target_dir/x86_64-apple-ios/release/libvox_core_uniffi.a" "$temp/simulator/x86_64.a"
xcrun lipo -create "$temp/simulator/arm64.a" "$temp/simulator/x86_64.a" -output "$temp/simulator/libVoxCoreFFI.a"
xcodebuild -create-xcframework -library "$temp/device/libVoxCoreFFI.a" -headers "$headers" -library "$temp/simulator/libVoxCoreFFI.a" -headers "$headers" -output "$temp/VoxCore.xcframework"
python3 "$workspace_root/scripts/normalize-apple-xcframework.py" "$temp/VoxCore.xcframework"
rm -rf "$output"; mv "$temp/VoxCore.xcframework" "$output"
echo "Built static iOS 17.6 VoxCore XCFramework: $output"
