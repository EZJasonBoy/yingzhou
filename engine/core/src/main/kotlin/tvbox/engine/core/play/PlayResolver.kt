package tvbox.engine.core.play

import com.google.gson.JsonObject
import kotlinx.coroutines.async
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import tvbox.engine.core.config.ParseBean
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.SniffRequest
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.site.PlayerResult
import tvbox.engine.core.site.RawPlay
import tvbox.engine.core.vod.TvboxResult
import java.net.URLEncoder

class PlayResolveException(message: String) : Exception(message)

/**
 * Runs the TVBox parse chain on a site's play result (port of `PlayFragment.initParse/doParse/jsonParse`):
 *
 * - `parse == 0 && jx == 0`: play the url directly.
 * - otherwise pick a parser: the site's `playUrl` (`json:` prefix = JSON parser, `parse:Name` = named parser,
 *   anything else = sniff with that prefix), or the config's default parser when `jx == 1` / no `playUrl`.
 * - type 1 (JSON) parsers are called here; type 0 (sniff) pages are sniffed here when the engine has a [Sniffer]
 *   (headless browser / WebView), otherwise handed to the client as a [SniffRequest];
 *   type 4 (super parse) races all JSON parsers.
 *
 * Types 2/3 (JSON ext / mix) need jar spiders and arrive with the jar runtime.
 */
