#!/usr/bin/env python3
"""Stdlib-only strict M2 implemented-toolchain validator."""
import argparse,hashlib,json
from pathlib import Path
DEFAULT_ROOT=Path(__file__).resolve().parents[3]
def fail(m): raise SystemExit("Toolchain validation failed: "+m)
def load(p):
 try:return json.loads(p.read_text())
 except Exception as e:fail(f"{p}: {e}")
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def exact(v,keys,label):
 if set(v)!=set(keys):fail(f"{label} fields differ")
def main(argv=None):
 p=argparse.ArgumentParser();p.add_argument("--root",type=Path);a=p.parse_args(argv);root=(a.root or DEFAULT_ROOT).resolve();m=load(root/"toolchains/android-wear-shared-core.json");load(root/"toolchains/android-wear-shared-core.schema.json")
 exact(m,["$schema","schemaVersion","status","rust","uniffi","androidNative","apple","bindingGeneration","governedImplementationFiles"],"manifest")
 if (m["$schema"],m["schemaVersion"],m["status"])!=("android-wear-shared-core.schema.json",1,"m2-bindings-native-packaging-implemented"):fail("manifest identity/status")
 expected_r={"toolchain":"1.97.1","msrv":"1.87.0","edition":"2024","cargoResolver":"3","profile":"minimal","components":["clippy","rustfmt"],"targets":["aarch64-apple-ios","aarch64-apple-ios-sim","x86_64-apple-ios","aarch64-linux-android","armv7-linux-androideabi","x86_64-linux-android","i686-linux-android"],"rustToolchainPath":"Packages/vox-core-rust/rust-toolchain.toml"}
 if m["rust"]!=expected_r:fail("Rust pins differ")
 if m["uniffi"]!={"bindgenVersion":"0.32.0","cliVersion":"0.32.0","libraryVersion":"0.32.0"}:fail("UniFFI pins differ")
 targets=[{"abi":"arm64-v8a","apiLevel":28,"rustTarget":"aarch64-linux-android"},{"abi":"armeabi-v7a","apiLevel":28,"rustTarget":"armv7-linux-androideabi"},{"abi":"x86_64","apiLevel":28,"rustTarget":"x86_64-linux-android"},{"abi":"x86","apiLevel":28,"rustTarget":"i686-linux-android"}]
 if m["androidNative"]!={"cargoNdkVersion":"4.1.2","ndkRevision":"27.1.12297006","targets":targets}:fail("Android native pins differ")
 if m["apple"]!={"deploymentTarget":"17.6","packagingTool":"xcodebuild -create-xcframework","swiftVersion":"6.3.3","targets":["aarch64-apple-ios","aarch64-apple-ios-sim","x86_64-apple-ios"],"xcodeBuild":"17F113","xcodeVersion":"26.6"}:fail("Apple pins differ")
 bg=m["bindingGeneration"]; exact(bg,["swiftConfigPath","kotlinConfigPath","swiftScriptPath","kotlinScriptPath","swiftOutputPaths","kotlinOutputPaths","hashStatus"],"bindingGeneration")
 if bg["hashStatus"]!="governed-implemented":fail("binding hash status")
 expected_swift=["Packages/vox-core-rust/generated/swift/VoxCore.swift","Packages/vox-core-rust/generated/swift/VoxCoreFFI.h","Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap"];expected_kotlin=["Packages/vox-core-rust/generated/kotlin/md/vox/core/vox_core_uniffi.kt"]
 if bg["swiftOutputPaths"]!=expected_swift or bg["kotlinOutputPaths"]!=expected_kotlin:fail("generated output inventory")
 governed=m["governedImplementationFiles"]
 if len(governed)!=len({x.get("path") for x in governed}):fail("duplicate governed path")
 for item in governed:
  exact(item,["path","sha256"],"governed file"); path=root/item["path"]
  if not path.is_file():fail(f"governed file missing: {item['path']}")
  if digest(path)!=item["sha256"]:fail(f"governed file hash drift: {item['path']}")
 for path in expected_swift+expected_kotlin:
  if not (root/path).is_file():fail(f"generated binding missing: {path}")
 cargo=(root/"Packages/vox-core-rust/Cargo.toml").read_text();lock=(root/"Packages/vox-core-rust/Cargo.lock").read_text();rt=(root/expected_r["rustToolchainPath"]).read_text()
 for needle in ['channel = "1.97.1"','profile = "minimal"','components = ["clippy", "rustfmt"]']:
  if needle not in rt:fail(f"rust-toolchain drift: {needle}")
 for needle in ['resolver = "3"','edition = "2024"','rust-version = "1.87.0"','version = "=0.32.0"']:
  if needle not in cargo:fail(f"Cargo drift: {needle}")
 if 'name = "uniffi_bindgen"\nversion = "0.32.0"' not in lock:fail("UniFFI bindgen 0.32.0 absent from lock")
 print(f"Toolchain validation passed: {len(governed)} governed implementation hashes, UniFFI 0.32.0 generated Swift/Kotlin inventories, 4 Android API-28 and 3 iOS-17.6 targets.")
if __name__=="__main__":main()
