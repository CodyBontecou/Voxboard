package md.vox.android.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import md.vox.android.capturedomain.*
import md.vox.android.corebridge.CoreResult
import md.vox.android.corebridge.productionCoreBridge
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * ADR-0023 Phase 5 on-target evidence: the full M3 vertical slice executes against the
 * REAL local DocumentsProvider (com.android.externalstorage) through the production
 * coordinator (real native core via the lazy bridge), production durable store, and the
 * production SAF executor. Only grant revalidation is substituted (shell-adopted
 * identity); persisted-grant UX flows remain future interactive campaign evidence.
 */
@RunWith(AndroidJUnit4::class)
class SafVaultCommitExecutorInstrumentationTest {
    private val requestID = "11111111-1111-4111-8111-111111111111"
    private val leaseToken = "22222222-2222-4222-8222-222222222222"

    private fun requestBytes(): ByteArray = InstrumentationRegistry.getInstrumentation().context.assets
        .open("capture-preparation-input/valid-android-m3-text-link.json").use { it.readBytes() }

    @Test
    fun enqueueMaterializeCommitAndVerifyThroughRealProvider() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.adoptShellPermissionIdentity()

        val context = instrumentation.targetContext
        // SAF child-listing is restricted under Android/data on Android 11+, so the
        // campaign vault lives under the public Download tree where provider listing,
        // folder creation, and read-back are all exercised for real.
        val vaultRoot = File(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS), "vox-e2e-vault")
        vaultRoot.deleteRecursively()
        File(context.noBackupFilesDir, "vox-captures/$requestID").deleteRecursively()
        context.deleteDatabase("capture-index-v1.db")
        check(vaultRoot.mkdirs()) { "vaultRootCreateFailed" }
        val treeUri = android.net.Uri.parse("content://com.android.externalstorage.documents/tree/" + android.net.Uri.encode("primary:Download/vox-e2e-vault"))
        val destination = VaultDestination("33333333-3333-4333-8333-333333333333", treeUri.toString())

        val database = CaptureDatabase.create(context)
        val store = DurableCapturePackageStore(context.noBackupFilesDir, RoomCaptureIndex(database), AndroidDurableFileOps())
        val coordination = RoomCaptureCoordination(database)
        val coordinator = CaptureDurabilityCoordinator(store, coordination)

        // 1. Durable local enqueue (Phase 2 production path).
        assertEquals(EnqueueResult.SavedLocally(requestID), store.enqueue(requestBytes(), 1_700_000_000_000))

        // 2. Lease + PREPARING append (Phase 3 production path).
        val granted = coordinator.acquire(requestID, leaseToken, 1_700_000_000_001, 600_000)
        assertTrue("lease grant failed: $granted", granted is LeasePlan.Grant)
        val queued = store.loadJournal(requestID)!!
        val preparingAppend = coordinator.mutate(
            JournalMutationCommand(requestID, queued.revision, JournalEvent(queued.revision + 1, CaptureState.QUEUED, CaptureState.PREPARING, JournalCode.PREPARATION_STARTED, 1_700_000_000_002), leaseToken),
            1_700_000_000_002,
        )
        assertTrue("preparing append failed: $preparingAppend", preparingAppend is JournalMutationResult.Applied)

        // 3. Materialization through the REAL native core (Phase 4 bridge + Phase 5 coordinator).
        val bridge = productionCoreBridge()
        val gateway = ShellGrantGateway(context)
        val occupancy = SafCandidateOccupancy(gateway, destination)
        var time = 1_700_000_000_003L
        val materializer = CoreMaterializationCoordinator(bridge, store, coordinator, occupancy, destination) { time++ }
        val materialized = materializer.materialize(requestID, leaseToken, store.loadJournal(requestID)!!.revision)
        assertTrue(
            "materialization failed: $materialized; bridge=${bridge.availability}",
            materialized is CoreMaterializationCoordinator.MaterializationResult.Materialized,
        )
        val planHash = (materialized as CoreMaterializationCoordinator.MaterializationResult.Materialized).planHash
        assertEquals(CaptureState.MATERIALIZED, store.loadJournal(requestID)!!.state)

        // Prepared note bytes exist and are non-empty markdown verified by the core.
        val artifacts = store.loadPreparedArtifacts(requestID, planHash)!!
        assertTrue(artifacts.noteBytes.size in 1..1_048_576)
        val noteText = artifacts.noteBytes.toString(Charsets.UTF_8)
        assertTrue(noteText.endsWith("\n"))

        // 4. Commit through the real local DocumentsProvider (Phase 5 executor).
        val executor = SafVaultCommitExecutor(
            store, coordinator, gateway, destination,
            buildInfo = { bridge.buildInfo() },
            clock = { time++ },
        )
        val outcome = executor.execute(requestID, leaseToken)
        assertTrue("commit failed: $outcome", outcome is ExecutorOutcome.Ok && outcome.value is CommitOutcome.VerifiedCommitted)

        // 5. Terminal state: COMPLETED journal with the deterministic receipt on disk.
        val snapshot = store.loadJournal(requestID)!!
        assertEquals(CaptureState.COMPLETED, snapshot.state)
        val receiptID = snapshot.events.last().receiptID!!
        val receipt = store.loadReceipt(requestID, receiptID)!!
        assertEquals(planHash, receipt.planHash)
        assertEquals(artifacts.descriptor.noteLengthBytes, receipt.verifiedLengthBytes)
        assertEquals(artifacts.descriptor.noteSHA256, receipt.verifiedSHA256)
        assertEquals(CommitMarker.MarkerState.ACTIVE, store.readCommitMarker(requestID)!!.state)

        // 6. Read the committed note back through the provider and compare exact bytes.
        val noteDescriptor = gateway.findChildByDisplayName(
            gateway.resolveFolder(destination, logicalFolderOf(artifacts.planBytes), createMissing = false)!!,
            candidateNameOf(artifacts.planBytes),
        ).single()
        val readBack = (gateway.readBackDocument(noteDescriptor) as SafResult.Success).value
        assertEquals(artifacts.noteBytes.size.toLong(), readBack.first)
        assertEquals(artifacts.descriptor.noteSHA256, readBack.second)

        database.close()
    }

    private fun logicalFolderOf(planBytes: ByteArray): List<String> {
        val plan = CapturePackageCodec.parseCanonical(planBytes)
        val note = (plan["artifacts"] as kotlinx.serialization.json.JsonArray)
            .single { (it as kotlinx.serialization.json.JsonObject)["kind"].toString().contains("note") } as kotlinx.serialization.json.JsonObject
        return (note["logicalPath"] as kotlinx.serialization.json.JsonArray).map { (it as kotlinx.serialization.json.JsonPrimitive).content }.dropLast(1)
    }

    private fun candidateNameOf(planBytes: ByteArray): String {
        val plan = CapturePackageCodec.parseCanonical(planBytes)
        val note = (plan["artifacts"] as kotlinx.serialization.json.JsonArray)
            .single { (it as kotlinx.serialization.json.JsonObject)["kind"].toString().contains("note") } as kotlinx.serialization.json.JsonObject
        return (note["logicalPath"] as kotlinx.serialization.json.JsonArray).map { (it as kotlinx.serialization.json.JsonPrimitive).content }.last()
    }

    /** Production gateway with grant revalidation substituted under shell identity. */
    private class ShellGrantGateway(context: android.content.Context) : AndroidSafDocumentsGateway(context) {
        override fun revalidateGrant(destination: VaultDestination) = true
    }
}
