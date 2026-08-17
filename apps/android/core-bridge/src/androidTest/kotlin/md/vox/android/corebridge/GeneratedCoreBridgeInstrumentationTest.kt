package md.vox.android.corebridge

import androidx.test.platform.app.InstrumentationRegistry
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Compiled production-path consumer; assembly is not execution evidence. */
class GeneratedCoreBridgeInstrumentationTest {
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets

    @Test
    fun governedM3FixturePassesGeneratedReadinessAndPrepare() {
        val bridge = productionCoreBridge()
        assertEquals(CoreAvailability.LAZY_NOT_PROBED, bridge.availability)

        val build = (bridge.buildInfo() as CoreResult.Success).value
        assertEquals(1U, build.coreApiVersion)
        // Runtime build info reports the live crate CORE_VERSION (vox-core
        // workspace version), not the synthetic fixture value used by
        // schema-validation fixtures.
        assertEquals("0.1.0-alpha.1", build.coreVersion)
        assertTrue(build.sourceRevision.matches(Regex("[0-9a-f]{40}")))
        assertTrue(build.toolchainManifestSha256.matches(Regex("[0-9a-f]{64}")))
        assertEquals(listOf("newNoteTextLink"), build.supportedOperations)
        assertEquals(listOf("apple-parity-v1"), build.supportedProfileIds)

        // Readiness is fail-closed against the runtime toolchain manifest
        // digest baked in by build.rs. The synthetic schema fixture carries a
        // zero digest, so it must be rejected on-target first, and only a
        // document carrying the runtime digest from buildInfo may pass.
        val expected = assets.open("valid-expected-versions.json").use { it.readBytes() }
        val synthetic = (bridge.readiness(expected) as CoreResult.Success).value
        assertEquals("incompatible", synthetic.status)
        assertFalse(synthetic.sessionPermitted)
        assertEquals(listOf("toolchainManifestMismatch"), synthetic.mismatchCodes)

        val runtimeConsistent = expected.toString(StandardCharsets.UTF_8)
            .replace("0000000000000000000000000000000000000000000000000000000000000000", build.toolchainManifestSha256)
            .toByteArray(StandardCharsets.UTF_8)
        val readiness = (bridge.readiness(runtimeConsistent) as CoreResult.Success).value
        assertEquals("ready", readiness.status)
        assertTrue(readiness.sessionPermitted)
        assertTrue(readiness.mismatchCodes.isEmpty())

        val request = assets.open("valid-android-m3-text-link.json").use { it.readBytes() }
        val prepared = (bridge.prepare(request) as CoreResult.Success).value
        val text = prepared.toString(StandardCharsets.UTF_8)
        // prepare returns the canonical RequiredObservations control document,
        // not rendered markdown; markdown exists only after a materialization
        // session seals and drains an artifact.
        assertTrue(prepared.size in 1..1_048_576)
        assertTrue(text.endsWith("\n"))
        assertTrue(text.contains("\"requestID\": \"11111111-1111-4111-8111-111111111111\""))
        assertTrue(text.contains("\"candidateOccupancy\""))
        assertTrue(text.contains("\"preparationRevision\": 1"))
        assertTrue(text.contains("\"snapshotHash\": \""))
        // Preparation output must stay content-free: request payload text,
        // link labels, and URLs must never be echoed by the core.
        assertFalse(text.contains("Synthetic"))
        assertFalse(text.contains("https://example.invalid/synthetic"))
        assertEquals(CoreAvailability.AVAILABLE, bridge.availability)
    }
}
