package md.vox.android.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import md.vox.android.capturedomain.*
import md.vox.android.corebridge.CoreBuildInfo
import md.vox.android.corebridge.CoreResult

/** Bounded executor result: value or coarse failure (kotlin.Result has no error-typed sum). */
internal sealed interface ExecutorOutcome<out V> {
    data class Ok<out V>(val value: V) : ExecutorOutcome<V>
    data class Err(val code: String) : ExecutorOutcome<Nothing>
    data object LeaseLost : ExecutorOutcome<Nothing>

    companion object {
        fun <V> ok(value: V): ExecutorOutcome<V> = Ok(value)
        fun err(code: String): ExecutorOutcome<Nothing> = Err(code)
    }
}

/**
 * ADR-0023 §3–§6: the only caller of the SAF gateway. Executes the ADR-0019 precondition
 * order against the persisted destination record, drives the crash-window marker
 * lifecycle, reconciles restarts from `committing`/`unknownOutcome`, and returns exactly
 * one coarse [CommitOutcome] per attempt. Runs as the lease-holding worker; every journal
 * append routes through the revision-CAS coordinator. After `committing` it never
 * rerenders, switches engines, selects another candidate, or falls back to Kotlin
 * rendering.
 */
internal class SafVaultCommitExecutor(
    private val store: DurableCapturePackageStore,
    private val coordinator: CaptureDurabilityCoordinator,
    private val gateway: SafDocumentsGateway,
    private val destination: VaultDestination,
    private val buildInfo: () -> CoreResult<CoreBuildInfo>,
    private val clock: () -> Long,
) {
    /**
     * One commit attempt. MATERIALIZED → normal pre-commit attempt;
     * COMMITTING/UNKNOWN_OUTCOME → reconciliation only (ADR-0019 restart rule).
     */
    fun execute(requestID: String, leaseToken: String): ExecutorOutcome<CommitOutcome> {
        val snapshot = store.loadJournal(requestID) ?: return ExecutorOutcome.err("packageMissing")
        return when (snapshot.state) {
            CaptureState.MATERIALIZED -> normalAttempt(requestID, leaseToken, snapshot)
            CaptureState.COMMITTING, CaptureState.UNKNOWN_OUTCOME -> reconcile(requestID, leaseToken, snapshot)
            else -> ExecutorOutcome.err("stateNotCommittable")
        }
    }

    // ---- Normal pre-commit attempt (ADR-0019 preconditions 1–7) ----

    private fun normalAttempt(requestID: String, leaseToken: String, snapshot: JournalSnapshot): ExecutorOutcome<CommitOutcome> {
        // 1–2. Valid durable package/journal; pins were verified against buildInfo before
        // the MATERIALIZED append (coordinator); the executor re-proves the bridge is alive.
        if (buildInfo() !is CoreResult.Success) return ExecutorOutcome.err("bridgeUnavailable")

        // 3. Verify finalized plan hash + immutable note.bin bytes for the authoritative plan.
        val planHash = authoritativePlanHash(snapshot) ?: return ExecutorOutcome.err("planHashBinding")
        val artifacts = store.loadPreparedArtifacts(requestID, planHash) ?: return ExecutorOutcome.err("preparedArtifactsMissing")
        val noteDescriptor = noteDescriptorOf(artifacts.planBytes) ?: return ExecutorOutcome.err("noteDescriptorMissing")
        val logicalPath = noteDescriptor.logicalPath
        if (logicalPath.isEmpty()) return ExecutorOutcome.err("logicalPathMissing")
        val candidateDisplayName = logicalPath.last()
        if (artifacts.descriptor.noteLengthBytes != noteDescriptor.length || artifacts.descriptor.noteSHA256 != noteDescriptor.sha256) {
            return ExecutorOutcome.err("noteDescriptorMismatch")
        }

        // 4. Revalidate the persisted URI grant and destination identity.
        if (!gateway.revalidateGrant(destination)) return appendPermissionLost(requestID, leaseToken, snapshot)

        // 5. Observe candidate occupancy against the plan's absent policy.
        if (noteDescriptor.expectedExistingPolicy == "absent") {
            val folder = gateway.resolveFolder(destination, logicalPath.dropLast(1), createMissing = false)
            val occupied = folder?.let { gateway.listChildDisplayNames(it) } ?: return ExecutorOutcome.err("occupancyObservation")
            if (candidateDisplayName in occupied) return ExecutorOutcome.ok(CommitOutcome.StaleOccupancy)
        }

        // 6. Quota reservation was held idempotently at enqueue/ADR-0021; the terminal
        //    quota transaction is reachable only after a verified receipt (§5).

        // 7. Persist COMMITTING (revision-CAS) with the authoritative plan hash and fsync.
        val committing = append(requestID, leaseToken, snapshot) {
            JournalEvent(it, CaptureState.MATERIALIZED, CaptureState.COMMITTING, JournalCode.COMMIT_STARTED, clock(), planHash = planHash)
        } ?: return ExecutorOutcome.LeaseLost

        // After committing: never rerender, never select another candidate.
        return commitOrReconcile(requestID, leaseToken, committing, artifacts, candidateDisplayName)
    }

    private data class NoteDescriptor(
        val operationID: String,
        val artifactID: String,
        val logicalPath: List<String>,
        val length: Long,
        val sha256: String,
        val expectedExistingPolicy: String,
    )

    private fun noteDescriptorOf(planBytes: ByteArray): NoteDescriptor? = try {
        val plan = CapturePackageCodec.parseCanonical(planBytes)
        val requestID = plan.stringField("requestID") ?: return null
        val note = (plan["artifacts"] as? JsonArray)
            ?.singleOrNull { (it as? JsonObject)?.stringField("kind") == "note" } as? JsonObject ?: return null
        NoteDescriptor(
            operationID = note.stringField("operationID") ?: return null,
            artifactID = note.stringField("artifactID") ?: return null,
            logicalPath = (note["logicalPath"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: return null,
            length = (note["resultLength"] as? JsonPrimitive)?.content?.toLongOrNull() ?: return null,
            sha256 = note.stringField("resultSHA256") ?: return null,
            expectedExistingPolicy = note.stringField("expectedExistingPolicy") ?: return null,
        ).also { VoxDeterministicIds.requireUuidText(requestID) }
    } catch (_: Exception) { null }

    /**
     * Marker → create → write → read-back; an ACTIVE marker switches to reconciliation.
     * Every post-marker failure maps to the ADR-0019 taxonomy; never a blind retry.
     */
    private fun commitOrReconcile(
        requestID: String,
        leaseToken: String,
        snapshot: JournalSnapshot,
        artifacts: DurableCapturePackageStore.PreparedArtifacts,
        candidateDisplayName: String,
    ): ExecutorOutcome<CommitOutcome> {
        val marker = store.readCommitMarker(requestID)
        if (marker?.state == CommitMarker.MarkerState.ACTIVE) return reconcile(requestID, leaseToken, snapshot)

        val planHash = authoritativePlanHash(snapshot) ?: return ExecutorOutcome.err("planHashBinding")

        // Durably persist the crash-window marker (new-file + fsync + dir fsync) BEFORE create.
        val token = try {
            store.persistCommitMarker(requestID, CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, destination.destinationID, planHash, candidateDisplayName, clock()))
        } catch (_: Exception) { return ExecutorOutcome.err("markerPersist") }

        val folder = gateway.resolveFolder(destination, noteDescriptorOf(artifacts.planBytes)?.logicalPath?.dropLast(1) ?: return ExecutorOutcome.err("logicalPathMissing"), createMissing = true)
            ?: return appendAmbiguous(requestID, leaseToken, snapshot)

        val created = gateway.createDocument(token, folder, candidateDisplayName, "text/markdown; charset=utf-8")
        val handle = (created as? SafResult.Success)?.value ?: return mapCreateFailure(requestID, leaseToken, snapshot, (created as? SafResult.Error)?.code)

        val written = gateway.writeDocument(handle, artifacts.noteBytes, artifacts.noteBytes.size.toLong())
        if (written !is SafResult.Success) return appendAmbiguous(requestID, leaseToken, snapshot)

        val verified = (gateway.readBackDocument(handle) as? SafResult.Success)?.value
            ?: return appendAmbiguous(requestID, leaseToken, snapshot)
        if (verified.first != artifacts.noteBytes.size.toLong() || verified.second != artifacts.descriptor.noteSHA256) {
            return appendAmbiguous(requestID, leaseToken, snapshot)
        }
        return finalizeVerified(requestID, leaseToken, snapshot, artifacts.planBytes, verified.first, verified.second)
    }

    // ---- Reconciliation (normal write path is never invoked first) ----

    private fun reconcile(requestID: String, leaseToken: String, snapshot: JournalSnapshot): ExecutorOutcome<CommitOutcome> {
        val planHash = authoritativePlanHash(snapshot) ?: return ExecutorOutcome.err("planHashBinding")
        val marker = store.readCommitMarker(requestID)

        // No marker, or a CLEARED marker whose PROVED_NOT_COMMITTED append may have been
        // interrupted: both are causal proof create-never-issued (ADR-0023 §4 refinement).
        if (marker == null || marker.state == CommitMarker.MarkerState.CLEARED) {
            return if (appendProvedNotCommitted(requestID, leaseToken, snapshot)) {
                ExecutorOutcome.ok(CommitOutcome.ProvedNotCommitted)
            } else {
                ExecutorOutcome.LeaseLost
            }
        }

        // ACTIVE marker: reconciliation-only bounded lookup/read-back.
        if (!gateway.revalidateGrant(destination)) return appendPermissionLost(requestID, leaseToken, snapshot)
        val artifacts = store.loadPreparedArtifacts(requestID, planHash) ?: return ExecutorOutcome.err("preparedArtifactsMissing")
        val noteDescriptor = noteDescriptorOf(artifacts.planBytes) ?: return ExecutorOutcome.err("noteDescriptorMissing")
        val folder = gateway.resolveFolder(destination, noteDescriptor.logicalPath.dropLast(1), createMissing = false)
            ?: return appendAmbiguous(requestID, leaseToken, snapshot)

        val matches = gateway.findChildByDisplayName(folder, marker.candidateDisplayName)
        if (matches.isEmpty()) return appendAmbiguous(requestID, leaseToken, snapshot) // delayed visibility is not proof of absence
        if (matches.size > 1) return appendAmbiguous(requestID, leaseToken, snapshot)
        val verified = (gateway.readBackDocument(matches.single()) as? SafResult.Success)?.value
            ?: return appendAmbiguous(requestID, leaseToken, snapshot)
        if (verified.first != artifacts.descriptor.noteLengthBytes || verified.second != artifacts.descriptor.noteSHA256) {
            return appendAmbiguous(requestID, leaseToken, snapshot)
        }
        return finalizeVerified(requestID, leaseToken, snapshot, artifacts.planBytes, verified.first, verified.second)
    }

    // ---- Terminal outcomes ----

    private fun finalizeVerified(
        requestID: String,
        leaseToken: String,
        snapshot: JournalSnapshot,
        planBytes: ByteArray,
        verifiedLength: Long,
        verifiedSHA256: String,
    ): ExecutorOutcome<CommitOutcome> {
        val planHash = authoritativePlanHash(snapshot) ?: return ExecutorOutcome.err("planHashBinding")
        val note = noteDescriptorOf(planBytes) ?: return ExecutorOutcome.err("noteDescriptorMissing")
        val requestID2 = try {
            CapturePackageCodec.parseCanonical(planBytes).stringField("requestID")
        } catch (_: PackageCodecException) { null } ?: return ExecutorOutcome.err("planCorrupt")
        if (requestID2 != requestID) return ExecutorOutcome.err("planCorrelation")

        val receipt = try {
            val receiptID = DeliveryReceipt.deriveReceiptID(requestID, note.operationID, note.artifactID)
            DeliveryReceipt.validated(receiptID, requestID, note.operationID, note.artifactID, planHash, destination.destinationID, verifiedLength, verifiedSHA256, clock())
        } catch (_: IllegalArgumentException) { return ExecutorOutcome.err("receiptDerivation") }

        // Persist the correlated receipt BEFORE the VERIFIED_COMMITTED append (ADR-0023 §5).
        try {
            store.persistReceipt(requestID, receipt)
        } catch (_: Exception) { return ExecutorOutcome.err("receiptPersist") }

        return when (appendEvent(requestID, leaseToken, snapshot.revision, leaseScoped = true) {
            JournalEvent(it, snapshot.state, CaptureState.COMPLETED, JournalCode.VERIFIED_COMMITTED, clock(), receiptID = receipt.receiptID)
        }) {
            AppendStatus.Applied, AppendStatus.AlreadyApplied -> ExecutorOutcome.ok(CommitOutcome.VerifiedCommitted(receipt.receiptID))
            AppendStatus.Failed -> ExecutorOutcome.err("verifiedAppendFailed")
            AppendStatus.LeaseLost -> ExecutorOutcome.LeaseLost
        }
    }

    private fun appendProvedNotCommitted(requestID: String, leaseToken: String, snapshot: JournalSnapshot): Boolean =
        when (coordinator.mutate(provedNotCommittedCommand(requestID, leaseToken, snapshot), clock())) {
            is JournalMutationResult.Applied, is JournalMutationResult.AlreadyApplied, is JournalMutationResult.PersistedIndexPending -> true
            else -> false
        }

    private fun provedNotCommittedCommand(requestID: String, leaseToken: String, snapshot: JournalSnapshot): JournalMutationCommand {
        val from = if (snapshot.state == CaptureState.UNKNOWN_OUTCOME) CaptureState.UNKNOWN_OUTCOME else CaptureState.COMMITTING
        return JournalMutationCommand(
            requestID = requestID,
            expectedRevision = snapshot.revision,
            event = JournalEvent(snapshot.revision + 1, from, CaptureState.RETRYABLE_FAILURE, JournalCode.PROVED_NOT_COMMITTED, clock()),
            leaseToken = leaseToken,
            clearCommitMarker = true,
        )
    }

    private fun appendPermissionLost(requestID: String, leaseToken: String, snapshot: JournalSnapshot): ExecutorOutcome<CommitOutcome> {
        val from = snapshot.state
        if (from != CaptureState.COMMITTING && from != CaptureState.MATERIALIZED && from != CaptureState.UNKNOWN_OUTCOME) {
            return ExecutorOutcome.err("permissionState")
        }
        val resume = if (from == CaptureState.UNKNOWN_OUTCOME) CaptureState.COMMITTING else from
        return when (appendEvent(requestID, leaseToken, snapshot.revision, leaseScoped = true) {
            JournalEvent(it, from, CaptureState.NEEDS_PERMISSION, JournalCode.PERMISSION_LOST, clock(), resumeState = resume)
        }) {
            AppendStatus.Applied, AppendStatus.AlreadyApplied -> ExecutorOutcome.ok(CommitOutcome.PermissionLost)
            AppendStatus.Failed -> ExecutorOutcome.err("permissionAppendFailed")
            AppendStatus.LeaseLost -> ExecutorOutcome.LeaseLost
        }
    }

    private fun appendAmbiguous(requestID: String, leaseToken: String, snapshot: JournalSnapshot): ExecutorOutcome<CommitOutcome> {
        if (snapshot.state == CaptureState.UNKNOWN_OUTCOME) {
            // Already ambiguous: no illegal self-transition; the durable state is the record.
            return ExecutorOutcome.ok(CommitOutcome.Ambiguous)
        }
        return when (appendEvent(requestID, leaseToken, snapshot.revision, leaseScoped = true) {
            JournalEvent(it, CaptureState.COMMITTING, CaptureState.UNKNOWN_OUTCOME, JournalCode.COMMIT_AMBIGUOUS, clock())
        }) {
            AppendStatus.Applied, AppendStatus.AlreadyApplied -> ExecutorOutcome.ok(CommitOutcome.Ambiguous)
            AppendStatus.Failed -> ExecutorOutcome.err("ambiguousAppendFailed")
            AppendStatus.LeaseLost -> ExecutorOutcome.LeaseLost
        }
    }

    // ---- Helpers ----

    private enum class AppendStatus { Applied, AlreadyApplied, Failed, LeaseLost }

    private fun append(
        requestID: String,
        leaseToken: String,
        snapshot: JournalSnapshot,
        event: (Int) -> JournalEvent,
    ): JournalSnapshot? =
        when (appendEvent(requestID, leaseToken, snapshot.revision, leaseScoped = true, event)) {
            AppendStatus.Applied, AppendStatus.AlreadyApplied -> store.loadJournal(requestID)
            else -> null
        }

    private fun appendEvent(
        requestID: String,
        leaseToken: String,
        expectedRevision: Int,
        leaseScoped: Boolean,
        event: (Int) -> JournalEvent,
    ): AppendStatus {
        val command = JournalMutationCommand(requestID, expectedRevision, event(expectedRevision + 1), if (leaseScoped) leaseToken else null)
        return when (coordinator.mutate(command, clock())) {
            is JournalMutationResult.Applied -> AppendStatus.Applied
            is JournalMutationResult.AlreadyApplied -> AppendStatus.AlreadyApplied
            is JournalMutationResult.PersistedIndexPending -> AppendStatus.Applied
            JournalMutationResult.LeaseLost, is JournalMutationResult.FrontierConflict -> AppendStatus.LeaseLost
            else -> AppendStatus.Failed
        }
    }

    private fun mapCreateFailure(requestID: String, leaseToken: String, snapshot: JournalSnapshot, code: String?): ExecutorOutcome<CommitOutcome> =
        if (code == GatewayError.PermissionLost.name) appendPermissionLost(requestID, leaseToken, snapshot)
        else appendAmbiguous(requestID, leaseToken, snapshot)

    private fun authoritativePlanHash(snapshot: JournalSnapshot): String? =
        snapshot.events.lastOrNull { it.code == JournalCode.MATERIALIZED }?.planHash?.takeIf { SHA_64.matches(it) }

    private fun JsonObject.stringField(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private companion object {
        val SHA_64 = Regex("^[0-9a-f]{64}$")
    }
}
