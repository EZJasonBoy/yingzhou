package tvbox.engine.core.play

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import tvbox.engine.core.model.SubtitleTrack
import tvbox.engine.core.util.Base64Compat
import tvbox.engine.core.util.TextDecoding
import java.net.URLDecoder
import java.net.URLEncoder

/** A subtitle a site's play answer named, before the engine wraps its address. */
data class RawSubtitle(
    val name: String,
    val url: String,
    val lang: String = "",
    /** What the site said or the address suggests: srt | ass | ssa | vtt | lrc | ttml | … ("" when unknown). */
    val format: String = "",
)

/**
 * Subtitles in a TVBox play answer (`playerContent`), as TVBoxOS / Box read them:
 *
 * - `subt`: one address. A `#name.ext` after it is the file name the player shows (and the extension its format).
 * - `subs`: `[{name, lang, format, url}]`, `format` a MIME type (`application/x-subrip`, `text/x-ssa`, `text/vtt`,
 *   `text/lrc`). Box only takes the first; TVBoxOS takes the first that is not lyrics. All of them are offered here,
 *   except lyrics (a name with "lyric", "lrc" or "歌词", which TVBoxOS shows as lyrics of music, not subtitles).
 */
object Subtitles {

    fun parse(obj: JsonObject): List<RawSubtitle> {
        val out = ArrayList<RawSubtitle>()
        obj.str("subt")?.trim()?.takeIf { it.isNotEmpty() }?.let { url -> fromUrl(url, "")?.let { out += it } }
        val subs = obj.get("subs")
        when {
            subs == null || subs.isJsonNull -> {}
            subs.isJsonArray -> subs.asJsonArray.forEach { item -> entry(item)?.let { out += it } }
            subs.isJsonObject -> entry(subs)?.let { out += it }
            // Some spiders put the list in as JSON text, or a single address.
            subs.isJsonPrimitive -> {
                val text = subs.asString.trim()
                if (text.startsWith("[") || text.startsWith("{")) {
                    runCatching { JsonParser.parseString(text) }.getOrNull()?.let { parsed ->
                        if (parsed.isJsonArray) parsed.asJsonArray.forEach { item -> entry(item)?.let { out += it } } else entry(parsed)?.let { out += it }
                    }
                } else if (text.isNotEmpty()) {
                    fromUrl(text, "")?.let { out += it }
                }
            }
        }
        // The same file named twice (`subt` and `subs` often carry the same one): keep the first.
        val seen = HashSet<String>()
        val unique = out.filter { seen.add(it.url) }
        return unique.mapIndexed { i, s -> if (s.name.isEmpty()) s.copy(name = if (unique.size == 1) "字幕" else "字幕 ${i + 1}") else s }
    }

    private fun entry(item: JsonElement): RawSubtitle? {
        if (!item.isJsonObject) return if (item.isJsonPrimitive) fromUrl(item.asString.trim(), "") else null
        val o = item.asJsonObject
        val name = o.str("name")?.trim().orEmpty()
        if (isLyrics(name)) return null
        val url = o.str("url")?.trim().orEmpty()
        val sub = fromUrl(url, name) ?: return null
        val format = formatOfMime(o.str("format").orEmpty()).ifEmpty { sub.format }
        if (format == "lrc" && name.isEmpty()) return null
        return sub.copy(lang = o.str("lang")?.trim() ?: o.str("language")?.trim() ?: "", format = format)
    }

    /** `url#name.ext`: the part after `#` names the file; it is not sent to the server. */
    private fun fromUrl(raw: String, name: String): RawSubtitle? {
        if (raw.isEmpty()) return null
        val hash = raw.indexOf('#')
        val url = if (hash > 0) raw.substring(0, hash) else raw
        val fragment = if (hash > 0) runCatching { URLDecoder.decode(raw.substring(hash + 1), "UTF-8") }.getOrDefault(raw.substring(hash + 1)) else ""
        if (!(url.startsWith("http://") || url.startsWith("https://") || url.startsWith("proxy://"))) return null
        val fileName = fragment.ifEmpty { url.substringBefore('?').substringAfterLast('/') }
        val format = formatOfName(fileName)
        val shown = name.ifEmpty { fragment.substringBeforeLast('.').ifEmpty { fragment } }
        return RawSubtitle(name = shown, url = url, format = format)
    }

    private fun isLyrics(name: String): Boolean {
        if (name.isEmpty()) return false
        val lower = name.lowercase()
        return "lyric" in lower || "lrc" in lower || "歌词" in name
    }

    fun formatOfMime(mime: String): String = when (mime.trim().lowercase()) {
        "application/x-subrip", "text/srt", "application/srt", "srt" -> "srt"
        // TVBox's MIME type for both; the file itself says which (see SubtitleConverter.detect).
        "text/x-ssa", "text/x-ass", "text/ass", "ass" -> "ass"
        "text/ssa", "ssa" -> "ssa"
        "text/vtt", "vtt", "webvtt" -> "vtt"
        "text/lrc", "lrc" -> "lrc"
        "application/ttml+xml", "ttml", "dfxp" -> "ttml"
        else -> ""
    }

