package md.vox.android.data

import md.vox.android.capturedomain.CaptureIndex
import md.vox.android.capturedomain.CaptureIndexProjection
import md.vox.android.capturedomain.CaptureState
import md.vox.android.capturedomain.IndexWriteResult

class RoomCaptureIndex(private val database: CaptureDatabase) : CaptureIndex {
    private val dao get() = database.captureProjectionDao()
    override fun read(requestID: String): CaptureIndexProjection? = dao.read(requestID)?.projection()
    override fun all(): List<CaptureIndexProjection> = dao.all().map(CaptureProjectionEntity::projection)
    override fun insertOrRepair(projection: CaptureIndexProjection): IndexWriteResult {
        var result = IndexWriteResult.CONFLICT
        database.runInTransaction {
            val entity = projection.entity()
            val existing = dao.read(entity.requestID)
            result = when {
                existing == null && dao.insert(entity) != -1L -> IndexWriteResult.INSERTED
                existing == null -> IndexWriteResult.CONFLICT
                existing.packageVersion != entity.packageVersion || existing.journalVersion != entity.journalVersion || existing.createdAtEpochMillis != entity.createdAtEpochMillis -> IndexWriteResult.CONFLICT
                existing.journalRevision > entity.journalRevision -> IndexWriteResult.PROJECTION_AHEAD
                existing.journalRevision == entity.journalRevision && existing.state == entity.state && existing.updatedAtEpochMillis == entity.updatedAtEpochMillis && existing.attemptCount == entity.attemptCount -> IndexWriteResult.IDENTICAL
                existing.journalRevision == entity.journalRevision -> IndexWriteResult.CONFLICT
                dao.repairOlder(entity.requestID, entity.packageVersion, entity.journalVersion, entity.journalRevision, entity.state, entity.updatedAtEpochMillis, entity.attemptCount) == 1 -> IndexWriteResult.REPAIRED_OLDER
                else -> IndexWriteResult.CONFLICT
            }
        }
        return result
    }
}

private fun CaptureProjectionEntity.projection() = CaptureIndexProjection(
    requestID, packageVersion, journalVersion, journalRevision,
    CaptureState.entries.first { it.name == state }, createdAtEpochMillis, updatedAtEpochMillis, attemptCount,
)
private fun CaptureIndexProjection.entity() = CaptureProjectionEntity(
    requestID, packageVersion, journalVersion, journalRevision, state.name, createdAtEpochMillis, updatedAtEpochMillis, attemptCount,
)
