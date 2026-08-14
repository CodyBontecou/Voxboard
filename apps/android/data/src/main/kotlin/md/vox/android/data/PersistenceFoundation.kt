package md.vox.android.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.room.RoomDatabase
import androidx.work.WorkManager

/** Dependency boundary only. No database, preference, worker, or persistence behavior exists yet. */
interface PersistenceFoundation {
    val roomDatabase: RoomDatabase
    val preferences: DataStore<Preferences>
    val workManager: WorkManager
}
