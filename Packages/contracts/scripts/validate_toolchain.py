#!/usr/bin/env python3
"""Stdlib-only strict M2 toolchain-entry validator."""
import argparse,json
from pathlib import Path
DEFAULT_ROOT=Path(__file__).resolve().parents[3]
def fail(message): raise SystemExit('Toolchain validation failed: '+message)
def load(p):
 try:return json.loads(p.read_text())
 except Exception as e:fail(f'{p}: {e}')
def exact_keys(v,keys,label):
 if set(v)!=set(keys):fail(f'{label} fields differ: {sorted(set(v)^set(keys))}')
def main(argv=None):
 global ROOT
 p=argparse.ArgumentParser();p.add_argument('--root',type=Path);a=p.parse_args(argv);ROOT=(a.root or DEFAULT_ROOT).resolve();manifest=ROOT/'toolchains/android-wear-shared-core.json'
 m=load(manifest);load(ROOT/'toolchains/android-wear-shared-core.schema.json')
 exact_keys(m,['$schema','schemaVersion','status','rust','uniffi','androidNative','apple','bindingGeneration','requiredBeforeImplementation'],'manifest')
 if m['$schema']!='android-wear-shared-core.schema.json' or m['schemaVersion']!=1 or m['status']!='m2-entry-pins-selected-no-build-claim':fail('manifest identity/status')
 r=m['rust']; exact_keys(r,['toolchain','msrv','edition','cargoResolver','profile','components','targets','rustToolchainPath'],'rust')
 expected_r={'toolchain':'1.97.1','msrv':'1.87.0','edition':'2024','cargoResolver':'3','profile':'minimal','components':['clippy','rustfmt'],'targets':['aarch64-apple-ios','aarch64-apple-ios-sim','x86_64-apple-ios','aarch64-linux-android','armv7-linux-androideabi','x86_64-linux-android','i686-linux-android'],'rustToolchainPath':'Packages/vox-core-rust/rust-toolchain.toml'}
 if r!=expected_r:fail('Rust pins differ')
 if m['uniffi']!={'bindgenVersion':'0.32.0','cliVersion':'0.32.0','libraryVersion':'0.32.0'}:fail('UniFFI pins differ')
 expected_targets=[{'abi':'arm64-v8a','apiLevel':28,'rustTarget':'aarch64-linux-android'},{'abi':'armeabi-v7a','apiLevel':28,'rustTarget':'armv7-linux-androideabi'},{'abi':'x86_64','apiLevel':28,'rustTarget':'x86_64-linux-android'},{'abi':'x86','apiLevel':28,'rustTarget':'i686-linux-android'}]
 if m['androidNative']!={'cargoNdkVersion':'4.1.2','ndkRevision':'27.1.12297006','targets':expected_targets}:fail('Android native pins differ')
 if m['apple']!={'deploymentTarget':'17.6','packagingTool':'xcodebuild -create-xcframework','swiftVersion':'6.3.3','targets':['aarch64-apple-ios','aarch64-apple-ios-sim','x86_64-apple-ios'],'xcodeBuild':'17F113','xcodeVersion':'26.6'}:fail('Apple pins differ')
 bg=m['bindingGeneration']; exact_keys(bg,['swiftConfigPath','kotlinConfigPath','swiftScriptPath','kotlinScriptPath','hashStatus'],'bindingGeneration')
 if bg['hashStatus']!='required-before-implementation':fail('binding hash status')
 required=m['requiredBeforeImplementation']
 if required!=['Packages/vox-core-rust/Cargo.lock','Packages/vox-core-rust/scripts/generate-swift-bindings.sh','Packages/vox-core-rust/scripts/generate-kotlin-bindings.sh','Packages/vox-core-rust/scripts/build-android-cdylibs.sh','Packages/vox-core-rust/scripts/build-apple-xcframework.sh']:fail('required-before-implementation inventory differs')
 for path in (r['rustToolchainPath'],bg['swiftConfigPath'],bg['kotlinConfigPath']):
  if not (ROOT/path).is_file():fail(f'required entry file missing: {path}')
 for path in required:
  if (ROOT/path).exists():fail(f'{path} landed without replacing required-before-implementation with governed SHA-256')
 rt=(ROOT/r['rustToolchainPath']).read_text();cargo=(ROOT/'Packages/vox-core-rust/Cargo.toml').read_text()
 for needle in ['channel = "1.97.1"','profile = "minimal"','components = ["clippy", "rustfmt"]']:
  if needle not in rt:fail(f'rust-toolchain drift: {needle}')
 for needle in ['resolver = "3"','edition = "2024"','rust-version = "1.87.0"','version = "=0.32.0"']:
  if needle not in cargo:fail(f'Cargo stub drift: {needle}')
 print('Toolchain validation passed: Rust 1.97.1/MSRV 1.87.0, UniFFI 0.32.0, 4 Android targets at API 28, 3 iOS targets at 17.6; implementation hashes pending by policy.')
if __name__=='__main__':main()
