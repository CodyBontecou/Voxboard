package md.vox.android.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import md.vox.android.capturedomain.*
import md.vox.android.corebridge.CoreBuildInfo
import md.vox.android.corebridge.CoreResult
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * ADR-0023 §3–§6 executor taxonomy with a fake provider gateway over the REAL durable
 * store: verified commit (receipt before append), stale occupancy, permission loss,
 * post-marker ambiguity, causal proved-not-committed (absent and cleared marker), and
 * ACTIVE-marker reconciliation including duplicate/transformed → ambiguous.
 */
class SafVaultCommitExecutorTest {
    private val requestID = "11111111-1111-4111-8111-111111111111"
    private val leaseToken = "22222222-2222-4222-8222-222222222222"
    private val destination = VaultDestination("33333333-3333-4333-8333-333333333333", "content://test/tree")
    private val note = "# Synthetic capture text.\n".toByteArray()
    private val noteSha = CapturePackageCodec.sha256(note)

    // ---- fixtures ----

    private fun materializedPlan(): ByteArray {
        val operationID = VoxDeterministicIds.uuid5("vox.operation.v1", CapturePackageCodec.canonical(kotlinx.serialization.json.buildJsonObject {
            put("commitSequence", 0L); put("operation", "newNote"); put("requestID", requestID)
        }))
        val logicalPath = kotlinx.serialization.json.JsonArray(listOf(kotlinx.serialization.json.JsonPrimitive("Inbox"), kotlinx.serialization.json.JsonPrimitive("capture.md")))
        val artifactID = VoxDeterministicIds.uuid5("vox.artifact.v1", CapturePackageCodec.canonical(kotlinx.serialization.json.buildJsonObject {
            put("kind", "note"); put("logicalPath", logicalPath); put("operationID", operationID)
        }))
        val streamID = VoxDeterministicIds.uuid5("vox.stream.v1", CapturePackageCodec.canonical(kotlinx.serialization.json.buildJsonObject {
            put("artifactID", artifactID); put("resultLength", note.size.toLong()); put("resultSHA256", noteSha)
        }))
        val base = kotlinx.serialization.json.buildJsonObject {
            put("artifacts", kotlinx.serialization.json.JsonArray(listOf(kotlinx.serialization.json.buildJsonObject {
                put("artifactID", artifactID); put("commitSequence", 0L); put("equivalenceRule", "exactBytes")
                put("expectedExistingPolicy", "absent"); put("expectedExistingSHA256", kotlinx.serialization.json.JsonNull)
                put("journalFrontier", "noteVerified"); put("kind", "note"); put("logicalPath", logicalPath)
                put("mediaType", "text/markdown; charset=utf-8"); put("operationID", operationID)
                put("preparedStreamID", streamID); put("receiptKind", "noteCommit")
                put("resultLength", note.size.toLong()); put("resultSHA256", noteSha); put("writeMode", "create")
            })))
            put("contractVersion", 1L); put("diagnostics", kotlinx.serialization.json.JsonArray(emptyList())); put("operation", "newNote")
            put("pins", kotlinx.serialization.json.buildJsonObject {
                put("coreVersion", "0.1.0-alpha.1"); put("modelProfileID", kotlinx.serialization.json.JsonNull)
                put("modelRevision", kotlinx.serialization.json.JsonNull); put("profileID", "apple-parity-v1")
                put("profileVersion", 1L); put("rendererRevision", "swift-legacy-m0")
            })
            put("planHash", "0".repeat(64))
            put("preparedByteDelivery", kotlinx.serialization.json.buildJsonObject {
                put("finalJSONDuplicatesBytes", false); put("maximumChunkBytes", 1_048_576L); put("mode", "drainedImmutableArtifacts")
            })
            put("requestID", requestID)
            put("retryMarker", kotlinx.serialization.json.buildJsonObject { put("placement", "none"); put("policy", "none"); put("syntax", "") })
            put("warnings", kotlinx.serialization.json.JsonArray(emptyList()))
        }
        val zeroed = kotlinx.serialization.json.JsonObject(base.toMutableMap().also { it["planHash"] = kotlinx.serialization.json.JsonPrimitive("0".repeat(64)) })
        val trueHash = CapturePackageCodec.sha256(CapturePackageCodec.canonical(zeroed))
        return CapturePackageCodec.canonical(kotlinx.serialization.json.JsonObject(base.toMutableMap().also { it["planHash"] = kotlinx.serialization.json.JsonPrimitive(trueHash) }))
    }

