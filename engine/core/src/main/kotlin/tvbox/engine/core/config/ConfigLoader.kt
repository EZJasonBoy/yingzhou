package tvbox.engine.core.config

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException

/**
 * Downloads a subscription and turns it into a [ConfigDocument]:
 * fetch -> [ConfigDecoder] -> [ConfigLocator.fixContent] -> [ConfigParser].
 */
class ConfigLoader(
    private val http: OkHttpClient,
    private val locator: ConfigLocator,
) {
    class LoadException(message: String, cause: Throwable? = null) : IOException(message, cause)

    /** The decoded text is returned too, so callers can cache it. */
    data class Result(val location: ConfigLocation, val text: String, val document: ConfigDocument)

    suspend fun load(input: String): Result = withContext(Dispatchers.IO) {
        val location = locator.locate(input)
        val body = fetch(location.fetchUrl)
        val text = locator.fixContent(location, ConfigDecoder.decode(body, location.key))
        val document = try {
            ConfigParser.parse(text)
        } catch (e: ConfigParser.InvalidConfigException) {
            // A parked domain or an error page answers 200 with HTML; say so instead of quoting a JSON parser.
            val head = body.trimStart().take(200).lowercase()
            val what = if (head.startsWith("<!doctype html") || head.startsWith("<html")) "the address returned a web page, not a config" else e.message
            throw LoadException("${location.fetchUrl}: $what", e)
        }
        Result(location, text, document)
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
