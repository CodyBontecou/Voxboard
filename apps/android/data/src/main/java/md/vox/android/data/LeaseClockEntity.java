package md.vox.android.data;
import androidx.room.Entity;
import androidx.room.PrimaryKey;
@Entity(tableName = "lease_clock")
public final class LeaseClockEntity {
 @PrimaryKey public int singletonID; public long maxObservedEpochMillis;
 public LeaseClockEntity(int singletonID, long maxObservedEpochMillis) { this.singletonID=singletonID; this.maxObservedEpochMillis=maxObservedEpochMillis; }
}
