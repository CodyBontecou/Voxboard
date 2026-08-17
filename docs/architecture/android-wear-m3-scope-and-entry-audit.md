# Android/Wear M3 scope and entry audit

Status: **M3 Phase 1–4 foundations hosted-qualified; vertical slice incomplete**

M2 is qualified at `450abcaab4f09f5a4803d535ee843d1c058f099b`. This audit
retains the machine-consistent M3 boundary and exact Android application toolchain while
recording the first compileable phone/tablet foundation, the hosted-qualified Phase 2–4
foundations, the Phase 4 lazy UniFFI packaging slice, and the first physical-target
execution of the native bridge and Room migration on one Pixel 7. It claims no provider
result, process-death campaign, physical directory-fsync result, SAF commit, quota outcome,
on-target materialization markdown, multi-device coverage, or M3 exit.

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

`:data` activates Room runtime plus its governed legacy-kapt compiler for the content-free
package projection. DataStore and WorkManager remain `compileOnly`, with no initializer or
worker. `:core-bridge` declares exact JNA without a native-load claim.

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

## Phase 2 durable-enqueue and local Phase 3 substrate status

ADR-0020 defines capture-package codec v1, byte-bound journal v1, the exact M3 text/link
admission profile, duplicate correlation, and no-downgrade fsync/atomic-promotion semantics.
The governed request fixture is consumed as exact bytes by Kotlin and the existing Rust
production `prepare` function. Admission requires native-observed sensitive case behavior;
real-provider discovery remains a blocker and is not assumed.

The data module contains strict canonical codecs, an app-private cooperative FileChannel
promotion-lock protocol, duplicate validation, bounded temporary reconciliation, typed
index failures, and a content-free Room schema/DAO/index. JVM tests inject distinct before
and after failures around operations; they do not claim injection inside OS calls. Generated
Room sources and the instrumentation APK compile. This is local build and fault-injection
evidence only: instrumentation has not run on an emulator/device, directory fsync and file
locking have not been physically qualified, and no M3 case is `passed`.

ADR-0021 now adds locally implemented, production-unwired journal replacement, root-lock-routed
opaque lease fencing with persisted rollback defense, Room-v2 migration, and request-idempotent
quota primitives. Its terminal quota/tombstone
transaction is internal and has no production caller before a future governed verified
receipt. Completed-package cleanup, composer acknowledgement, SAF/provider commit,
WorkManager execution, DataStore runtime, prepared artifacts, and the Rust Kotlin/native
bridge remain unconnected.

## Persistence and SAF authority

ADR-0018 makes the versioned package/journal recovery authority and Room the index/lease/
query coordinator. It defines fsync/promotion/Room/UI ordering, immutable prepared plan
storage, quota transaction ordering, and cleanup crash behavior.

ADR-0019 defines native-only SAF ownership and the exact result taxonomy:
`verifiedCommitted`, `provedNotCommitted`, `permissionLost`, and `ambiguous`. Restart from
`committing` without a receipt reconciles only; it never blindly invokes the normal writer.

## Local Phase 4 lazy bridge and native packaging status

ADR-0022 consumes the committed Kotlin binding as `core-bridge` production source and adds a
handwritten lazy, fail-closed, bounded owned-value API. Production delegates only to generated
UniFFI; fake adapters are test-only. The application composition root intentionally remains
`NOT_WIRED`, so this slice grants no capture, persistence, provider, quota, or success
authority and has no Kotlin rendering fallback.

Debug and release native outputs are variant-isolated and source-built for the four governed
API-28 ABIs. Static APK validation requires each Vox library plus JNA's Android runtime at the
same four ABIs and validates ELF class/machine.
A compiled instrumentation consumer calls generated build-info, readiness, and prepare with
governed fixture assets.

## Phase 4.1 first target-executed evidence

On 2026-08-15 the instrumentation suites were executed on a physical Pixel 7
(`panther`, Android 17, `arm64-v8a`) after the hosted Phase 4 qualification. Results:

