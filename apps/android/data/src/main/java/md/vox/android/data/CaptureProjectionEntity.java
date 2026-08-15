package md.vox.android.data;

import androidx.annotation.NonNull;
import androidx.room.Entity;
import androidx.room.PrimaryKey;

@Entity(tableName = "capture_projection")
public final class CaptureProjectionEntity {
    @PrimaryKey @NonNull public String requestID;
    public int packageVersion;
    public int journalVersion;
    public int journalRevision;
    @NonNull public String state;
    public long createdAtEpochMillis;
    public long updatedAtEpochMillis;
    public int attemptCount;

    public CaptureProjectionEntity(@NonNull String requestID, int packageVersion, int journalVersion,
            int journalRevision, @NonNull String state, long createdAtEpochMillis, long updatedAtEpochMillis, int attemptCount) {
        this.requestID = requestID;
        this.packageVersion = packageVersion;
        this.journalVersion = journalVersion;
        this.journalRevision = journalRevision;
        this.state = state;
        this.createdAtEpochMillis = createdAtEpochMillis;
        this.updatedAtEpochMillis = updatedAtEpochMillis;
        this.attemptCount = attemptCount;
    }
}
