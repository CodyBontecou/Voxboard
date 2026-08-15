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
        assertEquals("0.1.0-m2-foundation", build.coreVersion)
        assertTrue(build.sourceRevision.matches(Regex("[0-9a-f]{40}")))
        assertTrue(build.toolchainManifestSha256.matches(Regex("[0-9a-f]{64}")))
        assertEquals(listOf("newNoteTextLink"), build.supportedOperations)
        assertEquals(listOf("apple-parity-v1"), build.supportedProfileIds)

        val expected = assets.open("valid-expected-versions.json").use { it.readBytes() }
        val readiness = (bridge.readiness(expected) as CoreResult.Success).value
        assertEquals("ready", readiness.status)
        assertTrue(readiness.sessionPermitted)
        assertTrue(readiness.mismatchCodes.isEmpty())

        val request = assets.open("valid-android-m3-text-link.json").use { it.readBytes() }
        val prepared = (bridge.prepare(request) as CoreResult.Success).value
        val text = prepared.toString(StandardCharsets.UTF_8)
        assertTrue(prepared.size in 1..1_048_576)
        assertTrue(text.endsWith("\n"))
        assertTrue(text.contains("11111111-1111-4111-8111-111111111111"))
        assertTrue(text.contains("swift-legacy-m0"))
        assertFalse(text.contains("https://example.invalid/synthetic"))
        assertEquals(CoreAvailability.AVAILABLE, bridge.availability)
    }
}
