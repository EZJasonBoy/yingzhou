package tvbox.engine.core.site

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tvbox.engine.core.net.SiteHttp
import java.util.concurrent.ConcurrentHashMap

/**
 * TVBox `SourceViewModel.getFixUrl`: a site `ext` that is an http(s) url is replaced by the text it points to
 * (cached for the session). Anything else is passed through.
 */
class ExtResolver(private val http: SiteHttp) {
    private val cache = ConcurrentHashMap<String, String>()
    private val lock = Mutex()

    suspend fun resolve(ext: String, timeoutMs: Long = 20_000): String {
        if (ext.isEmpty() || !ext.startsWith("http")) return ext
        cache[ext]?.let { return it }
        return lock.withLock {
            cache[ext] ?: runCatching { http.get(ext, timeoutMs = timeoutMs).trim() }
                .onSuccess { cache[ext] = it }
                // On failure TVBox keeps the url itself as the ext; failures are not cached so they can recover.
                .getOrDefault(ext)
        }
    }

    fun clear() = cache.clear()
}
