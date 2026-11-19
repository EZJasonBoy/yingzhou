package tvbox.engine.core.live

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import tvbox.engine.core.model.CatchupTemplate
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Catch-up (回看): the address that plays what a channel showed between two times.
 *
 * The rules come from three places, read the way the players that use them read them:
 *
 * - TVBox (TVBoxOS / takagen99 Box, `LivePlayActivity`): the `catchup` object of a `lives` entry or a channel
 *   (`type`, `source`, `replace`, `regex`); `default` means the source is the whole address, anything else appends
 *   it to the live address (after `replace`, with `?` turned into `&` when the address has a query already); the
 *   placeholders `${(b)<pattern>}` / `${(e)<pattern>}` (start / end in a Java date pattern, or `timestamp`) and
 *   `{utc:}` / `{utcend:}`; a channel without a rule whose address has `/PLTV/` plays its past as
 *   `/TVOD/…?playseek=<start>-<end>` (Box: `?playseek=` on the live address).
 * - M3U attributes, as Kodi's IPTV Simple client defines them (`catchup`, `catchup-source`, `catchup-days`,
 *   `catchup-correction`, the modes `default`, `append`, `shift`, `flussonic`, `xc`, `vod`) and its placeholders
 *   (`{utc}`, `${start}`, `{utcend}`, `${end}`, `{lutc}`, `${now}`, `${timestamp}`, `{duration}`, `{duration:N}`,
 *   `{offset:N}`, `{Y}{m}{d}{H}{M}{S}`, `{utc:YmdHMS}`, `${end:Ymd-H-M}` …).
 *
 * Dates are written in China time, like the programme guide. java.time is avoided (Android 7).
 */
object Catchup {
    /** Days back when a rule does not say (TVBox lists a week of guide days). */
    const val DEFAULT_DAYS = 7

    private const val PLAYSEEK = "?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}"

    /** How many days back [url] can be played again under [rule]; 0 when it cannot. */
    fun days(rule: CatchupTemplate?, url: String): Int =
        if (templates(rule, url).isEmpty()) 0 else rule?.days?.takeIf { it > 0 } ?: DEFAULT_DAYS

    /**
     * The addresses that may play [startMs]..[endMs] of the line [url], best first (a mode can address the same
     * archive in more than one way). Empty when the line has no catch-up.
     */
    fun build(rule: CatchupTemplate?, url: String, startMs: Long, endMs: Long, nowMs: Long = System.currentTimeMillis()): List<String> {
        val shift = (rule?.correctionSeconds ?: 0L) * 1000
        val start = startMs + shift
        // A programme still on air is played up to now.
        val end = minOf(endMs, nowMs) + shift
        return templates(rule, url).map { format(it, start, end, nowMs) }.distinct()
    }

    /** The address templates (with placeholders) of [url] under [rule]. */
    internal fun templates(rule: CatchupTemplate?, url: String): List<String> {
        if (url.isBlank() || url.startsWith("rtp://") || url.startsWith("udp://")) return emptyList()
        if (rule == null) return listOfNotNull(pltv(url))
        if (rule.regex.isNotEmpty() && !matches(rule.regex, url)) return emptyList()
        return when (rule.type) {
            "default", "vod" -> if (rule.source.isNotEmpty()) listOf(rule.source) else listOfNotNull(pltv(url))
            "shift", "timeshift" -> listOf(url + (if (url.contains('?')) "&" else "?") + "utc={utc}&lutc={lutc}")
            "flussonic", "flussonic-hls", "flussonic-ts", "fs" -> flussonic(url)
            "xc" -> listOfNotNull(xtream(url))
            // "append", TVBox's own words for it, or nothing said: a source is appended to the live address.
            else -> if (rule.source.isNotEmpty()) listOf(append(replaced(url, rule.replace), rule.source)) else listOfNotNull(pltv(url))
        }
    }

    private fun matches(regex: String, url: String): Boolean =
        url.contains(regex) || runCatching { Regex(regex).containsMatchIn(url) }.getOrDefault(false)

    /** TVBox `replace`: `regex,replacement`. */
    private fun replaced(url: String, replace: String): String {
        val parts = replace.split(',', limit = 2)
        if (parts.size < 2 || parts[0].isEmpty()) return url
        return runCatching { url.replace(Regex(parts[0]), parts[1].replace("\\", "\\\\").replace("$", "\\$")) }.getOrDefault(url)
    }

