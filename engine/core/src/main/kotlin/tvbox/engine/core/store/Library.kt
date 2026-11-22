package tvbox.engine.core.store

import tvbox.engine.core.model.FavoriteEntry
import tvbox.engine.core.model.HistoryEntry

/**
 * Watch history and favorites. Lives in the engine, so every client connected to the same engine
 * sees the same progress ("stopped on the TV, continue on the phone").
 */
class Library(
    private val store: EngineStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val maxHistory: Int = 500,
) {
    private val lock = Any()
    private val history = LinkedHashMap<String, HistoryEntry>()
    private val favorites = LinkedHashMap<String, FavoriteEntry>()

    init {
        store.loadHistory().forEach { history[key(it.site, it.vodId)] = it }
        store.loadFavorites().forEach { favorites[key(it.site, it.vodId)] = it }
    }

    fun history(limit: Int = 100): List<HistoryEntry> = synchronized(lock) {
        history.values.sortedByDescending { it.updatedAt }.take(limit.coerceIn(1, maxHistory))
    }

    fun historyFor(site: String, vodId: String): HistoryEntry? = synchronized(lock) { history[key(site, vodId)] }

    fun putHistory(entry: HistoryEntry): HistoryEntry = synchronized(lock) {
        val stamped = entry.copy(updatedAt = clock())
        history[key(entry.site, entry.vodId)] = stamped
        if (history.size > maxHistory) {
            history.values.sortedBy { it.updatedAt }.take(history.size - maxHistory)
                .forEach { history.remove(key(it.site, it.vodId)) }
        }
        store.saveHistory(history.values.toList())
        stamped
    }

    fun removeHistory(site: String, vodId: String): Boolean = synchronized(lock) {
        val removed = history.remove(key(site, vodId)) != null
        if (removed) store.saveHistory(history.values.toList())
        removed
    }

    fun clearHistory() = synchronized(lock) {
        history.clear()
        store.saveHistory(emptyList())
    }

    fun favorites(): List<FavoriteEntry> = synchronized(lock) { favorites.values.sortedByDescending { it.addedAt } }

    fun favoriteFor(site: String, vodId: String): FavoriteEntry? = synchronized(lock) { favorites[key(site, vodId)] }

    /** Adding an existing favorite refreshes its fields but keeps when it was first added. */
    fun putFavorite(entry: FavoriteEntry): FavoriteEntry = synchronized(lock) {
        val k = key(entry.site, entry.vodId)
        val stamped = entry.copy(addedAt = favorites[k]?.addedAt ?: clock())
        favorites[k] = stamped
        store.saveFavorites(favorites.values.toList())
        stamped
    }

    fun removeFavorite(site: String, vodId: String): Boolean = synchronized(lock) {
        val removed = favorites.remove(key(site, vodId)) != null
        if (removed) store.saveFavorites(favorites.values.toList())
        removed
    }

    /** What a merge did, or would do: entries added, entries that replaced older ones, entries left as they were. */
    data class Merge(val add: Int, val update: Int, val keep: Int)

    /**
     * Brings history from elsewhere (a backup) in: a video not here is added; one watched later there than here (by
     * [HistoryEntry.updatedAt]) takes the place of what is here; for the others what is here stays. Entries keep
     * their own times. With [write] false nothing changes, the answer says what would.
     */
    fun mergeHistory(entries: List<HistoryEntry>, write: Boolean = true): Merge = synchronized(lock) {
        val work = if (write) history else LinkedHashMap(history)
        var add = 0
        var update = 0
        var keep = 0
        for (e in entries) {
            if (e.site.isBlank() || e.vodId.isBlank()) continue
            val k = key(e.site, e.vodId)
            val here = work[k]
            when {
                here == null -> { work[k] = e; add++ }
                e.updatedAt > here.updatedAt -> { work[k] = e; update++ }
                else -> keep++
            }
        }
        if (write && add + update > 0) {
            if (history.size > maxHistory) {
                history.values.sortedBy { it.updatedAt }.take(history.size - maxHistory)
                    .forEach { history.remove(key(it.site, it.vodId)) }
            }
            store.saveHistory(history.values.toList())
        }
        Merge(add, update, keep)
    }

    /** Favorites from elsewhere: those not here are added (with when they were added there); [Merge.keep] the rest. */
    fun mergeFavorites(entries: List<FavoriteEntry>, write: Boolean = true): Merge = synchronized(lock) {
        val work = if (write) favorites else LinkedHashMap(favorites)
        var add = 0
        var keep = 0
        for (e in entries) {
            if (e.site.isBlank() || e.vodId.isBlank()) continue
            val k = key(e.site, e.vodId)
            if (work.containsKey(k)) {
                keep++
            } else {
                work[k] = if (e.addedAt > 0) e else e.copy(addedAt = clock())
                add++
            }
        }
        if (write && add > 0) store.saveFavorites(favorites.values.toList())
        Merge(add, 0, keep)
    }

    private fun key(site: String, vodId: String) = site + '\u0000' + vodId
}
