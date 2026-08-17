package md.vox.android.data

import md.vox.android.capturedomain.*

/** Production-unwired coordinator. Scheduling and TTL policy deliberately remain absent. */
internal class CaptureDurabilityCoordinator(
    private val store: DurableCapturePackageStore,
    private val leases: CaptureLeasePersistence,
) {
    fun acquire(requestID: String, candidateToken: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan =
        store.withRootMutationLock { leases.acquire(requestID, candidateToken, nowEpochMillis, durationMillis) }

    fun renew(requestID: String, token: String, nowEpochMillis: Long, durationMillis: Long): LeasePlan =
        store.withRootMutationLock { leases.renew(requestID, token, nowEpochMillis, durationMillis) }

    fun release(requestID: String, token: String): Boolean =
        store.withRootMutationLock { leases.release(requestID, token) }

    fun isCurrent(requestID: String, token: String, nowEpochMillis: Long): LeasePlan =
        store.withRootMutationLock { leases.isCurrent(requestID, token, nowEpochMillis) }

    /** The store keeps one root lock continuous across fence check, CAS, replace, fsync, and projection. */
    fun mutate(command: JournalMutationCommand, nowEpochMillis: Long): JournalMutationResult =
        store.mutateJournal(command) { candidate ->
            command.leaseToken == candidate && leases.isCurrent(command.requestID, candidate, nowEpochMillis) is LeasePlan.Current
        }

    /** Expiry clears only Room ownership. It never appends a journal event. */
    fun clearExpiredLeases(nowEpochMillis: Long): LeaseClearResult =
        store.withRootMutationLock { leases.clearExpired(nowEpochMillis) }
}
