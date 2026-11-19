package tvbox.engine.core.cache

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/**
 * Answers of sites (home, category pages, details) and live lists, kept for a while.
 *
 * - [get]: an answer younger than its lifetime is served as it is; an older one is served too, at once, while a
 *   fresh one is fetched in the background ("stale while revalidate") - so a slow site costs its delay once, and a
 *   dead network still shows what was seen before. `refresh` fetches now and replaces the kept answer.
 * - [orStored]: the network first; the kept answer only when that fails.
 *
 * Keys are made by the engine and start with the config's fingerprint and the site, so answers never cross sites
 * or configs, and a config that changed simply stops finding the old ones. Search and play are never kept.
 */
class SiteDataCache(
    private val cache: DataCache,
    private val background: CoroutineScope,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val revalidating: MutableSet<String> = ConcurrentHashMap.newKeySet()

    suspend fun <T> get(
        key: String,
        lifetimeMs: Long,
        refresh: Boolean,
        serializer: KSerializer<T>,
        /** An empty answer (a site having a bad moment) is passed on but not kept. */
        worthKeeping: (T) -> Boolean,
        fetch: suspend () -> T,
    ): T {
        val kept = if (refresh) null else cache.get(DataCache.SITE, key)
        val value = kept?.let { runCatching { json.decodeFromString(serializer, it.text) }.getOrNull() }
        if (kept == null || value == null) return fetch().also { store(DataCache.SITE, key, serializer, it, worthKeeping) }
        if (now() - kept.at > lifetimeMs && revalidating.add(key)) {
            background.launch {
                try {
                    store(DataCache.SITE, key, serializer, fetch(), worthKeeping)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // The site is slow or gone: the kept answer stays.
                } finally {
                    revalidating.remove(key)
                }
            }
        }
        return value
    }

    suspend fun <T> orStored(area: String, key: String, serializer: KSerializer<T>, fetch: suspend () -> T): T =
        try {
            fetch().also { store(area, key, serializer, it) { true } }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            cache.get(area, key)?.let { runCatching { json.decodeFromString(serializer, it.text) }.getOrNull() } ?: throw e
        }

    private fun <T> store(area: String, key: String, serializer: KSerializer<T>, value: T, worthKeeping: (T) -> Boolean) {
        if (worthKeeping(value)) cache.put(area, key, json.encodeToString(serializer, value))
    }
}

/**
 * Rides along with one activation of a config: whether it reads the kept copies instead of the network, and what
 * it loaded (address and a hash of the text), which is the config's fingerprint.
 */
class LoadTrace(val stored: Boolean = false) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<LoadTrace>

    val loaded = CopyOnWriteArrayList<Pair<String, String>>()

    /** When the oldest of the loaded texts was downloaded. */
    @Volatile var fetchedAt = 0L

    fun add(url: String, text: String, at: Long) {
        loaded += url to DataCache.hash(text)
        if (at > 0 && (fetchedAt == 0L || at < fetchedAt)) fetchedAt = at
    }
}