    /** TVBox `appendCatchupUrl`: a source starting a query continues the address's own query. */
    private fun append(url: String, source: String): String {
        val q = url.indexOf('?')
        return url + if (q >= 0 && q < url.length - 1) source.replace("?", "&") else source
    }

    /** IPTV / Huawei-style addresses: `/PLTV/` is the live stream, `/TVOD/` the same channel's archive. */
    private fun pltv(url: String): String? = if (url.contains("/PLTV/")) append(url.replace("/PLTV/", "/TVOD/"), PLAYSEEK) else null

    private val FLUSSONIC = Regex("^(https?://[^/]+)/(.*)/([^/]*)(mpegts|\\.m3u8)(\\?.+=.+)?$")
    private val FLUSSONIC_ANY = Regex("^(https?://[^/]+)/(.*)/([^?]*)(\\?.+=.+)?$")

    /**
     * Flussonic: the archive as a finished playlist (`<list>-<start>-<duration>.m3u8`, which has a seek bar) first,
     * then Kodi's address that plays on from the start like live (`timeshift_rel` / `timeshift_abs`).
     */
    private fun flussonic(url: String): List<String> {
        FLUSSONIC.find(url)?.let { m ->
            val (host, channel, list, kind) = m.destructured
            val query = m.groupValues[5]
            return if (kind == "mpegts") {
                listOf("$host/$channel/archive-{utc}-{duration}.ts$query", "$host/$channel/timeshift_abs-{utc}.ts$query")
            } else {
                val name = list.ifEmpty { "index" }
                listOf(
                    "$host/$channel/$name-{utc}-{duration}.m3u8$query",
                    if (name == "index") "$host/$channel/timeshift_rel-{offset:1}.m3u8$query" else "$host/$channel/$name-timeshift_rel-{offset:1}.m3u8$query",
                )
            }
        }
        val m = FLUSSONIC_ANY.find(url) ?: return emptyList()
        val (host, channel) = m.destructured
        val query = m.groupValues[4]
        return listOf("$host/$channel/index-{utc}-{duration}.m3u8$query", "$host/$channel/timeshift_rel-{offset:1}.m3u8$query")
    }

    private val XTREAM = Regex("^(https?://[^/]+)/(?:live/)?([^/]+)/([^/]+)/([^/.]+)(\\.m3u8?)?$")

    /** Xtream Codes: `/timeshift/<user>/<password>/<minutes>/<Y-m-d:H-M>/<id>.<ext>`. */
    private fun xtream(url: String): String? {
        val m = XTREAM.find(url) ?: return null
        val (host, user, password, id) = m.destructured
        val ext = m.groupValues[5].ifEmpty { ".ts" }
        return "$host/timeshift/$user/$password/{duration:60}/{Y}-{m}-{d}:{H}-{M}/$id$ext"
    }

    private val TOKEN = Regex("\\$?\\{([^}]*)\\}")
    private val JAVA_PATTERN = Regex("yy|MM|dd|HH|mm|ss")

    /** Replaces every placeholder of [template]; one it does not know is left as it is. */
    internal fun format(template: String, start: Long, end: Long, now: Long): String = TOKEN.replace(template) { m ->
        token(m.groupValues[1], start, end, now) ?: m.value
    }

    private fun token(tag: String, start: Long, end: Long, now: Long): String? {
        // TVBox: ${(b)yyyyMMddHHmmss}, ${(e)timestamp}
        if (tag.startsWith("(b)")) return time(start, tag.substring(3), java = true)
        if (tag.startsWith("(e)")) return time(end, tag.substring(3), java = true)
        val name = tag.substringBefore(':')
        val arg = if (tag.contains(':')) tag.substringAfter(':') else null
        return when (name) {
            "utc", "start" -> time(start, arg)
            "utcend", "end" -> time(end, arg)
            "lutc", "now", "timestamp" -> time(now, arg)
            "duration" -> units(end - start, arg)
            "offset" -> units(now - start, arg)
            "Y", "m", "d", "H", "M", "S" -> if (arg == null) time(start, name) else null
            else -> null
        }
    }

    /** Seconds since the epoch when there is no pattern, else the time written in it (China time). */
    private fun time(ms: Long, pattern: String?, java: Boolean = false): String {
        if (pattern.isNullOrEmpty() || pattern == "timestamp") return (ms / 1000).toString()
        val javaPattern = if (java || JAVA_PATTERN.containsMatchIn(pattern)) pattern else kodiPattern(pattern)
        return runCatching { SimpleDateFormat(javaPattern, Locale.ROOT).apply { timeZone = Epg.ZONE }.format(Date(ms)) }.getOrDefault("")
    }

