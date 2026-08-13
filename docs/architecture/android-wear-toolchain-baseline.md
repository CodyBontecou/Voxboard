# Android/Wear shared-core toolchain baseline

Status: **Pin slots approved; exact selections pending**

Decision authority: [ADR-0016](adr-0016-vox-owned-toolchain-pinning.md)

This document defines the Vox-owned pin file and update process. It is not a version
record yet: the repository has no Rust workspace or Android build from which the exact
selections can be honestly established. M2 and M3 stay blocked as stated below.

## Canonical machine-readable pin file

The canonical index will be committed at:

```text
toolchains/android-wear-shared-core.json
```

It must be strict JSON with an integer schema version and exact, non-range values for
all applicable fields. `latest`, `stable`, wildcards, version ranges, preview aliases,
CI-image aliases, and omitted required fields are invalid.

Required before **M2 starts**:

- Rust toolchain/channel resolved to an exact release and required components/targets;
- Cargo resolver and exact UniFFI CLI/library/bindgen versions;
- Apple target triples, Xcode build/version, Swift version, and XCFramework packaging
  command/tool identity;
- exact Android NDK revision, exact native API/platform level for every Rust target, and
  the complete Android ABI-to-Rust-target mapping needed to build M2 Android libraries;
- generated Swift and Kotlin binding generator version/config hashes; and
- hashes/paths for the committed Rust lockfile, `rust-toolchain.toml`, binding config,
  and generation scripts.

Required before **M3 starts** (in addition to the M2 fields):

- JDK vendor and exact version;
- Gradle distribution version and checksum;
- Android Gradle Plugin and Kotlin versions;
- compile SDK, target SDK, min SDKs, and exact SDK build-tools;
- Compose compiler/BOM or individually pinned Compose artifacts; and
- hashes/paths for version catalogs, wrapper properties, dependency lock/verification
  metadata, and Android binding-generation configuration.

Native files such as `rust-toolchain.toml`, `Cargo.lock`, Gradle wrapper properties,
version catalogs, dependency verification/locks, and CI Xcode selection remain the
execution authorities. The JSON index must agree with them and makes cross-file drift
reviewable.

## Selection and update process

1. Open a dedicated toolchain proposal naming every old/new exact value, upstream
   release and security notes, supported host/target matrix, license/provenance changes,
   and rollback revision.
2. Confirm each candidate exists in an authoritative distribution and is mutually
   compatible; do not infer a version from Health.md or a local cache.
3. Update the JSON index and all native lock/toolchain files atomically.
4. Regenerate committed bindings and require zero unreviewed diff after a second clean
   generation.
5. Run contract/schema tests, Rust tests, host-language consumer tests, ABI/package
   builds, binary-size budgets, and the milestone's supported host/device checks.
6. Review and commit the update; CI uses only the committed pins and fails on drift or
   downloads that violate checksum/verification metadata.

Emergency security updates follow the same record and validation requirements; urgency
does not permit floating versions.

## Current entry-gate state

- **M2: BLOCKED.** Exact Rust, UniFFI, binding, Xcode/Swift, target, packaging, Android
  NDK, native API/platform levels, and ABI-to-Rust-target pins have not been selected and
  committed in the Vox-owned manifest/native files.
- **M3: BLOCKED.** The M2 NDK/native-target prerequisites above remain required; the
  additional exact JDK/Gradle/AGP/Kotlin/SDK/Compose pins and Android lock/verification
  files also do not yet exist.

This status records missing prerequisites only. It claims no implementation, generated
binding authority, build reproducibility, or validation evidence.
