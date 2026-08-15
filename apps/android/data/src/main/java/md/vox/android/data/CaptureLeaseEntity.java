package md.vox.android.data;
import androidx.annotation.NonNull;
import androidx.room.Entity;
import androidx.room.PrimaryKey;
@Entity(tableName = "capture_lease")
public final class CaptureLeaseEntity {
 @PrimaryKey @NonNull public String requestID; @NonNull public String token; public long expiresAtEpochMillis;
 public CaptureLeaseEntity(@NonNull String requestID, @NonNull String token, long expiresAtEpochMillis) { this.requestID=requestID; this.token=token; this.expiresAtEpochMillis=expiresAtEpochMillis; }
}
