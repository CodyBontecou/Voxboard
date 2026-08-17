package md.vox.android.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import md.vox.android.capturedomain.*
import md.vox.android.corebridge.*
import java.nio.charset.StandardCharsets
import java.util.UUID

/**
 * ADR-0023 §2: the only production composer of the materialization control document and
 * the only driver of prepare → startMaterialization → seal → drain → finalize into the
 * durable package. Runs as the fenced lease holder; every journal append routes through
 * the revision-CAS coordinator path. No Kotlin rendering fallback exists anywhere.
 *
 * Prepared artifacts are drained into a same-parent staging directory and promoted into
 * the plan-hash-named append-only directory only after finalize returns the plan, so
 * note.bin is written once at its final governed name (ADR-0018 layout).
 */
internal class CoreMaterializationCoordinator(
    private val bridge: CoreBridge,
    private val store: DurableCapturePackageStore,
    private val coordinator: CaptureDurabilityCoordinator,
    private val occupancy: CandidateOccupancySource,
    private val destination: VaultDestination,
    private val clock: () -> Long,
) {
    /** Bounded, content-free result taxonomy for the materialization stage. */
    sealed interface MaterializationResult {
        /** Prepared artifacts persisted and hash-verified; journal now at MATERIALIZED. */
        data class Materialized(val planHash: String, val projection: CaptureIndexProjection) : MaterializationResult

        /** Coarse retryable failure; no MATERIALIZED event was appended. */
        data class Retryable(val coarseCode: String) : MaterializationResult

        /** Lease was lost or the frontier moved; the caller re-reads and re-drives. */
        data object LeaseLost : MaterializationResult
    }

    /**
     * Live native occupancy observation: reports which candidate logical paths already
     * exist under the planned destination folder. Returns null on observation failure.
     */
    interface CandidateOccupancySource {
        fun observeOccupiedCandidates(destination: VaultDestination, candidates: List<List<String>>): List<List<String>>?
    }

    fun materialize(requestID: String, leaseToken: String, expectedRevision: Int): MaterializationResult {
        val requestBytes = store.loadRequestBytes(requestID) ?: return MaterializationResult.Retryable("packageMissing")
        val snapshot = store.loadJournal(requestID) ?: return MaterializationResult.Retryable("packageMissing")
        if (snapshot.revision != expectedRevision || snapshot.state != CaptureState.PREPARING) {
            return MaterializationResult.Retryable("frontierMismatch")
        }

        // 1. Bridge prepare over the exact durable request bytes.
        val requiredBytes = when (val prepared = bridge.prepare(requestBytes)) {
            is CoreResult.Success -> prepared.value
            is CoreResult.Failure -> return MaterializationResult.Retryable(coarse(prepared.code))
        }
        val required = try {
            CapturePackageCodec.parseCanonical(requiredBytes)
        } catch (_: PackageCodecException) { return MaterializationResult.Retryable("requiredObservationsDecode") }
        val snapshotHash = required.stringField("snapshotHash") ?: return MaterializationResult.Retryable("requiredObservationsDecode")

        // 2. Freeze the observation snapshot for this attempt (ADR-0018 layout).
        val attempt = ObservationAttempt(requestID, snapshot.revision)
        try {
            store.persistObservationSnapshot(requestID, attempt, requiredBytes)
        } catch (_: Exception) { return MaterializationResult.Retryable("observationPersist") }

        // 3. Compose the canonical control: bridge observations + native candidate occupancy.
        val controlBytes = try {
            composeControl(requestBytes, required, snapshotHash)
        } catch (failure: ControlCompositionFailure) {
            return MaterializationResult.Retryable(failure.coarseCode)
        }

        // 4. Drive the bounded session; staged drain, then verified promotion.
        val planHash = when (val driven = driveSession(requestID, controlBytes)) {
            is SessionDriveResult.Done -> driven.planHash
            is SessionDriveResult.Retryable -> return MaterializationResult.Retryable(driven.coarseCode)
        }

        // 5. Append MATERIALIZED with the authoritative plan hash through revision-CAS.
        val event = JournalEvent(
            revision = snapshot.revision + 1,
            fromState = CaptureState.PREPARING,
            state = CaptureState.MATERIALIZED,
            code = JournalCode.MATERIALIZED,
            occurredAtEpochMillis = clock(),
            planHash = planHash,
        )
        val command = JournalMutationCommand(requestID, snapshot.revision, event, leaseToken)
        return when (val mutation = coordinator.mutate(command, clock())) {
            is JournalMutationResult.Applied -> MaterializationResult.Materialized(planHash, mutation.projection)
            is JournalMutationResult.AlreadyApplied -> MaterializationResult.Materialized(planHash, mutation.projection)
            JournalMutationResult.LeaseLost -> MaterializationResult.LeaseLost
            is JournalMutationResult.FrontierConflict -> MaterializationResult.LeaseLost
            is JournalMutationResult.ReducerRejected -> MaterializationResult.Retryable(mutation.coarseCode)
            is JournalMutationResult.CoordinationFailure -> MaterializationResult.Retryable(mutation.coarseCode)
            is JournalMutationResult.DurabilityUncertain -> MaterializationResult.Retryable(mutation.coarseCode)
            is JournalMutationResult.PersistedIndexPending -> MaterializationResult.Materialized(planHash, mutation.projection)
            is JournalMutationResult.PackageCorrupt -> MaterializationResult.Retryable(mutation.coarseCode)
        }
    }

    private class ControlCompositionFailure(val coarseCode: String) : IllegalStateException()

    /** Builds the exact materialization control the core accepts: request fields + frozen observations + session limits. */
    private fun composeControl(requestBytes: ByteArray, required: JsonObject, snapshotHash: String): ByteArray {
        val request = CapturePackageCodec.parseCanonical(requestBytes)
        val requiredObservations = (required["observations"] as? JsonArray) ?: throw ControlCompositionFailure("requiredObservationsDecode")

        val observationJson = JsonArray(
            requiredObservations.map { element ->
                val obs = (element as? JsonObject) ?: throw ControlCompositionFailure("requiredObservationsDecode")
                when (obs["kind"]?.let { (it as? JsonPrimitive)?.content }) {
                    "candidateOccupancy" -> candidateOccupancyObservation(obs)
                    "frozenTemplate" -> frozenTemplateObservation(obs)
                    else -> throw ControlCompositionFailure("unsupportedObservationKind")
                }
            },
        )

        val control = buildJsonObject {
            for ((key, value) in request) put(key, value)
            put("controlByteCount", 1_048_576L)
            put("observations", observationJson)
            put("preparationRevision", 1L)
            put("session", buildJsonObject {
                put("inputOrdering", "observation-list-then-sequence")
                put("maximumAggregateObservationBytes", 268_435_456L)
                put("maximumChunkBytes", 1_048_576L)
                put("singleFinalize", true)
                put("singleSeal", true)
            })
            put("snapshotHash", snapshotHash)
        }
        return CapturePackageCodec.canonical(control)
    }

    private fun candidateOccupancyObservation(required: JsonObject): kotlinx.serialization.json.JsonElement {
        val observationID = required.stringField("id") ?: throw ControlCompositionFailure("observationID")
        val candidates = (required["logicalCandidates"] as? JsonArray)
            ?.mapNotNull { (it as? JsonArray)?.map { segment -> (segment as? JsonPrimitive)?.content ?: throw ControlCompositionFailure("candidateSegments") } }
            ?: throw ControlCompositionFailure("logicalCandidates")
        val occupied = occupancy.observeOccupiedCandidates(destination, candidates)
            ?: throw ControlCompositionFailure("occupancyObservation")
        if (occupied.size > 256) throw ControlCompositionFailure("occupancyBounds")
        val occupiedSorted = occupied.distinct().sortedBy { it.joinToString("\u0000") }
        val orderedSetHash = CapturePackageCodec.sha256(
            CapturePackageCodec.canonical(JsonArray(occupiedSorted.map { path -> JsonArray(path.map { JsonPrimitive(it) }) })),
        )
        return buildJsonObject {
            put("kind", "candidateOccupancy")
            put("observationID", observationID)
            put("status", "present")
            put("logicalPaths", JsonArray(occupiedSorted.map { path -> JsonArray(path.map { JsonPrimitive(it) }) }))
            put("orderedSetHash", orderedSetHash)
        }
    }

    private fun frozenTemplateObservation(required: JsonObject): kotlinx.serialization.json.JsonElement {
        // M3 profile pins templatePolicy none; an absent template requires no stream push.
        val observationID = required.stringField("id") ?: throw ControlCompositionFailure("observationID")
        return buildJsonObject {
            put("kind", "frozenTemplate")
            put("observationID", observationID)
            put("status", "absent")
            put("length", 0L)
            put("sha256", CapturePackageCodec.sha256(ByteArray(0)))
            put("byteStreamID", JsonNull)
        }
    }

    private sealed interface SessionDriveResult {
        data class Done(val planHash: String) : SessionDriveResult
        data class Retryable(val coarseCode: String) : SessionDriveResult
    }

    private fun driveSession(requestID: String, controlBytes: ByteArray): SessionDriveResult {
        if (controlBytes.isEmpty() || controlBytes.size > CONTROL_LIMIT_BYTES) return SessionDriveResult.Retryable("controlBounds")
        val stagingUUID = UUID.randomUUID().toString()
        val started = bridge.startMaterialization(controlBytes)
        val session = when (started) {
            is CoreResult.Success -> started.value
            is CoreResult.Failure -> return SessionDriveResult.Retryable(coarse(started.code))
        }
        var finalized: ByteArray? = null
        try {
            val descriptors = when (val sealed = session.seal()) {
                is CoreResult.Success -> sealed.value
                is CoreResult.Failure -> return SessionDriveResult.Retryable(coarse(sealed.code))
            }
            if (descriptors.size != 1) return SessionDriveResult.Retryable("descriptorInventory")
            val note = descriptors.first()
            if (note.kind != "note") return SessionDriveResult.Retryable("noteDescriptorMissing")

            // Staged drain with per-chunk hash verification before each next drain.
            val sink = try {
                store.openStagedNoteSink(requestID, stagingUUID, note.length.toLong(), note.resultSha256)
            } catch (_: Exception) { return SessionDriveResult.Retryable("preparedSink") }
            val drained = try {
                drainAll(session, note, sink)
            } catch (failure: DrainFailure) {
                return SessionDriveResult.Retryable(failure.coarseCode)
            }

            val drainedControl = canonicalDrainedHashes(requestID, note)
            finalized = when (val result = session.finalize(drainedControl)) {
                is CoreResult.Success -> result.value
                is CoreResult.Failure -> return SessionDriveResult.Retryable(coarse(result.code))
            }
        } finally {
            session.close()
        }

        val planBytes = finalized ?: return SessionDriveResult.Retryable("sessionState")
        val planHash = verifyPlan(planBytes) ?: return SessionDriveResult.Retryable("planVerification")
        try {
            store.promotePreparedArtifacts(requestID, planHash, planBytes, stagingUUID)
        } catch (_: Exception) { return SessionDriveResult.Retryable("planPromotion") }
        return SessionDriveResult.Done(planHash)
    }

    private class DrainFailure(val coarseCode: String) : IllegalStateException()

    private fun drainAll(session: CoreMaterializationSession, note: CoreArtifactDescriptor, sink: StagedNoteSink) {
        var sequence = 0U
        while (true) {
            val chunk = when (val drained = session.drain(note.artifactId, sequence, 1_048_576UL)) {
                is CoreResult.Success -> drained.value
                is CoreResult.Failure -> throw DrainFailure(coarse(drained.code))
            }
            sink.write(chunk.bytes)
            if (chunk.eof) break
            sequence++
        }
        sink.verifyAndClose()
    }

    /** Canonical drainedArtifactHashes control for finalize (single M3 note artifact). */
    private fun canonicalDrainedHashes(requestID: String, note: CoreArtifactDescriptor): ByteArray =
        CapturePackageCodec.canonical(
            buildJsonObject {
                put("kind", "drainedArtifactHashes")
                put("requestID", requestID)
                put("artifacts", JsonArray(listOf(buildJsonObject {
                    put("artifactID", note.artifactId)
                    put("streamID", note.streamId)
                    put("length", note.length.toLong())
                    put("resultSHA256", note.resultSha256)
                })))
            },
        )

    /** Delegates to the shared artifact-plan/v1 verifier (hash + deterministic IDs). */
    fun verifyPlan(planBytes: ByteArray): String? = PreparedPlanVerifier.verifiedPlanHash(planBytes)

    private fun coarse(code: CoreErrorCode): String = code.name.lowercase().replace(Regex("_([a-z])")) { it.groupValues[1].uppercase() }

    private companion object {
        val SHA_PATTERN_64 = Regex("^[0-9a-f]{64}$")
        const val MAX_CHUNK_CONTROL_BYTES = 1_048_576UL
    }
}

private fun JsonObject.stringField(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
