package md.vox.android.data

import android.system.Os
import android.system.OsConstants
import md.vox.android.capturedomain.*
import java.io.File
import java.io.FileOutputStream
import java.nio.channels.OverlappingFileLockException
import java.nio.file.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

private val JOURNAL_TEMP_PATTERN = Regex("^\\.delivery-journal\\.[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.tmp$")
private val MARKER_TEMP_PATTERN = Regex("^\\.commit-attempt\\.[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\.tmp$")
private val STAGING_TEMP_PATTERN = Regex("^\\.tmp-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

/**
 * Type-level proof that a commit marker was durably persisted (ADR-0023 §3/§4,
 * oracle obligation 3). Only [DurableCaptureStore.persistCommitMarker] constructs it;
 * [SafDocumentsGateway.createDocument] requires it, making provider create unreachable
 * without a durable marker at the type level, complementing source-scan governance.
 */
class DurableMarkerToken internal constructor(
    val requestID: String,
    val planHash: String,
    val recordedAtEpochMillis: Long,
)

/** Streaming staged drain sink for prepared note bytes; verifies and finalizes on close. */
class StagedNoteSink(
    private val store: DurableCapturePackageStore,
    private val requestID: String,
    private val stagingUUID: String,
    private val expectedLength: Long,
    private val expectedSHA256: String,
) {
    private var closed = false

    fun write(chunk: ByteArray) {
        check(!closed) { "sinkClosed" }
        store.writeStagedNoteChunk(requestID, stagingUUID, chunk)
    }

    /** Verifies exact length and SHA-256 of the staged bytes. */
    fun verifyAndClose() {
        check(!closed) { "sinkClosed" }
        closed = true
        store.verifyStagedNote(requestID, stagingUUID, expectedLength, expectedSHA256)
    }
}


interface DurableFileOps {
    fun ensureDirectory(directory: File)
    fun createDirectory(directory: File)
    fun writeFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit)
    fun writeNewFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit)
    fun readBounded(file: File, maximumBytes: Int): ByteArray
    fun syncDirectory(directory: File)
    fun <T> withPromotionLock(root: File, action: () -> T): T
    fun promoteDirectoryNoReplace(source: File, target: File)
    fun replaceFileAtomically(source: File, target: File)
    fun moveFileNoReplaceAtomically(source: File, target: File)
    fun list(directory: File): List<File>
    fun exists(file: File): Boolean
    fun isDirectoryNoFollow(file: File): Boolean
    fun isRegularFileNoFollow(file: File): Boolean
    fun isSymlink(file: File): Boolean
    fun length(file: File): Long
    fun deleteOwnedTemporary(directory: File)
    fun deleteOwnedFile(file: File)
    fun checkpoint(name: String) {}
}

class AndroidDurableFileOps : DurableFileOps {
    override fun ensureDirectory(directory: File) {
        if (!exists(directory) && !directory.mkdir() && !exists(directory)) error("mkdirFailed")
        if (!isDirectoryNoFollow(directory) || isSymlink(directory)) error("notDirectory")
    }
    override fun createDirectory(directory: File) { if (!directory.mkdir() || !isDirectoryNoFollow(directory)) error("mkdirFailed") }
    override fun writeFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit) = writeStream(FileOutputStream(file), bytes, checkpoint)
    override fun writeNewFileDurably(file: File, bytes: ByteArray, checkpoint: (String) -> Unit) {
        val descriptor = Os.open(file.absolutePath, OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_WRONLY or OsConstants.O_NOFOLLOW, 0x180)
        writeStream(FileOutputStream(descriptor), bytes, checkpoint)
    }
    private fun writeStream(stream: FileOutputStream, bytes: ByteArray, checkpoint: (String) -> Unit) {
        var primary: Throwable? = null
        try {
            checkpoint("beforeWrite"); stream.write(bytes); checkpoint("afterWrite")
            checkpoint("beforeFlush"); stream.flush(); checkpoint("afterFlush")
            checkpoint("beforeFileSync"); stream.fd.sync(); checkpoint("afterFileSync")
        } catch (error: Throwable) { primary = error; throw error }
        finally {
            try { checkpoint("beforeClose"); stream.close(); checkpoint("afterClose") }
            catch (close: Throwable) { if (primary == null) throw close else primary.addSuppressed(close) }
        }
    }
    override fun readBounded(file: File, maximumBytes: Int): ByteArray {
        if (!isRegularFileNoFollow(file)) error("invalidFile")
        val size = length(file); if (size !in 1..maximumBytes.toLong()) error("fileBounds")
        file.inputStream().use { input -> val result = ByteArray(size.toInt()); var offset = 0; while (offset < result.size) { val count = input.read(result, offset, result.size - offset); if (count < 0) error("shortRead"); offset += count }; if (input.read() != -1) error("fileGrew"); return result }
    }
    override fun syncDirectory(directory: File) { val descriptor = Os.open(directory.absolutePath, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0); try { Os.fsync(descriptor) } finally { Os.close(descriptor) } }
    override fun <T> withPromotionLock(root: File, action: () -> T): T {
        val path = root.absoluteFile.normalize().path
        return processLocks.computeIfAbsent(path) { ReentrantLock() }.withLock {
            val descriptor = Os.open(
                File(root, ".promotion.lock").absolutePath,
                OsConstants.O_CREAT or OsConstants.O_RDWR or OsConstants.O_NOFOLLOW,
                0x180, // 0600
            )
            try {
                if (!OsConstants.S_ISREG(Os.fstat(descriptor).st_mode)) error("lockNotRegular")
                FileOutputStream(descriptor).use { stream ->
                    val lock = try { stream.channel.lock() } catch (error: OverlappingFileLockException) {
                        throw IllegalStateException("lockUnsupported", error)
                    }
                    lock.use { action() }
                }
            } catch (error: Throwable) {
                runCatching { Os.close(descriptor) }
                throw error
            }
        }
    }
    override fun promoteDirectoryNoReplace(source: File, target: File) {
        // No-replace is supplied by the cooperative app-private lock plus this NOFOLLOW recheck.
        if (Files.exists(target.toPath(), LinkOption.NOFOLLOW_LINKS)) throw FileAlreadyExistsException(target.path)
        Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
    }
    override fun replaceFileAtomically(source: File, target: File) {
        if (!isRegularFileNoFollow(source) || isSymlink(source) || !isRegularFileNoFollow(target) || isSymlink(target)) error("unsafeAtomicReplace")
        Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }
    override fun moveFileNoReplaceAtomically(source: File, target: File) {
        if (!isRegularFileNoFollow(source) || isSymlink(source) || exists(target)) error("unsafeAtomicCreate")
        Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
    }
    override fun list(directory: File): List<File> = directory.listFiles()?.toList() ?: error("listFailed")
    override fun exists(file: File) = Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)
    override fun isDirectoryNoFollow(file: File) = Files.isDirectory(file.toPath(), LinkOption.NOFOLLOW_LINKS)
    override fun isRegularFileNoFollow(file: File) = Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)
    override fun isSymlink(file: File) = Files.isSymbolicLink(file.toPath())
    override fun length(file: File) = Files.size(file.toPath())
    override fun deleteOwnedTemporary(directory: File) { Files.walk(directory.toPath()).use { paths -> paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists) } }
    override fun deleteOwnedFile(file: File) { if (!isRegularFileNoFollow(file) || isSymlink(file)) error("unsafeOwnedFile"); Files.delete(file.toPath()) }
    private companion object { val processLocks = ConcurrentHashMap<String, ReentrantLock>() }
}

