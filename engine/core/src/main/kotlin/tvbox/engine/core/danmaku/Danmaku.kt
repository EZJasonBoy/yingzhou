package tvbox.engine.core.danmaku

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.serialization.Serializable

/** One danmaku comment, the same whatever it came as. */
@Serializable
data class DanmakuComment(
    /** When it appears, in milliseconds of the video. */
    val time: Long,
    /** scroll | top | bottom */
    val mode: String,
    /** 0xRRGGBB. */
    val color: Int = WHITE,
    /** Bilibili's font size: 25 is normal, 18 small, 36 large. */
    val size: Int = 25,
    val text: String,
) {
    companion object {
        const val WHITE = 0xFFFFFF
        const val SCROLL = "scroll"
        const val TOP = "top"
        const val BOTTOM = "bottom"
    }
}

/** `GET /api/v1/danmaku`: the danmaku of an episode, by time. */
@Serializable
data class DanmakuList(
    /** Where they came from: `site` (the play answer), `config` (the config's API), `custom` (the user's), `file`; "" for none. */
    val source: String = "",
    /** The address or service they came from, for display. */
    val from: String = "",
    val count: Int = 0,
    val items: List<DanmakuComment> = emptyList(),
)

class DanmakuException(message: String) : Exception(message)

/**
 * Reads danmaku in the forms found in TVBox configs and spiders, and in files people keep:
 *
 * - Bilibili XML: `<d p="time,mode,size,color,…">text</d>` (mode 1–3 and 6 scroll, 4 bottom, 5 top; 7 and 8 are
 *   positioned / scripted ones and are left out).
 * - JSON: `{comments: [{p, m}]}` from dandanplay-compatible services (`p` = time,mode,color,user — or Bilibili's
 *   layout when it has five fields or more); the same under `data` or as a bare array; DPlayer / ArtPlayer arrays
 *   `[time, type, color, author, text]` (type 0 scroll, 1 top, 2 bottom); objects with `text` / `time` / `color` /
 *   `mode`.
 * - ASS written by danmaku converters: `\move` scrolls, `\an8` / `\an2` (or the style's alignment) stay at the top /
 *   bottom; the colour from `\c&HBBGGRR&`.
 */
object DanmakuParser {
    /** Danmaku of a long film rarely pass a few tens of thousands; more than this is cut. */
    const val MAX_ITEMS = 200_000

    fun parse(text: String): List<DanmakuComment> {
        val t = text.trimStart('\uFEFF', ' ', '\n', '\r', '\t')
        val items = when {
            t.startsWith("<") -> xml(t)
            t.startsWith("[Script Info]", ignoreCase = true) || t.contains("\nDialogue:") -> ass(t)
            t.startsWith("{") || t.startsWith("[") -> json(t)
            else -> emptyList()
        }
        return items.asSequence().filter { it.text.isNotBlank() && it.time >= 0 }.take(MAX_ITEMS).sortedBy { it.time }.toList()
    }

    // ---- Bilibili XML ----

    private val D = Regex("<d\\b([^>]*)>([\\s\\S]*?)</d>")
    private val P = Regex("(?:^|\\s)p\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')")
    private val CDATA = Regex("<!\\[CDATA\\[([\\s\\S]*?)]]>")

    fun xml(text: String): List<DanmakuComment> = D.findAll(text).mapNotNull { m ->
        val p = P.find(m.groupValues[1])?.let { it.groupValues[1].ifEmpty { it.groupValues[2] } } ?: return@mapNotNull null
        val body = unescape(m.groupValues[2].replace(CDATA) { it.groupValues[1] }).replace("\r", "")
        bilibili(p.split(','), body)
    }.toList()

    /** `time,mode,size,color,…` (Bilibili). */
    private fun bilibili(p: List<String>, text: String): DanmakuComment? {
        val time = p.getOrNull(0)?.trim()?.toDoubleOrNull() ?: return null
        val mode = biliMode(p.getOrNull(1)?.trim()?.toIntOrNull() ?: 1) ?: return null
        val size = p.getOrNull(2)?.trim()?.toIntOrNull()?.takeIf { it in 8..80 } ?: 25
        val color = p.getOrNull(3)?.let { color(it) } ?: DanmakuComment.WHITE
        return DanmakuComment((time * 1000).toLong(), mode, color, size, text)
    }

    private fun biliMode(mode: Int): String? = when (mode) {
        1, 2, 3, 6 -> DanmakuComment.SCROLL
        4 -> DanmakuComment.BOTTOM
        5 -> DanmakuComment.TOP
        else -> null
    }

