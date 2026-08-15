# Android/Wear M3 scope and entry audit

Status: **M3 Phase 1 Android build foundation and backup defense hosted-qualified; vertical slice not started**

M2 is qualified at `450abcaab4f09f5a4803d535ee843d1c058f099b`. This audit
retains the machine-consistent M3 boundary and exact Android application toolchain while
recording the first compileable phone/tablet foundation. It claims no provider result,
physical device, process-death result, durable package, Room migration, SAF commit, quota
outcome, Kotlin binding consumption, native library load, or M3 exit.

## Approved M3 product scope

M3 is the smallest complete phone/tablet new-note text/link slice. The M0 ledger now keeps
only these capabilities at M3:

- `cap.ai.mode-none`
- `cap.billing.reinstall-adjustment`
- `cap.delivery.standard`
- `cap.entry.app`
- `cap.history.tombstone`
- `cap.payload.text`
- `cap.payload.url`
- `cap.quota.capture`
- `cap.quota.retry-no-charge`
- `cap.target.new`

M3 implements successful-delivery capture quota and its product-adjusted reinstall behavior.
Transcription quota and voice-metering preferences move to M4. Editor actions, location,
configurable presets, templates, prefix/suffix, frontmatter, retry markers, and rolling or
existing-note targets move to M5, matching the implementation plan and shared-core operation
promotion order. The M3 composer uses one fixed preset policy only. These are schedule
corrections, not removal or parity reclassification.

`SAF-001` now requires exact Rust-authoritative text/link note commit/readback and no longer
claims M5 attachments. Recording-focused `REC-004` is M4. A separate M3 large-screen
text/link lifecycle definition is `SAF-007`.

## Named M3 evidence definitions

The case catalog defines, without claiming results:

- `CORE-006`: generated Kotlin consumption, lazy four-ABI load, independently supplied
  readiness pins, Rust authority, and no Kotlin renderer fallback;
- `CORE-007`: manifest, permission, backup, and data-extraction exclusion;
- `CORE-008`: exact-once successful-delivery quota;
- `CORE-009`: composer acknowledgement only after durable package and Room index;
- `CORE-010`: physical seeded backup extraction, fresh-install/device-transfer identity,
  quota/grant non-restoration, and explicit grant repair;
- `CORE-011`: typed ADR-0018 corrupt/truncated package, stale lease, orphan reservation,
  and package/row/journal divergence reconciliation matrix;
- `SAF-001`–`SAF-005`: exact new note, revoked grant, non-local behavior, commit crash
  reconciliation, and large-screen provider flow;
- `SAF-006`: process death after every durable transition;
- `SAF-007`: large-screen text/link lifecycle;
- `SAF-008`: executable ADR-0019 fake/instrumented provider fault matrix and exact result
  taxonomy;
- `PERF-001`, `PERF-002`, and `PERF-004`: durable enqueue, Quick Capture, and SAF watchdog.

M3 milestone aggregation still includes every required M0–M2 predecessor. Definitions alone
cannot satisfy a case. Until each M3 case has a case-specific governed typed producer,
receipt, and exact provenance validator, the validator rejects any `passed` M3 evidence.
Physical/provider cases remain incomplete until retained synthetic campaign bytes name
actually observed devices and providers.

## Exact Android application toolchain

Machine authority is `toolchains/android-wear-shared-core.json` schema version 2. Native M2
pins are unchanged. The new application baseline is:

| Item | Exact selection |
| --- | --- |
| Namespace/application ID | `md.vox.android` |
| Build JDK | Eclipse Temurin `17.0.20+8`; Java language/JVM target 17 |
| Gradle | `9.3.1`; wrapper distribution and JAR SHA-256 pinned |
| Android Gradle Plugin | `9.1.1` |
| Kotlin / Compose compiler plugin | `2.4.10` / `2.4.10`; AGP built-in Kotlin |
| Annotation processing | `com.android.legacy-kapt` `9.1.1`; no unverified KSP claim |
| Android command-line tools | Linux archive `15859902`, tools `22.0`, exact URL and SHA-256 pinned |
| Android platform/build tools | compile SDK 37; Build Tools `36.0.0` |
| Phone | min SDK 28; target SDK 36 |
| Wear | min SDK 30; target SDK 35 |
| Compose BOM | `2026.08.00` |

All direct Android dependency versions required for the initial architecture are exact in
`apps/android/gradle/libs.versions.toml`. Compose libraries use the exact stable BOM; the
compiler remains the independently pinned Kotlin plugin. No `+`, `latest`, preview,
`org.jetbrains.kotlin.android`, or unreviewed KSP alias is admitted.

The repository now contains an included `apps/android/build-logic` build with application,
library, Compose, and JVM-test convention plugins plus `:app`, `:core-bridge`,
`:capture-domain`, `:data`, and `:platform-services`. There is deliberately no Wear module.
AGP built-in Kotlin is used; module dependencies point inward and manual concrete wiring is
confined to `:app`.

