package md.vox.android.capturedomain

private val LOWER_UUID = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

/** Revision-CAS command; a worker-owned mutation carries its opaque active fence. */
data class JournalMutationCommand(
    val requestID: String,
    val expectedRevision: Int,
    val event: JournalEvent,
    val leaseToken: String? = null,
    /**
     * ADR-0023 §4 marker lifecycle: appending PROVED_NOT_COMMITTED clears the active
     * commit marker atomically within this journaled mutation window. Any other event
     * code with a non-null value is rejected as a command frontier error.
     */
    val clearCommitMarker: Boolean = false,
)

/** Only direct native user actions may mutate without an active worker fence. */
fun JournalCode.requiresWorkerLease(): Boolean = this !in setOf(JournalCode.USER_DISCARDED, JournalCode.PERMISSION_RESTORED)

sealed interface JournalMutationResult {
    data class Applied(val projection: CaptureIndexProjection) : JournalMutationResult
    data class AlreadyApplied(val projection: CaptureIndexProjection) : JournalMutationResult
    data class FrontierConflict(val actualRevision: Int) : JournalMutationResult
    data class ReducerRejected(val coarseCode: String) : JournalMutationResult
    data object LeaseLost : JournalMutationResult
    data class CoordinationFailure(val coarseCode: String) : JournalMutationResult
    data class DurabilityUncertain(val coarseCode: String) : JournalMutationResult
    data class PersistedIndexPending(val projection: CaptureIndexProjection) : JournalMutationResult
    data class PackageCorrupt(val coarseCode: String) : JournalMutationResult
}

data class CaptureLease(val requestID: String, val token: String, val expiresAtEpochMillis: Long)

/** Every valid non-rollback time observation carries the new persisted maximum. */
sealed interface LeasePlan {
    data class Grant(val lease: CaptureLease, val newMaximumEpochMillis: Long) : LeasePlan
    data class Current(val lease: CaptureLease, val newMaximumEpochMillis: Long) : LeasePlan
    data class Busy(val newMaximumEpochMillis: Long) : LeasePlan
    data class Lost(val newMaximumEpochMillis: Long) : LeasePlan
    data object ClockRollback : LeasePlan
    data object InvalidInput : LeasePlan
}

/** Pure persisted-wall-clock and opaque-fence policy used by the Room adapter. */
object CaptureLeasePlanner {
    const val MIN_DURATION_MILLIS = 1_000L
    const val MAX_DURATION_MILLIS = 600_000L

    fun acquire(requestID: String, candidateToken: String, now: Long, duration: Long, maximumSeen: Long?, current: CaptureLease?): LeasePlan {
        val expiry = checkedExpiry(requestID, candidateToken, now, duration) ?: return LeasePlan.InvalidInput
        if (maximumSeen != null && now < maximumSeen) return LeasePlan.ClockRollback
        val maximum = maxOf(maximumSeen ?: 0, now)
        if (current != null && current.requestID != requestID) return LeasePlan.InvalidInput
        if (current != null && current.expiresAtEpochMillis > now) return LeasePlan.Busy(maximum)
        return LeasePlan.Grant(CaptureLease(requestID, candidateToken, expiry), maximum)
    }

    fun renew(requestID: String, token: String, now: Long, duration: Long, maximumSeen: Long?, current: CaptureLease?): LeasePlan {
        val expiry = checkedExpiry(requestID, token, now, duration) ?: return LeasePlan.InvalidInput
        if (maximumSeen != null && now < maximumSeen) return LeasePlan.ClockRollback
        val maximum = maxOf(maximumSeen ?: 0, now)
        if (current == null || current.token != token || current.requestID != requestID || current.expiresAtEpochMillis <= now) return LeasePlan.Lost(maximum)
        return LeasePlan.Grant(CaptureLease(requestID, token, expiry), maximum)
    }

    fun check(requestID: String, token: String, now: Long, maximumSeen: Long?, current: CaptureLease?): LeasePlan {
        if (!LOWER_UUID.matches(requestID) || !LOWER_UUID.matches(token) || now < 0) return LeasePlan.InvalidInput
        if (maximumSeen != null && now < maximumSeen) return LeasePlan.ClockRollback
        val maximum = maxOf(maximumSeen ?: 0, now)
        if (current == null || current.requestID != requestID || current.token != token || current.expiresAtEpochMillis <= now) return LeasePlan.Lost(maximum)
        return LeasePlan.Current(current, maximum)
    }

    private fun checkedExpiry(requestID: String, token: String, now: Long, duration: Long): Long? {
        if (!LOWER_UUID.matches(requestID) || !LOWER_UUID.matches(token) || now < 0 || duration !in MIN_DURATION_MILLIS..MAX_DURATION_MILLIS) return null
        return try { Math.addExact(now, duration) } catch (_: ArithmeticException) { null }
    }
}

data class QuotaSnapshot(val committedUnits: Int, val activeRequestIDs: Set<String>, val committedRequestIDs: Set<String>)

sealed interface QuotaPlan {
    data object Reserve : QuotaPlan
    data object ExistingReservation : QuotaPlan
    data object AlreadyCommitted : QuotaPlan
    data object LimitReached : QuotaPlan
    data object InvalidInput : QuotaPlan
}

object CaptureQuotaPlanner {
    const val FREE_CAPACITY = 10
    fun reserve(requestID: String, snapshot: QuotaSnapshot): QuotaPlan {
        if (!LOWER_UUID.matches(requestID) || snapshot.committedUnits !in 0..FREE_CAPACITY || snapshot.activeRequestIDs.any { !LOWER_UUID.matches(it) } || snapshot.committedRequestIDs.any { !LOWER_UUID.matches(it) }) return QuotaPlan.InvalidInput
        if (requestID in snapshot.committedRequestIDs) return QuotaPlan.AlreadyCommitted
        if (requestID in snapshot.activeRequestIDs) return QuotaPlan.ExistingReservation
        return if (snapshot.committedUnits + snapshot.activeRequestIDs.size >= FREE_CAPACITY) QuotaPlan.LimitReached else QuotaPlan.Reserve
    }
}

enum class OrphanReservationDisposition { RELEASE, RETAIN, CORRUPT_OR_MISSING }

object OrphanReservationPlanner {
    fun classify(snapshot: JournalSnapshot?): OrphanReservationDisposition {
        if (snapshot == null) return OrphanReservationDisposition.CORRUPT_OR_MISSING
        return when (snapshot.state) {
            CaptureState.MATERIALIZED,
            CaptureState.COMMITTING,
            CaptureState.UNKNOWN_OUTCOME,
            CaptureState.COMPLETED,
            -> OrphanReservationDisposition.RETAIN
            CaptureState.NEEDS_PERMISSION -> if (snapshot.resumeState == CaptureState.COMMITTING) {
                OrphanReservationDisposition.RETAIN
            } else {
                OrphanReservationDisposition.RELEASE
            }
            CaptureState.QUEUED,
            CaptureState.PREPARING,
            CaptureState.RETRYABLE_FAILURE,
            CaptureState.NEEDS_USER_ACTION,
            CaptureState.PERMANENT_FAILURE,
            CaptureState.DISCARDED,
            -> OrphanReservationDisposition.RELEASE
        }
    }
}
