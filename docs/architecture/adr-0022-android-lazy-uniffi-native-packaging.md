# ADR-0022: Android lazy UniFFI loading and source-built native packaging

Status: **Accepted**

Product decision IDs: `PD-M3-ANDROID-UNIFFI-BRIDGE-001`, `PD-M3-ANDROID-NATIVE-PACKAGING-001`

## Context

M3 now needs an Android consumer for the committed Kotlin UniFFI binding, but no Android
capture flow is yet permitted to report success or perform provider work. Loading JNA or a
native library during application startup would turn a missing or incompatible binary into
an app-start failure. Committed native binaries would also evade the governed source build.

## Decision

`core-bridge` compiles the committed generated Kotlin source directly from
`Packages/vox-core-rust/generated/kotlin`. Because UniFFI 0.32 has no Kotlin visibility option,
the governed binding normalizer makes every generated top-level declaration module-internal;
generation fails if a new public declaration shape appears. A handwritten owned-value boundary
is the only API available to other Android modules, and governance rejects `md.vox.core`
references from every non-test Android source set except the sole adapter (including Java,
debug, release, and flavor bypasses).
Generated/JNA types, native handles, paths, callbacks, and platform authority do not cross it.
Production delegates only to the generated binding; JVM tests inject a fake below the
handwritten boundary. Kotlin generation pins UniFFI's
`android_cleaner = true`, retaining the JNA fallback below API 34 instead of directly requiring
a newer `java.lang.ref.Cleaner` API.

Bridge construction is inert. The first explicit core operation lazily constructs the
production adapter and may load `libvox_core_uniffi.so`. Availability remains
`LAZY_NOT_PROBED` before that operation and fails closed to a content-free coarse error if
loading fails. Application composition remains `NOT_WIRED` in this phase. There is no Kotlin
renderer fallback and readiness grants no native side-effect authority.

Control and observation inputs are copied and bounded to 1 MiB; identifiers are bounded to
256 UTF-8 bytes; drains are bounded to 1 MiB. The adapter passes those owned inputs through
short-lived direct `ByteBuffer` borrows as required by the generated converter, then clears both
the direct storage and its private input copy. Heap `ByteBuffer.wrap` is forbidden. Sessions
expose owned values only. Local bound rejection, cancellation, finalization, explicit close, and
native failures release the generated session; a failing cancellation makes exactly one native
cancellation attempt and then closes the handle without retrying. Error results contain only an
enum code and never exception text or user content.

Every Android variant source-builds its own output directory using Rust `1.97.1`, cargo-ndk
`4.1.2`, NDK `27.1.12297006`, API 28, and exactly `arm64-v8a`, `armeabi-v7a`, `x86_64`, and
`x86`. No `.so` is committed. Android consumes JNA's pinned AAR (not its JVM-only JAR),
excludes obsolete armeabi/MIPS payloads, and requires `libjnidispatch.so` at the same four ABI
paths. Debug APK inspection requires one Vox and one JNA runtime library at each exact ABI path
and checks ELF class, little-endian encoding, and machine identity. That inspection
attests packaging structure, not runtime behavior.

A production-adapter instrumentation consumer compiles against governed expected-version and
M3 request fixture assets. Until it runs on an Android target, it is not execution evidence
and does not promote any contract mirror lifecycle.

## Consequences

Hosted assembly can establish source compilation, four-ABI packaging, and static ELF facts.
It cannot establish Android loader behavior, UniFFI execution, device ABI coverage,
cancellation under process death, performance, persistence, SAF delivery, or product success.
Those claims remain blocked on target execution and later M3 slices.
