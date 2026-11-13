package tvbox.engine.core.live

import com.google.gson.JsonParser
import tvbox.engine.core.model.EpgProgram
import java.io.ByteArrayInputStream
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.zip.GZIPInputStream

/**
 * Programme guides. TVBox EPG addresses come in three kinds:
 *
 * - a template with `{name}` and `{date}` (e.g. `https://epg.112114.xyz/?ch={name}&date={date}`) answering
 *   `{"epg_data": [{"start": "HH:mm", "end": "HH:mm", "title"}]}`;
 * - a plain address of the same API, called as `<url>?ch=<name>&date=<date>` (DIYP style, Box's fallback);
 * - an XMLTV file (`.xml` / `.xml.gz`, also an M3U's `x-tvg-url`).
 *
 * Times are China time, as TVBox assumes. java.time is avoided so this also runs on Android 7.
 */
object Epg {
    val ZONE: TimeZone = TimeZone.getTimeZone("Asia/Shanghai")

    fun isXmltv(url: String): Boolean {
        val path = url.substringBefore('?').lowercase()
        return path.endsWith(".xml") || path.endsWith(".xml.gz") || path.endsWith(".gz")
    }

    /** The address to ask for one channel and day (template or DIYP style). */
    fun requestUrl(spec: String, name: String, date: String): String {
        val enc = java.net.URLEncoder.encode(name, "UTF-8")
        return if (spec.contains("{name}") || spec.contains("{date}")) {
            spec.replace("{name}", enc).replace("{date}", date)
        } else {
            spec + (if (spec.contains('?')) "&" else "?") + "ch=" + enc + "&date=" + date
        }
    }

    /** `{"epg_data": [{"start": "HH:mm", "end": "HH:mm", "title"}]}` for [date] (`yyyy-MM-dd`). */
    fun parseJson(text: String, date: String): List<EpgProgram> {
        val root = runCatching { JsonParser.parseString(text) }.getOrNull()?.takeIf { it.isJsonObject }?.asJsonObject ?: return emptyList()
        val data = root.get("epg_data")?.takeIf { it.isJsonArray }?.asJsonArray ?: return emptyList()
        val day = dayFormat().parse(date)?.time ?: return emptyList()
        val programs = ArrayList<EpgProgram>()
        for (el in data) {
            val o = el.takeIf { it.isJsonObject }?.asJsonObject ?: continue
            val start = clock(o.get("start")?.asString) ?: continue
            var end = clock(o.get("end")?.asString) ?: continue
            if (end <= start) end += DAY
            val title = o.get("title")?.takeIf { it.isJsonPrimitive }?.asString?.trim().orEmpty()
            if (title.isNotEmpty()) programs += EpgProgram(day + start, day + end, title)
        }
        return programs.sortedBy { it.start }
    }

    /** XMLTV, gzipped or not: channel key (normalized display name or id) to its programmes. */
    fun parseXmltv(bytes: ByteArray): Map<String, List<EpgProgram>> {
        val raw = if (bytes.size > 2 && bytes[0] == 0x1f.toByte() && bytes[1] == 0x8b.toByte()) {
            GZIPInputStream(ByteArrayInputStream(bytes)).use { it.readBytes() }
        } else {
            bytes
        }
        val text = String(raw, Charsets.UTF_8)
        // Channel ids to the names they are known by.
        val names = HashMap<String, MutableSet<String>>()
        for (m in CHANNEL.findAll(text)) {
            val id = unescape(m.groupValues[1])
            val set = names.getOrPut(id) { linkedSetOf(normalize(id)) }
            for (d in DISPLAY_NAME.findAll(m.groupValues[2])) set += normalize(unescape(d.groupValues[1]))
        }
        val byId = HashMap<String, MutableList<EpgProgram>>()
        val format = SimpleDateFormat("yyyyMMddHHmmss Z", Locale.ROOT)
        for (m in PROGRAMME.findAll(text)) {
            val attrs = m.groupValues[1]
            val start = XML_ATTR.find(attrs, "start")?.let { runCatching { format.parse(fixZone(it))?.time }.getOrNull() } ?: continue
            val stop = XML_ATTR.find(attrs, "stop")?.let { runCatching { format.parse(fixZone(it))?.time }.getOrNull() } ?: continue
            val channel = XML_ATTR.find(attrs, "channel")?.let(::unescape) ?: continue
            val title = TITLE.find(m.groupValues[2])?.groupValues?.get(1)?.let(::unescape)?.trim().orEmpty()
            if (title.isNotEmpty()) byId.getOrPut(channel) { ArrayList() } += EpgProgram(start, stop, title)
        }
        val result = HashMap<String, List<EpgProgram>>()
        for ((id, programs) in byId) {
            val sorted = programs.sortedBy { it.start }
            for (key in names[id] ?: setOf(normalize(id))) result.putIfAbsent(key, sorted)
        }
        return result
    }

    /** Programmes overlapping the China-time day [date]. */
    fun forDay(programs: List<EpgProgram>, date: String): List<EpgProgram> {
        val start = dayFormat().parse(date)?.time ?: return emptyList()
        val end = start + DAY
        return programs.filter { it.end > start && it.start < end }
    }

    /**
     * A channel name as EPG services and XMLTV files know it: `CCTV-1 综合` → `CCTV1`, `CCTV5+ 体育赛事` → `CCTV5+`,
     * `湖南卫视 HD` → `湖南卫视`.
     */
    fun normalize(name: String): String {
        var n = name.trim().uppercase(Locale.ROOT).replace(Regex("[\\s\\-_·]"), "")
        n = n.replace(Regex("[(\\[（【].*?[)\\]）】]"), "")
        CCTV.find(n)?.let { return "CCTV" + it.groupValues[1] }
        for (suffix in SUFFIXES) if (n.length > suffix.length && n.endsWith(suffix)) n = n.removeSuffix(suffix)
        return n
    }

    fun dayFormat() = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).apply { timeZone = ZONE }

    private const val DAY = 24 * 3600 * 1000L
    private val CCTV = Regex("^CCTV(\\d{1,2}\\+?|5\\+)")
    private val SUFFIXES = listOf("超高清", "高清", "超清", "标清", "频道", "FHD", "UHD", "HD", "4K", "8K")
    private val CHANNEL = Regex("<channel\\s+id=\"([^\"]*)\"[^>]*>([\\s\\S]*?)</channel>")
    private val DISPLAY_NAME = Regex("<display-name[^>]*>([\\s\\S]*?)</display-name>")
    private val PROGRAMME = Regex("<programme\\s([^>]*)>([\\s\\S]*?)</programme>")
    private val TITLE = Regex("<title[^>]*>([\\s\\S]*?)</title>")

    private object XML_ATTR {
        fun find(attrs: String, name: String): String? = Regex("\\b$name=\"([^\"]*)\"").find(attrs)?.groupValues?.get(1)
    }

    /** XMLTV times may omit the zone ("20261113080000"); China time then. */
    private fun fixZone(t: String): String = if (t.trim().length == 14) t.trim() + " +0800" else t.trim()

    private fun clock(s: String?): Long? {
        val m = Regex("^(\\d{1,2}):(\\d{2})").find(s?.trim() ?: return null) ?: return null
        return (m.groupValues[1].toLong() * 60 + m.groupValues[2].toLong()) * 60_000
    }

    private fun unescape(s: String) = s.replace("<![CDATA[", "").replace("]]>", "")
        .replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}
