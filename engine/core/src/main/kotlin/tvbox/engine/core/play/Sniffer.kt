package tvbox.engine.core.play

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import tvbox.engine.core.model.SniffRequest
import com.google.gson.JsonParser
import tvbox.engine.core.vod.VideoFormat

/**
 * Loads a web page like a browser and reports the first media request (TVBox's web view sniffing).
 * Desktop: headless Edge/Chrome over CDP; Android: a WebView.
 */
interface Sniffer {
    /** Returns the first request [isMedia] accepts, or null when nothing shows up within the request's timeout. */
    suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult?
}

/** A sniffed media url plus the headers the page used for it (Referer, User-Agent, Cookie). */
data class SniffResult(val url: String, val headers: Map<String, String> = emptyMap())

/**
 * Which requests count as media while sniffing a page (TVBox `PlayFragment.checkVideoFormat` + `VideoParseRuler`):
 * the config's `rules` (`{"host": "...", "rule": [...], "filter": [...]}`: on pages of that host, a url containing
 * every `rule` string is media, one containing every `filter` string is not), then [VideoFormat].
 */
class SniffRules private constructor(
    private val hostRules: List<Pair<String, List<String>>>,
    private val hostFilters: List<Pair<String, List<String>>>,
) {
    fun isMedia(pageUrl: String, url: String): Boolean {
        if (!url.startsWith("http://") && !url.startsWith("https://")) return false
        if (url.contains("url=http") || url.contains(".html")) return false
        val host = hostOf(pageUrl)
        if (hostFilters.any { (h, items) -> host.contains(h) && items.all { url.contains(it) } }) return false
        if (hostRules.any { (h, items) -> host.contains(h) && items.all { url.contains(it) } }) return true
        return VideoFormat.isVideo(url)
    }

    companion object {
        val NONE = SniffRules(emptyList(), emptyList())

        fun parse(rulesJson: String): SniffRules {
            if (rulesJson.isBlank()) return NONE
            val rules = ArrayList<Pair<String, List<String>>>()
            val filters = ArrayList<Pair<String, List<String>>>()
            val array = runCatching { JsonParser.parseString(rulesJson).asJsonArray }.getOrNull() ?: return NONE
            for (e in array) {
                val o = e.takeIf { it.isJsonObject }?.asJsonObject ?: continue
                val hosts = o.strings("hosts") + listOfNotNull(o.string("host"))
                val rule = o.strings("rule")
                val filter = o.strings("filter")
                for (h in hosts.filter { it.isNotBlank() }) {
                    if (rule.isNotEmpty()) rules += h to rule
                    if (filter.isNotEmpty()) filters += h to filter
                }
            }
            return SniffRules(rules, filters)
        }

        private fun hostOf(url: String) = url.substringAfter("://", "").substringBefore('/').substringBefore('?').lowercase()

        private fun JsonObject.string(key: String) = get(key)?.takeIf { it.isJsonPrimitive }?.asString

        private fun JsonObject.strings(key: String): List<String> =
            (get(key) as? JsonArray)?.mapNotNull { it.takeIf { e -> e.isJsonPrimitive }?.asString } ?: emptyList()
    }
}
