package tvbox.engine.core.store

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import tvbox.engine.core.model.EngineSettings
import tvbox.engine.core.model.FavoriteEntry
import tvbox.engine.core.model.HistoryEntry
import tvbox.engine.core.model.Subscription
import java.io.File
import java.io.IOException

/** Subscriptions plus which one is active (and which repo of it). */
@Serializable
data class SubscriptionState(
    val subscriptions: List<Subscription> = emptyList(),
    val activeId: String? = null,
    val activeRepo: String? = null,
    /** The groups the active repo is nested in, outermost first; empty for a top-level entry. */
    val activeRepoPath: List<String> = emptyList(),
)

/** Persistence for engine data. Implementations must be safe to call from any thread. */
interface EngineStore {
    fun loadSubscriptions(): SubscriptionState
    fun saveSubscriptions(state: SubscriptionState)
    fun loadHistory(): List<HistoryEntry>
    fun saveHistory(entries: List<HistoryEntry>)
    fun loadFavorites(): List<FavoriteEntry>
    fun saveFavorites(entries: List<FavoriteEntry>)

    /** Engine settings; a store that does not keep them answers the defaults. */
    fun loadSettings(): EngineSettings = EngineSettings()
    fun saveSettings(settings: EngineSettings) {}

    /** LAN sharing and paired devices; a store that does not keep them answers "off, nobody paired". */
    fun loadAccess(): AccessState = AccessState()
    fun saveAccess(state: AccessState) {}

    /** Cloud drives and folders, credentials included (they never leave the engine); a store that does not keep them answers none. */
    fun loadDrives(): List<tvbox.engine.core.drive.DriveConfig> = emptyList()
    fun saveDrives(drives: List<tvbox.engine.core.drive.DriveConfig>) {}
}

/** Keeps everything in memory (tests, demo mode). */
class MemoryStore : EngineStore {
    @Volatile private var subs = SubscriptionState()
    @Volatile private var history = emptyList<HistoryEntry>()
    @Volatile private var favorites = emptyList<FavoriteEntry>()

    override fun loadSubscriptions() = subs
    override fun saveSubscriptions(state: SubscriptionState) { subs = state }
    override fun loadHistory() = history
    override fun saveHistory(entries: List<HistoryEntry>) { history = entries }
    override fun loadFavorites() = favorites
    override fun saveFavorites(entries: List<FavoriteEntry>) { favorites = entries }

    @Volatile private var settings = EngineSettings()
    override fun loadSettings() = settings
    override fun saveSettings(settings: EngineSettings) { this.settings = settings }

    @Volatile private var access = AccessState()
    override fun loadAccess() = access
    override fun saveAccess(state: AccessState) { access = state }

    @Volatile private var drives = emptyList<tvbox.engine.core.drive.DriveConfig>()
    override fun loadDrives() = drives
    override fun saveDrives(drives: List<tvbox.engine.core.drive.DriveConfig>) { this.drives = drives }
}

/**
 * One JSON file per collection in [dir]. Writes go to a temp file that is then moved over the old one,
 * so a crash never leaves a half-written file. Unreadable files are kept aside as `*.broken` and start empty.
 */
class JsonFileStore(private val dir: File) : EngineStore {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }
    private val lock = Any()

    init {
        dir.mkdirs()
    }

    override fun loadSubscriptions() = read("subscriptions.json", SubscriptionState.serializer()) ?: SubscriptionState()
    override fun saveSubscriptions(state: SubscriptionState) = write("subscriptions.json", SubscriptionState.serializer(), state)
    override fun loadHistory() = read("history.json", HistoryFile.serializer())?.entries ?: emptyList()
    override fun saveHistory(entries: List<HistoryEntry>) = write("history.json", HistoryFile.serializer(), HistoryFile(entries))
    override fun loadFavorites() = read("favorites.json", FavoritesFile.serializer())?.entries ?: emptyList()
    override fun saveFavorites(entries: List<FavoriteEntry>) = write("favorites.json", FavoritesFile.serializer(), FavoritesFile(entries))
    override fun loadSettings() = read("settings.json", EngineSettings.serializer()) ?: EngineSettings()
    override fun saveSettings(settings: EngineSettings) = write("settings.json", EngineSettings.serializer(), settings)
    override fun loadAccess() = read("access.json", AccessState.serializer()) ?: AccessState()
    override fun saveAccess(state: AccessState) = write("access.json", AccessState.serializer(), state)
    override fun loadDrives() = read("drives.json", DrivesFile.serializer())?.entries ?: emptyList()
    override fun saveDrives(drives: List<tvbox.engine.core.drive.DriveConfig>) = write("drives.json", DrivesFile.serializer(), DrivesFile(drives))

    private fun <T> read(name: String, serializer: KSerializer<T>): T? = synchronized(lock) {
        val file = File(dir, name)
        if (!file.exists()) return null
        try {
            json.decodeFromString(serializer, file.readText())
        } catch (e: Exception) {
            file.renameTo(File(dir, "$name.broken"))
            null
        }
    }

    private fun <T> write(name: String, serializer: KSerializer<T>, value: T) = synchronized(lock) {
        val target = File(dir, name)
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(json.encodeToString(serializer, value))
        // rename() replaces atomically on Linux/Android; Windows refuses to overwrite, so delete first there.
        // (java.nio.file is avoided: it needs Android 8.0+, and many TV boxes run 7.x.)
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) throw IOException("cannot write ${target.path}")
        }
    }

    @Serializable
    private data class HistoryFile(val entries: List<HistoryEntry> = emptyList())

    @Serializable
    private data class FavoritesFile(val entries: List<FavoriteEntry> = emptyList())

    @Serializable
    private data class DrivesFile(val entries: List<tvbox.engine.core.drive.DriveConfig> = emptyList())
}