    // ---- JSON ----

    fun json(text: String): List<DanmakuComment> {
        val root = runCatching { JsonParser.parseString(text) }.getOrNull() ?: return emptyList()
        return items(root)?.mapNotNull { comment(it) } ?: emptyList()
    }

    /** The array of comments, wherever the answer keeps it. */
    private fun items(root: JsonElement): JsonArray? = when {
        root.isJsonArray -> root.asJsonArray
        root.isJsonObject -> {
            val o = root.asJsonObject
            listOf("comments", "danmaku", "danmu", "list", "data", "result")
                .firstNotNullOfOrNull { key ->
                    val v = o.get(key) ?: return@firstNotNullOfOrNull null
                    when {
                        v.isJsonArray -> v.asJsonArray
                        v.isJsonObject -> items(v)
                        else -> null
                    }
                }
        }
        else -> null
    }

    private fun comment(e: JsonElement): DanmakuComment? {
        if (e.isJsonArray) {
            // DPlayer / ArtPlayer: [time, type, color, author, text]
            val a = e.asJsonArray
            if (a.size() < 5) return null
            val time = a[0].num() ?: return null
            val mode = when (a[1].num()?.toInt()) {
                1 -> DanmakuComment.TOP
                2 -> DanmakuComment.BOTTOM
                else -> DanmakuComment.SCROLL
            }
            val color = a[2].let { if (it.isJsonPrimitive) color(it.asString) else null } ?: DanmakuComment.WHITE
            return DanmakuComment((time * 1000).toLong(), mode, color, 25, a[4].str() ?: return null)
        }
        if (!e.isJsonObject) return null
        val o = e.asJsonObject
        val text = o.firstStr("m", "text", "content", "msg", "txt") ?: return null
        o.firstStr("p")?.let { p ->
            val parts = p.split(',')
            if (parts.size >= 5) return bilibili(parts, text)
            // dandanplay: time,mode,color,user
            val time = parts.getOrNull(0)?.trim()?.toDoubleOrNull() ?: return null
            val mode = biliMode(parts.getOrNull(1)?.trim()?.toIntOrNull() ?: 1) ?: return null
            return DanmakuComment((time * 1000).toLong(), mode, parts.getOrNull(2)?.let { color(it) } ?: DanmakuComment.WHITE, 25, text)
        }
        val time = o.get("time")?.num()?.let { (it * 1000).toLong() }
            ?: o.get("progress")?.num()?.toLong() // Bilibili's JSON: milliseconds
            ?: o.get("stime")?.num()?.let { (it * 1000).toLong() }
            ?: return null
        // `mode` in Bilibili's numbers (4 bottom, 5 top), `type` / `position` in DPlayer's (1 top, 2 bottom); words in either.
        val bili = o.get("mode")?.str()?.lowercase()
        val dplayer = (o.get("type") ?: o.get("position"))?.str()?.lowercase()
        val mode = when {
            bili == "top" || bili == "5" || dplayer == "top" || dplayer == "1" -> DanmakuComment.TOP
            bili == "bottom" || bili == "4" || dplayer == "bottom" || dplayer == "2" -> DanmakuComment.BOTTOM
            bili == "7" || bili == "8" -> return null
            else -> DanmakuComment.SCROLL
        }
        val color = o.get("color")?.str()?.let { color(it) } ?: DanmakuComment.WHITE
        val size = o.get("size")?.num()?.toInt() ?: o.get("fontsize")?.num()?.toInt() ?: 25
        return DanmakuComment(time, mode, color, size.takeIf { it in 8..80 } ?: 25, text)
    }

    // ---- ASS ----

    private val OVERRIDE = Regex("\\{[^}]*}")
    private val COLOR_TAG = Regex("\\\\1?c&H([0-9a-fA-F]{1,8})&?")
    private val FONT_SIZE = Regex("\\\\fs(\\d+(?:\\.\\d+)?)")
    private val ALIGN = Regex("\\\\an?(\\d+)")

