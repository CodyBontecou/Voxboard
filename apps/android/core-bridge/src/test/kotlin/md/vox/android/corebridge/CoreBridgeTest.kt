package md.vox.android.corebridge

import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreBridgeTest {
    @Test
    fun generatedByteBorrowUsesOwnedDirectMemoryAndClearsIt() {
        val source = byteArrayOf(1, 2, 3)
        var borrowed = byteArrayOf()
        var retainedDirect: java.nio.ByteBuffer? = null

        withOwnedDirectBytes(source) { direct ->
            assertTrue(direct.isDirect)
            retainedDirect = direct
            borrowed = ByteArray(direct.remaining()).also { direct.get(it) }
        }

        assertArrayEquals(byteArrayOf(1, 2, 3), borrowed)
        assertArrayEquals(byteArrayOf(0, 0, 0), source)
        val cleared = retainedDirect!!.duplicate().apply { rewind() }
        assertArrayEquals(byteArrayOf(0, 0, 0), ByteArray(cleared.remaining()).also { cleared.get(it) })
    }

    @Test
    fun constructionIsLazyAndFirstCallLoadsOnce() {
        val creations = AtomicInteger()
        val bridge = LazyCoreBridge { creations.incrementAndGet(); FakeAdapter() }

        assertEquals(CoreAvailability.LAZY_NOT_PROBED, bridge.availability)
        assertEquals(0, creations.get())
        assertTrue(bridge.buildInfo() is CoreResult.Success)
        assertTrue(bridge.buildInfo() is CoreResult.Success)
        assertEquals(1, creations.get())
        assertEquals(CoreAvailability.AVAILABLE, bridge.availability)
    }

    @Test
    fun boundedInputFailsBeforeNativeLoading() {
        val bridge = LazyCoreBridge { error("must remain lazy") }
        assertEquals(CoreResult.Failure(CoreErrorCode.CONTROL_TOO_LARGE), bridge.prepare(ByteArray(0)))
        assertEquals(
            CoreResult.Failure(CoreErrorCode.CONTROL_TOO_LARGE),
            bridge.readiness(ByteArray(1_048_577)),
        )
        assertEquals(CoreAvailability.LAZY_NOT_PROBED, bridge.availability)
    }

    @Test
    fun nativeErrorsAreContentFreeAndAvailabilityFailsClosed() {
        val bridge = LazyCoreBridge { throw UnsatisfiedLinkError("sensitive loader path") }
        assertEquals(CoreResult.Failure(CoreErrorCode.NATIVE_UNAVAILABLE), bridge.buildInfo())
        assertEquals(CoreAvailability.UNAVAILABLE, bridge.availability)

        val invalid = LazyCoreBridge { FakeAdapter(failure = CoreErrorCode.NON_CANONICAL_CONTROL) }
        assertEquals(CoreResult.Failure(CoreErrorCode.NON_CANONICAL_CONTROL), invalid.prepare(byteArrayOf(1)))
        assertEquals(CoreAvailability.AVAILABLE, invalid.availability)

        val incompatible = LazyCoreBridge { throw IllegalStateException("sensitive binding failure") }
        assertEquals(CoreResult.Failure(CoreErrorCode.NATIVE_UNAVAILABLE), incompatible.buildInfo())
        assertEquals(CoreAvailability.UNAVAILABLE, incompatible.availability)
    }

    @Test
    fun ownedValuesAreCopiedAcrossBoundary() {
        val bytes = byteArrayOf(1, 2, 3)
        val adapter = FakeAdapter(prepared = bytes)
        val bridge = LazyCoreBridge { adapter }
        val input = byteArrayOf(4)
        val result = bridge.prepare(input) as CoreResult.Success
        input[0] = 9
        bytes[0] = 9
        assertArrayEquals(byteArrayOf(1, 2, 3), result.value)
        assertArrayEquals(byteArrayOf(4), adapter.lastInput)
    }

    @Test
    fun cancelAndFinalizeReleaseSessionExactlyOnce() {
        val firstNative = FakeSession()
        val bridge = LazyCoreBridge { FakeAdapter(session = firstNative) }
        val first = (bridge.startMaterialization(byteArrayOf(1)) as CoreResult.Success).value
        assertEquals(CoreResult.Success(Unit), first.cancel())
        assertEquals(1, firstNative.cancelCount)
        assertEquals(1, firstNative.closeCount)
        assertEquals(CoreResult.Failure(CoreErrorCode.RELEASED), first.seal())
        first.close()
        assertEquals(1, firstNative.closeCount)

        val secondNative = FakeSession()
        val secondBridge = LazyCoreBridge { FakeAdapter(session = secondNative) }
        val second = (secondBridge.startMaterialization(byteArrayOf(1)) as CoreResult.Success).value
        assertTrue(second.finalize(byteArrayOf(1)) is CoreResult.Success)
        assertEquals(1, secondNative.closeCount)
        assertEquals(CoreResult.Failure(CoreErrorCode.RELEASED), second.cancel())
    }

    @Test
    fun explicitCloseCancelsAndReleasesExactlyOnce() {
        val native = FakeSession()
        val bridge = LazyCoreBridge { FakeAdapter(session = native) }
        val session = (bridge.startMaterialization(byteArrayOf(1)) as CoreResult.Success).value
        session.close()
        session.close()
        assertEquals(1, native.cancelCount)
        assertEquals(1, native.closeCount)
        assertEquals(CoreResult.Failure(CoreErrorCode.RELEASED), session.seal())
    }

    @Test
    fun localSessionBoundFailureIsTerminalAndReleasesContent() {
        val native = FakeSession()
        val bridge = LazyCoreBridge { FakeAdapter(session = native) }
        val session = (bridge.startMaterialization(byteArrayOf(1)) as CoreResult.Success).value

        assertEquals(
            CoreResult.Failure(CoreErrorCode.LIMIT_EXCEEDED),
            session.pushObservation("stream", 0U, ByteArray(1_048_577), eof = false),
        )
        assertEquals(1, native.cancelCount)
        assertEquals(1, native.closeCount)
        assertEquals(CoreResult.Failure(CoreErrorCode.RELEASED), session.seal())
    }

    @Test
    fun nativeSessionFailureReleasesAndReturnsOnlyCode() {
        val native = FakeSession(failure = CoreErrorCode.VERIFICATION_FAILED)
        val bridge = LazyCoreBridge { FakeAdapter(session = native) }
        val session = (bridge.startMaterialization(byteArrayOf(1)) as CoreResult.Success).value
        assertEquals(CoreResult.Failure(CoreErrorCode.VERIFICATION_FAILED), session.seal())
        assertEquals(1, native.closeCount)
        assertEquals(1, native.cancelCount)
    }
}