class PlayResolver(
    private val http: SiteHttp,
    /** Replacement for `proxy://`, e.g. `http://127.0.0.1:9978/proxy?`. */
    private val proxyBase: String,
    /** Sniffs web pages on the engine; without one, `kind=sniff` is left to the client. */
    private val sniffer: Sniffer? = null,
) {
    @Volatile private var rules: Pair<String, SniffRules> = "" to SniffRules.NONE

    suspend fun resolve(raw: RawPlay, config: TvboxConfig): PlayInfo {
        val url = replaceProxy(raw.url)
        if (raw.parse == 0 && raw.jx == 0) return PlayInfo(kind = "direct", url = url, headers = raw.headers)

        val parser = chooseParser(raw, config) ?: throw PlayResolveException("this video needs a parser, but the config has none")
        return sniffIfNeeded(runParser(parser, url, config, raw.headers), config)
    }

    /** Resolves `kind=sniff` here when the engine can sniff; otherwise the client gets the page to sniff itself. */
    private suspend fun sniffIfNeeded(info: PlayInfo, config: TvboxConfig): PlayInfo {
        val request = info.sniff ?: return info
        val sniffer = sniffer ?: return info
        val sniffRules = rules.takeIf { it.first == config.rulesJson }?.second
            ?: SniffRules.parse(config.rulesJson).also { rules = config.rulesJson to it }
        val found = sniffer.sniff(request) { sniffRules.isMedia(request.pageUrl, it) }
            ?: throw PlayResolveException("sniffing found no video on the page")
        return PlayInfo(kind = "direct", url = found.url, headers = request.headers + found.headers, parsedBy = info.parsedBy)
    }

    private fun chooseParser(raw: RawPlay, config: TvboxConfig): ParseBean? {
        val playUrl = raw.playUrl.trim()
        val useDefault = raw.jx == 1 || playUrl.isEmpty()
        if (useDefault) return defaultParser(raw.flag, config)
        return when {
            playUrl.startsWith("json:") -> ParseBean(name = "json", url = playUrl.removePrefix("json:"), type = 1)
            playUrl.startsWith("parse:") -> config.parses.firstOrNull { it.name == playUrl.removePrefix("parse:") }
            else -> null
        } ?: ParseBean(name = "sniff", url = playUrl, type = 0)
    }

    /** TVBox uses the user-selected parser, else the first; we prefer a JSON one since it needs no web view. */
    private fun defaultParser(flag: String, config: TvboxConfig): ParseBean? =
        config.parses.firstOrNull { it.type == 1 } ?: config.parses.firstOrNull()

    private suspend fun runParser(parser: ParseBean, url: String, config: TvboxConfig, siteHeaders: Map<String, String>): PlayInfo =
        when (parser.type) {
            0 -> PlayInfo(kind = "sniff", sniff = SniffRequest(pageUrl = parser.url + url, headers = siteHeaders), parsedBy = parser.name)
            1 -> jsonParse(parser, url) ?: throw PlayResolveException("parser ${parser.name} returned no url")
            4 -> superParse(url, config) ?: throw PlayResolveException("no parser could resolve this video")
            else -> {
                // JSON ext / mix need jar support; fall back to the plain JSON parsers.
                superParse(url, config) ?: throw PlayResolveException("parser ${parser.name} (type ${parser.type}) is not supported yet")
            }
        }

    /** Races every JSON parser; the first usable answer wins. */
    private suspend fun superParse(url: String, config: TvboxConfig): PlayInfo? {
        val parsers = config.parses.filter { it.type == 1 }
        if (parsers.isEmpty()) return null
        return coroutineScope {
            val jobs = parsers.map { p -> async { runCatching { jsonParse(p, url) }.getOrNull() } }
            var winner: PlayInfo? = null
            val pending = jobs.toMutableList()
            while (winner == null && pending.isNotEmpty()) {
                val (done, result) = select<Pair<Deferred<PlayInfo?>, PlayInfo?>> {
                    pending.forEach { job -> job.onAwait { job to it } }
                }
                pending.remove(done)
                winner = result
            }
            pending.forEach { it.cancel() }
            winner
        }
    }

    /** GET `parser.url + urlencode(url)`; reads `url`/`data.url`, headers, `user-agent`, `referer`, `parse`. */
    private suspend fun jsonParse(parser: ParseBean, url: String): PlayInfo? {
        val requestHeaders = parserHeaders(parser)
        val text = http.get(parser.url + URLEncoder.encode(url, "UTF-8"), headers = requestHeaders)
        val root = TvboxResult.parseObject(text)
        val data = root.get("data")?.takeIf { it.isJsonObject }?.asJsonObject ?: root
        var result = (data.str("url") ?: root.str("url") ?: "").let { if (it.startsWith("//")) "http:$it" else it }
        var needsSniff = false
        if (result.startsWith("video://")) {
            result = result.removePrefix("video://")
            needsSniff = true
        }
        result = replaceProxy(result)
        if (!result.startsWith("http") && !result.startsWith("data:application")) return null

        val headers = LinkedHashMap<String, String>()
        headers += PlayerResult.headers(root)
        headers += PlayerResult.headers(data)
        (data.str("user-agent") ?: root.str("user-agent"))?.trim()?.takeIf { it.isNotEmpty() }?.let { headers["User-Agent"] = it }
        (data.str("referer") ?: root.str("referer"))?.trim()?.takeIf { it.isNotEmpty() }?.let { headers["Referer"] = it }
        needsSniff = needsSniff || ((data.str("parse") ?: root.str("parse"))?.trim() == "1")

        return if (needsSniff) {
            PlayInfo(kind = "sniff", sniff = SniffRequest(pageUrl = result, headers = headers), parsedBy = parser.name)
        } else {
            PlayInfo(kind = "direct", url = result, headers = headers, parsedBy = parser.name)
        }
    }

    /** A parser's `ext` may carry request headers (`{"header": {...}}`). */
    private fun parserHeaders(parser: ParseBean): Map<String, String> =
        if (parser.ext.isBlank()) emptyMap() else runCatching { PlayerResult.headers(TvboxResult.parseObject(parser.ext)) }.getOrDefault(emptyMap())

    private fun replaceProxy(url: String): String = if (url.startsWith("proxy://")) url.replaceFirst("proxy://", proxyBase) else url

    private fun JsonObject.str(key: String): String? {
        val v = get(key) ?: return null
        return if (v.isJsonPrimitive) v.asString else null
    }
}
