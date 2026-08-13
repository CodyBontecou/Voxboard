# ADR-0016: Vox-owned toolchain pinning

- Status: **Accepted**
- Product decision ID: `PD-M1-TOOLCHAIN-PINNING-001`
- Required by: M2 and M3

## Context

M2 requires reproducible Rust, UniFFI, bindings, and Apple packaging. M3 adds the
Android build toolchain. Referencing Health.md establishes precedent but does not pin
Vox.md builds, and “newest stable” is not an executable version. This repository does
not yet contain Android or Rust build files from which exact honest versions can be
recorded.

## Decision

Vox.md owns its toolchain choices. The mandatory baseline and review process are defined
in [`android-wear-toolchain-baseline.md`](android-wear-toolchain-baseline.md). Before M2
starts, the repository must commit exact Rust/UniFFI/bindgen and Apple packaging pins in
the canonical Vox-owned pin manifest plus native lock/toolchain files. Before M3 starts,
it must add exact JDK, Gradle, AGP, Kotlin, Android SDK/build-tools, NDK, Compose, and
Android dependency pins.

No version is inherited dynamically from Health.md, a developer workstation, CI image
alias, “latest,” or an unreviewed transitive resolution. The pin manifest is an index;
actual package managers remain authoritative for their lock formats, and CI validates
that both representations agree.

Because exact Android/Rust selections are not established by current Vox.md repository
evidence, this ADR deliberately does not invent them. M2 and M3 remain blocked at their
respective entry gates until the required exact pins are committed and reviewed.

## Consequences

Toolchain updates are explicit reviewed changes with regeneration, compatibility,
binary-size, license/provenance, and rollback consideration. Health.md may inform a
proposal but cannot satisfy the Vox-owned gate by reference.

## Executable gate

M2/M3 entry validation rejects a missing/incomplete pin manifest, floating aliases,
lockfile drift, generated-binding drift, or disagreement between the manifest and
native toolchain files. This ADR claims no selected version or reproducible build.