    /** Kodi's letters (`Y m d H M S`) as a Java date pattern; everything else is kept as written. */
    private fun kodiPattern(pattern: String): String = buildString {
        for (c in pattern) {
            append(
                when (c) {
                    'Y' -> "yyyy"
                    'm' -> "MM"
                    'd' -> "dd"
                    'H' -> "HH"
                    'M' -> "mm"
                    'S' -> "ss"
                    '\'' -> "''"
                    else -> if (c.isLetter()) "'$c'" else c.toString()
                },
            )
        }
    }

    /** A span in seconds, or in units of N seconds for `{duration:N}`; never below zero. */
    private fun units(ms: Long, arg: String?): String? {
        val divider = if (arg == null) 1L else arg.toLongOrNull()?.takeIf { it > 0 } ?: return null
        return maxOf(0L, ms / 1000 / divider).toString()
    }

    // ---- reading rules ----

    /**
     * A rule from M3U attributes (lower-case names): `catchup`, `catchup-source`, `catchup-days`,
     * `catchup-correction` (hours), TVBox's `catchup-replace`, and SIPTV's `timeshift="<days>"`. Null when none.
     */
    fun fromAttributes(attrs: Map<String, String>): CatchupTemplate? {
        val type = attrs["catchup"]?.trim().orEmpty()
        val source = attrs["catchup-source"]?.trim().orEmpty()
        val replace = attrs["catchup-replace"]?.trim().orEmpty()
        val siptv = attrs["timeshift"]?.trim()?.toIntOrNull()
        val days = attrs["catchup-days"]?.trim()?.toDoubleOrNull()?.toInt()
        val correction = attrs["catchup-correction"]?.trim()?.toDoubleOrNull()?.let { (it * 3600).toLong() }
        if (type.isEmpty() && source.isEmpty() && replace.isEmpty() && siptv == null && days == null && correction == null) return null
        if (type.isEmpty() && source.isEmpty() && replace.isEmpty() && siptv != null) {
            return CatchupTemplate(type = "shift", days = siptv, correctionSeconds = correction)
        }
        return CatchupTemplate(type = type.lowercase(Locale.ROOT), source = source, replace = replace, days = days ?: siptv, correctionSeconds = correction)
    }

    /**
     * TVBox's `catchup` of a `lives` entry or of a channel in a JSON list: an object `{type, source, replace, regex,
     * days}`, or a type string next to `catchup-source` / `catchup-replace` / `catchup-days`.
     */
    fun fromJson(owner: JsonObject): CatchupTemplate? {
        fun JsonElement?.text(): String = this?.takeIf { it.isJsonPrimitive }?.asString?.trim().orEmpty()
        val element = owner.get("catchup") ?: return null
        return if (element.isJsonObject) {
            val o = element.asJsonObject
            fromAttributes(
                mapOf(
                    "catchup" to o.get("type").text(),
                    "catchup-source" to o.get("source").text(),
                    "catchup-replace" to o.get("replace").text(),
                    "catchup-days" to o.get("days").text(),
                    "catchup-correction" to o.get("correction").text(),
                ).filterValues { it.isNotEmpty() },
            )?.copy(regex = o.get("regex").text())
        } else {
            fromAttributes(
                mapOf(
                    "catchup" to element.text(),
                    "catchup-source" to owner.get("catchup-source").text(),
                    "catchup-replace" to owner.get("catchup-replace").text(),
                    "catchup-days" to owner.get("catchup-days").text(),
                ).filterValues { it.isNotEmpty() },
            )
        }
    }

    /** A channel's own rule, with what it leaves unsaid taken from the playlist header's. */
    fun merge(own: CatchupTemplate?, header: CatchupTemplate?): CatchupTemplate? = when {
        own == null -> header
        header == null -> own
        else -> own.copy(
            type = own.type.ifEmpty { header.type },
            source = own.source.ifEmpty { header.source },
            replace = own.replace.ifEmpty { header.replace },
            days = own.days ?: header.days,
            correctionSeconds = own.correctionSeconds ?: header.correctionSeconds,
        )
    }

    /** Whether a rule can address an archive by itself (it is more than days or a correction). */
    fun isComplete(rule: CatchupTemplate?): Boolean =
        rule != null && (rule.source.isNotEmpty() || rule.type in setOf("shift", "timeshift", "flussonic", "flussonic-hls", "flussonic-ts", "fs", "xc"))
}