    fun formatOfName(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "srt" -> "srt"
        "ass" -> "ass"
        "ssa" -> "ssa"
        "vtt", "webvtt" -> "vtt"
        "lrc" -> "lrc"
        "ttml", "dfxp", "xml" -> "ttml"
        else -> ""
    }

    /**
     * The address the player is given: the engine's `/subtitle?url=&h=&f=` ([base] is `http://<engine>/subtitle?`),
     * which fetches the file with the play answer's headers and hands it over as UTF-8 in a format libmpv reads.
     */
    fun track(sub: RawSubtitle, base: String, headers: Map<String, String>, proxyBase: String): SubtitleTrack {
        val source = if (sub.url.startsWith("proxy://")) sub.url.replaceFirst("proxy://", proxyBase) else sub.url
        val sb = StringBuilder(base).append("url=").append(URLEncoder.encode(source, "UTF-8"))
        if (headers.isNotEmpty()) {
            sb.append("&h=").append(Base64Compat.encode(com.google.gson.Gson().toJson(headers).toByteArray(), urlSafe = true, padding = false))
        }
        if (sub.format.isNotEmpty()) sb.append("&f=").append(sub.format)
        val served = when (sub.format) {
            "", "lrc", "ttml" -> "srt"
            else -> sub.format
        }
        return SubtitleTrack(name = sub.name, lang = sub.lang, format = served, url = sb.toString())
    }

    private fun JsonObject.str(key: String): String? {
        val v = get(key) ?: return null
        return if (v.isJsonPrimitive) v.asString else null
    }
}

/**
 * Turns a subtitle file into something libmpv shows: UTF-8 text (see [TextDecoding]) in SRT, ASS/SSA or WebVTT.
 * Those three pass through as they are; TTML / DFXP, LRC and Bilibili's JSON subtitles (`{"body": [{from, to,
 * content}]}`) become SRT.
 */
object SubtitleConverter {

    data class Converted(val format: String, val text: String) {
        val contentType: String
            get() = when (format) {
                "ass", "ssa" -> "text/x-ssa; charset=utf-8"
                "vtt" -> "text/vtt; charset=utf-8"
                else -> "application/x-subrip; charset=utf-8"
            }
    }

    /** [hint] is the format the site named, used only when the text itself does not say. */
    fun convert(bytes: ByteArray, declaredCharset: String? = null, hint: String = ""): Converted {
        val text = TextDecoding.text(bytes, declaredCharset).removePrefix("\uFEFF").replace("\r\n", "\n").replace('\r', '\n')
        return when (val format = detect(text).ifEmpty { hint }) {
            "vtt", "ass", "ssa" -> Converted(format, text)
            "srt" -> Converted("srt", normalizeSrt(text))
            "ttml" -> Converted("srt", ttmlToSrt(text))
            "lrc" -> Converted("srt", lrcToSrt(text))
            "bcc" -> Converted("srt", bilibiliJsonToSrt(text))
            // Unknown: libmpv probes the text itself (MicroDVD, SubViewer, …).
            else -> Converted(format.ifEmpty { "srt" }, text)
        }
    }

    fun detect(text: String): String {
        val head = text.trimStart().take(4096)
        return when {
            head.startsWith("WEBVTT") -> "vtt"
            head.contains("[V4 Styles]", ignoreCase = true) -> "ssa"
            head.contains("[Script Info]", ignoreCase = true) || head.contains("[V4+ Styles]", ignoreCase = true) -> "ass"
            SRT_TIME.containsMatchIn(head) -> "srt"
            head.startsWith("<") && (head.contains("<tt") || head.contains("ttml")) -> "ttml"
            head.startsWith("{") && head.contains("\"body\"") -> "bcc"
            LRC_LINE.containsMatchIn(head) -> "lrc"
            else -> ""
        }
    }

    /** Commas in the times (some files use dots), and a blank line between cues. */
    private fun normalizeSrt(text: String): String =
        text.replace(SRT_DOT_TIME) { m -> m.groupValues[1] + "," + m.groupValues[2] }

    // ---- TTML / DFXP ----

    private val P_TAG = Regex("<(?:\\w+:)?p\\b([^>]*)>([\\s\\S]*?)</(?:\\w+:)?p>", RegexOption.IGNORE_CASE)
    private val BR = Regex("<(?:\\w+:)?br\\s*/?>", RegexOption.IGNORE_CASE)
    private val TAG = Regex("<[^>]+>")

    fun ttmlToSrt(text: String): String {
        val tickRate = Regex("ttp:tickRate=\"(\\d+)\"").find(text)?.groupValues?.get(1)?.toLongOrNull() ?: 10_000_000L
        val cues = ArrayList<Triple<Long, Long, String>>()
        for (m in P_TAG.findAll(text)) {
            val attrs = m.groupValues[1]
            val begin = attr(attrs, "begin")?.let { ttmlTime(it, tickRate) } ?: continue
            val end = attr(attrs, "end")?.let { ttmlTime(it, tickRate) }
                ?: attr(attrs, "dur")?.let { d -> ttmlTime(d, tickRate)?.let { begin + it } }
                ?: continue
            val body = unescape(m.groupValues[2].replace(BR, "\n").replace(TAG, "")).trim()
            if (body.isNotEmpty()) cues += Triple(begin, end, body)
        }
        return srt(cues)
    }

