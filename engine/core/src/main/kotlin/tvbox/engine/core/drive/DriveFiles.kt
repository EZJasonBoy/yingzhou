package tvbox.engine.core.drive

import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/** Paths inside a drive, file kinds by extension, sorting and the dates servers send. */
object DriveFiles {
    /** What players open: recognised by extension, like TVBox's and Box's drive pages do. */
    val VIDEO = setOf(
        "mp4", "m4v", "mkv", "mk3d", "mov", "qt", "avi", "divx", "wmv", "asf", "flv", "f4v", "webm", "ogv", "ts", "m2ts", "mts", "m2t",
        "tp", "trp", "mpg", "mpeg", "mpe", "m2v", "vob", "rm", "rmvb", "3gp", "3g2", "dv", "hevc",
    )

    /** Subtitles shown beside a video of the same base name (`film.mkv`: `film.srt`, `film.zh.ass`, ...). */
    val SUBTITLE = setOf("srt", "ass", "ssa", "vtt")

    fun extension(name: String): String = name.substringAfterLast('.', "").lowercase(Locale.ROOT)

    fun baseName(name: String): String = if ('.' in name) name.substringBeforeLast('.') else name

    fun type(name: String, dir: Boolean): String = when {
        dir -> "folder"
        extension(name) in VIDEO -> "video"
        extension(name) in SUBTITLE -> "subtitle"
        else -> "other"
    }

    fun isVideo(name: String) = extension(name) in VIDEO

    /**
     * The canonical form of a path inside a drive: "/" + segments joined by "/". Empty and "." segments go; ".."
     * and segments with a backslash or a NUL are refused (and, for folders on the engine's machine, a colon, which
     * names a drive letter or a stream on Windows).
     */
    fun normalize(path: String, local: Boolean = false): String {
        val segments = path.split('/').filter { it.isNotEmpty() && it != "." }
        for (s in segments) {
            if (s == ".." || '\\' in s || '\u0000' in s || (local && ':' in s)) throw DriveException.bad("路径不合法：$path")
        }
        return "/" + segments.joinToString("/")
    }

    fun parent(path: String): String = path.substringBeforeLast('/', "").ifEmpty { "/" }

    fun nameOf(path: String): String = path.substringAfterLast('/')

    /** [base] (a normalised path) and [rest] (one too), joined. */
    fun join(base: String, rest: String): String = when {
        base == "/" -> rest
        rest == "/" -> base
        else -> base + rest
    }

    /** [path] relative to [base], or null when it is not inside it. Both normalised. */
    fun relative(path: String, base: String): String? = when {
        base == "/" -> path
        path == base -> "/"
        path.startsWith("$base/") -> path.substring(base.length)
        else -> null
    }

