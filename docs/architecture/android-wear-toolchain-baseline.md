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
`check-bindings.sh` regenerates both into a temporary directory and requires byte identity,
including the committed SwiftPM `VoxCoreGenerated` copy. `VoxCoreRust` is the handwritten
owned-value wrapper; the hosted materialization executable links the source-built static
library without committing a binary. Kotlin product authority remains outside M2.

## Source-built native packages

- `build-android-cdylibs.sh` builds `libvox_core_uniffi.so` for all four pinned ABIs at
  API 28 using the exact NDK and cargo-ndk pins.
- `build-apple-xcframework.sh` builds static device arm64 and simulator arm64/x86_64
  libraries at iOS 17.6, combines each architecture into a single relocatable archive,
  and packages exactly two XCFramework leaves with `xcodebuild -create-xcframework`.
- `inspect-native-packages.py` executes over the exact retained leaves, checks ELF
  class/machine/shared type/dependency allowlist and UniFFI export plus XCFramework plist,
  architectures, static members/export/deployment target, and emits the current typed
  `initialCandidate` receipt. The independent campaign validator then parses loader-visible
  ELF, Mach-O, archive, and XCFramework structure directly before accepting the receipt.

`.so`, `.a`, and XCFramework binaries remain uncommitted source-built outputs. The former
local inspection JSON was removed because its source revision was not reproducible and a
manifest cannot establish execution. `PERF-008` is representable without a fabricated
predecessor: the first package uses six absolute leaves, an Apple aggregate, null baselines,
and no percentage-growth claim. It passes only inside the canonical hosted campaign after
retained bytes and the exact raw USTAR archive are rehashed. No approval, physical hardware,
or campaign fact is inferred from repository or local build bytes.

The Rust contract mirror is now `required`: `m2_core::rust_contract_mirror_is_consumed`
loads the mirrored expected-versions fixture in production Rust tests. Swift and Android
resource mirrors remain `resourceOnlyPlanned` because this slice adds no executable host
consumer.
