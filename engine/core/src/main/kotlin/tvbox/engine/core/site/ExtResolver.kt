package tvbox.engine.core.site

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tvbox.engine.core.net.SiteHttp
import java.util.concurrent.ConcurrentHashMap

/**
 * TVBox `SourceViewModel.getFixUrl`: the `ext` of a CMS or `type: 4` site that is an http(s) url is replaced by the
 * text it points to (cached for the session). Anything else is passed through. Spiders (`type: 3`) are not given
 * this: TVBox hands them the `ext` as written.
 */
class ExtResolver(private val http: SiteHttp, private val disk: tvbox.engine.core.cache.DataCache? = null) {
    private val cache = ConcurrentHashMap<String, String>()
    private val lock = Mutex()

    suspend fun resolve(ext: String, timeoutMs: Long = 20_000): String {
        if (ext.isEmpty() || !ext.startsWith("http")) return ext
        cache[ext]?.let { return it }
        return lock.withLock {
            cache[ext] ?: runCatching { http.get(ext, timeoutMs = timeoutMs).trim() }
                .onSuccess { cache[ext] = it }
                .onSuccess { disk?.put(tvbox.engine.core.cache.DataCache.EXT, ext, it) }
                // On failure the copy of an earlier download is used when there is one. Otherwise TVBox keeps the url
                // itself as the ext; failures are not cached so they can recover.
                .getOrElse { disk?.get(tvbox.engine.core.cache.DataCache.EXT, ext)?.text ?: ext }
        }
    }

    fun clear() = cache.clear()
}