class DurableCapturePackageStore(
    private val noBackupFilesDir: File,
    private val index: CaptureIndex,
    private val fileOps: DurableFileOps = AndroidDurableFileOps(),
) {
    private val root = File(noBackupFilesDir, "vox-captures")

    fun enqueue(requestBytes: ByteArray, nowEpochMillis: Long): EnqueueResult {
        val historical = try { CapturePackageCodec.decodeHistoricalRequest(requestBytes) } catch (error: PackageCodecException) {
            return EnqueueResult.DurabilityFailure("unknown", error.coarseCode)
        }
        val requestID = historical.requestID
        if (nowEpochMillis < 0) return EnqueueResult.DurabilityFailure(requestID, "enqueueTimeOutOfBounds")
        val assetsBytes = CapturePackageCodec.encodeAssets(AssetManifest(requestID))
        val finalDirectory = File(root, requestID)
        try {
            if (fileOps.exists(root)) {
                ensureSafeRoot()
                if (fileOps.exists(finalDirectory)) return duplicate(finalDirectory, requestBytes, assetsBytes)
            }
            try { CapturePackageCodec.admitRequest(requestBytes) } catch (error: PackageCodecException) {
                return EnqueueResult.DurabilityFailure(requestID, error.coarseCode)
            }
            ensureSafeRoot()
            if (fileOps.exists(finalDirectory)) return duplicate(finalDirectory, requestBytes, assetsBytes)
            val initial = JournalSnapshot(requestID, 0, CaptureState.QUEUED, null, listOf(JournalEvent(0, null, CaptureState.QUEUED, JournalCode.ENQUEUED, nowEpochMillis)))
            val journalBytes = CapturePackageCodec.encodeJournal(initial, requestBytes, assetsBytes)
            val temporary = File(root, ".tmp-$requestID-${UUID.randomUUID()}")
            phase("beforeTempCreate", "afterTempCreate") { fileOps.createDirectory(temporary) }
            try {
                writeVerified(temporary, "request.json", requestBytes) { CapturePackageCodec.admitRequest(it) }
                writeVerified(temporary, "assets.json", assetsBytes) { CapturePackageCodec.decodeAssets(it) }
                writeVerified(temporary, "delivery-journal.json", journalBytes) { CapturePackageCodec.decodeJournal(it) }
                phase("beforeTempDirectorySync", "afterTempDirectorySync") { fileOps.syncDirectory(temporary) }
                fileOps.checkpoint("beforePromotionLockAcquire")
                val existing = fileOps.withPromotionLock(root) {
                    fileOps.checkpoint("afterPromotionLockAcquire")
                    if (fileOps.exists(finalDirectory)) true else {
                        fileOps.checkpoint("beforePromotion")
                        fileOps.promoteDirectoryNoReplace(temporary, finalDirectory)
                        fileOps.checkpoint("afterPromotion")
                        false
                    }
                }
                fileOps.checkpoint("afterPromotionLockRelease")
                if (existing) { fileOps.deleteOwnedTemporary(temporary); return duplicate(finalDirectory, requestBytes, assetsBytes) }
                phase("beforeCapturesParentSync", "afterCapturesParentSync") { fileOps.syncDirectory(root) }
            } catch (error: Exception) {
                if (fileOps.exists(temporary)) runCatching { fileOps.deleteOwnedTemporary(temporary) }
                throw error
            }
            val verified = validatePackage(finalDirectory)
            val write = indexWrite(verified.projection) ?: return EnqueueResult.IndexFailure(requestID, "indexWriteFailed")
            if (write == IndexWriteResult.PROJECTION_AHEAD || write == IndexWriteResult.CONFLICT) return EnqueueResult.IndexFailure(requestID, "indexConflict")
            fileOps.checkpoint("postIndexPreResult")
            return EnqueueResult.SavedLocally(requestID)
        } catch (_: AtomicMoveNotSupportedException) { return EnqueueResult.DurabilityFailure(requestID, "atomicPromotionUnsupported") }
        catch (error: PackageCodecException) { return EnqueueResult.ExistingPackageCorrupt(requestID, error.coarseCode) }
        catch (_: Exception) { return EnqueueResult.DurabilityFailure(requestID, "durabilityFailure") }
    }

    internal fun mutateJournal(command: JournalMutationCommand, leaseValidator: ((String) -> Boolean)? = null): JournalMutationResult {
        var completed: JournalMutationResult? = null
        return try {
            withRootMutationLock {
                mutateJournalUnderRootLock(command, leaseValidator).also { completed = it }
            }
        } catch (_: Exception) {
            when (completed) {
                is JournalMutationResult.Applied,
                is JournalMutationResult.AlreadyApplied,
                is JournalMutationResult.PersistedIndexPending,
                is JournalMutationResult.DurabilityUncertain,
                -> JournalMutationResult.DurabilityUncertain("journalLockReleaseOutcomeUnknown")
                else -> JournalMutationResult.CoordinationFailure("journalLockFailure")
            }
        }
    }

    /** Caller must hold [withRootMutationLock]; used only by the coordinator for a continuous fence/CAS lock. */
    private fun mutateJournalUnderRootLock(command: JournalMutationCommand, leaseValidator: ((String) -> Boolean)? = null): JournalMutationResult {
        if (!UUID_PATTERN.matches(command.requestID) || command.expectedRevision !in 0..1022 ||
            command.event.revision != command.expectedRevision + 1
        ) return JournalMutationResult.ReducerRejected("commandFrontierMismatch")
        if (command.clearCommitMarker && command.event.code != JournalCode.PROVED_NOT_COMMITTED) return JournalMutationResult.ReducerRejected("commandFrontierMismatch")
        val token = command.leaseToken
        if (command.event.code.requiresWorkerLease() && token == null) return JournalMutationResult.LeaseLost
        if (token != null) {
            if (!UUID_PATTERN.matches(token) || leaseValidator == null) return JournalMutationResult.LeaseLost
            val current = try { leaseValidator(token) } catch (_: Exception) {
                return JournalMutationResult.CoordinationFailure("leaseCheckFailed")
            }
            if (!current) return JournalMutationResult.LeaseLost
        }
        val directory = File(root, command.requestID)
        var replacementAttempted = false
        var canonicalValidated = false
        return try {
            removeOwnedTemps(directory)
            // A MATERIALIZED/COMMIT_STARTED claim is legal only when the authoritative
            // plan-hash directory is already hash-verified on disk (ADR-0023 §1/§7).
            if (command.event.code == JournalCode.MATERIALIZED || command.event.code == JournalCode.COMMIT_STARTED) {
                val hash = command.event.planHash
                if (hash == null || !fileOps.isRegularFileNoFollow(File(File(File(directory, "prepared"), hash), "note.bin"))) {
                    return JournalMutationResult.ReducerRejected("preparedRequired")
                }
            }
            val prior = validatePackage(directory)
            canonicalValidated = true
            val current = prior.snapshot
            if (current.revision == command.event.revision && current.events.last() == command.event) {
                return projectMutation(prior, already = true)
            }
            if (current.revision != command.expectedRevision) return JournalMutationResult.FrontierConflict(current.revision)
            val reduction = CaptureJournalReducer.reduce(command.requestID, current, command.event)
            if (reduction is JournalReduction.Rejected) return JournalMutationResult.ReducerRejected(reduction.reason)
            val next = (reduction as JournalReduction.Accepted).snapshot
            val bytes = CapturePackageCodec.encodeJournal(next, prior.requestBytes, prior.assetsBytes)
            val temporary = File(directory, ".delivery-journal.${UUID.randomUUID()}.tmp")
            fileOps.writeNewFileDurably(temporary, bytes) { phase -> fileOps.checkpoint("$phase:journalReplacement") }
            fileOps.checkpoint("beforeJournalTempReopen")
            val reopened = fileOps.readBounded(temporary, CONTROL_LIMIT_BYTES)
            fileOps.checkpoint("afterJournalTempReopen")
            if (!reopened.contentEquals(bytes) || CapturePackageCodec.sha256(reopened) != CapturePackageCodec.sha256(bytes)) throw PackageCodecException("reopenMismatch")
            val decoded = CapturePackageCodec.decodeJournal(reopened); CapturePackageCodec.verifyBinding(decoded, prior.requestBytes, prior.assetsBytes)
            if (decoded.snapshot != next) throw PackageCodecException("journalReplayMismatch")
            fileOps.checkpoint("beforeJournalReplace")
            replacementAttempted = true
            fileOps.replaceFileAtomically(temporary, File(directory, "delivery-journal.json"))
            fileOps.checkpoint("afterJournalReplace")
            if (command.clearCommitMarker) {
                fileOps.checkpoint("beforeMarkerClear")
                clearCommitMarkerLocked(directory)
                fileOps.checkpoint("afterMarkerClear")
            }
            val verified = validatePackage(directory)
            if (verified.snapshot != next) throw PackageCodecException("journalReplaceMismatch")
            fileOps.checkpoint("beforePackageDirectorySync")
            fileOps.syncDirectory(directory)
            fileOps.checkpoint("afterPackageDirectorySync")
            projectMutation(verified, already = false)
        } catch (_: AtomicMoveNotSupportedException) {
            JournalMutationResult.DurabilityUncertain("atomicReplacementUnsupported")
        } catch (error: PackageCodecException) {
            when {
                replacementAttempted -> JournalMutationResult.DurabilityUncertain(error.coarseCode)
                canonicalValidated -> JournalMutationResult.CoordinationFailure(error.coarseCode)
                else -> JournalMutationResult.PackageCorrupt(error.coarseCode)
            }
        } catch (_: Exception) {
            if (replacementAttempted) JournalMutationResult.DurabilityUncertain("journalReplacementOutcomeUnknown")
            else JournalMutationResult.CoordinationFailure("journalReplacementFailed")
        }
    }

    /** One app-private lock order: root filesystem lock before any Room transaction. */
    internal fun <T> withRootMutationLock(action: () -> T): T {
        ensureSafeRoot()
        fileOps.checkpoint("beforeJournalLockAcquire")
        val result = fileOps.withPromotionLock(root) {
            fileOps.checkpoint("afterJournalLockAcquire")
            action()
        }
        fileOps.checkpoint("afterJournalLockRelease")
        return result
    }

    fun reconcile(): List<ReconciliationResult> {
        val results = mutableListOf<ReconciliationResult>(); val presentPackageIDs = mutableSetOf<String>()
        if (fileOps.exists(root)) {
            if (fileOps.isSymlink(root) || !fileOps.isDirectoryNoFollow(root)) return listOf(ReconciliationResult.CorruptPackage("vox-captures", "unsafeRoot"))
            val entries = try { fileOps.list(root) } catch (_: Exception) { return listOf(ReconciliationResult.CorruptPackage("vox-captures", "listFailed")) }
            entries.filter { it.name == ".promotion.lock" && (!fileOps.isRegularFileNoFollow(it) || fileOps.isSymlink(it)) }
                .forEach { results += ReconciliationResult.CorruptPackage(it.name, "unsafePromotionLock") }
            entries.filter { it.name != ".promotion.lock" && !it.name.startsWith(".tmp-") && !UUID_PATTERN.matches(it.name) }
                .forEach { results += ReconciliationResult.CorruptPackage(it.name, "unexpectedRootEntry") }
            entries.filter { it.name.startsWith(".tmp-") }.forEach { temporary ->
                results += try { fileOps.withPromotionLock(root) { reconcileTemporary(temporary) } } catch (_: Exception) { ReconciliationResult.SuspiciousTemporaryPackage(temporary.name, "temporaryLockFailed") }
            }
            entries.filter { UUID_PATTERN.matches(it.name) }.forEach { directory ->
                presentPackageIDs += directory.name
                val verified = try { fileOps.withPromotionLock(root) { removeOwnedTemps(directory); validatePackage(directory) } } catch (error: Exception) { results += ReconciliationResult.CorruptPackage(directory.name, (error as? PackageCodecException)?.coarseCode ?: "invalidPackage"); return@forEach }
                val write = try { index.insertOrRepair(verified.projection) } catch (_: Exception) { results += ReconciliationResult.IndexFailure(directory.name, "indexWriteFailed"); return@forEach }
                results += when (write) {
                    IndexWriteResult.INSERTED, IndexWriteResult.REPAIRED_OLDER -> ReconciliationResult.IndexedPackage(directory.name)
                    IndexWriteResult.IDENTICAL -> ReconciliationResult.ProjectionCurrent(directory.name)
                    IndexWriteResult.PROJECTION_AHEAD -> ReconciliationResult.ProjectionAhead(directory.name)
                    IndexWriteResult.CONFLICT -> ReconciliationResult.ProjectionConflict(directory.name)
                }
            }
        }
        val rows = try { index.all() } catch (_: Exception) { results += ReconciliationResult.IndexFailure(null, "indexReadFailed"); return results }
        rows.filter { it.requestID !in presentPackageIDs }.forEach { results += ReconciliationResult.MissingPackage(it.requestID) }
        return results
    }

    private fun ensureSafeRoot() {
        if (fileOps.isSymlink(noBackupFilesDir) || !fileOps.isDirectoryNoFollow(noBackupFilesDir)) error("unsafeNoBackupRoot")
        phase("beforeRootEnsure", "afterRootEnsure") { fileOps.ensureDirectory(root) }
        if (fileOps.isSymlink(root) || !fileOps.isDirectoryNoFollow(root)) error("unsafeCaptureRoot")
        phase("beforeRootParentSync", "afterRootParentSync") { fileOps.syncDirectory(noBackupFilesDir) }
    }

    private fun duplicate(directory: File, requestBytes: ByteArray, assetsBytes: ByteArray): EnqueueResult = try {
        fileOps.withPromotionLock(root) { duplicateLocked(directory, requestBytes, assetsBytes) }
    } catch (_: Exception) { EnqueueResult.DurabilityFailure(directory.name, "durabilityFailure") }

    private fun duplicateLocked(directory: File, requestBytes: ByteArray, assetsBytes: ByteArray): EnqueueResult {
        val verified = try { removeOwnedTemps(directory); validatePackage(directory) } catch (error: Exception) { return EnqueueResult.ExistingPackageCorrupt(directory.name, (error as? PackageCodecException)?.coarseCode ?: "invalidPackage") }
        if (!verified.requestBytes.contentEquals(requestBytes) || !verified.assetsBytes.contentEquals(assetsBytes)) return EnqueueResult.CorrelationConflict(directory.name)
        try { phase("beforeDuplicateCapturesParentSync", "afterDuplicateCapturesParentSync") { fileOps.syncDirectory(root) } } catch (_: Exception) { return EnqueueResult.DurabilityFailure(directory.name, "durabilityFailure") }
        val write = indexWrite(verified.projection) ?: return EnqueueResult.IndexFailure(directory.name, "indexWriteFailed")
        if (write !in setOf(IndexWriteResult.INSERTED, IndexWriteResult.IDENTICAL, IndexWriteResult.REPAIRED_OLDER)) return EnqueueResult.IndexFailure(directory.name, "indexConflict")
        fileOps.checkpoint("postIndexPreResult")
        return EnqueueResult.SavedLocally(directory.name)
    }

    private fun projectMutation(verified: VerifiedPackage, already: Boolean): JournalMutationResult {
        val write = indexWrite(verified.projection) ?: return JournalMutationResult.PersistedIndexPending(verified.projection)
        if (write !in setOf(IndexWriteResult.INSERTED, IndexWriteResult.IDENTICAL, IndexWriteResult.REPAIRED_OLDER)) return JournalMutationResult.PersistedIndexPending(verified.projection)
        return if (already) JournalMutationResult.AlreadyApplied(verified.projection) else JournalMutationResult.Applied(verified.projection)
    }

    private fun indexWrite(projection: CaptureIndexProjection): IndexWriteResult? = try { fileOps.checkpoint("beforeIndexCall"); val result = index.insertOrRepair(projection); fileOps.checkpoint("afterIndexCall"); fileOps.checkpoint("afterIndexResult"); result } catch (_: Exception) { null }
    private inline fun phase(before: String, after: String, action: () -> Unit) { fileOps.checkpoint(before); action(); fileOps.checkpoint(after) }

    private fun writeVerified(directory: File, name: String, bytes: ByteArray, validate: (ByteArray) -> Unit) {
        val file = File(directory, name)
        fileOps.writeFileDurably(file, bytes) { phase -> fileOps.checkpoint("$phase:$name") }
        fileOps.checkpoint("beforeReopen:$name"); val reopened = fileOps.readBounded(file, CONTROL_LIMIT_BYTES); fileOps.checkpoint("afterReopen:$name")
        if (!reopened.contentEquals(bytes) || CapturePackageCodec.sha256(reopened) != CapturePackageCodec.sha256(bytes)) throw PackageCodecException("reopenMismatch")
        validate(reopened)
    }

    private fun reconcileTemporary(directory: File): ReconciliationResult {
        val safeName = Regex("^\\.tmp-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(directory.name)
        val safe = try {
            safeName && !fileOps.isSymlink(directory) && fileOps.isDirectoryNoFollow(directory) && fileOps.list(directory).let { children -> children.size <= 3 && children.all { it.name in setOf("request.json", "assets.json", "delivery-journal.json") && !fileOps.isSymlink(it) && fileOps.isRegularFileNoFollow(it) && fileOps.length(it) in 0..CONTROL_LIMIT_BYTES.toLong() } }
        } catch (_: Exception) { false }
        if (!safe) return ReconciliationResult.SuspiciousTemporaryPackage(directory.name, "unsafeTemporary")
        return try { fileOps.deleteOwnedTemporary(directory); ReconciliationResult.TemporaryPackageDeleted(directory.name) } catch (_: Exception) { ReconciliationResult.SuspiciousTemporaryPackage(directory.name, "temporaryDeleteFailed") }
    }

    private fun removeOwnedTemps(directory: File) {
        if (!fileOps.exists(directory)) return
        val entriesHere = fileOps.list(directory)
        val journalTemps = entriesHere.filter { JOURNAL_TEMP_PATTERN.matches(it.name) }
        if (journalTemps.size > 1) throw PackageCodecException("journalTempInventory")
        val markerTemps = entriesHere.filter { MARKER_TEMP_PATTERN.matches(it.name) }
        if (markerTemps.size > 1) throw PackageCodecException("markerTempInventory")
        for (temporary in journalTemps + markerTemps) {
            if (fileOps.isSymlink(temporary) || !fileOps.isRegularFileNoFollow(temporary) || fileOps.length(temporary) !in 0..CONTROL_LIMIT_BYTES.toLong()) throw PackageCodecException("unsafeJournalTemp")
            fileOps.checkpoint("beforeJournalTempDelete"); fileOps.deleteOwnedFile(temporary); fileOps.checkpoint("afterJournalTempDelete")
        }
        // Provably-incomplete staged drains (crashed before promotion) are deleted here;
        // a verified plan-hash directory is never touched (ADR-0023 §1 deletion rule).
        val preparedRoot = entriesHere.firstOrNull { it.name == "prepared" }
        if (preparedRoot != null && fileOps.isDirectoryNoFollow(preparedRoot) && !fileOps.isSymlink(preparedRoot)) {
            for (staging in fileOps.list(preparedRoot).filter { STAGING_TEMP_PATTERN.matches(it.name) }) {
                if (fileOps.isSymlink(staging) || !fileOps.isDirectoryNoFollow(staging)) throw PackageCodecException("preparedInventory")
                val children = fileOps.list(staging)
                if (children.any { it.name != "note.bin" || fileOps.isSymlink(it) || !fileOps.isRegularFileNoFollow(it) }) throw PackageCodecException("preparedInventory")
                fileOps.checkpoint("beforeStagingCleanup"); fileOps.deleteOwnedTemporary(staging); fileOps.checkpoint("afterStagingCleanup")
            }
            fileOps.syncDirectory(preparedRoot)
        }
        if (journalTemps.isNotEmpty() || markerTemps.isNotEmpty()) fileOps.syncDirectory(directory)
    }

    private data class VerifiedPackage(val requestBytes: ByteArray, val assetsBytes: ByteArray, val snapshot: JournalSnapshot, val projection: CaptureIndexProjection)

    /**
     * State-gated package entry inventory (ADR-0023 §7). Base entries are always
     * mandatory; observations/prepared/marker/receipts are gated by the journal's
     * semantic state. Unknown entries, symlinks, and bound violations stay corrupt.
     */
    private fun validatePackage(directory: File): VerifiedPackage {
        if (fileOps.isSymlink(directory) || !fileOps.isDirectoryNoFollow(directory) || !UUID_PATTERN.matches(directory.name)) throw PackageCodecException("packagePath")
        val entries = fileOps.list(directory)
        if (entries.any(fileOps::isSymlink)) throw PackageCodecException("entryInventory")
        val names = entries.map { it.name }.toSet()
        for (required in listOf("assets.json", "delivery-journal.json", "request.json")) {
            if (required !in names) throw PackageCodecException("entryInventory")
        }
        val request = fileOps.readBounded(File(directory, "request.json"), CONTROL_LIMIT_BYTES)
        val assets = fileOps.readBounded(File(directory, "assets.json"), CONTROL_LIMIT_BYTES)
        val journal = fileOps.readBounded(File(directory, "delivery-journal.json"), CONTROL_LIMIT_BYTES)
        if (request.size.toLong() + assets.size + journal.size > AGGREGATE_LIMIT_BYTES) throw PackageCodecException("aggregateBounds")
        val admitted = CapturePackageCodec.decodeHistoricalRequest(request)
        val assetManifest = CapturePackageCodec.decodeAssets(assets)
        val decoded = CapturePackageCodec.decodeJournal(journal)
        CapturePackageCodec.verifyBinding(decoded, request, assets)
        val snapshot = decoded.snapshot
        if (admitted.requestID != directory.name || assetManifest.requestID != directory.name || snapshot.requestID != directory.name) throw PackageCodecException("correlation")

        // State-gated optional entries (ADR-0023 §7).
        val extra = names - setOf("assets.json", "delivery-journal.json", "request.json")
        val observationsDir = entries.firstOrNull { it.name == "observations" }
        val preparedDir = entries.firstOrNull { it.name == "prepared" }
        val receiptsDir = entries.firstOrNull { it.name == "receipts" }
        val markerFile = entries.firstOrNull { it.name == "commit-attempt.json" }
        val unexpected = extra - setOf("observations", "prepared", "receipts", "commit-attempt.json")
        if (unexpected.isNotEmpty()) throw PackageCodecException("entryInventory")

        val attempts = mutableMapOf<String, Int>()
        if (observationsDir != null) {
            if (!fileOps.isDirectoryNoFollow(observationsDir)) throw PackageCodecException("observationsEntry")
            val files = fileOps.list(observationsDir)
            if (files.size > MAX_OBSERVATION_ATTEMPTS || files.any { fileOps.isSymlink(it) || !fileOps.isRegularFileNoFollow(it) }) throw PackageCodecException("observationsInventory")
            for (file in files) {
                val attempt = ObservationAttempt.fromFileName(file.name) ?: throw PackageCodecException("observationsInventory")
                if (fileOps.length(file) !in 1..CONTROL_LIMIT_BYTES.toLong()) throw PackageCodecException("observationsInventory")
                attempts[attempt.requestID] = (attempts[attempt.requestID] ?: 0) + 1
            }
            if (attempts.keys != setOf(directory.name)) throw PackageCodecException("observationsInventory")
        }
        var preparedVerified = false
        if (preparedDir != null) {
            if (!fileOps.isDirectoryNoFollow(preparedDir)) throw PackageCodecException("preparedEntry")
            val entriesInPrepared = fileOps.list(preparedDir)
            // At most one provably-incomplete staging dir is tolerated (never counted as a
            // plan); deletion happens in the mutation/reconciliation cleanup pass.
            val stagingDirs = entriesInPrepared.filter { STAGING_TEMP_PATTERN.matches(it.name) }
            if (stagingDirs.size > 1) throw PackageCodecException("preparedInventory")
            stagingDirs.forEach { staging ->
                if (fileOps.isSymlink(staging) || !fileOps.isDirectoryNoFollow(staging)) throw PackageCodecException("preparedInventory")
                val children = fileOps.list(staging)
                if (children.any { it.name != "note.bin" || fileOps.isSymlink(it) || !fileOps.isRegularFileNoFollow(it) }) throw PackageCodecException("preparedInventory")
            }
            val planDirs = entriesInPrepared.filter { !STAGING_TEMP_PATTERN.matches(it.name) }
            if (planDirs.size > MAX_PREPARED_PLAN_DIRECTORIES || planDirs.any { fileOps.isSymlink(it) || !fileOps.isDirectoryNoFollow(it) }) throw PackageCodecException("preparedInventory")
            for (planDir in planDirs) {
                if (!SHA_PATTERN.matches(planDir.name)) throw PackageCodecException("preparedInventory")
                val children = fileOps.list(planDir)
                if (children.map { it.name }.sorted() != listOf("artifact-plan.json", "note.bin") || children.any { fileOps.isSymlink(it) || !fileOps.isRegularFileNoFollow(it) }) throw PackageCodecException("preparedInventory")
                val planBytes = fileOps.readBounded(File(planDir, "artifact-plan.json"), CONTROL_LIMIT_BYTES)
                if (PreparedPlanVerifier.verifiedPlanHash(planBytes) != planDir.name) throw PackageCodecException("preparedPlanHash")
                if (fileOps.length(File(planDir, "note.bin")) !in 0..MAX_PREPARED_NOTE_BYTES) throw PackageCodecException("preparedNoteBounds")
            }
            preparedVerified = planDirs.isNotEmpty()
        }
        if (markerFile != null) {
            if (!fileOps.isRegularFileNoFollow(markerFile) || fileOps.length(markerFile) !in 1..CONTROL_LIMIT_BYTES.toLong()) throw PackageCodecException("markerEntry")
        }
        if (receiptsDir != null) {
            if (!fileOps.isDirectoryNoFollow(receiptsDir)) throw PackageCodecException("receiptsEntry")
            val files = fileOps.list(receiptsDir)
            if (files.size > MAX_RECEIPTS || files.any { fileOps.isSymlink(it) || !fileOps.isRegularFileNoFollow(it) || !UUID_PATTERN.matches(it.name.removeSuffix(".json")) || it.name.endsWith(".json").not() || fileOps.length(it) !in 1..CONTROL_LIMIT_BYTES.toLong() }) throw PackageCodecException("receiptsInventory")
        }

        val markerState = markerFile?.let {
            try { CapturePackageCodec.decodeMarker(fileOps.readBounded(it, CONTROL_LIMIT_BYTES)).state } catch (_: Exception) { throw PackageCodecException("markerEntry") }
        }
        when (snapshot.state) {
            CaptureState.QUEUED -> if (observationsDir != null || preparedDir != null || markerFile != null || receiptsDir != null) throw PackageCodecException("entryInventory")
            CaptureState.PREPARING -> if (markerFile != null || receiptsDir != null) throw PackageCodecException("entryInventory")
            CaptureState.RETRYABLE_FAILURE, CaptureState.NEEDS_USER_ACTION -> {
                if (receiptsDir != null) throw PackageCodecException("entryInventory")
                // Only a CLEARED marker (proof of non-commit already recorded) may exist here.
                if (markerFile != null && markerState != CommitMarker.MarkerState.CLEARED) throw PackageCodecException("markerState")
            }
            CaptureState.MATERIALIZED -> if (!preparedVerified || markerFile != null || receiptsDir != null) throw PackageCodecException("preparedRequired")
            CaptureState.COMMITTING, CaptureState.UNKNOWN_OUTCOME -> {
                if (!preparedVerified) throw PackageCodecException("preparedRequired")
                // receipts/ is optional here: the verified-receipt→journal-append replay window.
            }
            CaptureState.NEEDS_PERMISSION -> if (receiptsDir != null) throw PackageCodecException("entryInventory")
            CaptureState.COMPLETED -> if (!preparedVerified || receiptsDir == null || receiptsDir.let { dir -> fileOps.list(dir).isEmpty() }) throw PackageCodecException("receiptsRequired")
            CaptureState.PERMANENT_FAILURE, CaptureState.DISCARDED -> Unit
        }
        if (snapshot.state == CaptureState.MATERIALIZED || snapshot.state == CaptureState.COMMITTING || snapshot.state == CaptureState.UNKNOWN_OUTCOME || snapshot.state == CaptureState.COMPLETED) {
            val planHash = snapshot.events.lastOrNull { it.code == JournalCode.MATERIALIZED }?.planHash ?: throw PackageCodecException("planHashBinding")
            if (!SHA_PATTERN.matches(planHash)) throw PackageCodecException("planHashBinding")
            if (preparedDir == null || fileOps.list(preparedDir).none { it.name == planHash }) throw PackageCodecException("planHashPreparedDirectory")
        }
        if (snapshot.state == CaptureState.COMPLETED) {
            val receiptID = snapshot.events.last().receiptID ?: throw PackageCodecException("correlation")
            if (receiptsDir == null || fileOps.list(receiptsDir).none { it.name == "$receiptID.json" }) throw PackageCodecException("receiptsRequired")
        }

        val attemptsCount = snapshot.events.count { it.code == JournalCode.PREPARATION_STARTED }
        return VerifiedPackage(request, assets, snapshot, CaptureIndexProjection(directory.name, decoded.binding.packageVersion, 1, snapshot.revision, snapshot.state, admitted.createdAtEpochMillis, snapshot.events.last().occurredAtEpochMillis, attemptsCount))
    }

    // ---- ADR-0023 Phase 5 persistence APIs (all under the package root lock) ----

    /** Loads the current journal snapshot without mutation. */
    fun loadJournal(requestID: String): JournalSnapshot? = try {
        validatePackage(File(root, requestID)).snapshot
    } catch (_: Exception) { null }

    /** Loads the durable request envelope bytes. */
    fun loadRequestBytes(requestID: String): ByteArray? = try {
        validatePackage(File(root, requestID)).requestBytes
    } catch (_: Exception) { null }

    /** Persists the immutable per-attempt observation snapshot (ADR-0018 layout). */
    fun persistObservationSnapshot(requestID: String, attempt: ObservationAttempt, bytes: ByteArray) {
        if (attempt.requestID != requestID || bytes.isEmpty() || bytes.size > CONTROL_LIMIT_BYTES) throw PackageCodecException("observationBounds")
        withRootMutationLock {
            val directory = File(root, requestID)
            val verified = validatePackage(directory)
            if (verified.snapshot.state !in setOf(CaptureState.PREPARING, CaptureState.RETRYABLE_FAILURE)) throw PackageCodecException("observationState")
            val observations = File(directory, "observations")
            if (!fileOps.exists(observations)) { fileOps.createDirectory(observations); fileOps.syncDirectory(directory) }
            val target = File(observations, attempt.fileName)
            if (fileOps.exists(target)) throw PackageCodecException("observationAttemptExists")
            fileOps.writeNewFileDurably(target, bytes) { phase -> fileOps.checkpoint("$phase:observation:${attempt.fileName}") }
            fileOps.syncDirectory(observations)
        }
    }

    /**
     * Opens a same-parent staged drain under prepared/.tmp-<stagingUUID>/note.bin. The
     * staged bytes are promoted into the plan-hash-named directory only after finalize
     * returns the plan, so note.bin is written once at its final governed name.
     */
    fun openStagedNoteSink(requestID: String, stagingUUID: String, expectedLength: Long, expectedSHA256: String): StagedNoteSink {
        if (!UUID_PATTERN.matches(stagingUUID) || !SHA_PATTERN.matches(expectedSHA256) || expectedLength !in 0..MAX_PREPARED_NOTE_BYTES) throw PackageCodecException("preparedNoteBounds")
        withRootMutationLock {
            val directory = File(root, requestID)
            val verified = validatePackage(directory)
            if (verified.snapshot.state !in setOf(CaptureState.PREPARING, CaptureState.RETRYABLE_FAILURE)) throw PackageCodecException("stagingState")
            val preparedRoot = File(directory, "prepared")
            if (!fileOps.exists(preparedRoot)) { fileOps.createDirectory(preparedRoot); fileOps.syncDirectory(directory) }
            val staging = File(preparedRoot, ".tmp-$stagingUUID")
            if (fileOps.exists(staging)) throw PackageCodecException("stagingExists")
            fileOps.createDirectory(staging)
            fileOps.syncDirectory(preparedRoot)
        }
        return StagedNoteSink(this, requestID, stagingUUID, expectedLength, expectedSHA256)
    }

    internal fun writeStagedNoteChunk(requestID: String, stagingUUID: String, chunk: ByteArray) {
        withRootMutationLock {
            val note = stagedNoteFile(requestID, stagingUUID)
            val current = if (fileOps.exists(note)) fileOps.readBounded(note, MAX_PREPARED_NOTE_BYTES.toInt()) else ByteArray(0)
            if (current.size.toLong() + chunk.size > MAX_PREPARED_NOTE_BYTES) throw PackageCodecException("preparedNoteBounds")
            fileOps.writeFileDurably(note, current + chunk) { phase -> fileOps.checkpoint("$phase:stagedNote:$stagingUUID") }
        }
    }

    internal fun verifyStagedNote(requestID: String, stagingUUID: String, expectedLength: Long, expectedSHA256: String) {
        withRootMutationLock {
            val note = stagedNoteFile(requestID, stagingUUID)
            if (!fileOps.isRegularFileNoFollow(note)) throw PackageCodecException("preparedNoteMissing")
            if (fileOps.length(note) != expectedLength) throw PackageCodecException("preparedNoteLength")
            val bytes = fileOps.readBounded(note, MAX_PREPARED_NOTE_BYTES.toInt())
            if (CapturePackageCodec.sha256(bytes) != expectedSHA256) throw PackageCodecException("preparedNoteHash")
        }
    }

    /**
     * Promotes staged note bytes into prepared/<plan-hash>/ (append-only): durably writes
     * artifact-plan.json, atomically moves the staged note.bin, fsyncs, and removes the
     * staging directory. Fails closed if the plan directory already exists.
     */
    fun promotePreparedArtifacts(requestID: String, planHash: String, planBytes: ByteArray, stagingUUID: String) {
        if (!SHA_PATTERN.matches(planHash) || planBytes.isEmpty() || planBytes.size > CONTROL_LIMIT_BYTES || !UUID_PATTERN.matches(stagingUUID)) throw PackageCodecException("preparedPlanBounds")
        withRootMutationLock {
            val directory = File(root, requestID)
            validatePackage(directory)
            val preparedRoot = File(directory, "prepared")
            val staging = File(preparedRoot, ".tmp-$stagingUUID")
            val stagedNote = File(staging, "note.bin")
            if (!fileOps.isRegularFileNoFollow(stagedNote)) throw PackageCodecException("stagedNoteMissing")
            val planDir = File(preparedRoot, planHash)
            if (fileOps.exists(planDir)) throw PackageCodecException("preparedPlanExists")
            if (fileOps.list(preparedRoot).size >= MAX_PREPARED_PLAN_DIRECTORIES + 1) throw PackageCodecException("preparedInventory")
            fileOps.createDirectory(planDir)
            fileOps.writeNewFileDurably(File(planDir, "artifact-plan.json"), planBytes) { phase -> fileOps.checkpoint("$phase:plan:$planHash") }
            val reopened = fileOps.readBounded(File(planDir, "artifact-plan.json"), CONTROL_LIMIT_BYTES)
            if (!reopened.contentEquals(planBytes) || PreparedPlanVerifier.verifiedPlanHash(reopened) != planHash) throw PackageCodecException("preparedPlanHash")
            fileOps.checkpoint("beforeStagedNoteMove")
            fileOps.moveFileNoReplaceAtomically(stagedNote, File(planDir, "note.bin"))
            fileOps.checkpoint("afterStagedNoteMove")
            fileOps.syncDirectory(planDir)
            fileOps.deleteOwnedTemporary(staging)
            fileOps.syncDirectory(preparedRoot)
        }
    }

    private fun stagedNoteFile(requestID: String, stagingUUID: String): File =
        File(File(File(File(root, requestID), "prepared"), ".tmp-$stagingUUID"), "note.bin")

    /** Verified persisted prepared artifacts for the authoritative plan hash. */
    data class PreparedArtifacts(val planBytes: ByteArray, val noteBytes: ByteArray, val descriptor: PreparedPlanDescriptor)

    /** Loads and verifies persisted prepared artifacts for the authoritative plan hash. */
    fun loadPreparedArtifacts(requestID: String, planHash: String): PreparedArtifacts? = try {
        val loaded = withRootMutationLock {
            val planDir = File(File(File(root, requestID), "prepared"), planHash)
            if (!fileOps.isDirectoryNoFollow(planDir)) return@withRootMutationLock null
            val planBytes = fileOps.readBounded(File(planDir, "artifact-plan.json"), CONTROL_LIMIT_BYTES)
            if (PreparedPlanVerifier.verifiedPlanHash(planBytes) != planHash) return@withRootMutationLock null
            val note = File(planDir, "note.bin")
            if (!fileOps.isRegularFileNoFollow(note)) return@withRootMutationLock null
            val noteBytes = fileOps.readBounded(note, MAX_PREPARED_NOTE_BYTES.toInt())
            Triple(planBytes, noteBytes, PreparedPlanDescriptor(planHash, noteBytes.size.toLong(), CapturePackageCodec.sha256(noteBytes)))
        }
        loaded?.let { (plan, noteBytes, descriptor) -> PreparedArtifacts(plan, noteBytes, descriptor) }
    } catch (_: Exception) { null }

    /** Durably persists the crash-window marker (new-file + fsync + parent fsync) and returns the type-level token. */
    fun persistCommitMarker(requestID: String, marker: CommitMarker): DurableMarkerToken {
        if (marker.state != CommitMarker.MarkerState.ACTIVE) throw PackageCodecException("markerState")
        val bytes = CapturePackageCodec.encodeMarker(marker)
        withRootMutationLock {
            val directory = File(root, requestID)
            val verified = validatePackage(directory)
            if (verified.snapshot.state !in setOf(CaptureState.COMMITTING, CaptureState.UNKNOWN_OUTCOME, CaptureState.NEEDS_PERMISSION)) throw PackageCodecException("markerState")
            val markerFile = File(directory, "commit-attempt.json")
            if (fileOps.exists(markerFile)) {
                val existing = CapturePackageCodec.decodeMarker(fileOps.readBounded(markerFile, CONTROL_LIMIT_BYTES))
                if (existing.state == CommitMarker.MarkerState.ACTIVE) throw PackageCodecException("markerActiveExists")
            }
            fileOps.writeNewFileDurably(markerFile, bytes) { phase -> fileOps.checkpoint("$phase:marker") }
            fileOps.syncDirectory(directory)
        }
        return DurableMarkerToken(requestID, marker.planHash, marker.recordedAtEpochMillis)
    }

    fun readCommitMarker(requestID: String): CommitMarker? = try {
        val markerFile = File(File(root, requestID), "commit-attempt.json")
        if (!fileOps.isRegularFileNoFollow(markerFile)) null
        else CapturePackageCodec.decodeMarker(fileOps.readBounded(markerFile, CONTROL_LIMIT_BYTES))
    } catch (_: Exception) { null }

    /** Replaces the marker with a durable cleared state (temp → fsync → replace → dir fsync) under the root lock. */
    private fun clearCommitMarkerLocked(directory: File) {
        val markerFile = File(directory, "commit-attempt.json")
        if (!fileOps.exists(markerFile)) return
        val current = CapturePackageCodec.decodeMarker(fileOps.readBounded(markerFile, CONTROL_LIMIT_BYTES))
        if (current.state == CommitMarker.MarkerState.CLEARED) return
        val cleared = CommitMarker.validated(CommitMarker.MarkerState.CLEARED, current.destinationID, current.planHash, current.candidateDisplayName, current.recordedAtEpochMillis)
        val bytes = CapturePackageCodec.encodeMarker(cleared)
        val temporary = File(directory, ".commit-attempt.${UUID.randomUUID()}.tmp")
        fileOps.writeNewFileDurably(temporary, bytes) { phase -> fileOps.checkpoint("$phase:markerClear") }
        fileOps.replaceFileAtomically(temporary, markerFile)
        fileOps.syncDirectory(directory)
    }

    /** Append-only verified receipt persistence (ADR-0023 §5). */
    fun persistReceipt(requestID: String, receipt: DeliveryReceipt) {
        if (receipt.requestID != requestID) throw PackageCodecException("receiptCorrelation")
        val bytes = CapturePackageCodec.encodeReceipt(receipt)
        withRootMutationLock {
            val directory = File(root, requestID)
            val verified = validatePackage(directory)
            if (verified.snapshot.state !in setOf(CaptureState.COMMITTING, CaptureState.UNKNOWN_OUTCOME, CaptureState.COMPLETED)) throw PackageCodecException("receiptState")
            val receipts = File(directory, "receipts")
            if (!fileOps.exists(receipts)) { fileOps.createDirectory(receipts); fileOps.syncDirectory(directory) }
            val target = File(receipts, "${receipt.receiptID}.json")
            if (fileOps.exists(target)) {
                val existing = CapturePackageCodec.decodeReceipt(fileOps.readBounded(target, CONTROL_LIMIT_BYTES))
                if (existing != receipt) throw PackageCodecException("receiptConflict")
                return@withRootMutationLock
            }
            if (fileOps.list(receipts).size >= MAX_RECEIPTS) throw PackageCodecException("receiptsInventory")
            fileOps.writeNewFileDurably(target, bytes) { phase -> fileOps.checkpoint("$phase:receipt:${receipt.receiptID}") }
            fileOps.syncDirectory(receipts)
        }
    }

    fun loadReceipt(requestID: String, receiptID: String): DeliveryReceipt? = try {
        val target = File(File(File(root, requestID), "receipts"), "$receiptID.json")
        if (!fileOps.isRegularFileNoFollow(target)) null
        else CapturePackageCodec.decodeReceipt(fileOps.readBounded(target, CONTROL_LIMIT_BYTES))
    } catch (_: Exception) { null }
}
