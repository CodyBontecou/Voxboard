package md.vox.android.data

import md.vox.android.capturedomain.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class DurableCapturePackageStoreTest {
    @Test fun savedLocallyRequiresBothParentSyncsAndIndexResult() {
        val base = Files.createTempDirectory("capture-store").toFile(); val index = MemoryIndex(); val ops = JvmOps()
        assertTrue(DurableCapturePackageStore(base, index, ops).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        assertTrue(ops.seen.indexOf("afterRootParentSync") < ops.seen.indexOf("postIndexPreResult"))
        assertTrue(ops.seen.indexOf("afterCapturesParentSync") < ops.seen.indexOf("beforeIndexCall"))
        assertEquals(CaptureState.QUEUED, index.read(ID)!!.state)
    }

    @Test fun negativeEnqueueTimeCreatesNothing() {
        val base = Files.createTempDirectory("capture-negative-time").toFile()
        assertEquals(EnqueueResult.DurabilityFailure(ID, "enqueueTimeOutOfBounds"), DurableCapturePackageStore(base, MemoryIndex(), JvmOps()).enqueue(request(), -1))
        assertFalse(File(base, "vox-captures").exists())
    }

    @Test fun distinctBeforeAndAfterFailuresNeverAcknowledgeAndRetryRepairs() {
        val perFile = listOf("request.json", "assets.json", "delivery-journal.json").flatMap { name -> listOf("beforeWrite:$name", "afterWrite:$name", "beforeFlush:$name", "afterFlush:$name", "beforeFileSync:$name", "afterFileSync:$name", "beforeClose:$name", "afterClose:$name", "beforeReopen:$name", "afterReopen:$name") }
        val failures = listOf("beforeRootEnsure", "afterRootEnsure", "beforeRootParentSync", "afterRootParentSync", "beforeTempCreate", "afterTempCreate") + perFile + listOf("beforeTempDirectorySync", "afterTempDirectorySync", "beforePromotionLockAcquire", "afterPromotionLockAcquire", "afterPromotionLockRelease", "beforePromotion", "afterPromotion", "beforeCapturesParentSync", "afterCapturesParentSync", "beforeIndexCall", "afterIndexCall", "afterIndexResult", "postIndexPreResult")
        failures.forEach { failure ->
            val base = Files.createTempDirectory("capture-failure").toFile()
            val first = DurableCapturePackageStore(base, MemoryIndex(), JvmOps(failAt = failure)).enqueue(request(), 10)
            assertFalse("$failure returned SavedLocally", first is EnqueueResult.SavedLocally)
            assertTrue("$failure retry failed", DurableCapturePackageStore(base, MemoryIndex(), JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        }
    }

    @Test fun duplicateSyncsRootParentAgainAndIsImmutable() {
        val base = Files.createTempDirectory("capture-duplicate").toFile(); val index = MemoryIndex()
        assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        val ops = JvmOps(); val packageDir = File(base, "vox-captures/$ID"); val before = File(packageDir, "request.json").readBytes()
        assertTrue(DurableCapturePackageStore(base, index, ops).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        assertTrue("afterDuplicateCapturesParentSync" in ops.seen); assertArrayEquals(before, File(packageDir, "request.json").readBytes())
        assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(changedRequest(), 10) is EnqueueResult.CorrelationConflict)
    }

    @Test fun duplicateCannotAcknowledgeUntilCapturesParentResyncCompletes() {
        for (failure in listOf("beforeDuplicateCapturesParentSync", "afterDuplicateCapturesParentSync")) {
            val base = Files.createTempDirectory("capture-duplicate-sync").toFile(); val index = MemoryIndex()
            assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
            assertFalse(DurableCapturePackageStore(base, index, JvmOps(failAt = failure)).enqueue(request(), 10) is EnqueueResult.SavedLocally)
            assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        }
    }

    @Test fun historicalCorePinCanRepairExistingPackageButCannotCreateNewPackage() {
        val oldRequest = request().toString(Charsets.UTF_8).replace("0.1.0-alpha.1", "0.1.0-alpha.0").toByteArray()
        val freshBase = Files.createTempDirectory("capture-old-new").toFile()
        assertEquals(EnqueueResult.DurabilityFailure(ID, "pinProfile"), DurableCapturePackageStore(freshBase, MemoryIndex(), JvmOps()).enqueue(oldRequest, 10))
        assertFalse(File(freshBase, "vox-captures").exists())

        val existingBase = Files.createTempDirectory("capture-old-existing").toFile(); val packageDir = File(existingBase, "vox-captures/$ID")
        assertTrue(packageDir.mkdirs())
        val assets = CapturePackageCodec.encodeAssets(AssetManifest(ID))
        val snapshot = JournalSnapshot(ID, 0, CaptureState.QUEUED, null, listOf(JournalEvent(0, null, CaptureState.QUEUED, JournalCode.ENQUEUED, 10)))
        File(packageDir, "request.json").writeBytes(oldRequest)
        File(packageDir, "assets.json").writeBytes(assets)
        File(packageDir, "delivery-journal.json").writeBytes(CapturePackageCodec.encodeJournal(snapshot, oldRequest, assets))
        assertTrue(DurableCapturePackageStore(existingBase, MemoryIndex(), JvmOps()).enqueue(oldRequest, 10) is EnqueueResult.SavedLocally)
    }

    @Test fun forcedPromotionRaceHasOneWinnerAndOneCorrelationConflict() {
        val base = Files.createTempDirectory("capture-race").toFile(); val barrier = CyclicBarrier(2); val index = MemoryIndex()
        val first = DurableCapturePackageStore(base, index, JvmOps(barrier = barrier)); val second = DurableCapturePackageStore(base, index, JvmOps(barrier = barrier))
        val a = request(); val b = changedRequest(); val results = java.util.Collections.synchronizedList(mutableListOf<Pair<EnqueueResult, ByteArray>>())
        val threads = listOf(Thread { results += first.enqueue(a, 10) to a }, Thread { results += second.enqueue(b, 10) to b }); threads.forEach(Thread::start); threads.forEach(Thread::join)
        assertEquals(1, results.count { it.first is EnqueueResult.SavedLocally }); assertEquals(1, results.count { it.first is EnqueueResult.CorrelationConflict })
        val winner = results.single { it.first is EnqueueResult.SavedLocally }.second
        assertArrayEquals(winner, File(base, "vox-captures/$ID/request.json").readBytes())
    }

    @Test fun journalBindingDetectsRequestOrAssetReplacementBeforeIndexing() {
        val base = Files.createTempDirectory("capture-binding").toFile(); val store = DurableCapturePackageStore(base, MemoryIndex(), JvmOps())
        assertTrue(store.enqueue(request(), 10) is EnqueueResult.SavedLocally)
        File(base, "vox-captures/$ID/request.json").writeBytes(changedRequest())
        assertEquals(EnqueueResult.ExistingPackageCorrupt(ID, "journalBindingMismatch"), store.enqueue(changedRequest(), 10))
    }

    @Test fun atomicUnsupportedAndUnsafeRootFailClosed() {
        val base = Files.createTempDirectory("capture-atomic").toFile()
        assertEquals(EnqueueResult.DurabilityFailure(ID, "atomicPromotionUnsupported"), DurableCapturePackageStore(base, MemoryIndex(), JvmOps(atomicUnsupported = true)).enqueue(request(), 10))
        val outside = Files.createTempDirectory("outside"); val unsafeBase = Files.createTempDirectory("unsafe-base").toFile(); val root = File(unsafeBase, "vox-captures")
        try { Files.createSymbolicLink(root.toPath(), outside) } catch (_: UnsupportedOperationException) { return }
        assertTrue(DurableCapturePackageStore(unsafeBase, MemoryIndex(), JvmOps()).enqueue(request(), 10) is EnqueueResult.DurabilityFailure)
    }

    @Test fun reconciliationCoversTemporaryCorruptIndexStatesAndExceptions() {
        val base = Files.createTempDirectory("capture-reconcile").toFile(); val original = MemoryIndex()
        assertTrue(DurableCapturePackageStore(base, original, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        val captures = File(base, "vox-captures")
        val safeTemp = File(captures, ".tmp-$ID-22222222-2222-4222-8222-222222222222"); safeTemp.mkdir(); File(safeTemp, "request.json").writeText("partial")
        val suspicious = File(captures, ".tmp-suspicious"); suspicious.mkdir()
        File(captures, "unexpected-root-entry").writeText("synthetic")
        val repaired = MemoryIndex(); var results = DurableCapturePackageStore(base, repaired, JvmOps()).reconcile()
        assertTrue(results.any { it is ReconciliationResult.IndexedPackage }); assertTrue(results.any { it is ReconciliationResult.TemporaryPackageDeleted }); assertTrue(results.any { it is ReconciliationResult.SuspiciousTemporaryPackage })
        assertTrue(results.any { it is ReconciliationResult.CorruptPackage && it.coarseCode == "unexpectedRootEntry" })
        assertFalse(safeTemp.exists()); assertTrue(suspicious.exists())
        repaired.rows[ID] = repaired.rows.getValue(ID).copy(journalRevision = -1); assertTrue(DurableCapturePackageStore(base, repaired, JvmOps()).reconcile().any { it is ReconciliationResult.IndexedPackage })
        assertTrue(DurableCapturePackageStore(base, repaired, JvmOps()).reconcile().any { it is ReconciliationResult.ProjectionCurrent })
        repaired.rows[ID] = repaired.rows.getValue(ID).copy(journalRevision = 9); assertTrue(DurableCapturePackageStore(base, repaired, JvmOps()).reconcile().any { it is ReconciliationResult.ProjectionAhead })
        repaired.rows[ID] = repaired.rows.getValue(ID).copy(journalRevision = 0, state = CaptureState.PREPARING, updatedAtEpochMillis = 10); assertTrue(DurableCapturePackageStore(base, repaired, JvmOps()).reconcile().any { it is ReconciliationResult.ProjectionConflict })
        assertTrue(DurableCapturePackageStore(base, MemoryIndex(failWrites = true), JvmOps()).reconcile().any { it is ReconciliationResult.IndexFailure })
        assertTrue(DurableCapturePackageStore(base, MemoryIndex(failReads = true), JvmOps()).reconcile().any { it is ReconciliationResult.IndexFailure })
        File(captures, "$ID/delivery-journal.json").writeText("{\n")
        val corruptResults = DurableCapturePackageStore(base, repaired, JvmOps()).reconcile()
        assertTrue(corruptResults.any { it is ReconciliationResult.CorruptPackage && it.requestID == ID })
        assertFalse(corruptResults.any { it is ReconciliationResult.MissingPackage && it.requestID == ID })
    }

    private fun request() = resource("contracts/v1/fixtures/capture-preparation-input/valid-android-m3-text-link.json")
    private fun changedRequest() = request().toString(Charsets.UTF_8).replace("Synthetic capture text.", "Different capture text.").toByteArray()
    private fun resource(path: String) = checkNotNull(javaClass.classLoader!!.getResourceAsStream(path)).use { it.readBytes() }

    private class MemoryIndex(private val failWrites: Boolean = false, private val failReads: Boolean = false) : CaptureIndex {
        val rows = linkedMapOf<String, CaptureIndexProjection>()
        override fun read(requestID: String) = rows[requestID]
        override fun all(): List<CaptureIndexProjection> { if (failReads) error("injected"); return rows.values.toList() }
        @Synchronized override fun insertOrRepair(projection: CaptureIndexProjection): IndexWriteResult {
            if (failWrites) error("injected"); val old = rows[projection.requestID]
            if (old == null) { rows[projection.requestID] = projection; return IndexWriteResult.INSERTED }
            if (old.packageVersion != projection.packageVersion || old.journalVersion != projection.journalVersion || old.createdAtEpochMillis != projection.createdAtEpochMillis) return IndexWriteResult.CONFLICT
            if (old.journalRevision > projection.journalRevision) return IndexWriteResult.PROJECTION_AHEAD
            if (old.journalRevision == projection.journalRevision) return if (old == projection) IndexWriteResult.IDENTICAL else IndexWriteResult.CONFLICT
            rows[projection.requestID] = projection; return IndexWriteResult.REPAIRED_OLDER
        }
    }

    private class JvmOps(private val failAt: String? = null, private val atomicUnsupported: Boolean = false, private val barrier: CyclicBarrier? = null) : DurableFileOps {
        val seen = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun checkpoint(name: String) { seen += name; if (name == "afterTempDirectorySync") barrier?.await(); if (name == failAt) error("injected") }
        override fun ensureDirectory(directory: File) { if (!exists(directory) && !directory.mkdir() && !exists(directory)) error("mkdir"); if (!isDirectoryNoFollow(directory) || isSymlink(directory)) error("dir") }
        override fun createDirectory(directory: File) { if (!directory.mkdir()) error("mkdir") }
        override fun writeFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit) { val out = FileOutputStream(file); try { checkpoint("beforeWrite"); out.write(bytes); checkpoint("afterWrite"); checkpoint("beforeFlush"); out.flush(); checkpoint("afterFlush"); checkpoint("beforeFileSync"); out.fd.sync(); checkpoint("afterFileSync"); checkpoint("beforeClose"); out.close(); checkpoint("afterClose") } finally { runCatching { out.close() } } }
        override fun readBounded(file: File, maximumBytes: Int): ByteArray { if (!isRegularFileNoFollow(file) || length(file) !in 1..maximumBytes.toLong()) error("bounds"); return file.readBytes() }
        override fun syncDirectory(directory: File) { if (!isDirectoryNoFollow(directory)) error("dir") }
        override fun <T> withPromotionLock(root: File, action: () -> T): T = locks.computeIfAbsent(root.absolutePath) { ReentrantLock() }.withLock {
            RandomAccessFile(File(root, ".promotion.lock"), "rw").use { file -> file.channel.lock().use { action() } }
        }
        override fun promoteDirectoryNoReplace(source: File, target: File) { if (atomicUnsupported) throw AtomicMoveNotSupportedException(source.path, target.path, "injected"); if (exists(target)) throw FileAlreadyExistsException(target.path); Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE) }
        override fun list(directory: File) = directory.listFiles()?.toList() ?: error("list")
        override fun exists(file: File) = Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)
        override fun isDirectoryNoFollow(file: File) = Files.isDirectory(file.toPath(), LinkOption.NOFOLLOW_LINKS)
        override fun isRegularFileNoFollow(file: File) = Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)
        override fun isSymlink(file: File) = Files.isSymbolicLink(file.toPath())
        override fun length(file: File) = Files.size(file.toPath())
        override fun deleteOwnedTemporary(directory: File) { Files.walk(directory.toPath()).use { it.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists) } }
        companion object { val locks = ConcurrentHashMap<String, ReentrantLock>() }
    }
    companion object { const val ID = "11111111-1111-4111-8111-111111111111" }
}