    /** Each segment percent-encoded (UTF-8); the slashes stay. */
    fun encodePath(path: String): String = path.split('/').joinToString("/") { encodeSegment(it) }

    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    fun encodeSegment(s: String): String = buildString {
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xFF
            if (c < 0x80 && UNRESERVED.indexOf(c.toChar()) >= 0) {
                append(c.toChar())
            } else {
                append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
            }
        }
    }

    /** Percent-decoding of a path (a "+" stays a "+"); a malformed escape is kept as it is. */
    fun decodePath(s: String): String {
        if ('%' !in s) return s
        val out = ByteArrayOutputStream(s.length)
        val raw = s.toByteArray(Charsets.UTF_8)
        var i = 0
        while (i < raw.size) {
            val b = raw[i]
            if (b == '%'.code.toByte() && i + 2 < raw.size) {
                val hi = Character.digit(raw[i + 1].toInt(), 16)
                val lo = Character.digit(raw[i + 2].toInt(), 16)
                if (hi >= 0 && lo >= 0) {
                    out.write(hi * 16 + lo)
                    i += 3
                    continue
                }
            }
            out.write(b.toInt())
            i++
        }
        return String(out.toByteArray(), Charsets.UTF_8)
    }

    /**
     * Names compared the way people number episodes: runs of digits by their value ("第2集" before "第10集"), the
     * rest without regard to case.
     */
    val naturalOrder: Comparator<String> = Comparator { a, b ->
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            val ca = a[i]
            val cb = b[j]
            if (ca.isDigit() && cb.isDigit()) {
                var ei = i
                while (ei < a.length && a[ei].isDigit()) ei++
                var ej = j
                while (ej < b.length && b[ej].isDigit()) ej++
                val na = a.substring(i, ei).trimStart('0')
                val nb = b.substring(j, ej).trimStart('0')
                if (na.length != nb.length) return@Comparator na.length - nb.length
                val c = na.compareTo(nb)
                if (c != 0) return@Comparator c
                i = ei
                j = ej
            } else {
                val c = ca.lowercaseChar().compareTo(cb.lowercaseChar())
                if (c != 0) return@Comparator c
                i++
                j++
            }
        }
        (a.length - i) - (b.length - j)
    }

    /** Folders first, then by name as above. */
    val entryOrder: Comparator<DriveEntry> = Comparator { a, b ->
        if (a.dir != b.dir) (if (a.dir) -1 else 1) else naturalOrder.compare(a.name, b.name).let { if (it != 0) it else a.name.compareTo(b.name) }
    }

    /**
     * The subtitles among [siblings] that go with the video [videoName]: same base name, then optionally a language
     * tag (`film.zh.srt`, `film.chs.ass`). Pairs of the subtitle entry and its tag.
     */
    fun subtitlesFor(videoName: String, siblings: List<DriveEntry>): List<Pair<DriveEntry, String>> {
        val base = baseName(videoName).lowercase(Locale.ROOT)
        return siblings.filter { !it.dir && extension(it.name) in SUBTITLE }.mapNotNull { e ->
            val sub = baseName(e.name)
            when {
                sub.lowercase(Locale.ROOT) == base -> e to ""
                sub.lowercase(Locale.ROOT).startsWith("$base.") -> e to sub.substring(base.length + 1)
                else -> null
            }
        }.sortedWith { x, y -> naturalOrder.compare(x.first.name, y.first.name) }
    }

    /** MIME type by extension, for what the engine serves itself. */
    fun contentType(name: String): String = when (extension(name)) {
        "mp4", "m4v" -> "video/mp4"
        "mkv", "mk3d" -> "video/x-matroska"
        "webm" -> "video/webm"
        "mov", "qt" -> "video/quicktime"
        "avi", "divx" -> "video/x-msvideo"
        "wmv" -> "video/x-ms-wmv"
        "asf" -> "video/x-ms-asf"
        "flv" -> "video/x-flv"
        "f4v" -> "video/x-f4v"
        "ts", "m2ts", "mts", "m2t", "tp", "trp" -> "video/mp2t"
        "mpg", "mpeg", "mpe", "m2v", "vob" -> "video/mpeg"
        "ogv" -> "video/ogg"
        "3gp" -> "video/3gpp"
        "3g2" -> "video/3gpp2"
        "rm", "rmvb" -> "application/vnd.rn-realmedia-vbr"
        "srt" -> "application/x-subrip"
        "ass", "ssa" -> "text/x-ssa"
        "vtt" -> "text/vtt"
        else -> "application/octet-stream"
    }

    // ---- dates (no java.time: the engine runs on Android 7 too) ----

    private val ISO = Regex("(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(\\.\\d+)?(Z|[+-]\\d{2}:?\\d{2})?")

    /** `2024-05-01T12:34:56.789+08:00` (AList); 0 when it is not one. Without a zone, UTC. */
    fun parseIso(s: String): Long {
        val m = ISO.find(s.trim()) ?: return 0
        val g = m.groupValues
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"), Locale.ROOT)
        cal.clear()
        cal.set(g[1].toInt(), g[2].toInt() - 1, g[3].toInt(), g[4].toInt(), g[5].toInt(), g[6].toInt())
        var ms = cal.timeInMillis
        if (g[7].isNotEmpty()) ms += (g[7].substring(1).padEnd(3, '0').take(3)).toLong()
        val zone = g[8]
        if (zone.isNotEmpty() && zone != "Z") {
            val sign = if (zone[0] == '-') -1 else 1
            val digits = zone.substring(1).replace(":", "")
            ms -= sign * (digits.take(2).toLong() * 3600_000 + digits.drop(2).toLong() * 60_000)
        }
        // Go's zero time, what AList sends for "unknown".
        return if (ms < 0) 0 else ms
    }

    /** `Mon, 12 Feb 2024 10:00:00 GMT` (WebDAV `getlastmodified`); falls back to ISO; 0 when neither. */
    fun parseHttpDate(s: String): Long {
        val text = s.trim()
        if (text.isEmpty()) return 0
        return runCatching {
            SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT") }.parse(text)!!.time
        }.getOrElse { parseIso(text) }
    }
}
