# Android/Wear M2 foundation audit

Status: **Phase A core, generated bindings, Apple shadow seam, and hosted evidence producers implemented**

M2 remains open until the exact source revision completes the canonical hosted campaign.
The implementation now includes governed UniFFI 0.32.0 Swift/Kotlin generation and drift
checks, handwritten `VoxCoreRust`, binary-free admission/comparison policy, a pre-side-effect
`CapturePipeline` seam, exact four-ABI Android API-28 and two-leaf iOS 17.6 package builders,
and tracked CORE/PERF producers under the unconditional `m2-evidence` CI job.

The former detached local inspection record was removed because it was not a canonical
campaign receipt and referenced an unreproducible source revision. The evidence contract
now represents a first core honestly as `initialCandidate`, with six absolute leaves and no
predecessor or growth assertion. No real CORE, `PERF-003`, or `PERF-008` campaign is
claimed by repository bytes alone; qualification requires the tracked producers to execute
from a clean bound GitHub checkout with retained source-built artifacts and exact raw USTAR.

Native binaries are never committed. Generated binding source is committed in the canonical
Rust workspace and copied byte-identically into the SwiftPM generated target under a drift
gate. The Rust contract mirror alone is promoted to required through an executable Rust test
consumer; Swift and Kotlin/Android mirrors remain planned.
