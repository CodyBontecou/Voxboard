package md.vox.android.data

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import md.vox.android.capturedomain.CaptureIndexProjection
import md.vox.android.capturedomain.CaptureState
import md.vox.android.capturedomain.IndexWriteResult
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/** Compiles and executes generated Room DAO code when an emulator/device campaign is run. */
@RunWith(AndroidJUnit4::class)
class CaptureDatabaseInstrumentationTest {
    @Test fun generatedRoomProjectionIsContentFreeAndIdempotent() {
        val database = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), CaptureDatabase::class.java).build()
        try {
            val index = RoomCaptureIndex(database)
            val projection = CaptureIndexProjection("11111111-1111-4111-8111-111111111111", 1, 1, 0, CaptureState.QUEUED, 10, 10)
            assertEquals(IndexWriteResult.INSERTED, index.insertOrRepair(projection))
            assertEquals(IndexWriteResult.IDENTICAL, index.insertOrRepair(projection))
            assertEquals(projection, index.read(projection.requestID))
        } finally { database.close() }
    }
}
