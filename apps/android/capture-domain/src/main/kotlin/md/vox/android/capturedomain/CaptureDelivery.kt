package md.vox.android.capturedomain

import java.security.MessageDigest

/**
 * Pure delivery-phase semantics (ADR-0023). No platform handles, no I/O, no scheduling:
 * types, deterministic derivations, bounded validation, and the commit-result taxonomy
 * that maps onto the journal reducer's existing states.
 */

/** Deterministic UUIDv5 derivation discipline of artifact-plan/v1 (namespace 8c7f8d7e-…). */
object VoxDeterministicIds {
    private val PLAN_HASH = Regex("^[0-9a-f]{64}$")
    private val UUID_TEXT = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    private val NAMESPACE = uuidBytes("8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415")

    /** uuid5(namespace, ascii(domain) + NUL + name) per artifact-plan/v1. */
    fun uuid5(domainLabel: String, canonicalNameJson: ByteArray): String {
        require(domainLabel.toByteArray(Charsets.UTF_8).size <= 64) { "domainLabelBounds" }
        val digest = MessageDigest.getInstance("SHA-1")
        digest.update(NAMESPACE)
        digest.update(domainLabel.toByteArray(Charsets.US_ASCII))
        digest.update(0)
        digest.update(canonicalNameJson)
        val hash = digest.digest()
        hash[6] = ((hash[6].toInt() and 0x0f) or 0x50).toByte()
        hash[8] = ((hash[8].toInt() and 0x3f) or 0x80).toByte()
        val hex = hash.take(16).joinToString("") { "%02x".format(it) }
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }

    fun requirePlanHash(value: String) {
        require(PLAN_HASH.matches(value)) { "planHashPattern" }
    }

    fun requireUuidText(value: String) {
        require(UUID_TEXT.matches(value)) { "uuidPattern" }
    }

    private fun uuidBytes(text: String): ByteArray {
        requireUuidText(text)
        val hex = text.replace("-", "")
        return ByteArray(16) { ((hex.substring(it * 2, it * 2 + 2).toInt(16))).toByte() }
    }
}

/**
 * Native commit crash-window marker (ADR-0023 §4). Persisted durably
 * (file + directory fsync) strictly before createDocument is issued.
 * A cleared marker records completed proof of non-commit; it never implies issue.
 */
data class CommitMarker(
    val state: MarkerState,
    val destinationID: String,
    val planHash: String,
    val candidateDisplayName: String,
    val recordedAtEpochMillis: Long,
) {
    enum class MarkerState { ACTIVE, CLEARED }

    companion object {
        private val DISPLAY_NAME_UTF8_MAX = 255

        fun validated(state: MarkerState, destinationID: String, planHash: String, candidateDisplayName: String, recordedAtEpochMillis: Long): CommitMarker {
            VoxDeterministicIds.requireUuidText(destinationID)
            VoxDeterministicIds.requirePlanHash(planHash)
            require(candidateDisplayName.toByteArray(Charsets.UTF_8).size in 1..DISPLAY_NAME_UTF8_MAX) { "displayNameBounds" }
            require(recordedAtEpochMillis >= 0) { "timestampBounds" }
            require('\u0000' !in candidateDisplayName && '/' !in candidateDisplayName) { "displayNameCharacters" }
            return CommitMarker(state, destinationID, planHash, candidateDisplayName, recordedAtEpochMillis)
        }
    }
}

/**
 * Correlated provider-commit receipt (ADR-0023 §5). Content-free: no tree URIs,
 * document IDs, provider names, or user content. The receipt ID is deterministic
 * (vox.receipt.v1) so replay after crash is idempotent.
 */
