# Android/Wear shared-core toolchain baseline

Status: **M2 UniFFI bindings and native packaging implemented and governed**

The machine authority is `toolchains/android-wear-shared-core.json`, validated by the
stdlib-only `Packages/contracts/scripts/validate_toolchain.py`. The manifest pins Rust
1.97.1, MSRV 1.87.0, edition 2024/resolver 3, UniFFI 0.32.0, cargo-ndk 4.1.2,
NDK 27.1.12297006/API 28, and Xcode 26.6 (`17F113`)/Swift 6.3.3/iOS 17.6. It now carries
SHA-256 for every binding/native implementation script and the lock/configuration files.

## Generated bindings

`Packages/vox-core-rust/scripts/generate-swift-bindings.sh` and
`generate-kotlin-bindings.sh` run the locked UniFFI 0.32.0 library-mode bindgen through
the governed `xtask`. Committed outputs are under `Packages/vox-core-rust/generated`.
`check-bindings.sh` regenerates both into a temporary directory and requires byte identity.
No Swift or Kotlin product consumer is claimed in this slice.

## Source-built native packages

- `build-android-cdylibs.sh` builds `libvox_core_uniffi.so` for all four pinned ABIs at
  API 28 using the exact NDK and cargo-ndk pins.
- `build-apple-xcframework.sh` builds static device arm64 and simulator arm64/x86_64
  libraries at iOS 17.6, combines each architecture into a single relocatable archive,
  and packages exactly two XCFramework leaves with `xcodebuild -create-xcframework`.
- `inspect-native-packages.py` checks ELF class/machine/shared type/dynamic dependencies
  and UniFFI export; XCFramework plist, architectures, static archive content, UniFFI
  export, and deployment target; plus bytes, SHA-256, and absolute gates.

`.so`, `.a`, and XCFramework binaries remain uncommitted build outputs. The privacy-safe
local inspection record is `docs/validation/evidence/m2-local-native-package-inspection.json`.
It binds the exact committed source revision and toolchain-manifest hash used by the
recorded build. All six leaves and the Apple aggregate pass absolute
limits. Percentage growth is correctly not applicable because no approved nonzero
predecessor exists.

The record is deliberately not PERF-008 campaign evidence. The current campaign schema
requires baseline/candidate pairs and cannot represent the first-core no-predecessor case;
that validator gap must be repaired before PERF-008 can pass. No approval, physical
hardware, or campaign fact is inferred from this local build.

The Rust contract mirror is now `required`: `m2_core::rust_contract_mirror_is_consumed`
loads the mirrored expected-versions fixture in production Rust tests. Swift and Android
resource mirrors remain `resourceOnlyPlanned` because this slice adds no executable host
consumer.
