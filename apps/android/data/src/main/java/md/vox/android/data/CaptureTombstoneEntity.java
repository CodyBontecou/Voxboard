package md.vox.android.data;
import androidx.annotation.NonNull;
import androidx.room.Entity;
import androidx.room.PrimaryKey;
@Entity(tableName = "capture_tombstone")
public final class CaptureTombstoneEntity {
 @PrimaryKey @NonNull public String requestID;
 @NonNull public String installationID;
 @NonNull public String state;
 public long completedAtEpochMillis;
 @NonNull public String destinationID;
 @NonNull public String receiptID;
 public int packageVersion;
 public int journalVersion;
 public int requestContractVersion;
 public int finalJournalRevision;
 @NonNull public String coreVersion;
 @NonNull public String rendererVersion;
 @NonNull public String profileID;
 public int profileVersion;
 public int quotaUnits;
 public CaptureTombstoneEntity(@NonNull String requestID, @NonNull String installationID, @NonNull String state, long completedAtEpochMillis, @NonNull String destinationID, @NonNull String receiptID, int packageVersion, int journalVersion, int requestContractVersion, int finalJournalRevision, @NonNull String coreVersion, @NonNull String rendererVersion, @NonNull String profileID, int profileVersion, int quotaUnits) {
  this.requestID=requestID; this.installationID=installationID; this.state=state; this.completedAtEpochMillis=completedAtEpochMillis; this.destinationID=destinationID; this.receiptID=receiptID; this.packageVersion=packageVersion; this.journalVersion=journalVersion; this.requestContractVersion=requestContractVersion; this.finalJournalRevision=finalJournalRevision; this.coreVersion=coreVersion; this.rendererVersion=rendererVersion; this.profileID=profileID; this.profileVersion=profileVersion; this.quotaUnits=quotaUnits;
 }
}
