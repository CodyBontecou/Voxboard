package md.vox.android.data

import kotlinx.serialization.json.*
import md.vox.android.capturedomain.*
import md.vox.android.corebridge.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * ADR-0023 §2: the coordinator composes the exact control the Rust core accepts (canonical
 * request + frozen observations + session limits), drives the bounded session, promotes
 * verified prepared artifacts, and appends MATERIALIZED under the lease. The fake bridge
 * parses the control like the core (strict keys, session limits, observation correlation)
 * and finalizes a real artifact-plan/v1 plan whose IDs the coordinator must re-verify.
 */
class CoreMaterializationCoordinatorTest {
    private val requestID = "11111111-1111-4111-8111-111111111111"
    private val leaseToken = "22222222-2222-4222-8222-222222222222"
    private val destination = VaultDestination("33333333-3333-4333-8333-333333333333", "content://test/tree")
    private val note = "# Synthetic capture text.\n".toByteArray()
    private val noteSha = CapturePackageCodec.sha256(note)

    @Test fun materializeComposesControlDrainsAndAppendsMaterIALIZED() {
        val base = Files.createTempDirectory("coordinator").toFile()
        val store = DurableCapturePackageStore(base, MemoryIndex(), JvmOps())
        val request = checkNotNull(javaClass.classLoader!!.getResourceAsStream("contracts/v1/fixtures/capture-preparation-input/valid-android-m3-text-link.json")).use { it.readBytes() }
        assertEquals(EnqueueResult.SavedLocally(requestID), store.enqueue(request, 10))
        val leases = MemoryLeases()
        val coordinator = CaptureDurabilityCoordinator(store, leases)
        coordinator.acquire(requestID, leaseToken, 20, 600_000)
        coordinator.mutate(JournalMutationCommand(requestID, store.loadJournal(requestID)!!.revision, JournalEvent(store.loadJournal(requestID)!!.revision + 1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), leaseToken), 20)

        val fake = FakeCoreBridge(request, note)
        val occupancy = object : CoreMaterializationCoordinator.CandidateOccupancySource {
            override fun observeOccupiedCandidates(destination: VaultDestination, candidates: List<List<String>>): List<List<String>> =
                candidates.filter { it.last() == "occupied.md" }
        }
        var time = 30L
        val underTest = CoreMaterializationCoordinator(fake, store, coordinator, occupancy, destination, clock = { time++ })

        val result = underTest.materialize(requestID, leaseToken, store.loadJournal(requestID)!!.revision)
        assertTrue("materialize failed: $result", result is CoreMaterializationCoordinator.MaterializationResult.Materialized)
        val planHash = (result as CoreMaterializationCoordinator.MaterializationResult.Materialized).planHash

        // The control the fake received must be the canonical core-accepted shape.
        fake.controlAssertions.forEach { assertion -> assertion() }
        assertEquals(CaptureState.MATERIALIZED, store.loadJournal(requestID)!!.state)
        assertEquals(planHash, store.loadJournal(requestID)!!.events.last().planHash)
        // Prepared artifacts promoted at the plan-hash name and verified.
        val artifacts = store.loadPreparedArtifacts(requestID, planHash)!!
        assertArrayEquals(note, artifacts.noteBytes)
        // Observation snapshot frozen for the attempt.
        assertTrue(File(base, "vox-captures/$requestID/observations/$requestID.1.json").isFile)
    }