The single-activity Compose shell navigates among onboarding, vault setup, Quick Capture,
inbox, and history. Every product surface says unavailable/not implemented and makes no
durability, SAF, native-load, or delivery claim. Phase 1 adds no sensitive, network,
storage/media, microphone, or location permission. It sets `allowBackup=false` and
references defense-in-depth legacy and modern rules excluding all storage domains at their
roots for cloud backup and device transfer. Static source tests and the Gradle-wired artifact
validator parse the actual merged debug manifest, reject unreviewed exported transitive
components and WorkManager startup, and recheck both backup rule resources. These are static
build-artifact limits, not backup extraction or device-transfer evidence.

`:data` retains the exact Room, DataStore, and WorkManager declarations as `compileOnly`, so
none is runtime-packaged or initialized before behavior exists. `:core-bridge` declares exact
JNA without a native-load claim.

Generated dependency locks and SHA-256 verification metadata cover the configurations
actually resolved by `test lint assembleDebug`. The authoritative root, included-build,
convention-plugin, module-build, artifact-validator, lock/verification, wrapper, and Android
CI workflow are hash-governed. CI pins action commits, Temurin, command-line-tools archive,
SDK packages, and tool hashes exactly. The `ubuntu-24.04` hosted runner image is observed
infrastructure, not a bit-pinned toolchain or an evidence claim.

## Compatibility rationale

- Android's AGP 9.1.1 release notes establish API 37, Gradle 9.3.1, Build Tools 36.0.0,
  and JDK 17 compatibility:
  <https://developer.android.com/build/releases/agp-9-1-0-release-notes>
- Kotlin's compatibility and release pages establish Kotlin 2.4.10 and the conservative
  AGP 9.1 ceiling used here:
  <https://kotlinlang.org/docs/gradle-configure-project.html> and
  <https://kotlinlang.org/docs/releases.html>
- AGP 9 built-in Kotlin and its legacy-kapt migration escape hatch are documented at:
  <https://developer.android.com/build/migrate-to-built-in-kotlin>
- Compose compiler/Kotlin coupling and stable BOM policy are documented at:
  <https://developer.android.com/develop/ui/compose/compiler> and
  <https://developer.android.com/develop/ui/compose/bom>
- AndroidX versions are selected from stable component release channels:
  <https://developer.android.com/jetpack/androidx/versions/stable-channel>
- Dagger/Hilt `2.60.1` comes from the owning project's setup guide:
  <https://dagger.dev/hilt/gradle-setup>
- The exact Temurin release is `jdk-17.0.20+8`; CI must request that exact distribution,
  not a floating Java 17 alias.

AGP 9.3 was not selected even though available: Kotlin 2.4.10's published compatibility
range conservatively ends at AGP 9.1. KSP was not selected because an exact Kotlin 2.4.10
compatible stable KSP release was not established. These may change only through a reviewed
pin update with a resolved build and regenerated locks/verification metadata.

## Persistence and SAF authority

ADR-0018 makes the versioned package/journal recovery authority and Room the index/lease/
query coordinator. It defines fsync/promotion/Room/UI ordering, immutable prepared plan
storage, quota transaction ordering, and cleanup crash behavior.

ADR-0019 defines native-only SAF ownership and the exact result taxonomy:
`verifiedCommitted`, `provedNotCommitted`, `permissionLost`, and `ambiguous`. Restart from
`committing` without a receipt reconciles only; it never blindly invokes the normal writer.

## Phase 1 hosted qualification

The final Phase 1 source revision is
`7de3c0ae1512eff9b4427dea5e62ca1c4e4e2475`. GitHub Actions run
[`31852058850`](https://github.com/CodyBontecou/vox.md/actions/runs/31852058850), job
`94929526814`, passed on `ubuntu-24.04`. The hosted job:

- downloaded command-line tools archive `15859902` and passed the exact Linux SHA-256
  check before installing API 37, Build Tools 36.0.0, and NDK 27.1.12297006;
- passed wrapper startup, all 45 governed implementation hashes, contract validation, and
  83 project-contract tests;
- completed `test lint assembleDebug :app:validateDebugArtifacts` with 237 actionable
  Gradle tasks; and
- passed merged-manifest, permission/export, WorkManager-startup, and backup-defense
  artifact validation.

The hosted run initially exposed Linux-only Gradle metadata variants absent from the macOS
resolution. A temporary, closed, never-merged diagnostic PR ran Gradle's metadata writer on
Linux; every added Maven Central byte was then independently downloaded and SHA-256 checked
before admission. The governed validator and mutation tests now require those exact Linux
artifacts. Failed discovery runs and the diagnostic run are retained as troubleshooting
history, not passing evidence. Independent Phase 1 build and security reviews both returned
PASS with no blocker/high finding.

This qualifies only the Phase 1 build/static-defense foundation. It is not physical-device,
provider, backup-extraction, process-death, performance, or M3 product evidence.

## Remaining M3 blockers

- Implement the Kotlin bridge and promote the Kotlin mirror only after its named executable
  fixture consumer runs; it remains `resourceOnlyPlanned` in Phase 1.
- Implement durable packages, actual Room/DataStore/WorkManager behavior, quota, SAF,
  provider reconciliation, and the text/link vertical slice. The current UI is only an
  explicitly unavailable shell and backup defense is only statically established.
- Run process-death instrumentation and exact artifact inspection.
- Execute local plus two named non-local DocumentsProvider campaigns on actual required
  devices. Do not fabricate unavailable providers or measurements.
