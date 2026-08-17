package md.vox.android.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import md.vox.android.capturedomain.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** ADR-0023 Phase 5: prepared artifacts, marker lifecycle, receipts, and inventory gating. */
class DurableCaptureStorePhase5Test {
    private val requestID = "11111111-1111-4111-8111-111111111111"
    private val leaseToken = "22222222-2222-4222-8222-222222222222"
    private val planHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private val otherPlanHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private fun fixture() = checkNotNull(javaClass.classLoader!!.getResourceAsStream("contracts/v1/fixtures/capture-preparation-input/valid-android-m3-text-link.json")).use { it.readBytes() }

    private fun preparedFixture(): Triple<DurableCapturePackageStore, MemoryIndex, File> {
        val base = Files.createTempDirectory("phase5").toFile()
        val index = MemoryIndex()
        val store = DurableCapturePackageStore(base, index, JvmOps())
        assertEquals(EnqueueResult.SavedLocally(requestID), store.enqueue(fixture(), 10))
        val leases = MemoryLeases()
        val coordinator = CaptureDurabilityCoordinator(store, leases)
        val granted = coordinator.acquire(requestID, leaseToken, 20, 60_000)
        assertTrue("lease grant failed: $granted", granted is LeasePlan.Grant)
        var snapshot = store.loadJournal(requestID)!!
        // QUEUED -> PREPARING (worker lease)
        when (val r = coordinator.mutate(command(snapshot, leaseToken) { JournalEvent(it, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20) }, 20)) {
            is JournalMutationResult.Applied -> Unit
            else -> fail("preparing append failed: $r")
        }
        snapshot = store.loadJournal(requestID)!!
        assertEquals(CaptureState.PREPARING, snapshot.state)
        return Triple(store, index, base)
    }

    private fun command(snapshot: JournalSnapshot, token: String, event: (Int) -> JournalEvent) =
        JournalMutationCommand(requestID, snapshot.revision, event(snapshot.revision + 1), token)

    private fun stageAndPromote(store: DurableCapturePackageStore, noteBytes: ByteArray, planBytes: ByteArray, hash: String = planHash): PreparedPlanDescriptor {
        val stagingUUID = "33333333-3333-4333-8333-333333333333"
        val sink = store.openStagedNoteSink(requestID, stagingUUID, noteBytes.size.toLong(), CapturePackageCodec.sha256(noteBytes))
        sink.write(noteBytes)
        sink.verifyAndClose()
        store.promotePreparedArtifacts(requestID, hash, planBytes, stagingUUID)
        return PreparedPlanDescriptor(hash, noteBytes.size.toLong(), CapturePackageCodec.sha256(noteBytes))
    }

