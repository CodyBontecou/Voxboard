#!/bin/sh
set -eu
[ "$#" -eq 2 ] || { echo "usage: $0 <debug|release> <jni-output-directory>" >&2; exit 64; }
profile=$1; output=$2; case "$profile" in debug) flag="";; release) flag="--release";; *) exit 64;; esac
workspace_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd); repo_root=$(CDPATH= cd -- "$workspace_root/../.." && pwd)
toolchain=1.97.1; ndk_version=27.1.12297006; ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}/ndk/$ndk_version}}
[ -f "$ndk/source.properties" ] && grep -Eq "^Pkg.Revision[[:space:]]*=[[:space:]]*$ndk_version" "$ndk/source.properties" || { echo "error: NDK $ndk_version not found" >&2; exit 1; }
version=$(rustup run "$toolchain" cargo ndk --version); case "$version" in *" 4.1.2") ;; *) echo "error: cargo-ndk 4.1.2 required, found $version" >&2; exit 1;; esac
rustc=$(rustup which --toolchain "$toolchain" rustc); cargo=$(rustup which --toolchain "$toolchain" cargo)
revision=${VOX_CORE_SOURCE_REVISION:-$(git -C "$repo_root" rev-parse HEAD)}
case "$output" in /*) ;; *) output="$(pwd)/$output";; esac
rm -rf "$output"; mkdir -p "$output"
cd "$workspace_root"
# shellcheck disable=SC2086
env ANDROID_NDK_HOME="$ndk" ANDROID_NDK_ROOT="$ndk" RUSTC="$rustc" VOX_CORE_SOURCE_REVISION="$revision" \
 "$cargo" ndk --platform 28 --target arm64-v8a --target armeabi-v7a --target x86_64 --target x86 --output-dir "$output" \
 build --locked --package vox-core-uniffi $flag
for abi in arm64-v8a armeabi-v7a x86_64 x86; do [ -s "$output/$abi/libvox_core_uniffi.so" ] || { echo "error: missing $abi library" >&2; exit 1; }; done
echo "Built libvox_core_uniffi.so for Android API 28: arm64-v8a armeabi-v7a x86_64 x86"
