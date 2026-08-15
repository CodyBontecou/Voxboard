package md.vox.android.data;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.room.Database;
import androidx.room.Room;
import androidx.room.RoomDatabase;
import androidx.room.migration.Migration;
import androidx.sqlite.db.SupportSQLiteDatabase;

@Database(entities = {CaptureProjectionEntity.class, CaptureLeaseEntity.class, LeaseClockEntity.class,
        InstallationIdentityEntity.class, QuotaReservationEntity.class, CaptureTombstoneEntity.class}, version = 2, exportSchema = true)
public abstract class CaptureDatabase extends RoomDatabase {
    public abstract CaptureProjectionDao captureProjectionDao();
    public abstract CaptureCoordinationDao captureCoordinationDao();

    public static final Migration MIGRATION_1_2 = new Migration(1, 2) {
        @Override public void migrate(@NonNull SupportSQLiteDatabase db) {
            db.execSQL("ALTER TABLE capture_projection ADD COLUMN attemptCount INTEGER NOT NULL DEFAULT 0");
            db.execSQL("CREATE TABLE IF NOT EXISTS capture_lease (requestID TEXT NOT NULL, token TEXT NOT NULL, expiresAtEpochMillis INTEGER NOT NULL, PRIMARY KEY(requestID))");
            db.execSQL("CREATE TABLE IF NOT EXISTS lease_clock (singletonID INTEGER NOT NULL, maxObservedEpochMillis INTEGER NOT NULL, PRIMARY KEY(singletonID))");
            db.execSQL("CREATE TABLE IF NOT EXISTS installation_identity (singletonID INTEGER NOT NULL, installationID TEXT NOT NULL, createdAtEpochMillis INTEGER NOT NULL, PRIMARY KEY(singletonID))");
            db.execSQL("CREATE TABLE IF NOT EXISTS quota_reservation (requestID TEXT NOT NULL, reservationToken TEXT NOT NULL, installationID TEXT NOT NULL, reservedAtEpochMillis INTEGER NOT NULL, updatedAtEpochMillis INTEGER NOT NULL, PRIMARY KEY(requestID))");
            db.execSQL("CREATE TABLE IF NOT EXISTS capture_tombstone (requestID TEXT NOT NULL, installationID TEXT NOT NULL, state TEXT NOT NULL, completedAtEpochMillis INTEGER NOT NULL, destinationID TEXT NOT NULL, receiptID TEXT NOT NULL, packageVersion INTEGER NOT NULL, journalVersion INTEGER NOT NULL, requestContractVersion INTEGER NOT NULL, finalJournalRevision INTEGER NOT NULL, coreVersion TEXT NOT NULL, rendererVersion TEXT NOT NULL, profileID TEXT NOT NULL, profileVersion INTEGER NOT NULL, quotaUnits INTEGER NOT NULL, PRIMARY KEY(requestID))");
        }
    };

    public static CaptureDatabase create(Context context) {
        return Room.databaseBuilder(context.getApplicationContext(), CaptureDatabase.class, "capture-index-v1.db")
                .addMigrations(MIGRATION_1_2).build();
    }
}
