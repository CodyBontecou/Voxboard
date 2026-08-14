# Android/Wear shared-core toolchain baseline

Status: **M3 Android application toolchain entry and M2 native packaging governed**

The machine authority is `toolchains/android-wear-shared-core.json`, validated by the
stdlib-only `Packages/contracts/scripts/validate_toolchain.py`. Native M2 pins remain Rust
1.97.1, MSRV 1.87.0, edition 2024/resolver 3, UniFFI 0.32.0, cargo-ndk 4.1.2,
NDK 27.1.12297006/API 28, and Xcode 26.6 (`17F113`)/Swift 6.3.3/iOS 17.6. Schema version 2
adds the reviewed Android application entry pins and carries SHA-256 for every governed
binding/native script plus the Android wrapper/configuration inputs. The validator admits
one exact ordered, non-shrinkable governed path inventory and binds the complete schema by
its canonical SHA-256; deleting an inventory row or weakening any schema rule fails closed.

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
resource mirrors remain `resourceOnlyPlanned` until a named executable consumer exists.
Phase 0 creates no Kotlin product module and therefore does not promote the Android mirror.

## M3 Android application entry baseline

The exact application tuple is Eclipse Temurin `17.0.20+8`, Gradle `9.3.1`, AGP `9.1.0`,
AGP built-in Kotlin `2.4.10`, Compose compiler plugin `2.4.10`, stable Compose BOM
`2026.08.00`, compile SDK 37, and Build Tools `36.0.0`. Phone uses min SDK 28/target SDK 36;
Wear uses min SDK 30/target SDK 35. The application namespace and ID are `md.vox.android`.

Gradle's distribution SHA-256 is
`b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06`; the committed
wrapper JAR SHA-256 is
`b3a875ddc1f044746e1b1a55f645584505f4a10438c1afea9f15e92a7c42ec13`. The wrapper
properties enable URL validation and repeat the distribution checksum.

Kotlin 2.4.10's published compatibility range makes AGP 9.1 the conservative selection
rather than newer AGP 9.3. AGP 9 built-in Kotlin replaces `org.jetbrains.kotlin.android`.
No stable KSP/Kotlin 2.4.10 compatibility was asserted, so Room/Hilt processing is pinned
to AGP's `com.android.legacy-kapt` 9.1.0 escape hatch until a separately reviewed KSP
migration. Compose runtime libraries are governed by the exact stable BOM while the
compiler plugin remains tied exactly to Kotlin.

Direct stable dependency pins are centralized in
`apps/android/gradle/libs.versions.toml`: Core 1.19.0, Activity 1.13.0, Lifecycle 2.11.0,
Navigation 2.9.8, Room 2.8.4, DataStore 1.2.1, WorkManager 2.11.2, Dagger/Hilt 2.60.1,
AndroidX Hilt 1.4.0, coroutines 1.11.0, serialization 1.11.0, JNA 5.17.0, and exact Android
and JUnit test trains. Repository policy rejects project repositories. Floating, preview,
KSP, and legacy Kotlin Android plugin aliases fail validation.

Official compatibility/release authorities are:

- <https://developer.android.com/build/releases/agp-9-1-0-release-notes>
- <https://developer.android.com/build/migrate-to-built-in-kotlin>
- <https://kotlinlang.org/docs/gradle-configure-project.html>
- <https://kotlinlang.org/docs/releases.html>
- <https://developer.android.com/develop/ui/compose/compiler>
- <https://developer.android.com/develop/ui/compose/bom>
- <https://developer.android.com/jetpack/androidx/versions/stable-channel>
- <https://dagger.dev/hilt/gradle-setup>

The committed root build resolves exact plugins and `./gradlew help` validates wrapper and
plugin resolution. It is deliberately not an Android app build: Phase 1 must add modules,
resolve dependency locks/verification metadata, build with exact SDK packages, and obtain
separate review before product implementation claims begin.