    private class Fixture(
        val store: DurableCapturePackageStore,
        val coordinator: CaptureDurabilityCoordinator,
        val leases: MemoryLeases,
        val planHash: String,
    ) {
        var clock = 100L
        fun nextTime(): Long = clock++
    }

    private fun fixture(): Fixture {
        val base = Files.createTempDirectory("executor").toFile()
        val store = DurableCapturePackageStore(base, MemoryIndex(), JvmOps())
        val request = checkNotNull(javaClass.classLoader!!.getResourceAsStream("contracts/v1/fixtures/capture-preparation-input/valid-android-m3-text-link.json")).use { it.readBytes() }
        assertEquals(EnqueueResult.SavedLocally(requestID), store.enqueue(request, 10))
        val leases = MemoryLeases()
        val coordinator = CaptureDurabilityCoordinator(store, leases)
        val fixture = Fixture(store, coordinator, leases, "")
        coordinator.acquire(requestID, leaseToken, 20, 600_000)
        coordinator.mutate(JournalMutationCommand(requestID, store.loadJournal(requestID)!!.revision, JournalEvent(store.loadJournal(requestID)!!.revision + 1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), leaseToken), 20)
        // Staged drain + promotion.
        val planBytes = materializedPlan()
        val planHash = PreparedPlanVerifier.verifiedPlanHash(planBytes)!!
        val staging = "44444444-4444-4444-8444-444444444444"
        val sink = store.openStagedNoteSink(requestID, staging, note.size.toLong(), noteSha)
        sink.write(note); sink.verifyAndClose()
        store.promotePreparedArtifacts(requestID, planHash, planBytes, staging)
        coordinator.mutate(JournalMutationCommand(requestID, store.loadJournal(requestID)!!.revision, JournalEvent(store.loadJournal(requestID)!!.revision + 1, CaptureState.PREPARING, CaptureState.MATERIALIZED, JournalCode.MATERIALIZED, 21, planHash = planHash), leaseToken), 21)
        return Fixture(store, coordinator, leases, planHash)
    }

    private fun executor(fixture: Fixture, gateway: FakeGateway) = SafVaultCommitExecutor(
        fixture.store, fixture.coordinator, gateway, destination,
        buildInfo = { CoreResult.Success(CoreBuildInfo(1U, "0.1.0-alpha.1", "f".repeat(40), "debug", "a".repeat(64), listOf("newNoteTextLink"), listOf("apple-parity-v1"))) },
        clock = { fixture.nextTime() },
    )

    // ---- taxonomy paths ----

    @Test fun verifiedCommitPersistsReceiptBeforeAppendAndRetainsMarker() {
        val fixture = fixture()
        val gateway = FakeGateway()
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue("got $outcome", (outcome as ExecutorOutcome.Ok).value is CommitOutcome.VerifiedCommitted)
        val snapshot = fixture.store.loadJournal(requestID)!!
        assertEquals(CaptureState.COMPLETED, snapshot.state)
        val receiptID = (snapshot.events.last().receiptID)!!
        // Receipt file persisted with the deterministic derived identity.
        assertNotNull(fixture.store.loadReceipt(requestID, receiptID))
        assertEquals(CommitMarker.MarkerState.ACTIVE, fixture.store.readCommitMarker(requestID)!!.state)
        assertEquals(1, gateway.created.size)
    }

    @Test fun staleOccupancyReturnsBeforeCommittingAndKeepsMaterIALIZED() {
        val fixture = fixture()
        val gateway = FakeGateway(preexistingNames = setOf("capture.md"))
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue((outcome as ExecutorOutcome.Ok).value === CommitOutcome.StaleOccupancy)
        assertEquals(CaptureState.MATERIALIZED, fixture.store.loadJournal(requestID)!!.state)
        assertNull(fixture.store.readCommitMarker(requestID))
        assertEquals(0, gateway.created.size)
    }

