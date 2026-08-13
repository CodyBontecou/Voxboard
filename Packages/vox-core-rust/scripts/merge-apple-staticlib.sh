#!/bin/sh
set -eu
[ "$#" -eq 3 ] || { echo "usage: $0 <ios|ios-simulator> <input.a> <output.a>" >&2; exit 64; }
platform=$1; input=$2; output=$3
temp=$(mktemp -d "${TMPDIR:-/tmp}/vox-staticlib.XXXXXX"); trap 'rm -rf "$temp"' EXIT HUP INT TERM
(cd "$temp" && xcrun ar -x "$input")
case "$platform" in ios) platform_name=ios;; ios-simulator) platform_name=ios-simulator;; *) exit 64;; esac
xcrun ld -r -platform_version "$platform_name" 17.6 17.6 -o "$temp/vox-core.o" "$temp"/*.o
rm -f "$output"; xcrun ar -rcs "$output" "$temp/vox-core.o"
