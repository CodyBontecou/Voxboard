package md.vox.android.data;
import androidx.annotation.NonNull;
import androidx.room.Entity;
import androidx.room.PrimaryKey;
@Entity(tableName = "installation_identity")
public final class InstallationIdentityEntity {
 @PrimaryKey public int singletonID; @NonNull public String installationID; public long createdAtEpochMillis;
 public InstallationIdentityEntity(int singletonID, @NonNull String installationID, long createdAtEpochMillis) { this.singletonID=singletonID; this.installationID=installationID; this.createdAtEpochMillis=createdAtEpochMillis; }
}