    private fun minimalPlan(noteLength: Long, noteSha: String, hash: String = planHash): ByteArray {
        val operationID = VoxDeterministicIds.uuid5(
            "vox.operation.v1",
            CapturePackageCodec.canonical(
                kotlinx.serialization.json.buildJsonObject {
                    put("commitSequence", 0L)
                    put("operation", "newNote")
                    put("requestID", requestID)
                },
            ),
        )
        val logicalPath = kotlinx.serialization.json.JsonArray(listOf(kotlinx.serialization.json.JsonPrimitive("Inbox"), kotlinx.serialization.json.JsonPrimitive("capture.md")))
        val artifactID = VoxDeterministicIds.uuid5(
            "vox.artifact.v1",
            CapturePackageCodec.canonical(
                kotlinx.serialization.json.buildJsonObject {
                    put("kind", "note")
                    put("logicalPath", logicalPath)
                    put("operationID", operationID)
                },
            ),
        )
        val streamID = VoxDeterministicIds.uuid5(
            "vox.stream.v1",
            CapturePackageCodec.canonical(
                kotlinx.serialization.json.buildJsonObject {
                    put("artifactID", artifactID)
                    put("resultLength", noteLength)
                    put("resultSHA256", noteSha)
                },
            ),
        )
        val plan = kotlinx.serialization.json.buildJsonObject {
            put("artifacts", kotlinx.serialization.json.JsonArray(listOf(kotlinx.serialization.json.buildJsonObject {
                put("artifactID", artifactID)
                put("commitSequence", 0L)
                put("equivalenceRule", "exactBytes")
                put("expectedExistingPolicy", "absent")
                put("expectedExistingSHA256", kotlinx.serialization.json.JsonNull)
                put("journalFrontier", "noteVerified")
                put("kind", "note")
                put("logicalPath", logicalPath)
                put("mediaType", "text/markdown; charset=utf-8")
                put("operationID", operationID)
                put("preparedStreamID", streamID)
                put("receiptKind", "noteCommit")
                put("resultLength", noteLength)
                put("resultSHA256", noteSha)
                put("writeMode", "create")
            })))
            put("contractVersion", 1L)
            put("diagnostics", kotlinx.serialization.json.JsonArray(emptyList()))
            put("operation", "newNote")
            put("pins", kotlinx.serialization.json.buildJsonObject {
                put("coreVersion", "0.1.0-alpha.1")
                put("modelProfileID", kotlinx.serialization.json.JsonNull)
                put("modelRevision", kotlinx.serialization.json.JsonNull)
                put("profileID", "apple-parity-v1")
                put("profileVersion", 1L)
                put("rendererRevision", "swift-legacy-m0")
            })
            put("planHash", hash)
            put("preparedByteDelivery", kotlinx.serialization.json.buildJsonObject {
                put("finalJSONDuplicatesBytes", false)
                put("maximumChunkBytes", 1_048_576L)
                put("mode", "drainedImmutableArtifacts")
            })
            put("requestID", requestID)
            put("retryMarker", kotlinx.serialization.json.buildJsonObject {
                put("placement", "none")
                put("policy", "none")
                put("syntax", "")
            })
            put("warnings", kotlinx.serialization.json.JsonArray(emptyList()))
        }
        // Recompute the true plan hash so the directory name binds the canonical bytes.
        val zeroed = kotlinx.serialization.json.JsonObject(plan.toMutableMap().also { it["planHash"] = kotlinx.serialization.json.JsonPrimitive("0".repeat(64)) })
        val trueHash = CapturePackageCodec.sha256(CapturePackageCodec.canonical(zeroed))
        return CapturePackageCodec.canonical(kotlinx.serialization.json.JsonObject(plan.toMutableMap().also { it["planHash"] = kotlinx.serialization.json.JsonPrimitive(trueHash) }))
    }

    @Test fun materializedAppendRequiresVerifiedPreparedArtifacts() {
        val (store, _, _) = preparedFixture()
        val snapshot = store.loadJournal(requestID)!!
        // No prepared artifacts: MATERIALIZED append must fail closed in inventory validation.
        val leases = MemoryLeases()
        val coordinator = CaptureDurabilityCoordinator(store, leases)
        coordinator.acquire(requestID, leaseToken, 25, 60_000)
        val result = coordinator.mutate(command(snapshot, leaseToken) { JournalEvent(it, CaptureState.PREPARING, CaptureState.MATERIALIZED, JournalCode.MATERIALIZED, 30, planHash = planHash) }, 30)
        assertEquals(JournalMutationResult.ReducerRejected("preparedRequired"), result)
        assertEquals(CaptureState.PREPARING, store.loadJournal(requestID)!!.state)
    }

    @Test fun stagedDrainPromoteAndMaterializeRoundTrips() {
        val (store, _, _) = preparedFixture()
        val note = "# Synthetic capture text.\n".toByteArray()
        val planBytes = minimalPlan(note.size.toLong(), CapturePackageCodec.sha256(note))
        val trueHash = PreparedPlanVerifier.verifiedPlanHash(planBytes)!!
        val descriptor = stageAndPromote(store, note, planBytes, trueHash)
        assertEquals(note.size.toLong(), descriptor.noteLengthBytes)

        // Prepared without MATERIALIZED claim is legal (crash window), reload verifies.
        val artifacts = store.loadPreparedArtifacts(requestID, trueHash)!!
        assertArrayEquals(note, artifacts.noteBytes)

        val coordinator = CaptureDurabilityCoordinator(store, MemoryLeases())
        coordinator.acquire(requestID, leaseToken, 25, 60_000)
        val snapshot = store.loadJournal(requestID)!!
        val applied = coordinator.mutate(command(snapshot, leaseToken) { JournalEvent(it, CaptureState.PREPARING, CaptureState.MATERIALIZED, JournalCode.MATERIALIZED, 30, planHash = trueHash) }, 30)
        assertTrue("materialize append failed: $applied", applied is JournalMutationResult.Applied)
        assertEquals(CaptureState.MATERIALIZED, store.loadJournal(requestID)!!.state)
        // MATERIALIZED claim without the plan-hash directory fails closed.
        val missing = coordinator.mutate(command(store.loadJournal(requestID)!!, leaseToken) { JournalEvent(it, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 31, planHash = otherPlanHash) }, 31)
        assertTrue(missing is JournalMutationResult.ReducerRejected || missing is JournalMutationResult.PackageCorrupt || missing is JournalMutationResult.CoordinationFailure)
    }

