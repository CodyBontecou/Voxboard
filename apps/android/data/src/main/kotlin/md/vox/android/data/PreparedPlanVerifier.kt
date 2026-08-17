package md.vox.android.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.put
import md.vox.android.capturedomain.VoxDeterministicIds

/**
 * Artifact-plan/v1 verification: recomputes the canonical planHash (bytes with `planHash`
 * zeroed) and every deterministic ID; fails closed on any mismatch. Used by both the
 * materialization coordinator (before MATERIALIZED) and the durable store (promotion and
 * package validation), so the plan-hash directory name always binds the contract hash.
 */
internal object PreparedPlanVerifier {
    private val SHA_64 = Regex("^[0-9a-f]{64}$")

    /** Returns the verified planHash field, or null when the plan fails closed. */
    fun verifiedPlanHash(planBytes: ByteArray): String? = try {
        val plan = CapturePackageCodec.parseCanonical(planBytes)
        val claimedHash = plan.stringOf("planHash") ?: return null
        if (!SHA_64.matches(claimedHash)) return null
        val zeroed = JsonObject(plan.toMutableMap().also { it["planHash"] = JsonPrimitive("0".repeat(64)) })
        if (CapturePackageCodec.sha256(CapturePackageCodec.canonical(zeroed)) != claimedHash) return null
        verifiedIdentities(plan) ?: return null
        claimedHash
    } catch (_: Exception) {
        null
    }

    private fun verifiedIdentities(plan: JsonObject): Boolean {
        val requestID = plan.stringOf("requestID") ?: return false
        val operation = plan.stringOf("operation") ?: return false
        val artifacts = plan["artifacts"] as? JsonArray ?: return false
        for (artifact in artifacts) {
            val entry = artifact as? JsonObject ?: return false
            val artifactID = entry.stringOf("artifactID") ?: return false
            val operationID = entry.stringOf("operationID") ?: return false
            val commitSequence = (entry["commitSequence"] as? JsonPrimitive)?.content?.toLongOrNull() ?: return false
            val kind = entry.stringOf("kind") ?: return false
            val logicalPath = (entry["logicalPath"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: return false
            if (VoxDeterministicIds.uuid5("vox.operation.v1", preimage {
                    put("commitSequence", commitSequence); put("operation", operation); put("requestID", requestID)
                }) != operationID) return false
            if (VoxDeterministicIds.uuid5("vox.artifact.v1", preimage {
                    put("kind", kind)
                    put("logicalPath", kotlinx.serialization.json.JsonArray(logicalPath.map { kotlinx.serialization.json.JsonPrimitive(it) }))
                    put("operationID", operationID)
                }) != artifactID) return false
            val streamID = entry.stringOf("preparedStreamID")
            if (streamID != null) {
                val resultLength = (entry["resultLength"] as? JsonPrimitive)?.content?.toLongOrNull() ?: return false
                val resultSHA256 = entry.stringOf("resultSHA256") ?: return false
                if (VoxDeterministicIds.uuid5("vox.stream.v1", preimage {
                        put("artifactID", artifactID); put("resultLength", resultLength); put("resultSHA256", resultSHA256)
                    }) != streamID) return false
            }
        }
        return true
    }

    private inline fun preimage(block: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): ByteArray =
        CapturePackageCodec.canonical(kotlinx.serialization.json.buildJsonObject(block))

    private fun JsonObject.stringOf(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
}