private class FakeAdapter(
    private val failure: CoreErrorCode? = null,
    private val prepared: ByteArray = byteArrayOf(1, 2, 3),
    private val session: FakeSession = FakeSession(),
) : NativeCoreAdapter {
    var lastInput = byteArrayOf()

    private fun fail() { failure?.let { throw NativeCoreFailure(it) } }

    override fun buildInfo(): CoreBuildInfo {
        fail()
        return CoreBuildInfo(1U, "core", "0".repeat(40), "debug", "0".repeat(64), listOf("op"), listOf("profile"))
    }

    override fun readiness(bytes: ByteArray): CoreReadiness {
        fail()
        return CoreReadiness("ready", true, emptyList())
    }

    override fun prepare(bytes: ByteArray): ByteArray {
        fail()
        lastInput = bytes
        return prepared
    }

    override fun startMaterialization(bytes: ByteArray): NativeCoreSession {
        fail()
        return session
    }
}

private class FakeSession(private val failure: CoreErrorCode? = null) : NativeCoreSession {
    var cancelCount = 0
    var closeCount = 0
    private fun fail() { failure?.let { throw NativeCoreFailure(it) } }
    override fun pushObservation(streamId: String, sequence: UInt, bytes: ByteArray, eof: Boolean) = fail()
    override fun seal(): List<CoreArtifactDescriptor> { fail(); return emptyList() }
    override fun drain(artifactId: String, sequence: UInt, maximumBytes: ULong): CorePreparedChunk {
        fail(); return CorePreparedChunk(artifactId, "stream", sequence, byteArrayOf(1), 1UL, "0".repeat(64), true)
    }
    override fun finalize(bytes: ByteArray): ByteArray { fail(); return bytes.copyOf() }
    override fun cancel() { cancelCount += 1; fail() }
    override fun close() { closeCount += 1 }
}