    @Test fun markerPersistsReadsClearsAndRefusesActiveOverwrite() {
        val (store, _, _) = preparedFixture()
        val note = "n".toByteArray()
        val planBytes = minimalPlan(note.size.toLong(), CapturePackageCodec.sha256(note))
        val trueHash = PreparedPlanVerifier.verifiedPlanHash(planBytes)!!
        stageAndPromote(store, note, planBytes, trueHash)
        val coordinator = CaptureDurabilityCoordinator(store, MemoryLeases())
        coordinator.acquire(requestID, leaseToken, 25, 60_000)
        coordinator.mutate(command(store.loadJournal(requestID)!!, leaseToken) { JournalEvent(it, CaptureState.PREPARING, CaptureState.MATERIALIZED, JournalCode.MATERIALIZED, 30, planHash = trueHash) }, 30)
        coordinator.mutate(command(store.loadJournal(requestID)!!, leaseToken) { JournalEvent(it, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 31, planHash = trueHash) }, 31)

        assertNull(store.readCommitMarker(requestID))
        store.persistCommitMarker(requestID, CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, requestID, trueHash, "capture.md", 32))
        assertEquals(CommitMarker.MarkerState.ACTIVE, store.readCommitMarker(requestID)!!.state)
        // Active marker cannot be silently replaced.
        assertThrows(PackageCodecException::class.java) {
            store.persistCommitMarker(requestID, CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, requestID, trueHash, "capture.md", 33))
        }

        // PROVED_NOT_COMMITTED clears the marker within the journaled mutation window.
        val cleared = coordinator.mutate(
            JournalMutationCommand(requestID, store.loadJournal(requestID)!!.revision, JournalEvent(store.loadJournal(requestID)!!.revision + 1, CaptureState.COMMITTING, CaptureState.RETRYABLE_FAILURE, JournalCode.PROVED_NOT_COMMITTED, 33), leaseToken, clearCommitMarker = true),
            33,
        )
        assertTrue(cleared is JournalMutationResult.Applied)
        assertEquals(CommitMarker.MarkerState.CLEARED, store.readCommitMarker(requestID)!!.state)
        assertEquals(CaptureState.RETRYABLE_FAILURE, store.loadJournal(requestID)!!.state)
    }

    @Test fun receiptsAreAppendOnlyAndIdempotent() {
        val (store, _, _) = preparedFixture()
        val receipt = DeliveryReceipt.validated(
            DeliveryReceipt.deriveReceiptID(requestID, "84ad1460-9d3d-5734-bfa5-1de91c32de4b", "092b8435-ea25-54a3-8824-d76adb80a2a1"),
            requestID, "84ad1460-9d3d-5734-bfa5-1de91c32de4b", "092b8435-ea25-54a3-8824-d76adb80a2a1",
            planHash, requestID, 25, "d".repeat(64), 40,
        )
        // receipts/ is illegal before COMMITTING (entry inventory) and idempotent after.
        assertThrows(PackageCodecException::class.java) { store.persistReceipt(requestID, receipt) }
        val note = "n".toByteArray()
        val planBytes = minimalPlan(note.size.toLong(), CapturePackageCodec.sha256(note))
        val trueHash = PreparedPlanVerifier.verifiedPlanHash(planBytes)!!
        stageAndPromote(store, note, planBytes, trueHash)
        val coordinator = CaptureDurabilityCoordinator(store, MemoryLeases())
        coordinator.acquire(requestID, leaseToken, 25, 60_000)
        coordinator.mutate(command(store.loadJournal(requestID)!!, leaseToken) { JournalEvent(it, CaptureState.PREPARING, CaptureState.MATERIALIZED, JournalCode.MATERIALIZED, 30, planHash = trueHash) }, 30)
        coordinator.mutate(command(store.loadJournal(requestID)!!, leaseToken) { JournalEvent(it, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 31, planHash = trueHash) }, 31)
        store.persistReceipt(requestID, receipt)
        store.persistReceipt(requestID, receipt) // idempotent replay
        assertEquals(receipt, store.loadReceipt(requestID, receipt.receiptID))
        val conflicting = receipt.copy(verifiedLengthBytes = 26).let {
            DeliveryReceipt.validated(it.receiptID, it.requestID, it.operationID, it.artifactID, it.planHash, it.destinationID, 26, it.verifiedSHA256, it.committedAtEpochMillis)
        }
        assertThrows(PackageCodecException::class.java) { store.persistReceipt(requestID, conflicting) }
        // Foreign request correlation is rejected.
        assertThrows(PackageCodecException::class.java) {
            store.persistReceipt("99999999-9999-4999-8999-999999999999", receipt)
        }
    }

    @Test fun inventoryGatesUnknownEntriesAndStateShapesFailClosed() {
        val (store, _, base) = preparedFixture()
        val packageDir = File(base, "vox-captures/$requestID")
        // Unknown entry at QUEUED is corrupt.
        File(packageDir, "stray.txt").writeText("x")
        assertNull(store.loadJournal(requestID))
        File(packageDir, "stray.txt").delete()
        assertNotNull(store.loadJournal(requestID))
        // Symlinked observations dir is corrupt.
        Files.createSymbolicLink(File(packageDir, "observations").toPath(), File(packageDir, "request.json").toPath())
        assertNull(store.loadJournal(requestID))
        Files.delete(File(packageDir, "observations").toPath())
        assertNotNull(store.loadJournal(requestID))
    }

    // ---- minimal local fakes mirroring production semantics ----

    private class MemoryIndex : CaptureIndex {
        val rows = linkedMapOf<String, CaptureIndexProjection>()
        override fun read(requestID: String) = rows[requestID]
        override fun all(): List<CaptureIndexProjection> = rows.values.toList()
        @Synchronized override fun insertOrRepair(projection: CaptureIndexProjection): IndexWriteResult {
            val existing = rows[projection.requestID]
            return if (existing == null) { rows[projection.requestID] = projection; IndexWriteResult.INSERTED }
            else if (existing.journalRevision == projection.journalRevision) { IndexWriteResult.IDENTICAL }
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
                val renewed = CaptureLease(requestID, token, now + duration)
                leases[requestID] = renewed
                result(renewed, maximum)
            } else if (current == null || current.expiresAtEpochMillis <= now) {
                val lease = CaptureLease(requestID, token, now + duration)
                leases[requestID] = lease
                result(lease, maximum)
            } else LeasePlan.Busy(maximum)
        }
        override fun acquire(requestID: String, candidateToken: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan =
            plan(requestID, candidateToken, nowEpochMillis, durationMillis) { lease, max -> LeasePlan.Grant(lease, max) }
        override fun renew(requestID: String, token: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan =
            plan(requestID, token, nowEpochMillis, durationMillis) { lease, max -> LeasePlan.Grant(lease, max) }
        override fun release(requestID: String, token: String): Boolean = leases.remove(requestID, leases[requestID])
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
        override fun syncDirectory(directory: File) { File(directory.parentFile, directory.name).canonicalFile.mkdirs() }
        override fun <T> withPromotionLock(root: File, action: () -> T): T = lock(root).withLock { action() }
        override fun promoteDirectoryNoReplace(source: File, target: File) {
            if (target.exists()) error("exists"); if (!source.renameTo(target)) error("renameFailed")
        }
        override fun replaceFileAtomically(source: File, target: File) {
            Files.move(source.toPath(), target.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        }
        override fun moveFileNoReplaceAtomically(source: File, target: File) {
            check(!Files.exists(target.toPath())) { "unsafeAtomicCreate" }
            Files.move(source.toPath(), target.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE)
        }
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
