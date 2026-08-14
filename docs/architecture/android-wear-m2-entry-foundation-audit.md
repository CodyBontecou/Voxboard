# Android/Wear M2 foundation audit

Status: **Phase A core, exact generated bindings, and native package proof implemented**

M2 remains open for the Apple wrapper/shadow adapter and complete performance evidence.
This slice adds governed UniFFI 0.32.0 Swift/Kotlin generation, byte-identical drift
checks, exact four-ABI Android API-28 builds, exact two-leaf iOS 17.6 static XCFramework
packaging, inspection tooling/evidence, and path-filtered Rust CI.

The former detached local inspection record was removed because it was not a canonical
campaign receipt and referenced an unreproducible source revision. The evidence contract
now represents a first core honestly as `initialCandidate`, with six absolute leaves and no
predecessor or growth assertion. No real `PERF-008` campaign is claimed until the tracked
producer emits the typed receipt in a bound hosted run with retained source-built artifacts.

Native binaries are never committed. Generated binding source is committed. The Rust
contract mirror alone is promoted to required through an executable Rust test consumer;
Swift and Kotlin/Android mirrors remain planned.
