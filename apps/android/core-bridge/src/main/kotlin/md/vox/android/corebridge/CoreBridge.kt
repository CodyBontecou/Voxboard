package md.vox.android.corebridge

import java.util.concurrent.atomic.AtomicBoolean

private const val MAX_CONTROL_BYTES = 1_048_576
private const val MAX_STREAM_ID_BYTES = 256
private const val MAX_CHUNK_BYTES = 1_048_576UL

/**
 * Owned-value Android boundary around the generated UniFFI API.
 *
 * This API exposes no JNA/UniFFI objects, native handles, paths, persistence, callbacks, or
 * side-effect authority. Callers must still perform native durability, quota, and delivery work.
 */
interface CoreBridge {
    val availability: CoreAvailability
    fun buildInfo(): CoreResult<CoreBuildInfo>
    fun readiness(expectedVersionsJson: ByteArray): CoreResult<CoreReadiness>
    fun prepare(preparationJson: ByteArray): CoreResult<ByteArray>
    fun startMaterialization(controlJson: ByteArray): CoreResult<CoreMaterializationSession>
}

enum class CoreAvailability {
    NOT_WIRED,
    LAZY_NOT_PROBED,
    AVAILABLE,
    UNAVAILABLE,
}

enum class CoreErrorCode {
    CONTROL_TOO_LARGE,
    INVALID_CONTROL,
    STRING_TOO_LARGE,
    ARRAY_TOO_LARGE,
    INTEGER_OUT_OF_RANGE,
    UNKNOWN_FIELD,
    NON_CANONICAL_CONTROL,
    UNSUPPORTED,
    CORRELATION,
    INVALID_OBSERVATION,
    LIMIT_EXCEEDED,
    VERIFICATION_FAILED,
    SESSION_TERMINAL,
    CANCELLED,
    INTERNAL_FAILURE,
    NATIVE_UNAVAILABLE,
    RELEASED,
}

sealed interface CoreResult<out T> {
    data class Success<T>(val value: T) : CoreResult<T>
    data class Failure(val code: CoreErrorCode) : CoreResult<Nothing>
}

data class CoreBuildInfo(
    val coreApiVersion: UInt,
    val coreVersion: String,
    val sourceRevision: String,
    val buildConfiguration: String,
    val toolchainManifestSha256: String,
    val supportedOperations: List<String>,
    val supportedProfileIds: List<String>,
)

data class CoreReadiness(
    val status: String,
    val sessionPermitted: Boolean,
    val mismatchCodes: List<String>,
)

data class CoreArtifactDescriptor(
    val artifactId: String,
    val operationId: String,
    val streamId: String,
    val commitSequence: UInt,
    val kind: String,
    val mediaType: String,
    val length: ULong,
    val resultSha256: String,
    val receiptKind: String,
)

data class CorePreparedChunk(
    val artifactId: String,
    val streamId: String,
    val sequence: UInt,
    val bytes: ByteArray,
    val byteCount: ULong,
    val chunkSha256: String,
    val eof: Boolean,
) {
    override fun equals(other: Any?): Boolean =
        other is CorePreparedChunk &&
            artifactId == other.artifactId && streamId == other.streamId &&
            sequence == other.sequence && bytes.contentEquals(other.bytes) &&
            byteCount == other.byteCount && chunkSha256 == other.chunkSha256 && eof == other.eof

    override fun hashCode(): Int = 31 * artifactId.hashCode() + bytes.contentHashCode()
}

interface CoreMaterializationSession : AutoCloseable {
    fun pushObservation(streamId: String, sequence: UInt, bytes: ByteArray, eof: Boolean): CoreResult<Unit>
    fun seal(): CoreResult<List<CoreArtifactDescriptor>>
    fun drain(artifactId: String, sequence: UInt, maximumBytes: ULong): CoreResult<CorePreparedChunk>
    fun finalize(drainedHashesJson: ByteArray): CoreResult<ByteArray>
    fun cancel(): CoreResult<Unit>
    override fun close()
}

/** Factory construction does not touch JNA or load a native library. */
fun productionCoreBridge(): CoreBridge = LazyCoreBridge { GeneratedNativeCoreAdapter() }

