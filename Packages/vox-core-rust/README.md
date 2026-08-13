# vox-core Rust workspace

M2 implements only deterministic `newNoteTextLink` preparation and materialization. `vox-core` is pure and forbids unsafe code. `vox-core-uniffi` is the bounded panic-containing native boundary. Platform I/O, persistence, credentials, provider access, callbacks, and side effects remain native-owned.

Generated Swift and Kotlin bindings are committed under `generated/`; source-built libraries and XCFrameworks remain ignored build outputs.
