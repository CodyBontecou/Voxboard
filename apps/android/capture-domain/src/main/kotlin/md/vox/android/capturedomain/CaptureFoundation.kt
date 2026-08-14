package md.vox.android.capturedomain

import md.vox.android.corebridge.CoreBridge

/** Inward-facing contracts only; Android storage and UI implementations live outside this module. */
interface CaptureFoundation {
    val coreBridge: CoreBridge
    val captureAvailability: CaptureAvailability
}

enum class CaptureAvailability {
    NOT_IMPLEMENTED,
}
