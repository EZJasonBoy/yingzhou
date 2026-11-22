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
import tvbox.engine.core.util.Base64Compat
import tvbox.engine.core.vod.TvboxResult
import java.net.URLEncoder

class PlayResolveException(message: String) : Exception(message)

/** Parsers that live in the config's spider jar: `com.github.catvod.parser.Json<key>` (type 2) and `Mix<key>` (type 3). */
interface JarParsers {
    /** `Json<key>.parse(LinkedHashMap<name, url>, url)`; the returned JSON object as text, or null. */
    suspend fun jsonExt(key: String, jxs: LinkedHashMap<String, String>, url: String): String?

    /** `Mix<key>.parse(LinkedHashMap<name, {url, type, ext}>, name, flag, url)`; the returned JSON object as text, or null. */
    suspend fun jsonExtMix(flag: String, key: String, name: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): String?
}

/**
 * Runs the TVBox parse chain on a site's play result (port of `PlayFragment.initParse/doParse/jsonParse/parseMix`):
 *
 * - `parse == 0 && jx == 0`: play the url directly.
 * - otherwise pick a parser: the site's `playUrl` (`json:` prefix = JSON parser, `parse:Name` = named parser,
 *   anything else = sniff with that prefix), or the config's first parser (TVBox's default) when `jx == 1` / no
 *   `playUrl`. When that parser fails, every JSON parser is raced as a fallback.
 * - type 0 (sniff) pages are sniffed here when the engine has a [Sniffer] (headless browser / WebView), otherwise
 *   handed to the client as a [SniffRequest]; type 1 (JSON) parsers are called here; types 2/3 run the spider jar's
 *   parser classes ([JarParsers]); type 4 (super parse) races all JSON parsers.
 * - HLS urls are routed through the engine's playlist endpoint ([playlistBase]) so ads can be cut ([M3u8Cleaner]).
 */