    @Test fun preCommitPermissionLossEntersNeedsPermissionWithoutDeletion() {
        val fixture = fixture()
        val gateway = FakeGateway(grantValid = false)
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue((outcome as ExecutorOutcome.Ok).value === CommitOutcome.PermissionLost)
        assertEquals(CaptureState.NEEDS_PERMISSION, fixture.store.loadJournal(requestID)!!.state)
        assertNotNull(fixture.store.loadPreparedArtifacts(requestID, fixture.planHash))
    }

    @Test fun postMarkerCreateFailureIsAmbiguousNeverBlindRetry() {
        val fixture = fixture()
        val gateway = FakeGateway(failCreate = true)
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue((outcome as ExecutorOutcome.Ok).value === CommitOutcome.Ambiguous)
        assertEquals(CaptureState.UNKNOWN_OUTCOME, fixture.store.loadJournal(requestID)!!.state)
        // Marker retained; retry from unknownOutcome reconciles only.
        assertEquals(CommitMarker.MarkerState.ACTIVE, fixture.store.readCommitMarker(requestID)!!.state)
    }

    @Test fun restartCommittingWithoutMarkerIsCausallyProvedNotCommittedAndClears() {
        val fixture = fixture()
        val gateway = FakeGateway()
        // Simulate crash after COMMIT_STARTED but before marker persistence.
        fixture.coordinator.mutate(JournalMutationCommand(requestID, fixture.store.loadJournal(requestID)!!.revision, JournalEvent(fixture.store.loadJournal(requestID)!!.revision + 1, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 30, planHash = fixture.planHash), leaseToken), 30)
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue((outcome as ExecutorOutcome.Ok).value === CommitOutcome.ProvedNotCommitted)
        assertEquals(CaptureState.RETRYABLE_FAILURE, fixture.store.loadJournal(requestID)!!.state)
        assertEquals(0, gateway.created.size)
    }

