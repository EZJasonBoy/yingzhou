package tvbox.engine.core.live

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.LiveChannel
import tvbox.engine.core.model.LiveGroup
import tvbox.engine.core.model.LiveUrl
import tvbox.engine.core.util.Base64Compat

/**
 * One entry of the config's `lives`. Forms seen in real configs (TVBox / Box / FongMi):
 *
 * - `{"name", "type": 0, "url", "epg", "logo", "ua", "header"}`: a TXT or M3U playlist at `url`;
 * - `{"group", "channels": [{"name", "urls": ["proxy://do=live&type=txt&ext=<url or base64 url>"]}]}`: the
 *   playlist url hidden in TVBox's live proxy;
 * - `{"group", "channels": [{"name", "urls": [...]}]}`: channels written into the config;
 * - `{"type": 3, "api", "ext"}`: a spider that serves the list (not supported yet).
 */
data class LiveSourceSpec(
    val name: String,
    val url: String = "",
    val inline: List<LiveGroup> = emptyList(),
    val epg: String = "",
    val logo: String = "",
    val headers: Map<String, String> = emptyMap(),
    val supported: Boolean = true,
) {
    companion object {
        fun parseAll(livesJson: String, locator: ConfigLocator? = null): List<LiveSourceSpec> {
            if (livesJson.isBlank()) return emptyList()
            val array = runCatching { JsonParser.parseString(livesJson).asJsonArray }.getOrNull() ?: return emptyList()
            val specs = ArrayList<LiveSourceSpec>()
            val inline = ArrayList<LiveGroup>()
            var inlineEpg = ""
            for (el in array) {
                val o = el.takeIf { it.isJsonObject }?.asJsonObject ?: continue
                val channels = o.get("channels") as? JsonArray
                if (channels != null) {
                    val group = o.str("group").ifBlank { "直播" }
                    val hidden = channels.asSequence()
                        .mapNotNull { (it as? JsonObject)?.get("urls") as? JsonArray }
                        .flatMap { it.asSequence() }
                        .mapNotNull { it.takeIf { e -> e.isJsonPrimitive }?.asString }
                        .firstOrNull { it.startsWith("proxy://") }
                    if (hidden != null) {
                        val url = proxyPlaylistUrl(hidden, locator)
                        if (url != null) specs += LiveSourceSpec(name = group, url = url, epg = o.str("epg"), logo = o.str("logo"), headers = headers(o))
                    } else {
                        val list = channels.mapNotNull { c ->
                            val co = c as? JsonObject ?: return@mapNotNull null
                            val urls = (co.get("urls") as? JsonArray)?.mapNotNull { u -> u.takeIf { it.isJsonPrimitive }?.asString?.let(::liveUrl) }.orEmpty()
                            if (urls.isEmpty()) null else LiveChannel(name = co.str("name"), logo = co.str("logo"), urls = urls)
                        }
                        if (list.isNotEmpty()) inline += LiveGroup(group, list)
                        if (inlineEpg.isEmpty()) inlineEpg = o.str("epg")
                    }
                    continue
                }
                val type = o.get("type")?.takeIf { it.isJsonPrimitive }?.asString?.toIntOrNull() ?: 0
                val name = o.str("name").ifBlank { "直播 ${specs.size + 1}" }
                if (type != 0) {
                    specs += LiveSourceSpec(name = name, supported = false)
                    continue
                }
                var url = o.str("url").trim()
                if (url.startsWith("proxy://")) url = proxyPlaylistUrl(url, locator) ?: url
                if (locator != null && (url.startsWith("clan://") || url.startsWith("file://"))) {
                    url = locator.clanToAddress(url.replace("file://", "clan://localhost/"))
                }
                if (url.isEmpty()) continue
                specs += LiveSourceSpec(name = name, url = url, epg = o.str("epg"), logo = o.str("logo"), headers = headers(o))
            }
            if (inline.isNotEmpty()) specs.add(0, LiveSourceSpec(name = "直播", inline = inline, epg = inlineEpg))
            return specs
        }

        /** `proxy://do=live&type=txt&ext=<url, or url-safe base64 of it>` → the playlist url. */
        internal fun proxyPlaylistUrl(proxy: String, locator: ConfigLocator?): String? {
            val ext = proxy.substringAfter('?', proxy.removePrefix("proxy://")).split('&')
                .firstOrNull { it.startsWith("ext=") }?.removePrefix("ext=")?.let { java.net.URLDecoder.decode(it, "UTF-8") } ?: return null
            var url = if (ext.startsWith("http") || ext.startsWith("clan://") || ext.startsWith("file://")) ext
            else runCatching { String(Base64Compat.decode(ext)).trim() }.getOrNull() ?: return null
            if (locator != null && (url.startsWith("clan://") || url.startsWith("file://"))) {
                url = locator.clanToAddress(url.replace("file://", "clan://localhost/"))
            }
            return url.takeIf { it.startsWith("http") }
        }

        private fun headers(o: JsonObject): Map<String, String> {
            val h = LinkedHashMap<String, String>()
            (o.get("header") as? JsonObject)?.entrySet()?.forEach { (k, v) -> if (v.isJsonPrimitive) h[k] = v.asString }
            o.str("ua").takeIf { it.isNotBlank() }?.let { h["User-Agent"] = it }
            o.str("referer").takeIf { it.isNotBlank() }?.let { h["Referer"] = it }
            return h
        }

        private fun JsonObject.str(key: String): String = get(key)?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
    }
}

