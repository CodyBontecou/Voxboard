# Android/Wear shared-core toolchain baseline

Status: **M2 entry pins selected; no build or implementation claim**

Decision authority: [ADR-0016](adr-0016-vox-owned-toolchain-pinning.md) and
[ADR-0017](adr-0017-core-api-identities-readiness-packaging.md).

The strict machine authority is `toolchains/android-wear-shared-core.json`, checked by
`Packages/contracts/scripts/validate_toolchain.py`. Its schema rejects extra fields and
the validator compares every exact value plus native entry stubs.

## Exact M2 entry pins

- Rust toolchain 1.97.1; MSRV 1.87.0; edition 2024; Cargo resolver 3; minimal profile
  with rustfmt/clippy.
- UniFFI library, bindgen, and CLI exactly 0.32.0; cargo-ndk exactly 4.1.2.
- Android NDK 27.1.12297006 and native API 28 for:
  `arm64-v8a`/`aarch64-linux-android`,
  `armeabi-v7a`/`armv7-linux-androideabi`,
  `x86_64`/`x86_64-linux-android`, and `x86`/`i686-linux-android`.
- Xcode 26.6 build 17F113; Swift 6.3.3; iOS deployment 17.6 for
  `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios`.
- Apple packaging tool identity is `xcodebuild -create-xcframework`.

`Packages/vox-core-rust/rust-toolchain.toml`, `Cargo.toml`, and `uniffi.toml` are honest
entry configuration stubs only. They contain no crate and claim no behavior.

## Required before implementation files land

Cargo.lock and the two binding-generation and two native packaging scripts do not yet
exist. Their exact paths are enumerated as `required-before-implementation`. The
validator fails closed if any appears while still in that state; the implementation
commit must replace the status with governed file SHA-256 values and validate their
pins/config. Thus no fake hash is recorded, but drift cannot silently begin.

Generated Swift/Kotlin sources, libraries, XCFrameworks, AARs, and `.so` files do not
exist and are not claimed. M2 behavior begins only after the lock and scripts land with
hash governance.

## Selection and update process

Any update must name old/new exact values, upstream release/security information,
supported targets, license/provenance change, rollback revision, and regenerate all
bindings. Contract, Rust, host-language, ABI/package, and size gates must pass from clean
checkouts. Floating aliases, ranges, local-cache inference, and dynamic Health.md
inheritance are forbidden.

## Current gates

- **M2 entry foundation: PASS.** Exact selections and fail-closed pre-implementation
  slots are committed. This permits implementing the reviewed M2 scope; it does not
  satisfy any M2 exit gate.
- **M3: BLOCKED.** Exact JDK vendor/version, Gradle/checksum, AGP, Kotlin, compile/target
  SDK, build-tools, Compose, wrapper/catalog, dependency locks/verification, and Android
  binding configuration remain required.