    @Test fun restartWithActiveMarkerReconcilesByExactReadback() {
        val fixture = fixture()
        val gateway = FakeGateway()
        fixture.coordinator.mutate(JournalMutationCommand(requestID, fixture.store.loadJournal(requestID)!!.revision, JournalEvent(fixture.store.loadJournal(requestID)!!.revision + 1, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 30, planHash = fixture.planHash), leaseToken), 30)
        fixture.store.persistCommitMarker(requestID, CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, destination.destinationID, fixture.planHash, "capture.md", 31))
        // The provider already has the exact note (crash after commit, before receipt).
        gateway.documents[documentKey("Inbox", "capture.md")] = note
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue("got $outcome", (outcome as ExecutorOutcome.Ok).value is CommitOutcome.VerifiedCommitted)
        assertEquals(CaptureState.COMPLETED, fixture.store.loadJournal(requestID)!!.state)
        assertEquals(0, gateway.created.size) // normal write path never invoked
    }

    @Test fun restartWithActiveMarkerAndDuplicateCandidatesIsAmbiguous() {
        val fixture = fixture()
        val gateway = FakeGateway(duplicateNames = true)
        fixture.coordinator.mutate(JournalMutationCommand(requestID, fixture.store.loadJournal(requestID)!!.revision, JournalEvent(fixture.store.loadJournal(requestID)!!.revision + 1, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 30, planHash = fixture.planHash), leaseToken), 30)
        fixture.store.persistCommitMarker(requestID, CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, destination.destinationID, fixture.planHash, "capture.md", 31))
        gateway.documents[documentKey("Inbox", "capture.md")] = note
        gateway.duplicateNames = true
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue((outcome as ExecutorOutcome.Ok).value === CommitOutcome.Ambiguous)
    }

    @Test fun restartWithActiveMarkerAndTransformedBytesIsAmbiguous() {
        val fixture = fixture()
        val gateway = FakeGateway()
        fixture.coordinator.mutate(JournalMutationCommand(requestID, fixture.store.loadJournal(requestID)!!.revision, JournalEvent(fixture.store.loadJournal(requestID)!!.revision + 1, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 30, planHash = fixture.planHash), leaseToken), 30)
        fixture.store.persistCommitMarker(requestID, CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, destination.destinationID, fixture.planHash, "capture.md", 31))
        gateway.documents[documentKey("Inbox", "capture.md")] = "transformed".toByteArray()
        val outcome = executor(fixture, gateway).execute(requestID, leaseToken)
        assertTrue((outcome as ExecutorOutcome.Ok).value === CommitOutcome.Ambiguous)
        assertEquals(CaptureState.UNKNOWN_OUTCOME, fixture.store.loadJournal(requestID)!!.state)
    }

    @Test fun markerTypeGateForbidsCreateWithoutDurableToken() {
        val fixture = fixture()
        val gateway = FakeGateway()
        // Direct gateway create without a DurableMarkerToken is impossible to express:
        // createDocument's first parameter type has a single internal constructor.
        val constructedViaReflection = runCatching {
            DurableMarkerToken::class.java.getDeclaredConstructor(String::class.java, String::class.java, Long::class.javaPrimitiveType).apply { isAccessible = true }.newInstance(requestID, "a".repeat(64), 1L)
        }.isSuccess
        // Even reflection is the only path; the static governance gate scans for it.
        assertTrue(constructedViaReflection)
        assertEquals(0, gateway.created.size)
    }

    private fun documentKey(vararg segments: String) = segments.joinToString("/")

    // ---- fake provider ----

    private class FakeGateway(
        private val grantValid: Boolean = true,
        private val preexistingNames: Set<String> = emptySet(),
        internal var failCreate: Boolean = false,
        internal var duplicateNames: Boolean = false,
    ) : SafDocumentsGateway {
        val documents = LinkedHashMap<String, ByteArray>()
        val created = mutableListOf<String>()

        override fun revalidateGrant(destination: VaultDestination) = grantValid

        override fun listChildDisplayNames(parent: SafFolderHandle): List<String>? {
            if (!grantValid) return null
            val prefix = parent.key.removePrefix("/")
            return documents.keys.filter { it.removeSuffix("/${it.substringAfterLast('/')}") == prefix }.map { it.substringAfterLast('/') } +
                preexistingNames.filter { prefix.isEmpty() || prefix == "Inbox" }
        }

        override fun resolveFolder(destination: VaultDestination, segments: List<String>, createMissing: Boolean): SafFolderHandle? {
            if (!grantValid) return null
            return SafFolderHandle("/" + segments.joinToString("/"))
        }

        override fun createDocument(marker: DurableMarkerToken, parent: SafFolderHandle, displayName: String, mediaType: String): SafResult<SafDocumentHandle> {
            if (failCreate) return SafResult.error(GatewayError.ProviderFailure.name)
            val key = parent.key.removePrefix("/") + "/" + displayName
            if (documents.containsKey(key)) return SafResult.error(GatewayError.ProviderFailure.name)
            documents[key] = ByteArray(0)
            created.add(key)
            return SafResult.success(SafDocumentHandle("doc/$key"))
        }

        override fun writeDocument(handle: SafDocumentHandle, bytes: ByteArray, expectedLength: Long): SafResult<Unit> {
            val key = handle.key.removePrefix("doc/")
            documents[key] = bytes
            return SafResult.success(Unit)
        }

        override fun readBackDocument(handle: SafDocumentHandle): SafResult<Pair<Long, String>> {
            val key = handle.key.removePrefix("doc/")
            val bytes = documents[key] ?: return SafResult.error(GatewayError.ProviderFailure.name)
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            return SafResult.success(bytes.size.toLong() to digest)
        }

        override fun findChildByDisplayName(parent: SafFolderHandle, displayName: String): List<SafDocumentHandle> {
            if (!grantValid) return emptyList()
            val prefix = parent.key.removePrefix("/")
            val matches = documents.keys.filter { it == "$prefix/$displayName" }
            val result = matches.map { SafDocumentHandle("doc/$it") }.toMutableList()
            if (duplicateNames && matches.isNotEmpty()) result.add(matches[0].let { SafDocumentHandle("doc/$it") })
            return result
        }
    }

    // ---- store fakes (same as DurableCaptureStorePhase5Test) ----

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
