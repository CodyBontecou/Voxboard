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
            removeOwnedJournalTemp(directory)
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
                val verified = try { fileOps.withPromotionLock(root) { removeOwnedJournalTemp(directory); validatePackage(directory) } } catch (error: Exception) { results += ReconciliationResult.CorruptPackage(directory.name, (error as? PackageCodecException)?.coarseCode ?: "invalidPackage"); return@forEach }
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
        val verified = try { removeOwnedJournalTemp(directory); validatePackage(directory) } catch (error: Exception) { return EnqueueResult.ExistingPackageCorrupt(directory.name, (error as? PackageCodecException)?.coarseCode ?: "invalidPackage") }
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

    private fun removeOwnedJournalTemp(directory: File) {
        if (!fileOps.exists(directory)) return
        val candidates = fileOps.list(directory).filter { JOURNAL_TEMP_PATTERN.matches(it.name) }
        if (candidates.size > 1) throw PackageCodecException("journalTempInventory")
        val temporary = candidates.singleOrNull() ?: return
        if (fileOps.isSymlink(temporary) || !fileOps.isRegularFileNoFollow(temporary) || fileOps.length(temporary) !in 0..CONTROL_LIMIT_BYTES.toLong()) throw PackageCodecException("unsafeJournalTemp")
        fileOps.checkpoint("beforeJournalTempDelete"); fileOps.deleteOwnedFile(temporary); fileOps.checkpoint("afterJournalTempDelete")
        fileOps.syncDirectory(directory)
    }

    private data class VerifiedPackage(val requestBytes: ByteArray, val assetsBytes: ByteArray, val snapshot: JournalSnapshot, val projection: CaptureIndexProjection)
    private fun validatePackage(directory: File): VerifiedPackage {
        if (fileOps.isSymlink(directory) || !fileOps.isDirectoryNoFollow(directory) || !UUID_PATTERN.matches(directory.name)) throw PackageCodecException("packagePath")
        val entries = fileOps.list(directory)
        if (entries.any(fileOps::isSymlink) || entries.map { it.name }.sorted() != listOf("assets.json", "delivery-journal.json", "request.json")) throw PackageCodecException("entryInventory")
        val request = fileOps.readBounded(File(directory, "request.json"), CONTROL_LIMIT_BYTES); val assets = fileOps.readBounded(File(directory, "assets.json"), CONTROL_LIMIT_BYTES); val journal = fileOps.readBounded(File(directory, "delivery-journal.json"), CONTROL_LIMIT_BYTES)
        if (request.size.toLong() + assets.size + journal.size > AGGREGATE_LIMIT_BYTES) throw PackageCodecException("aggregateBounds")
        val admitted = CapturePackageCodec.decodeHistoricalRequest(request); val assetManifest = CapturePackageCodec.decodeAssets(assets); val decoded = CapturePackageCodec.decodeJournal(journal)
        CapturePackageCodec.verifyBinding(decoded, request, assets)
        val snapshot = decoded.snapshot
        if (admitted.requestID != directory.name || assetManifest.requestID != directory.name || snapshot.requestID != directory.name) throw PackageCodecException("correlation")
        val attempts = snapshot.events.count { it.code == JournalCode.PREPARATION_STARTED }
        return VerifiedPackage(request, assets, snapshot, CaptureIndexProjection(directory.name, decoded.binding.packageVersion, 1, snapshot.revision, snapshot.state, admitted.createdAtEpochMillis, snapshot.events.last().occurredAtEpochMillis, attempts))
    }
}
