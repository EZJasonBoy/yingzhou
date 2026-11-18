package tvbox.engine.core.net

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * Whether files on GitHub are fetched directly or through an accelerating proxy ("gh-proxy").
 *
 * Subscriptions often hard-code such a proxy in front of their GitHub addresses
 * (`https://gh-proxy.org/https://raw.githubusercontent.com/...`), because GitHub is slow or blocked where their
 * authors live. Those proxies come and go; a dead one makes a perfectly good config answer 404. So the choice is
 * the user's, not the config's:
 *
 * - off (default): GitHub addresses are fetched from GitHub, and a proxy written into an address is taken off;
 * - on: GitHub addresses go through [prefix], whatever proxy the address named, and straight to GitHub when the
 *   proxy fails.
 *
 * Installed as an OkHttp interceptor on the engine's client, so it covers configs, jars, scripts, playlists and
 * the requests spiders make through the host's client.
 */
class GithubProxy(
    @Volatile var enabled: Boolean = false,
    prefix: String = DEFAULT_PREFIX,
) : Interceptor {
    @Volatile var prefix: String = normalize(prefix)
        set(value) {
            field = normalize(value)
        }

    /** The address [url] is fetched from first: itself, unless it is a GitHub address (plain or behind a proxy). */
    fun route(url: String): String {
        val direct = direct(url) ?: return url
        return if (enabled && prefix.isNotEmpty()) prefix + direct else direct
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val url = request.url.toString()
        val direct = direct(url) ?: return chain.proceed(request)
        fun to(target: String) = if (target == url) request else request.newBuilder().url(target).build()
        if (!enabled || prefix.isEmpty()) return chain.proceed(to(direct))
        // Through the proxy; when it is down or does not have the file, GitHub itself gets a try.
        val response = try {
            chain.proceed(to(prefix + direct))
        } catch (e: IOException) {
            return chain.proceed(to(direct))
        }
        if (response.isSuccessful || request.method != "GET") return response
        response.close()
        return chain.proceed(to(direct))
    }

    companion object {
        /** Used when the switch is turned on without naming a proxy. Proxies change; this one answered in 2026-11. */
        const val DEFAULT_PREFIX = "https://ghfast.top/"

        private const val GITHUB_HOST = "(?:(?:raw|gist|objects|media|release-assets)\\.githubusercontent\\.com|(?:gist\\.|codeload\\.)?github\\.com)"

        /** `https://<proxy>/[https://]<github host>/...`: the usual shape of a gh-proxy address. */
        private val WRAPPED = Regex("^https?://([^/?#]+)/(?:(https?):/{1,2})?($GITHUB_HOST/.*)$", RegexOption.IGNORE_CASE)
        private val PLAIN = Regex("^https?://$GITHUB_HOST/.*$", RegexOption.IGNORE_CASE)
        private val HOST_ONLY = Regex("^$GITHUB_HOST$", RegexOption.IGNORE_CASE)

        /** The GitHub address [url] stands for: itself when it is one, what a proxy address wraps, else null. */
        fun direct(url: String): String? {
            if (PLAIN.matches(url)) return url
            val m = WRAPPED.find(url) ?: return null
            // github.com/<user>/raw.githubusercontent.com/... is a repository path, not a proxy.
            if (HOST_ONLY.matches(m.groupValues[1])) return null
            return (m.groupValues[2].ifEmpty { "https" }).lowercase() + "://" + m.groupValues[3]
        }

        /** A proxy prefix always ends with one slash; blank stays blank. */
        fun normalize(prefix: String): String {
            val p = prefix.trim()
            if (p.isEmpty()) return ""
            val withScheme = if (p.startsWith("http://") || p.startsWith("https://")) p else "https://$p"
            return withScheme.trimEnd('/') + "/"
        }
    }
}
