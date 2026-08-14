package md.vox.android.corebridge

/** Boundary for the generated UniFFI consumer. Native loading is not integrated in Phase 1. */
interface CoreBridge {
    val availability: CoreAvailability
}

enum class CoreAvailability {
    NOT_INTEGRATED,
}
