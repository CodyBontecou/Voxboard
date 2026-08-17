#!/bin/sh
set -eu
workspace_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir=${1:-"$workspace_root/target/generated-bindings/kotlin"}
case "$out_dir" in /*) ;; *) out_dir="$(pwd)/$out_dir" ;; esac
toolchain=$(awk -F'"' '/^[[:space:]]*channel[[:space:]]*=/ { print $2; exit }' "$workspace_root/rust-toolchain.toml")
[ "$toolchain" = "1.97.1" ] || { echo "error: Rust 1.97.1 is required" >&2; exit 1; }
rustc_path=$(rustup which --toolchain "$toolchain" rustc); toolchain_bin=$(dirname -- "$rustc_path")
rm -rf "$out_dir"; mkdir -p "$out_dir"
cd "$workspace_root"
env CARGO="$toolchain_bin/cargo" PATH="$toolchain_bin:$PATH" RUSTC="$rustc_path" \
  "$toolchain_bin/cargo" run --locked -p xtask -- bindings kotlin "$out_dir"
python3 "$workspace_root/scripts/normalize-kotlin-bindings.py" "$out_dir"
find "$out_dir" -type f -print0 | xargs -0 python3 "$workspace_root/scripts/normalize-generated-text.py"
