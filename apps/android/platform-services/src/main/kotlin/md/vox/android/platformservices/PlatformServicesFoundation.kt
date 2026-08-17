package md.vox.android.platformservices

import md.vox.android.capturedomain.CaptureAvailability

/** Platform adapters are intentionally absent from the Phase 1 foundation. */
interface PlatformServicesFoundation {
    val captureAvailability: CaptureAvailability
}