    @Test fun occupancyFailureIsRetryableAndNeverAppendsMaterIALIZED() {
        val base = Files.createTempDirectory("coordinator-occ").toFile()
        val store = DurableCapturePackageStore(base, MemoryIndex(), JvmOps())
        val request = checkNotNull(javaClass.classLoader!!.getResourceAsStream("contracts/v1/fixtures/capture-preparation-input/valid-android-m3-text-link.json")).use { it.readBytes() }
        assertEquals(EnqueueResult.SavedLocally(requestID), store.enqueue(request, 10))
        val leases = MemoryLeases()
        val coordinator = CaptureDurabilityCoordinator(store, leases)
        coordinator.acquire(requestID, leaseToken, 20, 600_000)
        coordinator.mutate(JournalMutationCommand(requestID, store.loadJournal(requestID)!!.revision, JournalEvent(store.loadJournal(requestID)!!.revision + 1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), leaseToken), 20)

        var time = 30L
        val underTest = CoreMaterializationCoordinator(
            FakeCoreBridge(request, note), store, coordinator,
            object : CoreMaterializationCoordinator.CandidateOccupancySource {
                override fun observeOccupiedCandidates(destination: VaultDestination, candidates: List<List<String>>): List<List<String>>? = null
            }, destination,
        ) { time++ }
        val result = underTest.materialize(requestID, leaseToken, store.loadJournal(requestID)!!.revision)
        assertTrue(result is CoreMaterializationCoordinator.MaterializationResult.Retryable)
        assertEquals(CaptureState.PREPARING, store.loadJournal(requestID)!!.state)
    }

    /** Fake bridge that parses the control exactly like the Rust core's strict decoder. */
    private class FakeCoreBridge(private val requestBytes: ByteArray, private val noteBytes: ByteArray) : CoreBridge {
        override val availability = CoreAvailability.AVAILABLE
        val controlAssertions = mutableListOf<() -> Unit>()
        private var control: JsonObject? = null

        override fun buildInfo(): CoreResult<CoreBuildInfo> = CoreResult.Success(
            CoreBuildInfo(1U, "0.1.0-alpha.1", "f".repeat(40), "debug", "a".repeat(64), listOf("newNoteTextLink"), listOf("apple-parity-v1")),
        )

        override fun readiness(expectedVersionsJson: ByteArray): CoreResult<CoreReadiness> = CoreResult.Success(CoreReadiness("ready", true, emptyList()))

        override fun prepare(preparationJson: ByteArray): CoreResult<ByteArray> {
            assertEquals(String(requestBytes, Charsets.UTF_8), String(preparationJson, Charsets.UTF_8))
            val candidates = JsonArray(listOf(JsonArray(listOf(JsonPrimitive("Inbox"), JsonPrimitive("occupied.md"))), JsonArray(listOf(JsonPrimitive("Inbox"), JsonPrimitive("capture.md")))))
            val observations = JsonArray(listOf(buildJsonObject {
                put("id", "44444444-4444-4444-8444-444444444444")
                put("kind", "candidateOccupancy")
                put("logicalCandidates", candidates)
            }))
            return CoreResult.Success(
                CapturePackageCodec.canonical(
                    buildJsonObject {
                        put("contractVersion", 1L)
                        put("requestID", "11111111-1111-4111-8111-111111111111")
                        put("preparationRevision", 1L)
                        put("snapshotHash", "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
                        put("observations", observations)
                        put("aggregateMaximumBytes", 268_435_456L)
                        put("ordering", "listed")
                    },
                ),
            )
        }

        override fun startMaterialization(controlJson: ByteArray): CoreResult<CoreMaterializationSession> {
            val parsed = CapturePackageCodec.parseCanonical(controlJson)
            control = parsed
            controlAssertions.add {
                val value = parsed
                // Every request field is present unchanged.
                val request = CapturePackageCodec.parseCanonical(requestBytes)
                for ((key, fieldValue) in request) assertEquals("request field $key", fieldValue, value[key])
                // Exact materialization-only keys.
                assertEquals(
                    setOf("calendar", "captureSource", "contractVersion", "controlByteCount", "createdAtEpochMilliseconds", "invocation", "locale", "observations", "operation", "payloads", "pins", "preparationRevision", "preset", "requestID", "session", "snapshotHash", "timezone"),
                    value.keys,
                )
                assertEquals(1_048_576L, (value["controlByteCount"] as JsonPrimitive).longSafe())
                assertEquals("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", value.stringOf("snapshotHash"))
                val session = value["session"] as JsonObject
                assertEquals("observation-list-then-sequence", session.stringOf("inputOrdering"))
                assertEquals(1_048_576L, (session["maximumChunkBytes"] as JsonPrimitive).longSafe())
                assertEquals(268_435_456L, (session["maximumAggregateObservationBytes"] as JsonPrimitive).longSafe())
                assertTrue((session["singleSeal"] as JsonPrimitive).booleanSafe())
                assertTrue((session["singleFinalize"] as JsonPrimitive).booleanSafe())
                val observation = (value["observations"] as JsonArray).single() as JsonObject
                assertEquals("candidateOccupancy", observation.stringOf("kind"))
                assertEquals("44444444-4444-4444-8444-444444444444", observation.stringOf("observationID"))
                assertEquals("present", observation.stringOf("status"))
                // Native occupancy observation: only the occupied candidate is reported, sorted.
                val logicalPaths = observation["logicalPaths"] as JsonArray
                assertEquals(1, logicalPaths.size)
                assertEquals("occupied.md", ((logicalPaths[0] as JsonArray)[1] as JsonPrimitive).content)
                val orderedSetHash = CapturePackageCodec.sha256(CapturePackageCodec.canonical(logicalPaths))
                assertEquals(orderedSetHash, observation.stringOf("orderedSetHash"))
            }
            return CoreResult.Success(FakeSession(this, noteBytes))
        }
    }

