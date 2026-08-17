package md.vox.android.capturedomain

import org.junit.Assert.*
import org.junit.Test

class CaptureDeliveryTest {
    private val requestID = "11111111-1111-4111-8111-111111111111"

    /** Governed contract vector (artifact-plan/v1 valid-receipt-derivation.json): the full derivation chain. */
    @Test fun receiptDerivationMatchesGovernedContractVector() {
        val commitSequence = 1L
        val operation = "existingNoteAppend"
        val logicalPath = listOf("Synthetic Vault", "Inbox", "capture.md")
        val operationID = VoxDeterministicIds.uuid5(
            "vox.operation.v1",
            ("{\n  \"commitSequence\": $commitSequence,\n  \"operation\": \"$operation\",\n  \"requestID\": \"$requestID\"\n}\n").toByteArray(Charsets.UTF_8),
        )
        assertEquals("84ad1460-9d3d-5734-bfa5-1de91c32de4b", operationID)
        val artifactID = VoxDeterministicIds.uuid5(
            "vox.artifact.v1",
            ("{\n  \"kind\": \"note\",\n  \"logicalPath\": [\n    \"Synthetic Vault\",\n    \"Inbox\",\n    \"capture.md\"\n  ],\n  \"operationID\": \"$operationID\"\n}\n").toByteArray(Charsets.UTF_8),
        )
        assertEquals("092b8435-ea25-54a3-8824-d76adb80a2a1", artifactID)
        assertEquals(
            "70792e8d-f768-5ae3-a902-62ea2b2cf186",
            DeliveryReceipt.deriveReceiptID(requestID, operationID, artifactID),
        )
    }

    @Test fun receiptValidationRejectsForeignDerivationAndBadBounds() {
        val operationID = "84ad1460-9d3d-5734-bfa5-1de91c32de4e"
        val artifactID = "092b8435-ea25-54a3-8824-d76adb80a2a1"
        val planHash = "a".repeat(64)
        val sha = "b".repeat(64)
        assertThrows(IllegalArgumentException::class.java) {
            DeliveryReceipt.validated("00000000-0000-4000-8000-000000000000", requestID, operationID, artifactID, planHash, requestID, 10, sha, 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            DeliveryReceipt.validated(DeliveryReceipt.deriveReceiptID(requestID, operationID, artifactID), requestID, operationID, artifactID, "zz", requestID, 10, sha, 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            DeliveryReceipt.validated(DeliveryReceipt.deriveReceiptID(requestID, operationID, artifactID), requestID, operationID, artifactID, planHash, requestID, -1, sha, 1)
        }
        val receipt = DeliveryReceipt.validated(DeliveryReceipt.deriveReceiptID(requestID, operationID, artifactID), requestID, operationID, artifactID, planHash, requestID, 25, sha, 1)
        assertEquals(25, receipt.verifiedLengthBytes)
    }

    @Test fun markerValidationBoundsAreFailClosed() {
        val planHash = "c".repeat(64)
        assertThrows(IllegalArgumentException::class.java) {
            CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, "not-a-uuid", planHash, "note.md", 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, requestID, "short", "note.md", 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, requestID, planHash, "bad/name.md", 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, requestID, planHash, "note.md", -1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, requestID, planHash, "x".repeat(256), 1)
        }
        CommitMarker.validated(CommitMarker.MarkerState.ACTIVE, requestID, planHash, "note.md", 1)
    }

    @Test fun observationAttemptFileNamesAreBoundedAndDeterministic() {
        assertEquals("$requestID.2.json", ObservationAttempt(requestID, 2).fileName)
        assertEquals(ObservationAttempt(requestID, 2), ObservationAttempt.fromFileName("$requestID.2.json"))
        assertNull(ObservationAttempt.fromFileName("$requestID.0.json"))
        assertNull(ObservationAttempt.fromFileName("$requestID.1023.json"))
        assertNull(ObservationAttempt.fromFileName("../escape.json"))
        assertNull(ObservationAttempt.fromFileName("$requestID.2.txt"))
        assertThrows(IllegalArgumentException::class.java) { ObservationAttempt(requestID, 0) }
        assertThrows(IllegalArgumentException::class.java) { ObservationAttempt(requestID, 1023) }
    }
}