/** Explicit no-authority composition used until a later phase wires the production bridge. */
fun unwiredCoreBridge(): CoreBridge = object : CoreBridge {
    override val availability = CoreAvailability.NOT_WIRED
    override fun buildInfo(): CoreResult<CoreBuildInfo> = CoreResult.Failure(CoreErrorCode.UNSUPPORTED)
    override fun readiness(expectedVersionsJson: ByteArray): CoreResult<CoreReadiness> = CoreResult.Failure(CoreErrorCode.UNSUPPORTED)
    override fun prepare(preparationJson: ByteArray): CoreResult<ByteArray> = CoreResult.Failure(CoreErrorCode.UNSUPPORTED)
    override fun startMaterialization(controlJson: ByteArray): CoreResult<CoreMaterializationSession> = CoreResult.Failure(CoreErrorCode.UNSUPPORTED)
}

internal interface NativeCoreAdapter {
    fun buildInfo(): CoreBuildInfo
    fun readiness(bytes: ByteArray): CoreReadiness
    fun prepare(bytes: ByteArray): ByteArray
    fun startMaterialization(bytes: ByteArray): NativeCoreSession
}

internal interface NativeCoreSession : AutoCloseable {
    fun pushObservation(streamId: String, sequence: UInt, bytes: ByteArray, eof: Boolean)
    fun seal(): List<CoreArtifactDescriptor>
    fun drain(artifactId: String, sequence: UInt, maximumBytes: ULong): CorePreparedChunk
    fun finalize(bytes: ByteArray): ByteArray
    fun cancel()
}

internal class NativeCoreFailure(val code: CoreErrorCode) : RuntimeException()

internal class LazyCoreBridge(
    private val adapterFactory: () -> NativeCoreAdapter,
) : CoreBridge {
    @Volatile private var status = CoreAvailability.LAZY_NOT_PROBED
    @Volatile private var adapter: NativeCoreAdapter? = null

    override val availability: CoreAvailability get() = status

    private fun native(): NativeCoreAdapter = adapter ?: synchronized(this) {
        adapter ?: adapterFactory().also { adapter = it }
    }

    private fun <T> invoke(block: NativeCoreAdapter.() -> T): CoreResult<T> = try {
        CoreResult.Success(native().block()).also { status = CoreAvailability.AVAILABLE }
    } catch (error: NativeCoreFailure) {
        status = if (error.code == CoreErrorCode.NATIVE_UNAVAILABLE) {
            CoreAvailability.UNAVAILABLE
        } else {
            // A typed core error proves that the generated binding reached native code.
            CoreAvailability.AVAILABLE
        }
        CoreResult.Failure(error.code)
    } catch (_: LinkageError) {
        status = CoreAvailability.UNAVAILABLE
        CoreResult.Failure(CoreErrorCode.NATIVE_UNAVAILABLE)
    } catch (_: Exception) {
        // Generated InternalException and other binding failures are compatibility failures,
        // not product errors; exception text never crosses the boundary.
        status = CoreAvailability.UNAVAILABLE
        CoreResult.Failure(CoreErrorCode.NATIVE_UNAVAILABLE)
    }

    override fun buildInfo(): CoreResult<CoreBuildInfo> = invoke { buildInfo() }

    override fun readiness(expectedVersionsJson: ByteArray): CoreResult<CoreReadiness> =
        boundedControl(expectedVersionsJson) ?: invoke { readiness(expectedVersionsJson.copyOf()) }

    override fun prepare(preparationJson: ByteArray): CoreResult<ByteArray> =
        boundedControl(preparationJson) ?: invoke { prepare(preparationJson.copyOf()).copyOf() }

    override fun startMaterialization(controlJson: ByteArray): CoreResult<CoreMaterializationSession> {
        boundedControl(controlJson)?.let { return it }
        return when (val result = invoke { startMaterialization(controlJson.copyOf()) }) {
            is CoreResult.Failure -> result
            is CoreResult.Success -> CoreResult.Success(OwnedCoreSession(result.value))
        }
    }

    private fun boundedControl(bytes: ByteArray): CoreResult.Failure? =
        if (bytes.isEmpty() || bytes.size > MAX_CONTROL_BYTES) CoreResult.Failure(CoreErrorCode.CONTROL_TOO_LARGE) else null
}

private class OwnedCoreSession(private val native: NativeCoreSession) : CoreMaterializationSession {
    private val released = AtomicBoolean(false)