/** A parsed playlist: groups, and the XMLTV url an M3U header may name. */
data class LivePlaylist(val groups: List<LiveGroup>, val tvgUrl: String = "")

/**
 * TXT (`分组,#genre#` then `频道,url#url2$线路名`) and M3U playlists, after Box `TxtSubscribe`, plus M3U attributes
 * (`tvg-logo`, `group-title`, `x-tvg-url`) and `#EXTVLCOPT` headers. Channels of the same name in a group are merged.
 */
object LivePlaylistParser {
    private val SCHEMES = listOf("http://", "https://", "rtmp://", "rtsp://", "rtp://", "udp://", "mms://", "proxy://")
    private val ATTR = Regex("([\\w-]+)=\"([^\"]*)\"")
    private const val UNGROUPED = "未分组"

    fun parse(raw: String, headers: Map<String, String> = emptyMap()): LivePlaylist {
        val text = raw.removePrefix("﻿").replace("\r\n", "\n").replace('\r', '\n').trim()
        return if (text.startsWith("#EXTM3U")) parseM3u(text, headers) else LivePlaylist(parseTxt(text, headers))
    }

    /** Whether text looks like a playlist (otherwise it may be wrapped like a config). */
    fun looksLikePlaylist(text: String): Boolean {
        val t = text.removePrefix("﻿").trimStart()
        return t.startsWith("#EXTM3U") || t.contains("#genre#") || SCHEMES.any { t.contains(",$it") }
    }

    private class Builder {
        val groups = LinkedHashMap<String, LinkedHashMap<String, Pair<String, MutableList<LiveUrl>>>>()

        fun add(group: String, name: String, logo: String, url: LiveUrl) {
            val channels = groups.getOrPut(group.ifBlank { UNGROUPED }) { LinkedHashMap() }
            val entry = channels.getOrPut(name) { logo to ArrayList() }
            if (entry.second.none { it.url == url.url }) entry.second += url
            if (entry.first.isEmpty() && logo.isNotEmpty()) channels[name] = logo to entry.second
        }

        fun build() = groups.mapNotNull { (g, channels) ->
            val list = channels.map { (name, v) -> LiveChannel(name = name, logo = v.first, urls = v.second) }
            if (list.isEmpty()) null else LiveGroup(g, list)
        }
    }

    private fun parseTxt(text: String, headers: Map<String, String>): List<LiveGroup> {
        val b = Builder()
        var group = UNGROUPED
        for (line in text.lineSequence()) {
            val parts = line.split(',', limit = 2)
            if (parts.size < 2) continue
            if (parts[1].trim().startsWith("#genre#")) {
                group = parts[0].trim()
                continue
            }
            val name = parts[0].trim()
            if (name.isEmpty()) continue
            for (u in parts[1].trim().split('#')) {
                val item = u.trim()
                if (SCHEMES.none { item.startsWith(it) }) continue
                b.add(group, name, "", liveUrl(item, headers))
            }
        }
        return b.build()
    }

    private fun parseM3u(text: String, base: Map<String, String>): LivePlaylist {
        val b = Builder()
        val lines = text.lines()
        val header = lines.first()
        val tvg = ATTR.findAll(header).firstOrNull { it.groupValues[1] in setOf("x-tvg-url", "url-tvg", "tvg-url") }?.groupValues?.get(2)
            ?.split(',')?.firstOrNull { it.isNotBlank() }?.trim().orEmpty()
        var i = 1
        while (i < lines.size) {
            val line = lines[i].trim()
            i++
            if (!line.startsWith("#EXTINF")) continue
            val attrs = ATTR.findAll(line).associate { it.groupValues[1].lowercase() to it.groupValues[2] }
            val name = line.substringAfterLast(',').trim().ifEmpty { attrs["tvg-name"].orEmpty() }.ifEmpty { "未命名" }
            val headers = LinkedHashMap(base)
            var url = ""
            while (i < lines.size) {
                val next = lines[i].trim()
                if (next.startsWith("#EXTINF")) break
                i++
                if (next.isEmpty()) continue
                if (next.startsWith("#EXTVLCOPT:")) {
                    val opt = next.removePrefix("#EXTVLCOPT:")
                    when {
                        opt.startsWith("http-user-agent=") -> headers["User-Agent"] = opt.substringAfter('=')
                        opt.startsWith("http-referrer=") -> headers["Referer"] = opt.substringAfter('=')
                    }
                    continue
                }
                if (next.startsWith("#")) continue
                url = next
                break
            }
            if (url.isEmpty()) continue
            b.add(attrs["group-title"].orEmpty(), name, attrs["tvg-logo"].orEmpty(), liveUrl(url, headers))
        }
        return LivePlaylist(b.build(), tvg)
    }
}

/** `url$label` → url and label. */
internal fun liveUrl(item: String, headers: Map<String, String> = emptyMap()): LiveUrl {
    val dollar = item.lastIndexOf('$')
    // A '$' inside the query is part of the url; a label follows the url.
    return if (dollar > 0 && !item.substring(dollar).contains('/') && !item.substring(dollar).contains('=')) {
        LiveUrl(item.substring(0, dollar).trim(), item.substring(dollar + 1).trim(), headers)
    } else {
        LiveUrl(item.trim(), "", headers)
    }
}
