# vox-core Rust workspace

M2 implements only deterministic `newNoteTextLink` preparation and materialization. `vox-core` is pure and forbids unsafe code. `vox-core-uniffi` is the bounded panic-containing native boundary. Platform I/O, persistence, credentials, provider access, callbacks, and side effects remain native-owned.

Generated Swift and Kotlin bindings are committed under `generated/`; the Swift binding is copied byte-identically into the `VoxCoreGenerated` SwiftPM target and checked for drift. Source-built libraries, host executables, and XCFrameworks remain ignored or externally retained outputs. `run-m2-hosted-evidence.sh` is the only canonical hosted orchestrator for CORE-001…005, PERF-003, and PERF-008; repository bytes alone do not claim execution.
