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
        runThreads(listOf({ results += first.enqueue(a, 10) to a }, { results += second.enqueue(b, 10) to b }))
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

    @Test fun journalMutationIsCasReducerValidatedAndExactlyReplayable() {
        val base = Files.createTempDirectory("journal-cas").toFile(); val index = MemoryIndex(); val store = DurableCapturePackageStore(base, index, JvmOps())
        assertTrue(store.enqueue(request(), 10) is EnqueueResult.SavedLocally)
        val event = JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20)
        val command = JournalMutationCommand(ID, 0, event, TOKEN)
        assertTrue(store.mutateJournal(command) { true } is JournalMutationResult.Applied)
        assertTrue(store.mutateJournal(command) { true } is JournalMutationResult.AlreadyApplied)
        assertEquals(JournalMutationResult.ReducerRejected("commandFrontierMismatch"), store.mutateJournal(command.copy(expectedRevision = 7)) { true })
        assertEquals(1, index.read(ID)!!.attemptCount)
        val conflict = store.mutateJournal(JournalMutationCommand(ID, 0, event.copy(occurredAtEpochMillis = 21), TOKEN)) { true }
        assertEquals(JournalMutationResult.FrontierConflict(1), conflict)
        val illegal = store.mutateJournal(JournalMutationCommand(ID, 1, JournalEvent(2, CaptureState.PREPARING, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 30), TOKEN)) { true }
        assertTrue(illegal is JournalMutationResult.ReducerRejected)
    }

    @Test fun journalReplacementFaultsRestartToExactlyOldOrNewAuthority() {
        val failures = listOf("beforeJournalLockAcquire", "afterJournalLockAcquire", "beforeWrite:journalReplacement", "afterWrite:journalReplacement", "beforeFlush:journalReplacement", "afterFlush:journalReplacement", "beforeFileSync:journalReplacement", "afterFileSync:journalReplacement", "beforeClose:journalReplacement", "afterClose:journalReplacement", "beforeJournalTempReopen", "afterJournalTempReopen", "beforeJournalReplace", "afterJournalReplace", "beforePackageDirectorySync", "afterPackageDirectorySync", "beforeIndexCall", "afterIndexCall", "afterIndexResult", "afterJournalLockRelease")
        failures.forEach { failure ->
            val base = Files.createTempDirectory("journal-fault").toFile(); val index = MemoryIndex()
            assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
            val command = JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), TOKEN)
            val first = DurableCapturePackageStore(base, index, JvmOps(failAt = failure)).mutateJournal(command) { true }
            val expectedType = when (failure) {
                "afterJournalReplace", "beforePackageDirectorySync", "afterPackageDirectorySync", "afterJournalLockRelease" -> JournalMutationResult.DurabilityUncertain::class
                "beforeIndexCall", "afterIndexCall", "afterIndexResult" -> JournalMutationResult.PersistedIndexPending::class
                else -> JournalMutationResult.CoordinationFailure::class
            }
            assertEquals("$failure: $first", expectedType, first::class)
            val retry = DurableCapturePackageStore(base, index, JvmOps()).mutateJournal(command) { true }
            val canonicalWasReplaced = failure in setOf(
                "afterJournalReplace", "beforePackageDirectorySync", "afterPackageDirectorySync",
                "beforeIndexCall", "afterIndexCall", "afterIndexResult", "afterJournalLockRelease",
            )
            if (canonicalWasReplaced) assertTrue("$failure: $retry", retry is JournalMutationResult.AlreadyApplied)
            else assertTrue("$failure: $retry", retry is JournalMutationResult.Applied)
            assertEquals(CaptureState.PREPARING, index.read(ID)!!.state)
        }
    }

    @Test fun journalTempIsNeverAuthorityAndConcurrentCasHasOneWinner() {
        val base = Files.createTempDirectory("journal-race").toFile(); val index = MemoryIndex()
        assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        val packageDir = File(base, "vox-captures/$ID")
        File(packageDir, ".delivery-journal.22222222-2222-4222-8222-222222222222.tmp").writeText("partial")
        val a = DurableCapturePackageStore(base, index, JvmOps()); val b = DurableCapturePackageStore(base, index, JvmOps())
        val results = java.util.Collections.synchronizedList(mutableListOf<JournalMutationResult>())
        runThreads(listOf(
            { results += a.mutateJournal(JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), TOKEN)) { true } },
            { results += b.mutateJournal(JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 21), TOKEN)) { true } },
        ))
        assertEquals(1, results.count { it is JournalMutationResult.Applied })
        assertEquals(1, results.count { it is JournalMutationResult.FrontierConflict })
        assertFalse(packageDir.listFiles()!!.any { it.name.startsWith(".delivery-journal.") })
    }

    @Test fun journalReplacementRequiresFenceWhenCommandCarriesToken() {
        val base = Files.createTempDirectory("journal-fence").toFile(); val index = MemoryIndex(); val store = DurableCapturePackageStore(base, index, JvmOps())
        assertTrue(store.enqueue(request(), 10) is EnqueueResult.SavedLocally)
        val command = JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), TOKEN)
        assertEquals(JournalMutationResult.LeaseLost, store.mutateJournal(command.copy(leaseToken = null)))
        assertEquals(JournalMutationResult.LeaseLost, store.mutateJournal(command))
        assertEquals(JournalMutationResult.LeaseLost, store.mutateJournal(command) { false })
        assertTrue(store.mutateJournal(command) { true } is JournalMutationResult.Applied)
    }

    @Test fun journalTempCleanupAndLeasePersistenceFailuresAreTypedAndRecoverable() {
        val base = Files.createTempDirectory("journal-temp-fault").toFile(); val index = MemoryIndex()
        assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        val directory = File(base, "vox-captures/$ID")
        fun stale(name: String) = File(directory, name).apply { writeText("partial") }
        val command = JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), TOKEN)
        for (failure in listOf("beforeJournalTempDelete", "afterJournalTempDelete")) {
            stale(".delivery-journal.33333333-3333-4333-8333-333333333333.tmp")
            val result = DurableCapturePackageStore(base, index, JvmOps(failAt = failure)).mutateJournal(command) { true }
            assertTrue("$failure: $result", result is JournalMutationResult.CoordinationFailure)
            directory.listFiles()!!.filter { it.name.startsWith(".delivery-journal.") }.forEach { it.delete() }
        }
        stale(".delivery-journal.33333333-3333-4333-8333-333333333333.tmp")
        stale(".delivery-journal.44444444-4444-4444-8444-444444444444.tmp")
        assertTrue(DurableCapturePackageStore(base, index, JvmOps()).mutateJournal(command) { true } is JournalMutationResult.PackageCorrupt)
        directory.listFiles()!!.filter { it.name.startsWith(".delivery-journal.") }.forEach { it.delete() }

        val persistence = MemoryLeasePersistence(throwOnCheckOnce = true)
        val coordinator = CaptureDurabilityCoordinator(DurableCapturePackageStore(base, index, JvmOps()), persistence)
        assertTrue(coordinator.acquire(ID, TOKEN, 0, 1_000) is LeasePlan.Grant)
        assertEquals(JournalMutationResult.CoordinationFailure("leaseCheckFailed"), coordinator.mutate(command, 1))
        assertTrue(coordinator.mutate(command, 1) is JournalMutationResult.Applied)
    }

    @Test fun unsupportedAndMoveThenThrowReplacementRecoverFromCanonicalAuthority() {
        fun command() = JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), TOKEN)
        val unsupportedBase = Files.createTempDirectory("journal-unsupported").toFile(); val unsupportedIndex = MemoryIndex()
        assertTrue(DurableCapturePackageStore(unsupportedBase, unsupportedIndex, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        assertEquals(JournalMutationResult.DurabilityUncertain("atomicReplacementUnsupported"), DurableCapturePackageStore(unsupportedBase, unsupportedIndex, JvmOps(atomicUnsupported = true)).mutateJournal(command()) { true })
        assertTrue(DurableCapturePackageStore(unsupportedBase, unsupportedIndex, JvmOps()).mutateJournal(command()) { true } is JournalMutationResult.Applied)

        val uncertainBase = Files.createTempDirectory("journal-move-throw").toFile(); val uncertainIndex = MemoryIndex()
        assertTrue(DurableCapturePackageStore(uncertainBase, uncertainIndex, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        assertEquals(JournalMutationResult.DurabilityUncertain("journalReplacementOutcomeUnknown"), DurableCapturePackageStore(uncertainBase, uncertainIndex, JvmOps(moveThenThrow = true)).mutateJournal(command()) { true })
        assertTrue(DurableCapturePackageStore(uncertainBase, uncertainIndex, JvmOps()).mutateJournal(command()) { true } is JournalMutationResult.AlreadyApplied)
    }

    @Test fun symlinkAndNonregularJournalTempsFailClosed() {
        fun exercise(symlink: Boolean) {
            val base = Files.createTempDirectory("journal-unsafe-temp").toFile(); val index = MemoryIndex(); val store = DurableCapturePackageStore(base, index, JvmOps())
            assertTrue(store.enqueue(request(), 10) is EnqueueResult.SavedLocally)
            val directory = File(base, "vox-captures/$ID")
            val temporary = File(directory, ".delivery-journal.33333333-3333-4333-8333-333333333333.tmp")
            if (symlink) {
                try { Files.createSymbolicLink(temporary.toPath(), File(directory, "request.json").toPath()) } catch (_: UnsupportedOperationException) { return }
            } else assertTrue(temporary.mkdir())
            val result = store.mutateJournal(JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), TOKEN)) { true }
            assertTrue(result is JournalMutationResult.PackageCorrupt)
            assertTrue(temporary.exists())
        }
        exercise(false); exercise(true)
    }

    @Test fun sharedRootLockPreventsFenceReplacementBetweenCheckAndJournalCommit() {
        val base = Files.createTempDirectory("journal-shared-lock").toFile(); val index = MemoryIndex()
        assertTrue(DurableCapturePackageStore(base, index, JvmOps()).enqueue(request(), 10) is EnqueueResult.SavedLocally)
        val entered = java.util.concurrent.CountDownLatch(1); val resume = java.util.concurrent.CountDownLatch(1)
        val store = DurableCapturePackageStore(base, index, JvmOps(pauseAt = "beforeJournalReplace", pauseEntered = entered, pauseRelease = resume))
        val persistence = MemoryLeasePersistence(); val coordinator = CaptureDurabilityCoordinator(store, persistence)
        assertTrue(coordinator.acquire(ID, TOKEN, 0, 1_000) is LeasePlan.Grant)
        val mutationResults = java.util.Collections.synchronizedList(mutableListOf<JournalMutationResult>())
        val acquireResults = java.util.Collections.synchronizedList(mutableListOf<LeasePlan>())
        val errors = java.util.Collections.synchronizedList(mutableListOf<Throwable>())
        val contenderStarted = java.util.concurrent.CountDownLatch(1); val contenderDone = java.util.concurrent.CountDownLatch(1)
        val mutation = Thread { try { mutationResults += coordinator.mutate(JournalMutationCommand(ID, 0, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 20), TOKEN), 500) } catch (error: Throwable) { errors += error } }
        mutation.start(); assertTrue("mutation never reached replacement", entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
        val contender = Thread { try { contenderStarted.countDown(); acquireResults += coordinator.acquire(ID, "33333333-3333-4333-8333-333333333333", 1_000, 1_000) } catch (error: Throwable) { errors += error } finally { contenderDone.countDown() } }
        contender.start(); assertTrue(contenderStarted.await(5, java.util.concurrent.TimeUnit.SECONDS)); assertFalse("contender bypassed root lock", contenderDone.await(200, java.util.concurrent.TimeUnit.MILLISECONDS))
        resume.countDown()
        mutation.join(10_000); contender.join(10_000)
        assertFalse(mutation.isAlive); assertFalse(contender.isAlive); assertTrue(errors.toString(), errors.isEmpty())
        assertTrue(mutationResults.single() is JournalMutationResult.Applied)
        assertTrue(acquireResults.single() is LeasePlan.Grant)
    }

    private fun runThreads(actions: List<() -> Unit>) {
        val errors = java.util.Collections.synchronizedList(mutableListOf<Throwable>())
        val threads = actions.map { action -> Thread { try { action() } catch (error: Throwable) { errors += error } } }
        threads.forEach(Thread::start)
        threads.forEach { it.join(10_000); assertFalse("worker thread timed out", it.isAlive) }
        if (errors.isNotEmpty()) throw AssertionError("worker thread failed", errors.first())
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

    private class MemoryLeasePersistence(private var throwOnCheckOnce: Boolean = false) : CaptureLeasePersistence {
        private var maximum: Long? = null; private var lease: CaptureLease? = null
        @Synchronized override fun acquire(requestID: String, candidateToken: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan = record(CaptureLeasePlanner.acquire(requestID, candidateToken, nowEpochMillis, durationMillis, maximum, lease))
        @Synchronized override fun renew(requestID: String, token: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan = record(CaptureLeasePlanner.renew(requestID, token, nowEpochMillis, durationMillis, maximum, lease))
        @Synchronized override fun isCurrent(requestID: String, token: String, nowEpochMillis: Long): LeasePlan {
            if (throwOnCheckOnce) { throwOnCheckOnce = false; error("injected lease storage failure") }
            return record(CaptureLeasePlanner.check(requestID, token, nowEpochMillis, maximum, lease))
        }
        @Synchronized override fun release(requestID: String, token: String): Boolean { if (lease?.requestID != requestID || lease?.token != token) return false; lease = null; return true }
        @Synchronized override fun clearExpired(nowEpochMillis: Long): LeaseClearResult { if (maximum != null && nowEpochMillis < maximum!!) return LeaseClearResult.ClockRollback; maximum = maxOf(maximum ?: 0, nowEpochMillis); val cleared = if (lease != null && lease!!.expiresAtEpochMillis <= nowEpochMillis) { lease = null; 1 } else 0; return LeaseClearResult.Cleared(cleared) }
        private fun record(plan: LeasePlan): LeasePlan { when (plan) { is LeasePlan.Grant -> { lease = plan.lease; maximum = plan.newMaximumEpochMillis }; is LeasePlan.Current -> maximum = plan.newMaximumEpochMillis; is LeasePlan.Busy -> maximum = plan.newMaximumEpochMillis; is LeasePlan.Lost -> maximum = plan.newMaximumEpochMillis; else -> Unit }; return plan }
    }

    private class JvmOps(
        private val failAt: String? = null,
        private val atomicUnsupported: Boolean = false,
        private val barrier: CyclicBarrier? = null,
        private val moveThenThrow: Boolean = false,
        private val pauseAt: String? = null,
        private val pauseEntered: java.util.concurrent.CountDownLatch? = null,
        private val pauseRelease: java.util.concurrent.CountDownLatch? = null,
    ) : DurableFileOps {
        val seen = java.util.Collections.synchronizedList(mutableListOf<String>())
        override fun checkpoint(name: String) { seen += name; if (name == "afterTempDirectorySync") barrier?.await(10, java.util.concurrent.TimeUnit.SECONDS); if (name == pauseAt) { pauseEntered?.countDown(); check(pauseRelease?.await(10, java.util.concurrent.TimeUnit.SECONDS) != false) { "pause timeout" } }; if (name == failAt) error("injected") }
        override fun ensureDirectory(directory: File) { if (!exists(directory) && !directory.mkdir() && !exists(directory)) error("mkdir"); if (!isDirectoryNoFollow(directory) || isSymlink(directory)) error("dir") }
        override fun createDirectory(directory: File) { if (!directory.mkdir()) error("mkdir") }
        override fun writeFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit) = write(file, bytes, checkpoint, false)
        override fun writeNewFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit) = write(file, bytes, checkpoint, true)
        private fun write(file: File, bytes: ByteArray, checkpoint: (String) -> Unit, createNew: Boolean) { if (createNew && exists(file)) error("exists"); val out = FileOutputStream(file); try { checkpoint("beforeWrite"); out.write(bytes); checkpoint("afterWrite"); checkpoint("beforeFlush"); out.flush(); checkpoint("afterFlush"); checkpoint("beforeFileSync"); out.fd.sync(); checkpoint("afterFileSync"); checkpoint("beforeClose"); out.close(); checkpoint("afterClose") } finally { runCatching { out.close() } } }
        override fun readBounded(file: File, maximumBytes: Int): ByteArray { if (!isRegularFileNoFollow(file) || length(file) !in 1..maximumBytes.toLong()) error("bounds"); return file.readBytes() }
        override fun syncDirectory(directory: File) { if (!isDirectoryNoFollow(directory)) error("dir") }
        override fun <T> withPromotionLock(root: File, action: () -> T): T = locks.computeIfAbsent(root.absolutePath) { ReentrantLock() }.withLock {
            RandomAccessFile(File(root, ".promotion.lock"), "rw").use { file -> file.channel.lock().use { action() } }
        }
        override fun promoteDirectoryNoReplace(source: File, target: File) { if (atomicUnsupported) throw AtomicMoveNotSupportedException(source.path, target.path, "injected"); if (exists(target)) throw FileAlreadyExistsException(target.path); Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE) }
        override fun replaceFileAtomically(source: File, target: File) { if (atomicUnsupported) throw AtomicMoveNotSupportedException(source.path, target.path, "injected"); if (!isRegularFileNoFollow(source) || !isRegularFileNoFollow(target) || isSymlink(source) || isSymlink(target)) error("unsafe"); Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING); if (moveThenThrow) error("move outcome injected") }
        override fun moveFileNoReplaceAtomically(source: File, target: File) { if (atomicUnsupported) throw AtomicMoveNotSupportedException(source.path, target.path, "injected"); if (!isRegularFileNoFollow(source) || isSymlink(source) || exists(target)) error("unsafe"); Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE) }
        override fun list(directory: File) = directory.listFiles()?.toList() ?: error("list")
        override fun exists(file: File) = Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)
        override fun isDirectoryNoFollow(file: File) = Files.isDirectory(file.toPath(), LinkOption.NOFOLLOW_LINKS)
        override fun isRegularFileNoFollow(file: File) = Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)
        override fun isSymlink(file: File) = Files.isSymbolicLink(file.toPath())
        override fun length(file: File) = Files.size(file.toPath())
        override fun deleteOwnedTemporary(directory: File) { Files.walk(directory.toPath()).use { it.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists) } }
        override fun deleteOwnedFile(file: File) { if (!isRegularFileNoFollow(file) || isSymlink(file)) error("unsafe"); Files.delete(file.toPath()) }
        companion object { val locks = ConcurrentHashMap<String, ReentrantLock>() }
    }
    companion object { const val ID = "11111111-1111-4111-8111-111111111111"; const val TOKEN = "22222222-2222-4222-8222-222222222222" }
}
