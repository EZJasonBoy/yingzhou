package tvbox.engine.core.config

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import tvbox.engine.core.cache.DataCache
import java.io.IOException

/**
 * Downloads a subscription and turns it into a [ConfigDocument]:
 * fetch -> [ConfigDecoder] -> [ConfigLocator.fixContent] -> [ConfigParser].
 */
class ConfigLoader(
    private val http: OkHttpClient,
    private val locator: ConfigLocator,
    /** Keeps the last good download of every address, for starts without (or ahead of) the network. */
    private val cache: DataCache? = null,
    private val sourceRoute: ((String) -> String?)? = null,
) {
    class LoadException(message: String, cause: Throwable? = null) : IOException(message, cause)

    /**
     * The decoded text is returned too, so callers can compare it.
     * [fetchedAt]: when the text was downloaded (0 when unknown); [stored]: it is the kept copy, not a download.
     */
    data class Result(
        val location: ConfigLocation,
        val text: String,
        val document: ConfigDocument,
        val fetchedAt: Long = 0,
        val stored: Boolean = false,
        val cacheKey: String = location.input,
    )

    internal fun routedUrl(input: String): String? = sourceRoute?.invoke(input)

    private fun copyKey(input: String, route: String?): String = if (route == null) input else "$input\u0000$route"

    /** Whether a copy of [input] is kept. */
    fun hasCopy(input: String): Boolean = cache?.get(DataCache.CONFIG, copyKey(input, routedUrl(input))) != null

    /** With [stored] the kept copy of an earlier download is used and nothing is fetched; it fails when there is none. */
    suspend fun load(input: String, stored: Boolean = false): Result = withContext(Dispatchers.IO) {
        val route = routedUrl(input)
        val location = if (route == null) locator.locate(input) else ConfigLocation(input, route, key = null, isClan = false)
        val cacheKey = copyKey(input, route)
        val copy = if (stored) cache?.get(DataCache.CONFIG, cacheKey) ?: throw LoadException("$input: no stored copy") else null
        val body = copy?.text ?: fetch(location.fetchUrl)
        val text = locator.fixContent(location, ConfigDecoder.decode(body, location.key))
        val document = try {
            ConfigParser.parse(text)
        } catch (e: ConfigParser.InvalidConfigException) {
            // A parked domain or an error page answers 200 with HTML; say so instead of quoting a JSON parser.
            val head = body.trimStart().take(200).lowercase()
            val what = if (head.startsWith("<!doctype html") || head.startsWith("<html")) "the address returned a web page, not a config" else e.message
            throw LoadException("${location.fetchUrl}: $what", e)
        }
        // Only what parsed is worth keeping: an error page must not replace a good copy.
        val at = copy?.at ?: cache?.put(DataCache.CONFIG, cacheKey, body)?.at ?: System.currentTimeMillis()
        Result(location, text, document, fetchedAt = at, stored = copy != null, cacheKey = cacheKey)
    }

    private fun fetch(url: String): String {
        try {
            val request = Request.Builder()
                .url(url)
                // TVBox sends this UA for config requests; some subscription hosts gate on it.
                .header("User-Agent", USER_AGENT)
                .build()
            http.newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw LoadException("$url: HTTP ${response.code}")
                return response.body?.string() ?: throw LoadException("$url: empty body")
            }
        } catch (e: LoadException) {
            throw e
        } catch (e: Exception) {
            throw LoadException("$url: ${e.message ?: e.javaClass.simpleName}", e)
        }
    }

    companion object {
        const val USER_AGENT = "okhttp/3.15"
    }
}
