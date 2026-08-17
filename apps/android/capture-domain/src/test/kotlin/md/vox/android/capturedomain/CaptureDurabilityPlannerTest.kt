package md.vox.android.capturedomain

import org.junit.Assert.*
import org.junit.Test

class CaptureDurabilityPlannerTest {
    private val request = "11111111-1111-4111-8111-111111111111"
    private val first = "22222222-2222-4222-8222-222222222222"
    private val second = "33333333-3333-4333-8333-333333333333"

    @Test fun leaseBoundsFencingExpiryRollbackAndEveryAcceptedObservationArePure() {
        assertEquals(LeasePlan.InvalidInput, CaptureLeasePlanner.acquire(request, first, 10, 999, null, null))
        val grant = CaptureLeasePlanner.acquire(request, first, 10, 10_000, null, null) as LeasePlan.Grant
        assertEquals(10_010, grant.lease.expiresAtEpochMillis)
        assertEquals(LeasePlan.Busy(9_000), CaptureLeasePlanner.acquire(request, second, 9_000, 1_000, 10, grant.lease))
        assertEquals(LeasePlan.ClockRollback, CaptureLeasePlanner.renew(request, first, 1_000, 1_000, 9_000, grant.lease))
        assertEquals(LeasePlan.Lost(9_001), CaptureLeasePlanner.renew(request, second, 9_001, 1_000, 9_000, grant.lease))
        assertEquals(LeasePlan.ClockRollback, CaptureLeasePlanner.check(request, first, 9_000, 9_001, grant.lease))
        assertTrue(CaptureLeasePlanner.renew(request, first, 9_002, 1_000, 9_001, grant.lease) is LeasePlan.Grant)
        assertTrue(CaptureLeasePlanner.acquire(request, second, 10_010, 1_000, 9_002, grant.lease) is LeasePlan.Grant)
        assertEquals(LeasePlan.InvalidInput, CaptureLeasePlanner.acquire(request, first, Long.MAX_VALUE, 1_000, null, null))
    }

    @Test fun quotaCapacityCoalescingAndCommitTakePrecedence() {
        assertEquals(QuotaPlan.Reserve, CaptureQuotaPlanner.reserve(request, QuotaSnapshot(0, emptySet(), emptySet())))
        assertEquals(QuotaPlan.ExistingReservation, CaptureQuotaPlanner.reserve(request, QuotaSnapshot(0, setOf(request), emptySet())))
        assertEquals(QuotaPlan.AlreadyCommitted, CaptureQuotaPlanner.reserve(request, QuotaSnapshot(1, setOf(request), setOf(request))))
        val nine = (1..9).map { "00000000-0000-4000-8000-${it.toString().padStart(12, '0')}" }.toSet()
        assertEquals(QuotaPlan.LimitReached, CaptureQuotaPlanner.reserve(request, QuotaSnapshot(1, nine, emptySet())))
    }

    @Test fun orphanReservationRetainsPossiblyOrVerifiedCommittedAndIntentionallyReleasesDiscard() {
        fun reduce(prior: JournalSnapshot?, event: JournalEvent) = (CaptureJournalReducer.reduce(request, prior, event) as JournalReduction.Accepted).snapshot
        var committing: JournalSnapshot? = null
        committing = reduce(committing, JournalEvent(0, null, CaptureState.QUEUED, JournalCode.ENQUEUED, 0))
        committing = reduce(committing, JournalEvent(1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 1))
        committing = reduce(committing, JournalEvent(2, CaptureState.PREPARING, CaptureState.MATERIALIZED, JournalCode.MATERIALIZED, 2, planHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        committing = reduce(committing, JournalEvent(3, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, 3, planHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        val completed = reduce(committing, JournalEvent(4, CaptureState.COMMITTING, CaptureState.COMPLETED, JournalCode.VERIFIED_COMMITTED, 4, receiptID = first))
        assertEquals(OrphanReservationDisposition.RETAIN, OrphanReservationPlanner.classify(completed))
        val ambiguous = reduce(committing, JournalEvent(4, CaptureState.COMMITTING, CaptureState.UNKNOWN_OUTCOME, JournalCode.COMMIT_AMBIGUOUS, 4))
        val reconciledCompleted = reduce(ambiguous, JournalEvent(5, CaptureState.UNKNOWN_OUTCOME, CaptureState.COMPLETED, JournalCode.VERIFIED_COMMITTED, 5, receiptID = first))
        assertEquals(OrphanReservationDisposition.RETAIN, OrphanReservationPlanner.classify(reconciledCompleted))
        val explicitlyDiscarded = reduce(ambiguous, JournalEvent(5, CaptureState.UNKNOWN_OUTCOME, CaptureState.DISCARDED, JournalCode.USER_DISCARDED, 5))
        assertEquals(OrphanReservationDisposition.RELEASE, OrphanReservationPlanner.classify(explicitlyDiscarded))

        val expected = mapOf(
            CaptureState.QUEUED to OrphanReservationDisposition.RELEASE,
            CaptureState.PREPARING to OrphanReservationDisposition.RELEASE,
            CaptureState.MATERIALIZED to OrphanReservationDisposition.RETAIN,
            CaptureState.COMMITTING to OrphanReservationDisposition.RETAIN,
            CaptureState.RETRYABLE_FAILURE to OrphanReservationDisposition.RELEASE,
            CaptureState.NEEDS_PERMISSION to OrphanReservationDisposition.RELEASE,
            CaptureState.NEEDS_USER_ACTION to OrphanReservationDisposition.RELEASE,
            CaptureState.UNKNOWN_OUTCOME to OrphanReservationDisposition.RETAIN,
            CaptureState.COMPLETED to OrphanReservationDisposition.RETAIN,
            CaptureState.PERMANENT_FAILURE to OrphanReservationDisposition.RELEASE,
            CaptureState.DISCARDED to OrphanReservationDisposition.RELEASE,
        )
        assertEquals(CaptureState.entries.toSet(), expected.keys)
        expected.forEach { (state, disposition) ->
            assertEquals(state.name, disposition, OrphanReservationPlanner.classify(JournalSnapshot(request, 0, state, null, emptyList())))
        }
        assertEquals(
            OrphanReservationDisposition.RETAIN,
            OrphanReservationPlanner.classify(JournalSnapshot(request, 0, CaptureState.NEEDS_PERMISSION, CaptureState.COMMITTING, emptyList())),
        )
        assertEquals(OrphanReservationDisposition.CORRUPT_OR_MISSING, OrphanReservationPlanner.classify(null))
    }
}
