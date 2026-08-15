package md.vox.android.data;

import android.content.Context;
import androidx.room.Database;
import androidx.room.Room;
import androidx.room.RoomDatabase;

@Database(entities = {CaptureProjectionEntity.class}, version = 1, exportSchema = true)
public abstract class CaptureDatabase extends RoomDatabase {
    public abstract CaptureProjectionDao captureProjectionDao();

    public static CaptureDatabase create(Context context) {
        return Room.databaseBuilder(context.getApplicationContext(), CaptureDatabase.class, "capture-index-v1.db").build();
    }
}