    private class FakeSession(private val bridge: FakeCoreBridge, private val noteBytes: ByteArray) : CoreMaterializationSession {
        private var sealed = false
        private var finalized = false
        private val operationID = VoxDeterministicIds.uuid5("vox.operation.v1", CapturePackageCodec.canonical(buildJsonObject {
            put("commitSequence", 0L); put("operation", "newNote"); put("requestID", "11111111-1111-4111-8111-111111111111")
        }))
        private val artifactID = VoxDeterministicIds.uuid5("vox.artifact.v1", CapturePackageCodec.canonical(buildJsonObject {
            put("kind", "note"); put("logicalPath", JsonArray(listOf(JsonPrimitive("Inbox"), JsonPrimitive("capture.md")))); put("operationID", operationID)
        }))
        private val streamID = VoxDeterministicIds.uuid5("vox.stream.v1", CapturePackageCodec.canonical(buildJsonObject {
            put("artifactID", artifactID); put("resultLength", noteBytes.size.toLong()); put("resultSHA256", CapturePackageCodec.sha256(noteBytes))
        }))

        override fun pushObservation(streamId: String, sequence: UInt, bytes: ByteArray, eof: Boolean) = CoreResult.Success(Unit)
        override fun seal(): CoreResult<List<CoreArtifactDescriptor>> {
            if (sealed) return CoreResult.Failure(CoreErrorCode.SESSION_TERMINAL)
            sealed = true
            return CoreResult.Success(
                listOf(
                    CoreArtifactDescriptor(
                        artifactId = artifactID, operationId = operationID, streamId = streamID, commitSequence = 0U,
                        kind = "note", mediaType = "text/markdown; charset=utf-8",
                        length = noteBytes.size.toULong(), resultSha256 = CapturePackageCodec.sha256(noteBytes),
                        receiptKind = "noteCommit",
                    ),
                ),
            )
        }
        override fun drain(artifactId: String, sequence: UInt, maximumBytes: ULong): CoreResult<CorePreparedChunk> {
            if (artifactId != artifactID) return CoreResult.Failure(CoreErrorCode.CORRELATION)
            if (sequence == 0U) return CoreResult.Success(CorePreparedChunk(artifactId, streamID, 0U, noteBytes, noteBytes.size.toULong(), CapturePackageCodec.sha256(noteBytes), true))
            return CoreResult.Failure(CoreErrorCode.SESSION_TERMINAL)
        }
        override fun finalize(drainedHashesJson: ByteArray): CoreResult<ByteArray> {
            if (finalized) return CoreResult.Failure(CoreErrorCode.SESSION_TERMINAL)
            finalized = true
            val drained = CapturePackageCodec.parseCanonical(drainedHashesJson)
            assertEquals("drainedArtifactHashes", drained.stringOf("kind"))
            val artifact = (drained["artifacts"] as JsonArray).single() as JsonObject
            assertEquals(artifactID, artifact.stringOf("artifactID"))
            assertEquals(noteBytes.size.toLong(), (artifact["length"] as JsonPrimitive).longSafe())
            val base = buildJsonObject {
                put("artifacts", JsonArray(listOf(buildJsonObject {
                    put("artifactID", artifactID); put("commitSequence", 0L); put("equivalenceRule", "exactBytes")
                    put("expectedExistingPolicy", "absent"); put("expectedExistingSHA256", JsonNull)
                    put("journalFrontier", "noteVerified"); put("kind", "note")
                    put("logicalPath", JsonArray(listOf(JsonPrimitive("Inbox"), JsonPrimitive("capture.md"))))
                    put("mediaType", "text/markdown; charset=utf-8"); put("operationID", operationID)
                    put("preparedStreamID", streamID); put("receiptKind", "noteCommit")
                    put("resultLength", noteBytes.size.toLong()); put("resultSHA256", CapturePackageCodec.sha256(noteBytes)); put("writeMode", "create")
                })))
                put("contractVersion", 1L); put("diagnostics", JsonArray(emptyList())); put("operation", "newNote")
                put("pins", buildJsonObject {
                    put("coreVersion", "0.1.0-alpha.1"); put("modelProfileID", JsonNull); put("modelRevision", JsonNull)
                    put("profileID", "apple-parity-v1"); put("profileVersion", 1L); put("rendererRevision", "swift-legacy-m0")
                })
                put("planHash", "0".repeat(64))
                put("preparedByteDelivery", buildJsonObject {
                    put("finalJSONDuplicatesBytes", false); put("maximumChunkBytes", 1_048_576L); put("mode", "drainedImmutableArtifacts")
                })
                put("requestID", "11111111-1111-4111-8111-111111111111")
                put("retryMarker", buildJsonObject { put("placement", "none"); put("policy", "none"); put("syntax", "") })
                put("warnings", JsonArray(emptyList()))
            }
            val zeroed = JsonObject(base.toMutableMap().also { it["planHash"] = JsonPrimitive("0".repeat(64)) })
            val planHash = CapturePackageCodec.sha256(CapturePackageCodec.canonical(zeroed))
            return CoreResult.Success(CapturePackageCodec.canonical(JsonObject(base.toMutableMap().also { it["planHash"] = JsonPrimitive(planHash) })))
        }
        override fun cancel(): CoreResult<Unit> = CoreResult.Success(Unit)
        override fun close() {}
    }

