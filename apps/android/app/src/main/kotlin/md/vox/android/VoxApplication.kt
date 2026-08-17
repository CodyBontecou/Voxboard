package md.vox.android

import android.app.Application
import md.vox.android.capturedomain.CaptureAvailability
import md.vox.android.capturedomain.CaptureFoundation
import md.vox.android.corebridge.unwiredCoreBridge

class VoxApplication : Application() {
    val compositionRoot: AppCompositionRoot by lazy { AppCompositionRoot.create() }
}

class AppCompositionRoot private constructor(
    val captureFoundation: CaptureFoundation,
) {
    companion object {
        fun create(): AppCompositionRoot {
            val coreBridge = unwiredCoreBridge()
            val captureFoundation = object : CaptureFoundation {
                override val coreBridge = coreBridge
                override val captureAvailability = CaptureAvailability.NOT_IMPLEMENTED
            }
            return AppCompositionRoot(captureFoundation)
        }
    }
}
