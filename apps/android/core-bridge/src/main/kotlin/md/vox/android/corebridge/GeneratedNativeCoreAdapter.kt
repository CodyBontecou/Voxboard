package md.vox.android.corebridge

import java.nio.ByteBuffer
import md.vox.core.CoreMaterializationSession as GeneratedSession
import md.vox.core.VoxCoreException
import md.vox.core.coreBuildInfo
import md.vox.core.corePrepare
import md.vox.core.coreReadiness
import md.vox.core.coreStartMaterialization

/** The only production adapter. It delegates directly to the committed generated binding. */
internal class GeneratedNativeCoreAdapter : NativeCoreAdapter {
    override fun buildInfo(): CoreBuildInfo = generatedCall {
        coreBuildInfo().let {
            CoreBuildInfo(
                it.coreApiVersion,
                it.coreVersion,
                it.sourceRevision,
                it.buildConfiguration,
                it.toolchainManifestSha256,
                it.supportedOperations.toList(),
                it.supportedProfileIds.toList(),
            )
        }
    }

    override fun readiness(bytes: ByteArray): CoreReadiness = generatedCall {
        withOwnedDirectBytes(bytes) { coreReadiness(it) }.let {
            CoreReadiness(it.status, it.sessionPermitted, it.mismatchCodes.toList())
        }
    }

    override fun prepare(bytes: ByteArray): ByteArray = generatedCall {
        withOwnedDirectBytes(bytes) { corePrepare(it) }.copyOf()
    }

    override fun startMaterialization(bytes: ByteArray): NativeCoreSession = generatedCall {
        GeneratedNativeCoreSession(withOwnedDirectBytes(bytes) { coreStartMaterialization(it) })
    }
}

private class GeneratedNativeCoreSession(private val generated: GeneratedSession) : NativeCoreSession {
    override fun pushObservation(streamId: String, sequence: UInt, bytes: ByteArray, eof: Boolean) = generatedCall {
        withOwnedDirectBytes(bytes) { generated.pushObservation(streamId, sequence, it, eof) }
    }

    override fun seal(): List<CoreArtifactDescriptor> = generatedCall {
        generated.seal().artifacts.map {
            CoreArtifactDescriptor(
                it.artifactId,
                it.operationId,
                it.streamId,
                it.commitSequence,
                it.kind,
                it.mediaType,
                it.length,
                it.resultSha256,
                it.receiptKind,
            )
        }
    }

    override fun drain(artifactId: String, sequence: UInt, maximumBytes: ULong): CorePreparedChunk = generatedCall {
        generated.drain(artifactId, sequence, maximumBytes).let {
            CorePreparedChunk(
                it.artifactId,
                it.streamId,
                it.sequence,
                it.bytes.copyOf(),
                it.byteCount,
                it.chunkSha256,
                it.eof,
            )
        }
    }

    override fun finalize(bytes: ByteArray): ByteArray = generatedCall {
        withOwnedDirectBytes(bytes) { generated.finalize(it) }.copyOf()
    }

    override fun cancel() = generated.cancel()

    override fun close() = generated.close()
}

internal inline fun <T> withOwnedDirectBytes(bytes: ByteArray, block: (ByteBuffer) -> T): T {
    val direct = ByteBuffer.allocateDirect(bytes.size)
    direct.put(bytes)
    direct.flip()
    return try {
        block(direct)
    } finally {
        direct.clear()
        while (direct.hasRemaining()) direct.put(0)
        bytes.fill(0)
    }
}

private inline fun <T> generatedCall(block: () -> T): T = try {
    block()
} catch (error: VoxCoreException) {
    throw NativeCoreFailure(
        when (error) {
            is VoxCoreException.ControlTooLarge -> CoreErrorCode.CONTROL_TOO_LARGE
            is VoxCoreException.InvalidControl -> CoreErrorCode.INVALID_CONTROL
            is VoxCoreException.StringTooLarge -> CoreErrorCode.STRING_TOO_LARGE
            is VoxCoreException.ArrayTooLarge -> CoreErrorCode.ARRAY_TOO_LARGE
            is VoxCoreException.IntegerOutOfRange -> CoreErrorCode.INTEGER_OUT_OF_RANGE
            is VoxCoreException.UnknownField -> CoreErrorCode.UNKNOWN_FIELD
            is VoxCoreException.NonCanonicalControl -> CoreErrorCode.NON_CANONICAL_CONTROL
            is VoxCoreException.Unsupported -> CoreErrorCode.UNSUPPORTED
            is VoxCoreException.Correlation -> CoreErrorCode.CORRELATION
            is VoxCoreException.InvalidObservation -> CoreErrorCode.INVALID_OBSERVATION
            is VoxCoreException.LimitExceeded -> CoreErrorCode.LIMIT_EXCEEDED
            is VoxCoreException.VerificationFailed -> CoreErrorCode.VERIFICATION_FAILED
            is VoxCoreException.SessionTerminal -> CoreErrorCode.SESSION_TERMINAL
            is VoxCoreException.Cancelled -> CoreErrorCode.CANCELLED
            is VoxCoreException.InternalPanic -> CoreErrorCode.INTERNAL_FAILURE
        },
    )
}