    // ---- store fakes ----
    private class MemoryIndex : CaptureIndex {
        val rows = linkedMapOf<String, CaptureIndexProjection>()
        override fun read(requestID: String) = rows[requestID]
        override fun all(): List<CaptureIndexProjection> = rows.values.toList()
        @Synchronized override fun insertOrRepair(projection: CaptureIndexProjection): IndexWriteResult {
            val existing = rows[projection.requestID]
            return if (existing == null) { rows[projection.requestID] = projection; IndexWriteResult.INSERTED }
            else if (existing.journalRevision == projection.journalRevision) IndexWriteResult.IDENTICAL
            else if (existing.journalRevision < projection.journalRevision) { rows[projection.requestID] = projection; IndexWriteResult.REPAIRED_OLDER }
            else IndexWriteResult.PROJECTION_AHEAD
        }
    }
    private class MemoryLeases : CaptureLeasePersistence {
        private val leases = ConcurrentHashMap<String, CaptureLease>()
        private var maximum = 0L
        private fun plan(requestID: String, token: String, now: Long, duration: Long, result: (CaptureLease, Long) -> LeasePlan): LeasePlan {
            maximum = maxOf(maximum, now)
            val current = leases[requestID]
            return if (current != null && current.token == token && current.requestID == requestID && current.expiresAtEpochMillis > now) {
                val renewed = CaptureLease(requestID, token, now + duration); leases[requestID] = renewed; result(renewed, maximum)
            } else if (current == null || current.expiresAtEpochMillis <= now) {
                val lease = CaptureLease(requestID, token, now + duration); leases[requestID] = lease; result(lease, maximum)
            } else LeasePlan.Busy(maximum)
        }
        override fun acquire(requestID: String, candidateToken: String, nowEpochMillis: Long, durationMillis: Long) = plan(requestID, candidateToken, nowEpochMillis, durationMillis) { l, m -> LeasePlan.Grant(l, m) }
        override fun renew(requestID: String, token: String, nowEpochMillis: Long, durationMillis: Long) = plan(requestID, token, nowEpochMillis, durationMillis) { l, m -> LeasePlan.Grant(l, m) }
        override fun release(requestID: String, token: String) = leases.remove(requestID, leases[requestID])
        override fun isCurrent(requestID: String, token: String, nowEpochMillis: Long): LeasePlan {
            maximum = maxOf(maximum, nowEpochMillis)
            val current = leases[requestID]
            return if (current != null && current.token == token && current.expiresAtEpochMillis > nowEpochMillis) LeasePlan.Current(current, maximum) else LeasePlan.Lost(maximum)
        }
        override fun clearExpired(nowEpochMillis: Long): LeaseClearResult = LeaseClearResult.Cleared(0)
    }
    private class JvmOps : DurableFileOps {
        override fun ensureDirectory(directory: File) { directory.mkdirs() || directory.isDirectory }
        override fun createDirectory(directory: File) { if (!directory.mkdir() || !isDirectoryNoFollow(directory)) error("mkdirFailed") }
        override fun writeFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit) {
            checkpoint("beforeWrite"); FileOutputStream(file).use { it.write(bytes); it.fd.sync() }; checkpoint("afterWrite")
        }
        override fun writeNewFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit) {
            if (file.exists()) error("alreadyExists"); writeFileDurably(file, bytes, checkpoint)
        }
        override fun readBounded(file: File, maximumBytes: Int): ByteArray = file.readBytes().also { check(it.size <= maximumBytes) }
        override fun syncDirectory(directory: File) { directory.canonicalFile.mkdirs() }
        override fun <T> withPromotionLock(root: File, action: () -> T): T = lock(root).withLock { action() }
        override fun promoteDirectoryNoReplace(source: File, target: File) { if (target.exists()) error("exists"); if (!source.renameTo(target)) error("renameFailed") }
        override fun replaceFileAtomically(source: File, target: File) { Files.move(source.toPath(), target.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE) }
        override fun list(directory: File): List<File> = directory.listFiles()?.toList() ?: error("listFailed")
        override fun exists(file: File) = Files.exists(file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)
        override fun isDirectoryNoFollow(file: File) = Files.isDirectory(file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)
        override fun isRegularFileNoFollow(file: File) = Files.isRegularFile(file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)
        override fun isSymlink(file: File) = Files.isSymbolicLink(file.toPath())
        override fun length(file: File) = Files.size(file.toPath())
        override fun deleteOwnedTemporary(directory: File) { directory.deleteRecursively() }
        override fun deleteOwnedFile(file: File) { Files.delete(file.toPath()) }
        private val locks = ConcurrentHashMap<String, ReentrantLock>()
        private fun lock(root: File) = locks.computeIfAbsent(root.absolutePath) { ReentrantLock() }
    }
}

private fun JsonObject.stringOf(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonPrimitive.longSafe(): Long = content.toLong()
private fun JsonPrimitive.booleanSafe(): Boolean = content.toBoolean()
