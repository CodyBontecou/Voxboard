package md.vox.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import md.vox.android.capturedomain.*

/** Named executable consumer for the governed Android contract mirror. */
class CapturePackageFixtureConsumerTest {
    @Test fun production_codec_consumes_governed_fixtures() {
        val base = "contracts/v1/fixtures/android-capture-package/"
        val assets = resource(base + "valid-assets.json")
        val request = resource("contracts/v1/fixtures/capture-preparation-input/valid-android-m3-text-link.json")
        assertEquals("11111111-1111-4111-8111-111111111111", CapturePackageCodec.decodeAssets(assets).requestID)
        val queuedBytes = resource(base + "valid-queued-journal.json")
        val queued = CapturePackageCodec.decodeJournal(queuedBytes)
        assertEquals(0, queued.snapshot.revision)
        assertEquals(queuedBytes.toList(), CapturePackageCodec.encodeJournal(queued.snapshot, request, assets).toList())
        val journal = CapturePackageCodec.decodeJournal(resource(base + "valid-journal.json"))
        assertEquals(5, journal.snapshot.revision)
        CapturePackageCodec.verifyBinding(journal, request, assets)
        assertEquals("11111111-1111-4111-8111-111111111111", CapturePackageCodec.admitRequest(request).requestID)
        for (name in listOf("invalid-transition.json", "invalid-terminal-successor.json", "invalid-materialized-self-transition.json", "invalid-version.json")) {
            try {
                val bytes = resource(base + name)
                if (name == "invalid-version.json") CapturePackageCodec.decodeAssets(bytes) else CapturePackageCodec.decodeJournal(bytes)
                fail("fixture must fail: $name")
            } catch (_: PackageCodecException) { }
        }
    }

    @Test fun strictCanonicalDecoderRejectsMutations() {
        val valid = resource("contracts/v1/fixtures/android-capture-package/valid-assets.json")
        val text = valid.toString(Charsets.UTF_8)
        val mutations = listOf(valid.copyOf(valid.size - 1), text.replace("  \"assets\"", " \"assets\"").toByteArray(), text.replace("\"assetCount\": 0,", "\"assetCount\": 0,\n  \"assetCount\": 0,").toByteArray(), text.replace("\"schemaVersion\": 1", "\"unknown\": 0,\n  \"schemaVersion\": 1").toByteArray())
        mutations.forEach { bytes -> try { CapturePackageCodec.decodeAssets(bytes); fail("mutation accepted") } catch (_: PackageCodecException) { } }
    }

    @Test fun journalEncodingReplaysAndRequiresSuppliedFrontier() {
        val event = JournalEvent(0, null, CaptureState.QUEUED, JournalCode.ENQUEUED, 1)
        val inconsistent = JournalSnapshot("11111111-1111-4111-8111-111111111111", 1, CaptureState.PREPARING, null, listOf(event))
        try {
            CapturePackageCodec.encodeJournal(inconsistent, byteArrayOf(1), byteArrayOf(2))
            fail("inconsistent snapshot accepted")
        } catch (_: PackageCodecException) { }
    }

    @Test fun completePreparationBoundsAndSnapshotFailClosed() {
        val request = resource("contracts/v1/fixtures/capture-preparation-input/valid-android-m3-text-link.json").toString(Charsets.UTF_8)
        val mutations = listOf(
            request.replace("America/Los_Angeles", "Not/A_Zone"),
            request.replace("\"sequence\": 1", "\"sequence\": -1"),
            request.replace("https://example.invalid/synthetic", "ftp://example.invalid/synthetic"),
            request.replace("\"expectedCaseSensitivity\": \"sensitive\"", "\"expectedCaseSensitivity\": \"unknown\""),
            request.replace("33333333-3333-4333-8333-333333333333", "55555555-5555-4555-8555-555555555555"),
            request.replace(Regex("\"snapshotHash\": \"[0-9a-f]{64}\""), "\"snapshotHash\": \"${"0".repeat(64)}\""),
        )
        mutations.forEach { text -> try { CapturePackageCodec.admitRequest(text.toByteArray()); fail("request mutation accepted") } catch (_: PackageCodecException) { } }
        try { CapturePackageCodec.parseCanonical(ByteArray(CONTROL_LIMIT_BYTES + 1) { ' '.code.toByte() }); fail("oversized control accepted") } catch (_: PackageCodecException) { }
    }

    private fun resource(path: String): ByteArray = checkNotNull(javaClass.classLoader!!.getResourceAsStream(path)) { path }.use { it.readBytes() }
}