- `:core-bridge:connectedDebugAndroidTest` — 1/1 passed. The source-built
  `libvox_core_uniffi.so` loaded on-target through the lazy bridge; generated
  build-info, readiness, and prepare executed through UniFFI. On-device checks
  now cover: live `CORE_VERSION` reporting; the readiness manifest gate failing
  closed on a synthetic zero digest (`toolchainManifestMismatch`, session not
  permitted) and passing only with the runtime digest from build-info; and
  prepare returning the canonical content-free `RequiredObservations` control
  (payload text/URLs are not echoed).
- `:data:connectedDebugAndroidTest` — 6/6 passed, including the v1→v2 Room
  migration equivalence, terminal transaction rollback/idempotency, lease, and
  quota instrumentation consumers.

First-execution findings were fixed in the same session: the instrumented test
previously asserted the synthetic schema-fixture version (`0.1.0-m2-foundation`)
and a zero manifest digest against live runtime output, and misread the prepare
result as rendered markdown; and `MIGRATION_1_2` had used `ALTER TABLE ADD
COLUMN … DEFAULT 0`, which leaves a `DEFAULT` clause that diverges from Room's
expected v2 schema and would fail runtime `TableInfo` validation on migrated
devices. The migration now rebuilds `capture_projection` to be byte-equivalent
to a fresh v2 create. This is exactly the class of defect that only target
execution reveals; hosted compilation could not catch it.

Bounded claims: native load + UniFFI control calls, Room migration/rollback/
quota behavior, and schema equivalence are now device-evidenced on one physical
target. Not yet claimed: materialization-session markdown on-target, SAF
provider behavior, process-death campaigns, backup/device-transfer extraction,
performance gates, or any passed M3 campaign case.

## Phase 4 hosted qualification

The reviewed Phase 4 implementation revision and hosted source revision are
`4c0b45716c9ffc2cf1167af62b60ed0158a44283`. GitHub Actions passed:

- [Android foundation CI `31895160525`](https://github.com/CodyBontecou/vox.md/actions/runs/31895160525),
  job `95037247247`, including 79 governed implementation hashes, 94 fixtures, 94 project-contract
  tests, source-built Rust/NDK native outputs for all four API-28 ABIs, JVM tests, lint, debug and
  instrumentation APK assembly, and static merged-artifact/ELF/backup validation;
- [Portable contracts CI `31895160434`](https://github.com/CodyBontecou/vox.md/actions/runs/31895160434),
  job `95037246716`;
- [Shared Rust core CI `31895160465`](https://github.com/CodyBontecou/vox.md/actions/runs/31895160465),
  jobs `95037246774` and `95037246713`; and
- [Apple CI `31895160478`](https://github.com/CodyBontecou/vox.md/actions/runs/31895160478),
  all five jobs.

The first Phase 4 Android run `31894694804` failed because the hosted SDK installed the governed
NDK but the build did not export its side-by-side path; commit `7e415c8` added an explicit path
assertion/export and the exact source rerun passed. The failed run is retained as discovery history,
not passing evidence.

This qualifies hosted source compilation, generated binding compilation, four-ABI packaging,
JVM behavior, and static artifact/governance checks. It does **not** qualify native loading,
UniFFI execution on a target, cancellation under process death, Room/device migration,
provider behavior, backup extraction/device transfer, performance, or any passed M3 case.

## Phase 3 hosted qualification

The reviewed Phase 3 implementation revision is
`b1cb02e6c89fe244a9ee73ed4448a2858fd3c777`; its clean-source oracle successor and hosted
source revision is `2549a83f9792226f49f9178cbac9c4871e709ef7`. GitHub Actions passed:

- [Android foundation CI `31889908157`](https://github.com/CodyBontecou/vox.md/actions/runs/31889908157),
  job `95024541014`, including 72 governed implementation hashes, 87 project-contract tests,
  all JVM durability/planner tests, lint, instrumentation APK assembly, and static artifact
  validation on `ubuntu-24.04`;
- [Portable contracts CI `31889908113`](https://github.com/CodyBontecou/vox.md/actions/runs/31889908113),
  job `95024541021`;
- [Shared Rust core CI `31889908104`](https://github.com/CodyBontecou/vox.md/actions/runs/31889908104),
  jobs `95024540909` and `95024540883`; and
- [Apple CI `31889908130`](https://github.com/CodyBontecou/vox.md/actions/runs/31889908130),
  attempt 2, whose iOS, repository-contract, macOS, Watch, and shared-package jobs all passed.

Apple attempt 1 terminated during an unrelated M0 inspiration-cache test with a simulator
process allocator error after all listed source changes were Android/governance-only. The
exact same source revision passed the complete Apple workflow on rerun; the failed attempt
is retained as flaky runtime history, not passing evidence.

Independent blocker/high review drove fixes for continuous root-lock lease fencing, typed
replacement uncertainty, exact revision replay, persisted rollback defense, conservative
quota classification, Room transaction rollback, migration equivalence, bounded concurrency,
and production-bypass governance. Final independent follow-up returned PASS with no remaining
blocker/high finding.

This qualifies host/JVM behavior, generated Room compilation/schema validation, and static
artifacts only. Instrumentation was assembled but not executed on an Android target. Physical
atomic replacement, directory fsync, locking, Room migration, clock/reboot, process-death,
backup/device-transfer, quota product flow, and provider behavior remain unqualified.

## Phase 2 hosted qualification

The reviewed Phase 2 implementation revision is
`8ab3c926f4202047eed4b549ddc224a2a0df1153`; its clean-source oracle successor and hosted
source revision is `db01ca1771401a477e427ff822a79bcf3d3749c8`. GitHub Actions passed:

- [Android foundation CI `31885964682`](https://github.com/CodyBontecou/vox.md/actions/runs/31885964682),
  job `95015192535`, including 59 governed implementation hashes, 85 project-contract tests,
  `test lint assembleDebug assembleDebugAndroidTest :app:validateDebugArtifacts`, and actual
  merged-manifest/backup artifact validation on `ubuntu-24.04`;
- [Portable contracts CI `31885964590`](https://github.com/CodyBontecou/vox.md/actions/runs/31885964590);
- [Shared Rust core CI `31885964684`](https://github.com/CodyBontecou/vox.md/actions/runs/31885964684),
  jobs `95015192685` and `95015192616`, including the exact governed Android M3 fixture through
  Rust production `prepare`, binding drift, MSRV tests, and retained M2 evidence regeneration;
  and
- [Apple CI `31885964628`](https://github.com/CodyBontecou/vox.md/actions/runs/31885964628),
  whose macOS, Watch, iOS, shared-package, and repository-contract jobs all passed.

Independent blocker/high review accepted the durability, codec, reducer, Room, and
governance substance but found two audit/workflow governance issues. Those were fixed by
commit-pinning and hash-governing Portable Contracts checkout with adversarial mutation
coverage, and by narrowing this audit's durability disclaimer. Independent follow-up review
returned PASS with no remaining blocker/high finding.

This hosted qualification proves compilation, deterministic consumers, JVM fault injection,
instrumentation APK assembly, and static artifact defenses. It does **not** prove on-device
Room execution, physical directory-fsync or lock behavior, process death, provider behavior,
backup extraction/device transfer, or any passed M3 case.

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

- Execute the packaged generated Kotlin/native bridge consumer on an actual Android target.
  The core-bridge contract-resource mirror remains `resourceOnlyPlanned` until a named
  executable consumer runs against that exact mirror; target execution must not be inferred
  from APK assembly.
- Execute the generated Room migration/coordination instrumentation consumers, then connect
  quota only at the future verified-receipt barrier and implement prepared artifacts,
  SAF/provider reconciliation, composer wiring, and the complete text/link
  vertical slice. DataStore and WorkManager runtime remain intentionally inactive. The
  current UI is still an explicitly unavailable shell.
- Run process-death instrumentation and exact artifact inspection.
- Execute local plus two named non-local DocumentsProvider campaigns on actual required
  devices. Do not fabricate unavailable providers or measurements.
