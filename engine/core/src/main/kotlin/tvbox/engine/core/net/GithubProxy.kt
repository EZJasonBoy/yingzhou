package tvbox.engine.core.net

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import okhttp3.Interceptor
import okhttp3.Response
import tvbox.engine.core.model.GithubProxyPreset
import tvbox.engine.core.model.GithubProxyProbeResult
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
 * the requests spiders make through the host's client. A request tagged [AsWritten] is left alone ([probe]).
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
        if (request.tag(AsWritten::class.java) != null) return chain.proceed(request)
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

    /** Tags a request that is to go exactly where it is addressed, whatever the setting (measuring a proxy). */
    object AsWritten

    companion object {
        /** Used when the switch is turned on without naming a proxy. Proxies change; this one answered in 2026-11. */
        const val DEFAULT_PREFIX = "https://ghfast.top/"

        /**
         * The proxies offered to pick from. Each fetched [PROBE_URL] and a release asset of this project in 2026-11
         * (5 tries each, all answered); [probe] tells the user which still do. Public gh-proxy instances are run by
         * individuals and vanish without notice: check them again before a release, and drop the dead.
         */
        val PRESETS: List<GithubProxyPreset> = listOf(
            "https://ghfast.top/",
            "https://gh-proxy.com/",
            "https://gh-proxy.org/",
            "https://ghproxy.net/",
            "https://gh.monlor.com/",
            "https://ghm.078465.xyz/",
            "https://ghproxy.imciel.com/",
            "https://git.yylx.win/",
            "https://jiashu.1win.eu.org/",
            "https://gh.dpik.top/",
        ).map { GithubProxyPreset(name = it.removePrefix("https://").trimEnd('/'), prefix = it) }

        /**
         * A small file of this project's public repository at a fixed commit, so it never changes: what [probe]
         * fetches. [PROBE_MARK] is in it, and not in the error pages some proxies answer 200 with.
         */
        const val PROBE_URL = "https://raw.githubusercontent.com/Sa1koro/yingzhou/1eb1e14e7df59ddf061cea981812af38c53bd958/.gitattributes"
        const val PROBE_MARK = "text=auto"
        const val PROBE_TIMEOUT_MS = 8_000L

        /** How many proxies one [probe] asks at most. */
        const val PROBE_MAX = 20

        /**
         * Fetches [file] straight from GitHub (the result with an empty prefix, first) and through each of
         * [prefixes] at once, past whatever the GitHub proxy setting says, and tells which answered with the file
         * and how long that took. Nothing but that one GET is sent to each.
         */
        suspend fun probe(
            http: SiteHttp,
            prefixes: List<String>,
            file: String = PROBE_URL,
            mark: String = PROBE_MARK,
            timeoutMs: Long = PROBE_TIMEOUT_MS,
        ): List<GithubProxyProbeResult> = coroutineScope {
            val targets = listOf("") + prefixes.map(::normalize).filter { it.isNotEmpty() }.distinct().take(PROBE_MAX)
            targets.map { prefix ->
                async {
                    val started = System.nanoTime()
                    fun ms() = (System.nanoTime() - started) / 1_000_000
                    try {
                        val body = http.getAsWritten(prefix + file, timeoutMs)
                        if (mark in body) GithubProxyProbeResult(prefix, ok = true, ms = ms())
                        else GithubProxyProbeResult(prefix, ok = false, ms = ms(), error = "answered, but not with the file")
                    } catch (e: SiteHttpException) {
                        GithubProxyProbeResult(prefix, ok = false, ms = ms(), error = e.message.orEmpty())
                    }
                }
            }.awaitAll()
        }

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
