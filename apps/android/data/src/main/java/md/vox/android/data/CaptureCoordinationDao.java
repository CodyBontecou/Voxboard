package md.vox.android.data;
import androidx.room.Dao;
import androidx.room.Insert;
import androidx.room.OnConflictStrategy;
import androidx.room.Query;
import java.util.List;
@Dao
public interface CaptureCoordinationDao {
 @Query("SELECT * FROM capture_lease WHERE requestID=:requestID") CaptureLeaseEntity readLease(String requestID);
 @Insert(onConflict=OnConflictStrategy.REPLACE) void putLease(CaptureLeaseEntity lease);
 @Query("DELETE FROM capture_lease WHERE requestID=:requestID AND token=:token") int releaseLease(String requestID, String token);
 @Query("DELETE FROM capture_lease WHERE expiresAtEpochMillis<=:now") int clearExpired(long now);
 @Query("SELECT * FROM lease_clock WHERE singletonID=1") LeaseClockEntity readClock();
 @Insert(onConflict=OnConflictStrategy.REPLACE) void putClock(LeaseClockEntity clock);
 @Query("SELECT * FROM installation_identity WHERE singletonID=1") InstallationIdentityEntity readInstallation();
 @Insert(onConflict=OnConflictStrategy.IGNORE) long insertInstallation(InstallationIdentityEntity identity);
 @Query("SELECT * FROM quota_reservation WHERE requestID=:requestID") QuotaReservationEntity readReservation(String requestID);
 @Query("SELECT * FROM quota_reservation ORDER BY requestID") List<QuotaReservationEntity> allReservations();
 @Insert(onConflict=OnConflictStrategy.IGNORE) long insertReservation(QuotaReservationEntity reservation);
 @Query("DELETE FROM quota_reservation WHERE requestID=:requestID AND reservationToken=:token") int releaseReservation(String requestID, String token);
 @Query("SELECT * FROM capture_tombstone WHERE requestID=:requestID") CaptureTombstoneEntity readTombstone(String requestID);
 @Query("SELECT * FROM capture_tombstone ORDER BY requestID") List<CaptureTombstoneEntity> allTombstones();
 @Query("SELECT COALESCE(SUM(quotaUnits),0) FROM capture_tombstone") int committedUnits();
 @Insert(onConflict=OnConflictStrategy.IGNORE) long insertTombstone(CaptureTombstoneEntity tombstone);
}
