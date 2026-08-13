# Android/Wear M2 foundation audit

Status: **Phase A core, exact generated bindings, and native package proof implemented**

M2 remains open for the Apple wrapper/shadow adapter and complete performance evidence.
This slice adds governed UniFFI 0.32.0 Swift/Kotlin generation, byte-identical drift
checks, exact four-ABI Android API-28 builds, exact two-leaf iOS 17.6 static XCFramework
packaging, inspection tooling/evidence, and path-filtered Rust CI.

The local source-built inspection record is
`docs/validation/evidence/m2-local-native-package-inspection.json`. It records actual
nonzero leaf sizes/hashes and absolute results without inventing predecessor growth,
approvals, or device facts. PERF-008 is not claimed because the current campaign evidence
contract cannot represent first-core evidence without a baseline/candidate pair.

Native binaries are never committed. Generated binding source is committed. The Rust
contract mirror alone is promoted to required through an executable Rust test consumer;
Swift and Kotlin/Android mirrors remain planned.