    private fun <T> invoke(block: NativeCoreSession.() -> T): CoreResult<T> {
        if (released.get()) return CoreResult.Failure(CoreErrorCode.RELEASED)
        return try {
            CoreResult.Success(native.block())
        } catch (error: NativeCoreFailure) {
            releaseAfterFailure()
            CoreResult.Failure(error.code)
        } catch (_: LinkageError) {
            releaseAfterFailure()
            CoreResult.Failure(CoreErrorCode.NATIVE_UNAVAILABLE)
        } catch (_: Exception) {
            releaseAfterFailure()
            CoreResult.Failure(CoreErrorCode.INTERNAL_FAILURE)
        }
    }

    @Synchronized
    override fun pushObservation(streamId: String, sequence: UInt, bytes: ByteArray, eof: Boolean): CoreResult<Unit> {
        if (released.get()) return CoreResult.Failure(CoreErrorCode.RELEASED)
        if (streamId.toByteArray(Charsets.UTF_8).size > MAX_STREAM_ID_BYTES) return localFailure(CoreErrorCode.STRING_TOO_LARGE)
        if (bytes.size > MAX_CONTROL_BYTES) return localFailure(CoreErrorCode.LIMIT_EXCEEDED)
        return invoke { pushObservation(streamId, sequence, bytes.copyOf(), eof) }
    }

    @Synchronized
    override fun seal(): CoreResult<List<CoreArtifactDescriptor>> = invoke { seal().toList() }

    @Synchronized
    override fun drain(artifactId: String, sequence: UInt, maximumBytes: ULong): CoreResult<CorePreparedChunk> {
        if (released.get()) return CoreResult.Failure(CoreErrorCode.RELEASED)
        if (artifactId.toByteArray(Charsets.UTF_8).size > MAX_STREAM_ID_BYTES) return localFailure(CoreErrorCode.STRING_TOO_LARGE)
        if (maximumBytes == 0UL || maximumBytes > MAX_CHUNK_BYTES) return localFailure(CoreErrorCode.LIMIT_EXCEEDED)
        return invoke {
            drain(artifactId, sequence, maximumBytes).let { it.copy(bytes = it.bytes.copyOf()) }
        }
    }

    @Synchronized
    override fun finalize(drainedHashesJson: ByteArray): CoreResult<ByteArray> {
        if (released.get()) return CoreResult.Failure(CoreErrorCode.RELEASED)
        if (drainedHashesJson.isEmpty() || drainedHashesJson.size > MAX_CONTROL_BYTES) return localFailure(CoreErrorCode.CONTROL_TOO_LARGE)
        val result = invoke { finalize(drainedHashesJson.copyOf()).copyOf() }
        release()
        return result
    }

    @Synchronized
    override fun cancel(): CoreResult<Unit> {
        if (released.get()) return CoreResult.Failure(CoreErrorCode.RELEASED)
        return try {
            // Cancellation is a single native attempt. If it throws, close the handle without
            // issuing a second cancel call.
            native.cancel()
            release()
            CoreResult.Success(Unit)
        } catch (error: NativeCoreFailure) {
            releaseAfterFailureWithoutCancel()
            CoreResult.Failure(error.code)
        } catch (_: LinkageError) {
            releaseAfterFailureWithoutCancel()
            CoreResult.Failure(CoreErrorCode.NATIVE_UNAVAILABLE)
        } catch (_: Exception) {
            releaseAfterFailureWithoutCancel()
            CoreResult.Failure(CoreErrorCode.INTERNAL_FAILURE)
        }
    }

    @Synchronized
    override fun close() {
        if (released.compareAndSet(false, true)) {
            cleanup { native.cancel() }
            cleanup { native.close() }
        }
    }

    private fun <T> localFailure(code: CoreErrorCode): CoreResult<T> {
        releaseAfterFailure()
        return CoreResult.Failure(code)
    }

    private fun releaseAfterFailure() {
        if (released.compareAndSet(false, true)) {
            cleanup { native.cancel() }
            cleanup { native.close() }
        }
    }

    private fun releaseAfterFailureWithoutCancel() {
        if (released.compareAndSet(false, true)) cleanup { native.close() }
    }

    private fun release() {
        if (released.compareAndSet(false, true)) cleanup { native.close() }
    }

    private inline fun cleanup(block: () -> Unit) {
        try {
            block()
        } catch (_: LinkageError) {
            // Cleanup is terminal and error details must not cross the boundary.
        } catch (_: Exception) {
            // Cleanup is terminal and error details must not cross the boundary.
        }
    }
}
