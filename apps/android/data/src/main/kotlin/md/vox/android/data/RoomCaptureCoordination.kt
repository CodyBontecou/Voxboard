package md.vox.android.data

import md.vox.android.capturedomain.*

/** Raw coordination is module-internal; production access is lock-routed by CaptureDurabilityCoordinator. */
internal interface CaptureLeasePersistence {
    fun acquire(requestID: String, candidateToken: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan
    fun renew(requestID: String, token: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan
    fun isCurrent(requestID: String, token: String, nowEpochMillis: Long): LeasePlan
    fun release(requestID: String, token: String): Boolean
    fun clearExpired(nowEpochMillis: Long): LeaseClearResult
}

internal class RoomCaptureCoordination(private val database: CaptureDatabase) : CaptureLeasePersistence {
    private val dao get() = database.captureCoordinationDao()

    override fun acquire(requestID: String, candidateToken: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan = transaction {
        if (database.captureProjectionDao().read(requestID) == null) return@transaction LeasePlan.InvalidInput
        val plan = CaptureLeasePlanner.acquire(requestID, candidateToken, nowEpochMillis, durationMillis, dao.readClock()?.maxObservedEpochMillis, dao.readLease(requestID)?.domain())
        persist(plan)
        plan
    }

    override fun renew(requestID: String, token: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan = transaction {
        val plan = CaptureLeasePlanner.renew(requestID, token, nowEpochMillis, durationMillis, dao.readClock()?.maxObservedEpochMillis, dao.readLease(requestID)?.domain())
        persist(plan)
        plan
    }

    override fun isCurrent(requestID: String, token: String, nowEpochMillis: Long): LeasePlan = transaction {
        val plan = CaptureLeasePlanner.check(requestID, token, nowEpochMillis, dao.readClock()?.maxObservedEpochMillis, dao.readLease(requestID)?.domain())
        persist(plan)
        plan
    }

    /** Release is deliberately allowed during wall-clock rollback. */
    override fun release(requestID: String, token: String): Boolean = dao.releaseLease(requestID, token) == 1

    override fun clearExpired(nowEpochMillis: Long): LeaseClearResult = transaction {
        val maximum = dao.readClock()?.maxObservedEpochMillis
        if (nowEpochMillis < 0) return@transaction LeaseClearResult.InvalidInput
        if (maximum != null && nowEpochMillis < maximum) return@transaction LeaseClearResult.ClockRollback
        dao.putClock(LeaseClockEntity(1, maxOf(maximum ?: 0, nowEpochMillis)))
        LeaseClearResult.Cleared(dao.clearExpired(nowEpochMillis))
    }

    private fun persist(plan: LeasePlan) {
        when (plan) {
            is LeasePlan.Grant -> {
                dao.putLease(plan.lease.entity())
                dao.putClock(LeaseClockEntity(1, plan.newMaximumEpochMillis))
            }
            is LeasePlan.Current -> dao.putClock(LeaseClockEntity(1, plan.newMaximumEpochMillis))
            is LeasePlan.Busy -> dao.putClock(LeaseClockEntity(1, plan.newMaximumEpochMillis))
            is LeasePlan.Lost -> dao.putClock(LeaseClockEntity(1, plan.newMaximumEpochMillis))
            LeasePlan.ClockRollback, LeasePlan.InvalidInput -> Unit
        }
    }

    private fun CaptureLeaseEntity.domain() = CaptureLease(requestID, token, expiresAtEpochMillis)
    private fun CaptureLease.entity() = CaptureLeaseEntity(requestID, token, expiresAtEpochMillis)
    private fun <T> transaction(block: () -> T): T { var value: T? = null; database.runInTransaction { value = block() }; @Suppress("UNCHECKED_CAST") return value as T }
}

sealed interface LeaseClearResult {
    data class Cleared(val count: Int) : LeaseClearResult
    data object ClockRollback : LeaseClearResult
    data object InvalidInput : LeaseClearResult
}
