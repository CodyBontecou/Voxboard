package md.vox.android.data;

import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.OnConflictStrategy;
import androidx.room.Query;
import java.util.List;

@Dao
public interface CaptureProjectionDao {
    @Query("SELECT * FROM capture_projection WHERE requestID = :requestID")
    CaptureProjectionEntity read(String requestID);

    @Query("SELECT * FROM capture_projection ORDER BY requestID")
    List<CaptureProjectionEntity> all();

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    long insert(CaptureProjectionEntity entity);

    @Query("UPDATE capture_projection SET packageVersion = :packageVersion, journalVersion = :journalVersion, journalRevision = :journalRevision, state = :state, updatedAtEpochMillis = :updatedAt WHERE requestID = :requestID AND journalRevision < :journalRevision")
    int repairOlder(String requestID, int packageVersion, int journalVersion, int journalRevision, String state, long updatedAt);
}
