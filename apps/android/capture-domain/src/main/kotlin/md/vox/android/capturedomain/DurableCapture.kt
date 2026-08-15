package md.vox.android.capturedomain

/** Framework-free semantic state. Filesystem staging is not a semantic state. */
enum class CaptureState {
    QUEUED,
    PREPARING,
    MATERIALIZED,
    COMMITTING,
    RETRYABLE_FAILURE,
    NEEDS_PERMISSION,
    NEEDS_USER_ACTION,
    UNKNOWN_OUTCOME,
    COMPLETED,
    PERMANENT_FAILURE,
    DISCARDED,
}

enum class JournalCode {
    ENQUEUED,
    PREPARATION_STARTED,
    MATERIALIZED,
    COMMIT_STARTED,
    RETRYABLE_FAILURE,
    PROVED_NOT_COMMITTED,
    PERMISSION_LOST,
    PERMISSION_RESTORED,
    USER_ACTION_REQUIRED,
    PERMANENT_FAILURE,
    COMMIT_AMBIGUOUS,
    VERIFIED_COMMITTED,
    USER_DISCARDED,
}

data class JournalEvent(
    val revision: Int,
    val fromState: CaptureState?,
    val state: CaptureState,
    val code: JournalCode,
    val occurredAtEpochMillis: Long,
    val resumeState: CaptureState? = null,
    val receiptID: String? = null,
)

data class JournalSnapshot(
    val requestID: String,
    val revision: Int,
    val state: CaptureState,
    val resumeState: CaptureState?,
    val events: List<JournalEvent>,
)

sealed interface JournalReduction {
    data class Accepted(val snapshot: JournalSnapshot) : JournalReduction
    data class Rejected(val reason: String) : JournalReduction
}

/** Pure reducer. It owns transition legality, not storage or scheduling. */
object CaptureJournalReducer {
    private val terminal = setOf(CaptureState.COMPLETED, CaptureState.PERMANENT_FAILURE, CaptureState.DISCARDED)

    fun reduce(requestID: String, prior: JournalSnapshot?, event: JournalEvent): JournalReduction {
        if (event.revision !in 0..1023) return JournalReduction.Rejected("revisionOutOfBounds")
        if (event.occurredAtEpochMillis < 0) return JournalReduction.Rejected("timestampOutOfBounds")
        if (prior == null) {
            if (event.revision != 0 || event.fromState != null || event.state != CaptureState.QUEUED ||
                event.code != JournalCode.ENQUEUED || event.resumeState != null || event.receiptID != null
            ) return JournalReduction.Rejected("invalidInitialEvent")
            return JournalReduction.Accepted(JournalSnapshot(requestID, 0, CaptureState.QUEUED, null, listOf(event)))
        }
        if (prior.state in terminal) return JournalReduction.Rejected("terminalState")
        if (event.revision != prior.revision + 1 || event.fromState != prior.state) {
            return JournalReduction.Rejected("frontierMismatch")
        }
        val expectedResume = if (event.state == CaptureState.NEEDS_PERMISSION) {
            if (prior.state == CaptureState.UNKNOWN_OUTCOME) CaptureState.COMMITTING else prior.state
        } else null
        if (event.resumeState != expectedResume) return JournalReduction.Rejected("resumeFrontierMismatch")
        if (prior.state == CaptureState.NEEDS_PERMISSION && event.state != CaptureState.DISCARDED &&
            (event.code != JournalCode.PERMISSION_RESTORED || event.state != prior.resumeState)
        ) return JournalReduction.Rejected("permissionResumeMismatch")
        if (!legal(prior.state, event.state, event.code)) return JournalReduction.Rejected("illegalTransition")
        if (event.state == CaptureState.COMPLETED) {
            if (event.code != JournalCode.VERIFIED_COMMITTED || event.receiptID == null) {
                return JournalReduction.Rejected("missingReceipt")
            }
        } else if (event.receiptID != null) return JournalReduction.Rejected("unexpectedReceipt")
        return JournalReduction.Accepted(
            JournalSnapshot(requestID, event.revision, event.state, event.resumeState, prior.events + event),
        )
    }

