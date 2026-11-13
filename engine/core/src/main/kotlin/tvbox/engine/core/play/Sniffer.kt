package tvbox.engine.core.play

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import tvbox.engine.core.model.SniffRequest
import tvbox.engine.core.vod.VideoFormat
import java.util.concurrent.ConcurrentHashMap

/**
 * Loads a web page like a browser and reports the first media request (TVBox's web view sniffing).
 * Desktop: headless Edge/Chrome over CDP; Android: a WebView. [SniffRequest.scripts] run once the page has loaded
 * (the config's click scripts, e.g. pressing a play button).
 */
interface Sniffer {
    /** Returns the first request [isMedia] accepts, or null when nothing shows up within the request's timeout. */
    suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult?
}

/** A sniffed media url plus the headers the page used for it (Referer, User-Agent, Cookie). */
data class SniffResult(val url: String, val headers: Map<String, String> = emptyMap())

/**
 * The config's `rules`, as TVBox (Box / TVBoxOS `VideoParseRuler`, FongMi `Rule`) reads them:
 *
 * - `{"host", "rule": [regex...], "filter": [regex...]}`: on pages of that host a request matching every `rule`
 *   pattern is media, one matching every `filter` pattern is not.
 * - `{"hosts": [...], "regex": [...]}`: entries that look like m3u8 content (`#EXT...` tags) or a segment duration
 *   (`15.1666`, `-15.1666` for the last segment) are ad patterns for playlists whose url contains one of the hosts;
 *   the other entries are sniff rules for those hosts. `exclude` entries mark urls that are never media.
 * - `{"hosts": [...], "script": [...]}`: JavaScript run on matching pages while sniffing.
 *
 * Patterns are regular expressions (searched, not matched whole); invalid ones are used as plain text.
 */
class PlayRules private constructor(
    private val sniff: List<HostPatterns>,
    private val filters: List<HostPatterns>,
    private val excludes: List<HostPatterns>,
    private val ads: List<HostPatterns>,
    private val scripts: List<HostPatterns>,
) {
    private class HostPatterns(val hosts: List<String>, val items: List<String>)

    /** Whether [url], requested while sniffing [pageUrl], is the media to play. */
    fun isMedia(pageUrl: String, url: String): Boolean {
        if (!url.startsWith("http://") && !url.startsWith("https://")) return false
        if (url.contains("url=http") || url.contains(".html")) return false
        val pageHost = hostOf(pageUrl)
        val urlHost = hostOf(url)
        if (excludes.any { r -> r.hosts.any { matchesHost(it, pageHost) || matchesHost(it, urlHost) } && r.items.any { url.contains(it) } }) return false
        if (filters.any { r -> r.hosts.any { matchesHost(it, pageHost) } && r.items.all { find(it, url) } }) return false
        if (VideoFormat.isVideo(url)) return true
        return sniff.any { r -> r.hosts.any { matchesHost(it, pageHost) || matchesHost(it, urlHost) } && r.items.all { find(it, url) } }
    }

    /** Click scripts for a page (TVBox: the page url contains the host). */
    fun scriptsFor(pageUrl: String): List<String> =
        scripts.filter { r -> r.hosts.any { it.isNotEmpty() && pageUrl.contains(it) } }.flatMap { it.items }.distinct()

    /** Ad patterns for a playlist (TVBox: the playlist url contains the host). */
    fun adsFor(playlistUrl: String): List<String> =
        ads.filter { r -> r.hosts.any { it.isNotEmpty() && playlistUrl.contains(it) } }.flatMap { it.items }.distinct()

    companion object {
        val NONE = PlayRules(emptyList(), emptyList(), emptyList(), emptyList(), emptyList())

        private val patterns = ConcurrentHashMap<String, Regex>()

        fun parse(rulesJson: String): PlayRules {
            if (rulesJson.isBlank()) return NONE
            val array = runCatching { JsonParser.parseString(rulesJson).asJsonArray }.getOrNull() ?: return NONE
            val sniff = ArrayList<HostPatterns>()
            val filters = ArrayList<HostPatterns>()
            val excludes = ArrayList<HostPatterns>()
            val ads = ArrayList<HostPatterns>()
            val scripts = ArrayList<HostPatterns>()
            for (e in array) {
                val o = e.takeIf { it.isJsonObject }?.asJsonObject ?: continue
                val hosts = (o.strings("hosts") + listOfNotNull(o.string("host"))).map { it.trim() }.filter { it.isNotEmpty() }
                if (hosts.isEmpty()) continue
                o.strings("rule").takeIf { it.isNotEmpty() }?.let { sniff += HostPatterns(hosts, it) }
                o.strings("filter").takeIf { it.isNotEmpty() }?.let { filters += HostPatterns(hosts, it) }
                o.strings("exclude").takeIf { it.isNotEmpty() }?.let { excludes += HostPatterns(hosts, it) }
                o.strings("script").takeIf { it.isNotEmpty() }?.let { scripts += HostPatterns(hosts, it) }
                val (adPatterns, sniffPatterns) = o.strings("regex").partition(::isAdPattern)
                if (adPatterns.isNotEmpty()) ads += HostPatterns(hosts, adPatterns)
                if (sniffPatterns.isNotEmpty()) sniff += HostPatterns(hosts, sniffPatterns)
            }
            return PlayRules(sniff, filters, excludes, ads, scripts)
        }

        /** Box `M3U8.isAd`: playlist tags, or a (possibly negative) segment duration. */
        fun isAdPattern(p: String): Boolean =
            listOf("#EXT-X-DISCONTINUITY", "#EXTINF", "#EXT-X-ENDLIST", "#EXT-X-KEY", "#EXT-X-CUE", "#EXT-X-DATERANGE").any { p.contains(it) } ||
                (p.toDoubleOrNull() ?: 0.0) != 0.0

        /** `*` matches every page; a configured host may carry a scheme ("https://api.example.com"). */
        private fun matchesHost(configured: String, host: String): Boolean {
            if (configured == "*") return true
            val h = configured.substringAfter("://").substringBefore('/').lowercase()
            return host == h || host.endsWith(".$h")
        }

        internal fun find(pattern: String, text: String): Boolean {
            val regex = patterns.getOrPut(pattern) { runCatching { Regex(pattern) }.getOrElse { Regex(Regex.escape(pattern)) } }
            return regex.containsMatchIn(text)
        }

        internal fun hostOf(url: String) = url.substringAfter("://", "").substringBefore('/').substringBefore('?').substringBefore(':').lowercase()

        private fun JsonObject.string(key: String) = get(key)?.takeIf { it.isJsonPrimitive }?.asString

        private fun JsonObject.strings(key: String): List<String> =
            (get(key) as? JsonArray)?.mapNotNull { it.takeIf { e -> e.isJsonPrimitive }?.asString } ?: emptyList()
    }
}