    fun ass(text: String): List<DanmakuComment> {
        var fields = listOf("Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text")
        val styles = HashMap<String, Pair<Int, Int>>() // name -> (alignment, font size)
        var styleFields = emptyList<String>()
        var defaultSize = 0
        val out = ArrayList<DanmakuComment>()
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            when {
                line.startsWith("Format:", ignoreCase = true) -> {
                    val f = line.substringAfter(':').split(',').map { it.trim() }
                    if ("Text" in f) fields = f else styleFields = f
                }
                line.startsWith("Style:", ignoreCase = true) && styleFields.isNotEmpty() -> {
                    val v = line.substringAfter(':').split(',').map { it.trim() }
                    val name = v.getOrNull(styleFields.indexOf("Name")).orEmpty()
                    val align = v.getOrNull(styleFields.indexOf("Alignment"))?.toIntOrNull() ?: 2
                    val size = v.getOrNull(styleFields.indexOf("Fontsize"))?.toDoubleOrNull()?.toInt() ?: 0
                    styles[name] = align to size
                    if (defaultSize == 0 && size > 0) defaultSize = size
                }
                line.startsWith("Dialogue:", ignoreCase = true) -> {
                    val v = line.substringAfter(':').split(',', limit = fields.size)
                    if (v.size < fields.size) continue
                    val start = assTime(v[fields.indexOf("Start")].trim()) ?: continue
                    val body = v[fields.indexOf("Text")]
                    val tags = OVERRIDE.findAll(body).joinToString("") { it.value }
                    val words = body.replace(OVERRIDE, "").replace("\\N", " ").replace("\\n", " ").replace("\\h", " ").trim()
                    if (words.isEmpty()) continue
                    val style = styles[v[fields.indexOf("Style")].trim()]
                    val align = ALIGN.find(tags)?.groupValues?.get(1)?.toIntOrNull() ?: style?.first ?: 2
                    val mode = when {
                        "\\move" in tags -> DanmakuComment.SCROLL
                        align in 7..9 -> DanmakuComment.TOP
                        align in 1..3 && ("\\pos" in tags || style != null) -> DanmakuComment.BOTTOM
                        else -> DanmakuComment.SCROLL
                    }
                    val bgr = COLOR_TAG.find(tags)?.groupValues?.get(1)?.toLongOrNull(16)
                    val color = bgr?.let { (((it and 0xFF) shl 16) or (it and 0xFF00) or ((it shr 16) and 0xFF)).toInt() } ?: DanmakuComment.WHITE
                    val fs = FONT_SIZE.find(tags)?.groupValues?.get(1)?.toDoubleOrNull()?.toInt() ?: style?.second ?: defaultSize
                    // Converters scale Bilibili's 25 to the script's font size: the default style's size counts as 25.
                    val size = if (fs > 0 && defaultSize > 0) (25.0 * fs / defaultSize).toInt().coerceIn(12, 50) else 25
                    out += DanmakuComment(start, mode, color, size, words)
                }
            }
        }
        return out
    }

    private fun assTime(s: String): Long? {
        val m = Regex("^(\\d+):(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?$").matchEntire(s) ?: return null
        val (h, mi, sec, frac) = m.destructured
        val f = if (frac.isEmpty()) 0L else ("0.$frac".toDouble() * 1000).toLong()
        return h.toLong() * 3_600_000 + mi.toLong() * 60_000 + sec.toLong() * 1000 + f
    }

    // ---- shared ----

    /** Decimal (`16777215`), `#ffffff`, `0xffffff`; null for anything else. */
    fun color(value: String): Int? {
        val v = value.trim()
        val n = when {
            v.startsWith("#") -> v.substring(1).toLongOrNull(16)
            v.startsWith("0x", ignoreCase = true) -> v.substring(2).toLongOrNull(16)
            else -> v.toLongOrNull()
        } ?: return null
        return (n and 0xFFFFFF).toInt()
    }

    private val ENTITY = Regex("&(#x[0-9a-fA-F]+|#\\d+|amp|lt|gt|quot|apos);")

    fun unescape(s: String): String = if ('&' !in s) s else ENTITY.replace(s) { m ->
        when (val e = m.groupValues[1]) {
            "amp" -> "&"
            "lt" -> "<"
            "gt" -> ">"
            "quot" -> "\""
            "apos" -> "'"
            else -> {
                val code = if (e.startsWith("#x")) e.substring(2).toIntOrNull(16) else e.substring(1).toIntOrNull()
                code?.takeIf { Character.isValidCodePoint(it) }?.let { String(Character.toChars(it)) } ?: m.value
            }
        }
    }

    private fun JsonElement.num(): Double? = if (isJsonPrimitive) runCatching { asDouble }.getOrNull() else null
    private fun JsonElement.str(): String? = if (isJsonPrimitive) asString else null
    private fun JsonObject.firstStr(vararg keys: String): String? = keys.firstNotNullOfOrNull { k -> get(k)?.takeIf { it.isJsonPrimitive }?.asString }
}