data class DeliveryReceipt(
    val receiptID: String,
    val requestID: String,
    val operationID: String,
    val artifactID: String,
    val planHash: String,
    val destinationID: String,
    val verifiedLengthBytes: Long,
    val verifiedSHA256: String,
    val committedAtEpochMillis: Long,
) {
    companion object {
        fun deriveReceiptID(requestID: String, operationID: String, artifactID: String): String {
            VoxDeterministicIds.requireUuidText(requestID)
            VoxDeterministicIds.requireUuidText(operationID)
            VoxDeterministicIds.requireUuidText(artifactID)
            // Canonical JSON: sorted keys, two-space indent, exactly one trailing LF.
            val name = ("{\n  \"artifactID\": \"$artifactID\",\n  \"operationID\": \"$operationID\"," +
                "\n  \"requestID\": \"$requestID\"\n}\n").toByteArray(Charsets.UTF_8)
            return VoxDeterministicIds.uuid5("vox.receipt.v1", name)
        }

        fun validated(
            receiptID: String,
            requestID: String,
            operationID: String,
            artifactID: String,
            planHash: String,
            destinationID: String,
            verifiedLengthBytes: Long,
            verifiedSHA256: String,
            committedAtEpochMillis: Long,
        ): DeliveryReceipt {
            VoxDeterministicIds.requireUuidText(receiptID)
            VoxDeterministicIds.requireUuidText(requestID)
            VoxDeterministicIds.requireUuidText(operationID)
            VoxDeterministicIds.requireUuidText(artifactID)
            VoxDeterministicIds.requirePlanHash(planHash)
            VoxDeterministicIds.requireUuidText(destinationID)
            require(verifiedLengthBytes in 0..MAX_PREPARED_NOTE_BYTES) { "lengthBounds" }
            VoxDeterministicIds.requirePlanHash(verifiedSHA256)
            require(committedAtEpochMillis >= 0) { "timestampBounds" }
            require(deriveReceiptID(requestID, operationID, artifactID) == receiptID) { "receiptIDerivation" }
            return DeliveryReceipt(receiptID, requestID, operationID, artifactID, planHash, destinationID, verifiedLengthBytes, verifiedSHA256, committedAtEpochMillis)
        }
    }
}

/** Native vault destination record. Storage handles never enter journals, receipts, or markers beyond the stable UUID. */
data class VaultDestination(
    val destinationID: String,
    val treeUri: String,
) {
    init {
        VoxDeterministicIds.requireUuidText(destinationID)
        require(treeUri.toByteArray(Charsets.UTF_8).size in 1..2048) { "treeUriBounds" }
    }
}

/** Verified descriptor of persisted prepared artifacts (ADR-0023 §1). */
data class PreparedPlanDescriptor(
    val planHash: String,
    val noteLengthBytes: Long,
    val noteSHA256: String,
) {
    init {
        VoxDeterministicIds.requirePlanHash(planHash)
        require(noteLengthBytes in 0..MAX_PREPARED_NOTE_BYTES) { "noteLengthBounds" }
        VoxDeterministicIds.requirePlanHash(noteSHA256)
    }
}

/** Attempt-scoped observation snapshot identity: observations/<requestID>.<revision>.json. */
data class ObservationAttempt(val requestID: String, val startRevision: Int) {
    val fileName: String get() = "$requestID.$startRevision.json"

    init {
        VoxDeterministicIds.requireUuidText(requestID)
        require(startRevision in 1..1022) { "attemptRevisionBounds" }
    }

    companion object {
        private val PATTERN = Regex("^([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\\.([0-9]{1,4})\\.json$")

        fun fromFileName(name: String): ObservationAttempt? {
            val match = PATTERN.matchEntire(name) ?: return null
            return try {
                ObservationAttempt(match.groupValues[1], match.groupValues[2].toInt())
            } catch (_: IllegalArgumentException) {
                null
            }
        }
    }
}

/** Exactly one coarse native result per executor attempt (ADR-0023 §6). Content-free. */
sealed interface CommitOutcome {
    /** Exact candidate read-back matched length and SHA-256; receipt already persisted. */
    data class VerifiedCommitted(val receiptID: String) : CommitOutcome

    /** Causally proven create-never-issued (or provider-proven absence); normal pre-commit retry is safe. */
    data object ProvedNotCommitted : CommitOutcome

    /** Destination capability revoked/unavailable; package and prepared bytes retained. */
    data object PermissionLost : CommitOutcome

    /** Commit or absence cannot be proved; retain everything, never blind-retry. */
    data object Ambiguous : CommitOutcome

    /** Candidate occupancy changed pre-commit; journaled rematerialization follows. */
    data object StaleOccupancy : CommitOutcome
}

/** Bounded package-content constants shared by validation layers. */
const val MAX_PREPARED_NOTE_BYTES: Long = 256L * 1024 * 1024
const val MAX_PREPARED_PLAN_DIRECTORIES = 64
const val MAX_OBSERVATION_ATTEMPTS = 1024
const val MAX_RECEIPTS = 1024