    private fun attr(attrs: String, name: String): String? =
        Regex("(?:^|\\s)$name\\s*=\\s*\"([^\"]*)\"").find(attrs)?.groupValues?.get(1)

    /** `00:00:01.500`, `00:00:01:12` (frames, taken as 1/30 s), `1.5s`, `1500ms`, `15000000t`. */
    private fun ttmlTime(value: String, tickRate: Long): Long? {
        val v = value.trim()
        Regex("^(\\d+):(\\d{2}):(\\d{2})(?:[.,](\\d+))?$").matchEntire(v)?.let { m ->
            val (h, mi, s) = m.destructured
            val frac = m.groupValues[4].let { if (it.isEmpty()) 0 else (("0.$it").toDouble() * 1000).toLong() }
            return h.toLong() * 3_600_000 + mi.toLong() * 60_000 + s.toLong() * 1000 + frac
        }
        Regex("^(\\d+):(\\d{2}):(\\d{2}):(\\d+)$").matchEntire(v)?.let { m ->
            val (h, mi, s, f) = m.destructured
            return h.toLong() * 3_600_000 + mi.toLong() * 60_000 + s.toLong() * 1000 + f.toLong() * 1000 / 30
        }
        Regex("^([\\d.]+)(h|m|s|ms|t)$").matchEntire(v)?.let { m ->
            val n = m.groupValues[1].toDoubleOrNull() ?: return null
            return when (m.groupValues[2]) {
                "h" -> (n * 3_600_000).toLong()
                "m" -> (n * 60_000).toLong()
                "s" -> (n * 1000).toLong()
                "ms" -> n.toLong()
                else -> (n * 1000 / tickRate).toLong()
            }
        }
        return null
    }

    // ---- LRC ----

    private val LRC_TIME = Regex("\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?]")

    fun lrcToSrt(text: String): String {
        val lines = ArrayList<Pair<Long, String>>()
        for (line in text.lineSequence()) {
            val times = LRC_TIME.findAll(line).toList()
            if (times.isEmpty()) continue
            val words = line.substring(times.last().range.last + 1).trim()
            for (t in times) {
                val (m, s, f) = t.destructured
                val frac = if (f.isEmpty()) 0L else (("0.$f").toDouble() * 1000).toLong()
                lines += (m.toLong() * 60_000 + s.toLong() * 1000 + frac) to words
            }
        }
        lines.sortBy { it.first }
        val cues = lines.mapIndexedNotNull { i, (start, words) ->
            if (words.isEmpty()) return@mapIndexedNotNull null
            val end = lines.getOrNull(i + 1)?.first?.takeIf { it > start } ?: (start + 5_000)
            Triple(start, end, words)
        }
        return srt(cues)
    }

    // ---- Bilibili JSON (BCC) ----

    fun bilibiliJsonToSrt(text: String): String {
        val root = runCatching { JsonParser.parseString(text).asJsonObject }.getOrNull() ?: return ""
        val body = root.getAsJsonArray("body") ?: return ""
        val cues = body.mapNotNull { e ->
            val o = e.takeIf { it.isJsonObject }?.asJsonObject ?: return@mapNotNull null
            val from = o.get("from")?.asDouble ?: return@mapNotNull null
            val to = o.get("to")?.asDouble ?: return@mapNotNull null
            val content = o.get("content")?.asString?.trim().orEmpty()
            if (content.isEmpty()) null else Triple((from * 1000).toLong(), (to * 1000).toLong(), content)
        }
        return srt(cues)
    }

    // ---- shared ----

    fun srt(cues: List<Triple<Long, Long, String>>): String = buildString {
        cues.forEachIndexed { i, (start, end, body) ->
            append(i + 1).append('\n')
            append(srtTime(start)).append(" --> ").append(srtTime(maxOf(end, start + 1))).append('\n')
            append(body).append("\n\n")
        }
    }

    private fun srtTime(ms: Long): String {
        val h = ms / 3_600_000
        val m = ms / 60_000 % 60
        val s = ms / 1000 % 60
        val f = ms % 1000
        return String.format(java.util.Locale.ROOT, "%02d:%02d:%02d,%03d", h, m, s, f)
    }

    private fun unescape(s: String): String = s
        .replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&#39;", "'")
        .replace("&nbsp;", " ").replace("&amp;", "&")

    private val SRT_TIME = Regex("\\d{1,2}:\\d{2}:\\d{2}[,.]\\d{1,3}\\s*-->\\s*\\d{1,2}:\\d{2}:\\d{2}[,.]\\d{1,3}")
    private val SRT_DOT_TIME = Regex("(\\d{1,2}:\\d{2}:\\d{2})\\.(\\d{1,3})(?=\\s*-->|\\s*$)", RegexOption.MULTILINE)
    private val LRC_LINE = Regex("(?m)^\\s*\\[\\d{1,3}:\\d{2}(?:[.:]\\d{1,3})?]")
}
