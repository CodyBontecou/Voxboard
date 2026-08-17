package md.vox.android.capturedomain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureJournalReducerTest {
    private val requestID = "11111111-1111-4111-8111-111111111111"

    @Test fun allStateCodePairsMatchTheGovernedGraph() {
        val resumes = mapOf(CaptureState.PREPARING to CaptureState.PREPARING, CaptureState.MATERIALIZED to CaptureState.MATERIALIZED, CaptureState.COMMITTING to CaptureState.COMMITTING, CaptureState.UNKNOWN_OUTCOME to CaptureState.COMMITTING)
        for (from in CaptureState.entries) for (to in CaptureState.entries) for (code in JournalCode.entries) {
            val priorResume = if (from == CaptureState.NEEDS_PERMISSION) CaptureState.MATERIALIZED else null
            val prior = JournalSnapshot(requestID, 0, from, priorResume, listOf(seed(from, priorResume)))
            val resume = if (to == CaptureState.NEEDS_PERMISSION) resumes[from] else null
            val receipt = if (to == CaptureState.COMPLETED) "22222222-2222-4222-8222-222222222222" else null
            val result = CaptureJournalReducer.reduce(requestID, prior, JournalEvent(1, from, to, code, 2, resume, receipt))
            val expected = legal(from, to, code, priorResume)
            assertEquals("$from->$to/$code", expected, result is JournalReduction.Accepted)
        }
    }

    @Test fun initialAndFrontierBoundsFailClosed() {
        val initial = CaptureJournalReducer.reduce(requestID, null, JournalEvent(0, null, CaptureState.QUEUED, JournalCode.ENQUEUED, 1))
        assertTrue(initial is JournalReduction.Accepted)
        val snapshot = (initial as JournalReduction.Accepted).snapshot
        assertTrue(CaptureJournalReducer.reduce(requestID, snapshot, JournalEvent(2, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 2)) is JournalReduction.Rejected)
        assertTrue(CaptureJournalReducer.reduce(requestID, snapshot, JournalEvent(1, CaptureState.QUEUED, CaptureState.COMPLETED, JournalCode.VERIFIED_COMMITTED, 2, receiptID = null)) is JournalReduction.Rejected)
    }

    @Test fun materializedSelfTransitionIsIndependentlyRejected() {
        val prior = JournalSnapshot(requestID, 2, CaptureState.MATERIALIZED, null, listOf(seed(CaptureState.MATERIALIZED, null)))
        val result = CaptureJournalReducer.reduce(requestID, prior, JournalEvent(3, CaptureState.MATERIALIZED, CaptureState.MATERIALIZED, JournalCode.MATERIALIZED, 2))
        assertTrue(result is JournalReduction.Rejected)
    }

    private fun seed(state: CaptureState, resume: CaptureState?) = JournalEvent(0, null, state, JournalCode.ENQUEUED, 1, resume)
    private fun legal(from: CaptureState, to: CaptureState, code: JournalCode, priorResume: CaptureState?): Boolean = when (from) {
        CaptureState.QUEUED -> (to == CaptureState.PREPARING && code == JournalCode.PREPARATION_STARTED) || (to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED)
        CaptureState.PREPARING -> common(to, code, CaptureState.MATERIALIZED)
        CaptureState.MATERIALIZED -> setOf(
            CaptureState.PREPARING to JournalCode.PREPARATION_STARTED,
            CaptureState.COMMITTING to JournalCode.COMMIT_STARTED,
            CaptureState.RETRYABLE_FAILURE to JournalCode.RETRYABLE_FAILURE,
            CaptureState.NEEDS_PERMISSION to JournalCode.PERMISSION_LOST,
            CaptureState.NEEDS_USER_ACTION to JournalCode.USER_ACTION_REQUIRED,
            CaptureState.PERMANENT_FAILURE to JournalCode.PERMANENT_FAILURE,
            CaptureState.DISCARDED to JournalCode.USER_DISCARDED,
        ).contains(to to code)
        CaptureState.COMMITTING -> (to == CaptureState.COMPLETED && code == JournalCode.VERIFIED_COMMITTED) || (to == CaptureState.RETRYABLE_FAILURE && code == JournalCode.PROVED_NOT_COMMITTED) || (to == CaptureState.NEEDS_PERMISSION && code == JournalCode.PERMISSION_LOST) || (to == CaptureState.UNKNOWN_OUTCOME && code == JournalCode.COMMIT_AMBIGUOUS)
        CaptureState.RETRYABLE_FAILURE -> (to == CaptureState.PREPARING && code == JournalCode.PREPARATION_STARTED) || (to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED)
        CaptureState.NEEDS_PERMISSION -> (to == priorResume && code == JournalCode.PERMISSION_RESTORED) || (to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED)
        CaptureState.UNKNOWN_OUTCOME -> (to == CaptureState.COMPLETED && code == JournalCode.VERIFIED_COMMITTED) || (to == CaptureState.RETRYABLE_FAILURE && code == JournalCode.PROVED_NOT_COMMITTED) || (to == CaptureState.NEEDS_PERMISSION && code == JournalCode.PERMISSION_LOST) || (to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED)
        CaptureState.NEEDS_USER_ACTION -> to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED
        else -> false
    }
    private fun common(to: CaptureState, code: JournalCode, success: CaptureState) = (to == success && code == JournalCode.MATERIALIZED) || (to == CaptureState.RETRYABLE_FAILURE && code == JournalCode.RETRYABLE_FAILURE) || (to == CaptureState.NEEDS_PERMISSION && code == JournalCode.PERMISSION_LOST) || (to == CaptureState.NEEDS_USER_ACTION && code == JournalCode.USER_ACTION_REQUIRED) || (to == CaptureState.PERMANENT_FAILURE && code == JournalCode.PERMANENT_FAILURE) || (to == CaptureState.DISCARDED && code == JournalCode.USER_DISCARDED)
}