class PlayResolver(
    private val http: SiteHttp,
    /** Replacement for `proxy://`, e.g. `http://127.0.0.1:9978/proxy?`. */
    private val proxyBase: String,
    /** Sniffs web pages on the engine; without one, `kind=sniff` is left to the client. */
    private val sniffer: Sniffer? = null,
    private val jarParsers: JarParsers? = null,
    /** The engine's playlist endpoint, e.g. `http://127.0.0.1:9978/m3u8?`; null leaves HLS urls alone. */
    private val playlistBase: String? = null,
) {
    @Volatile private var rules: Pair<String, PlayRules> = "" to PlayRules.NONE

    fun rules(config: TvboxConfig): PlayRules =
        rules.takeIf { it.first == config.rulesJson }?.second ?: PlayRules.parse(config.rulesJson).also { rules = config.rulesJson to it }

    /**
     * [sniff] false leaves a page that needs sniffing to the caller (`kind=sniff`) even when the engine could sniff it:
     * the line probe reports such a line as it is instead of opening a browser for it.
     */
    suspend fun resolve(raw: RawPlay, config: TvboxConfig, sniff: Boolean = true): PlayInfo {
        val url = replaceProxy(raw.url)
        val info = if (raw.parse == 0 && raw.jx == 0) {
            PlayInfo(kind = "direct", url = url, headers = raw.headers)
        } else {
            val parser = chooseParser(raw, config) ?: throw PlayResolveException("this video needs a parser, but the config has none")
            try {
                sniffIfNeeded(runParser(parser, url, raw, config), config, sniff)
            } catch (e: Exception) {
                if (parser.type == 1 || parser.type == 4) throw e
                // TVBox stops here; racing the JSON parsers gives the video another chance.
                superParse(url, config)?.let { sniffIfNeeded(it, config, sniff) } ?: throw e
            }
        }
        return withPlaylist(info)
    }

    /** Resolves `kind=sniff` here when the engine can sniff; otherwise the client gets the page to sniff itself. */
    private suspend fun sniffIfNeeded(info: PlayInfo, config: TvboxConfig, sniff: Boolean): PlayInfo {
        val request = info.sniff ?: return info
        val playRules = rules(config)
        val withScripts = request.copy(scripts = playRules.scriptsFor(request.pageUrl))
        val sniffer = sniffer?.takeIf { sniff } ?: return info.copy(sniff = withScripts)
        val found = sniffer.sniff(withScripts) { playRules.isMedia(request.pageUrl, it) }
            ?: throw PlayResolveException("sniffing found no video on the page")
        return PlayInfo(kind = "direct", url = found.url, headers = request.headers + found.headers, parsedBy = info.parsedBy)
    }

    /** HLS through the engine, which removes ads and falls back to the original playlist on any trouble. */
    private fun withPlaylist(info: PlayInfo): PlayInfo {
        val base = playlistBase ?: return info
        if (info.kind != "direct" || !info.url.contains(".m3u8") || !info.url.startsWith("http")) return info
        if (info.url.startsWith(proxyBase.substringBefore("/proxy"))) return info
        return info.copy(url = playlistUrl(base, info.url, info.headers))
    }

    private fun chooseParser(raw: RawPlay, config: TvboxConfig): ParseBean? {
        val playUrl = raw.playUrl.trim()
        val useDefault = raw.jx == 1 || playUrl.isEmpty()
        if (useDefault) return defaultParser(config)
        return when {
            playUrl.startsWith("json:") -> ParseBean(name = "json", url = playUrl.removePrefix("json:"), type = 1)
            playUrl.startsWith("parse:") -> config.parses.firstOrNull { it.name == playUrl.removePrefix("parse:") }
            else -> null
        } ?: ParseBean(name = "sniff", url = playUrl, type = 0)
    }

    /** TVBox's default parser is the first one; jar parsers count only when the jar runtime is there. */
    private fun defaultParser(config: TvboxConfig): ParseBean? =
        config.parses.firstOrNull { (it.type != 2 && it.type != 3) || jarParsers != null }

    private suspend fun runParser(parser: ParseBean, url: String, raw: RawPlay, config: TvboxConfig): PlayInfo =
        when (parser.type) {
            0 -> PlayInfo(kind = "sniff", sniff = SniffRequest(pageUrl = parser.url + url, headers = raw.headers), parsedBy = parser.name)
            1 -> jsonParse(parser, url) ?: throw PlayResolveException("parser ${parser.name} returned no url")
            2 -> jarParse(parser) { p ->
                val jxs = LinkedHashMap<String, String>()
                config.parses.filter { it.type == 1 }.forEach { jxs[it.name] = mixUrl(it) }
                p.jsonExt(parser.url, jxs, url)
            }
            3 -> jarParse(parser) { p ->
                val jxs = LinkedHashMap<String, HashMap<String, String>>()
                var name = ""
                for (it in config.parses) {
                    if (it.url == parser.url) name = it.name
                    jxs[it.name] = hashMapOf("url" to it.url, "type" to it.type.toString(), "ext" to it.ext)
                }
                // TVBox passes the line's flag with "111" appended.
                p.jsonExtMix(raw.flag + "111", parser.url, name, jxs, url)
            }
            4 -> superParse(url, config) ?: throw PlayResolveException("no parser could resolve this video")
            else -> superParse(url, config) ?: throw PlayResolveException("parser ${parser.name} (type ${parser.type}) is not supported")
        }

    /** Runs a jar parser and reads its answer like TVBox: `url`, `header`, `ua`, `parse` (1 = sniff `url`), `jxFrom`. */
    private suspend fun jarParse(parser: ParseBean, call: suspend (JarParsers) -> String?): PlayInfo {
        val parsers = jarParsers ?: throw PlayResolveException("parser ${parser.name} needs the spider jar")
        val text = call(parsers) ?: throw PlayResolveException("parser ${parser.name} returned nothing")
        val root = runCatching { TvboxResult.parseObject(text) }.getOrNull() ?: throw PlayResolveException("parser ${parser.name} returned invalid JSON")
        val result = replaceProxy(root.str("url").orEmpty().trim())
        if (result.isEmpty()) throw PlayResolveException("parser ${parser.name} returned no url")
        val headers = LinkedHashMap(PlayerResult.headers(root))
        root.str("ua")?.trim()?.takeIf { it.isNotEmpty() }?.let { headers["User-Agent"] = it }
        val from = root.str("jxFrom")?.takeIf { it.isNotBlank() }?.let { "${parser.name} · $it" } ?: parser.name
        return if (root.str("parse")?.trim() == "1") {
            PlayInfo(kind = "sniff", sniff = SniffRequest(pageUrl = result, headers = headers), parsedBy = from)
        } else {
            PlayInfo(kind = "direct", url = result, headers = headers, parsedBy = from)
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

    companion object {
        /** TVBox `ParseBean.mixUrl`: a JSON parser with `ext` gets it as `cat_ext=<url-safe base64>` in its query. */
        fun mixUrl(p: ParseBean): String {
            if (p.ext.isEmpty()) return p.url
            val idx = p.url.indexOf('?')
            if (idx <= 0) return p.url
            val ext = Base64Compat.encode(p.ext.toByteArray(), urlSafe = true)
            return p.url.substring(0, idx + 1) + "cat_ext=" + ext + "&" + p.url.substring(idx + 1)
        }

        /** `<base>url=<encoded>[&h=<url-safe base64 of the headers as JSON>]`. */
        fun playlistUrl(base: String, url: String, headers: Map<String, String>): String {
            val sb = StringBuilder(base).append("url=").append(URLEncoder.encode(url, "UTF-8"))
            if (headers.isNotEmpty()) {
                val json = com.google.gson.Gson().toJson(headers)
                sb.append("&h=").append(Base64Compat.encode(json.toByteArray(), urlSafe = true, padding = false))
            }
            return sb.toString()
        }

        /**
         * The source address and headers inside an engine playlist address made by [playlistUrl] (with whatever the
         * engine added after them, `&k=` or `&d=1`); null when [address] is not one.
         */
        fun unwrapPlaylist(base: String, address: String): Pair<String, Map<String, String>>? {
            if (!address.startsWith(base)) return null
            var url = ""
            var headers = emptyMap<String, String>()
            for (part in address.substring(base.length).split('&')) {
                val name = part.substringBefore('=')
                val value = part.substringAfter('=', "")
                when (name) {
                    "url" -> url = java.net.URLDecoder.decode(value, "UTF-8")
                    "h" -> headers = runCatching {
                        com.google.gson.JsonParser.parseString(String(Base64Compat.decode(value))).asJsonObject.entrySet()
                            .associate { (k, v) -> k to (if (v.isJsonPrimitive) v.asString else v.toString()) }
                    }.getOrDefault(emptyMap())
                }
            }
            return if (url.isEmpty()) null else url to headers
        }
    }
}