    private fun legal(from: CaptureState, to: CaptureState, code: JournalCode): Boolean = when (from) {
        CaptureState.QUEUED -> when (to) {
            CaptureState.PREPARING -> code == JournalCode.PREPARATION_STARTED
            CaptureState.DISCARDED -> code == JournalCode.USER_DISCARDED
            else -> false
        }
        CaptureState.PREPARING -> commonPreCommit(to, code, CaptureState.MATERIALIZED)
        CaptureState.MATERIALIZED -> when (to) {
            CaptureState.PREPARING -> code == JournalCode.PREPARATION_STARTED
            CaptureState.COMMITTING -> code == JournalCode.COMMIT_STARTED
            CaptureState.RETRYABLE_FAILURE -> code == JournalCode.RETRYABLE_FAILURE
            CaptureState.NEEDS_PERMISSION -> code == JournalCode.PERMISSION_LOST
            CaptureState.NEEDS_USER_ACTION -> code == JournalCode.USER_ACTION_REQUIRED
            CaptureState.PERMANENT_FAILURE -> code == JournalCode.PERMANENT_FAILURE
            CaptureState.DISCARDED -> code == JournalCode.USER_DISCARDED
            else -> false
        }
        CaptureState.COMMITTING -> when (to) {
            CaptureState.COMPLETED -> code == JournalCode.VERIFIED_COMMITTED
            CaptureState.RETRYABLE_FAILURE -> code == JournalCode.PROVED_NOT_COMMITTED
            CaptureState.NEEDS_PERMISSION -> code == JournalCode.PERMISSION_LOST
            CaptureState.UNKNOWN_OUTCOME -> code == JournalCode.COMMIT_AMBIGUOUS
            else -> false
        }
        CaptureState.RETRYABLE_FAILURE -> when (to) {
            CaptureState.PREPARING -> code == JournalCode.PREPARATION_STARTED
            CaptureState.DISCARDED -> code == JournalCode.USER_DISCARDED
            else -> false
        }
        CaptureState.NEEDS_PERMISSION -> (to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED) ||
            (to in setOf(CaptureState.PREPARING, CaptureState.MATERIALIZED, CaptureState.COMMITTING) && code == JournalCode.PERMISSION_RESTORED)
        CaptureState.UNKNOWN_OUTCOME -> when (to) {
            CaptureState.COMPLETED -> code == JournalCode.VERIFIED_COMMITTED
            CaptureState.RETRYABLE_FAILURE -> code == JournalCode.PROVED_NOT_COMMITTED
            CaptureState.NEEDS_PERMISSION -> code == JournalCode.PERMISSION_LOST
            CaptureState.DISCARDED -> code == JournalCode.USER_DISCARDED
            else -> false
        }
        CaptureState.NEEDS_USER_ACTION -> to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED
        else -> false
    }

    private fun commonPreCommit(to: CaptureState, code: JournalCode, success: CaptureState): Boolean = when (to) {
        success -> code == JournalCode.MATERIALIZED
        CaptureState.RETRYABLE_FAILURE -> code == JournalCode.RETRYABLE_FAILURE
        CaptureState.NEEDS_PERMISSION -> code == JournalCode.PERMISSION_LOST
        CaptureState.NEEDS_USER_ACTION -> code == JournalCode.USER_ACTION_REQUIRED
        CaptureState.PERMANENT_FAILURE -> code == JournalCode.PERMANENT_FAILURE
        CaptureState.DISCARDED -> code == JournalCode.USER_DISCARDED
        else -> false
    }
}

data class CaptureIndexProjection(
    val requestID: String,
    val packageVersion: Int,
    val journalVersion: Int,
    val journalRevision: Int,
    val state: CaptureState,
    val createdAtEpochMillis: Long,
    val updatedAtEpochMillis: Long,
)

interface CaptureIndex {
    fun read(requestID: String): CaptureIndexProjection?
    fun insertOrRepair(projection: CaptureIndexProjection): IndexWriteResult
    fun all(): List<CaptureIndexProjection>
}

enum class IndexWriteResult { INSERTED, IDENTICAL, REPAIRED_OLDER, PROJECTION_AHEAD, CONFLICT }

sealed interface EnqueueResult {
    data class SavedLocally(val requestID: String) : EnqueueResult
    data class CorrelationConflict(val requestID: String) : EnqueueResult
    data class ExistingPackageCorrupt(val requestID: String, val coarseCode: String) : EnqueueResult
    data class DurabilityFailure(val requestID: String, val coarseCode: String) : EnqueueResult
    data class IndexFailure(val requestID: String, val coarseCode: String) : EnqueueResult
}

sealed interface ReconciliationResult {
    data class IndexedPackage(val requestID: String) : ReconciliationResult
    data class ProjectionCurrent(val requestID: String) : ReconciliationResult
    data class MissingPackage(val requestID: String) : ReconciliationResult
    data class CorruptPackage(val requestID: String, val coarseCode: String) : ReconciliationResult
    data class ProjectionAhead(val requestID: String) : ReconciliationResult
    data class ProjectionConflict(val requestID: String) : ReconciliationResult
    data class TemporaryPackageDeleted(val name: String) : ReconciliationResult
    data class SuspiciousTemporaryPackage(val name: String, val coarseCode: String) : ReconciliationResult
    data class IndexFailure(val requestID: String?, val coarseCode: String) : ReconciliationResult
}
