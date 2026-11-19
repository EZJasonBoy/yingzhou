package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.response.header
import io.ktor.server.response.respondBytesWriter
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.utils.io.ByteWriteChannel
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.delay
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The demo's slow source: forty minutes of made-up video ([DemoVideo]) as HLS, served the way a poor site serves it
 * — every answer waits a while and then trickles — and keeping a record of every request. It is there to measure
 * what seeking costs and what the engine's stream cache saves (`client/integration_test/seek_test.dart`).
 *
 * Under `/demo/slow`:
 * - `index.m3u8`: a plain playlist with relative segment addresses; `master.m3u8`: a master playlist over it;
 *   `aes/index.m3u8`: the same segments AES-128 encrypted, with a key to fetch; `range/index.m3u8`: all segments
 *   as byte ranges of one file; `film.mpg`: that file as a direct link (not HLS).
 * - `set?delayMs=&connectMs=&kBps=&totalKBps=&cutAfter=&refuse=&reset=1`: the knobs, and clearing the record.
 * - `log`: the knobs and the record as JSON.
 */
class DemoSlowSource {
    val video = DemoVideo()
    val segments = MINUTES * 60 / video.segmentSeconds

    /** Wait before every answer (the time to first byte of a far-away server). */
    @Volatile var delayMs = 400

    /** Extra wait for the first request on a connection (TCP and TLS handshakes). */
    @Volatile var connectMs = 300

    /** Bandwidth of one answer in kB/s, and of all answers together; 0 lifts the limit. */
    @Volatile var kBps = 300
    @Volatile var totalKBps = 0

    /** Faults, for trying out what happens when a source misbehaves: every answer with video in it breaks off after this many bytes (0: never). */
    @Volatile var cutAfter = 0

    /** Segments and keys are refused with this HTTP status (0: served). */
    @Volatile var refuse = 0

    class Entry(val id: Int, val at: Long, val what: String, val index: Int, val range: String, val total: Int, val connection: Int, val newConnection: Boolean) {
        @Volatile var bytes = 0
        @Volatile var ms = -1L
        @Volatile var aborted = false
    }

    private val ids = AtomicInteger()
    private val entries = java.util.concurrent.ConcurrentLinkedQueue<Entry>()
    private val connections = ConcurrentHashMap<String, Int>()
    private val connectionIds = AtomicInteger()
    private val paceLock = Any()
    private var sharedNext = 0L

    /** The segments made last: an answer is written a few kilobytes at a time, and must not make its segment anew each time. */
    private val recent = object : LinkedHashMap<Int, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, ByteArray>): Boolean = size > 8
    }

    fun reset() {
        entries.clear()
    }

    fun logJson(): String = buildJsonObject {
        put("delayMs", delayMs)
        put("connectMs", connectMs)
        put("kBps", kBps)
        put("totalKBps", totalKBps)
        put("cutAfter", cutAfter)
        put("refuse", refuse)
        put("segmentBytes", video.segmentBytes)
        put("segmentSeconds", video.segmentSeconds)
        put("segments", segments)
        putJsonArray("requests") {
            for (e in entries) addJsonObject {
                put("id", e.id)
                put("at", e.at)
                put("what", e.what)
                put("index", e.index)
                put("range", e.range)
                put("total", e.total)
                put("bytes", e.bytes)
                put("ms", e.ms)
                put("aborted", e.aborted)
                put("connection", e.connection)
                put("newConnection", e.newConnection)
            }
        }
    }.toString()

    fun playlist(segmentLine: (Int) -> String, extra: String = ""): String = buildString {
        appendLine("#EXTM3U")
        appendLine("#EXT-X-VERSION:4")
        appendLine("#EXT-X-TARGETDURATION:${video.segmentSeconds}")
        appendLine("#EXT-X-MEDIA-SEQUENCE:0")
        appendLine("#EXT-X-PLAYLIST-TYPE:VOD")
        if (extra.isNotEmpty()) appendLine(extra)
        for (i in 0 until segments) {
            appendLine("#EXTINF:${video.segmentSeconds}.000,")
            appendLine(segmentLine(i))
        }
        appendLine("#EXT-X-ENDLIST")
    }

    fun segment(index: Int): ByteArray = synchronized(recent) { recent.getOrPut(index) { video.segment(index) } }

    /** Segment [index] encrypted as HLS does it: AES-128-CBC, the sequence number as the initialisation vector. */
    fun encrypted(index: Int): ByteArray {
        val iv = ByteArray(16)
        for (i in 0 until 4) iv[15 - i] = (index ushr (8 * i)).toByte()
        return Cipher.getInstance("AES/CBC/PKCS5Padding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(KEY, "AES"), IvParameterSpec(iv))
            doFinal(segment(index))
        }
    }

    /** Bytes [from, to) of all segments laid end to end. */
    fun slice(from: Long, to: Long): ByteArray {
        val out = ByteArray((to - from).toInt())
        var at = from
        while (at < to) {
            val index = (at / video.segmentBytes).toInt()
            val inside = (at % video.segmentBytes).toInt()
            val n = minOf((video.segmentBytes - inside).toLong(), to - at).toInt()
            System.arraycopy(segment(index), inside, out, (at - from).toInt(), n)
            at += n
        }
        return out
    }

    /**
     * Notes the request, waits as a slow server would, and answers the file of [wholeLength] bytes (or the part the
     * request asks for) at the capped rate. [body] gives bytes [from, to) of the file; it is asked for a few
     * kilobytes at a time.
     */
    suspend fun serve(call: ApplicationCall, what: String, index: Int, contentType: ContentType, wholeLength: Long, body: (Long, Long) -> ByteArray) {
        val peer = call.request.local.remoteAddress + ":" + call.request.local.remotePort
        val known = connections[peer]
        val connection = known ?: connectionIds.incrementAndGet().also { connections[peer] = it }
        val rangeHeader = call.request.headers[HttpHeaders.Range].orEmpty()
        val range = Regex("bytes=(\\d+)-(\\d*)").find(rangeHeader)
        val from = range?.groupValues?.get(1)?.toLong() ?: 0L
        val to = (range?.groupValues?.get(2)?.toLongOrNull()?.plus(1) ?: wholeLength).coerceAtMost(wholeLength)
        val entry = Entry(ids.incrementAndGet(), System.currentTimeMillis(), what, index, rangeHeader.removePrefix("bytes="), (to - from).coerceAtLeast(0).toInt(), connection, known == null)
        entries += entry
        while (entries.size > MAX_ENTRIES) entries.poll()
        val started = System.nanoTime()
        try {
            delay(delayMs.toLong() + if (known == null) connectMs else 0)
            if (what != "playlist" && refuse != 0) {
                entry.aborted = true
                call.respondText("refused", status = HttpStatusCode.fromValue(refuse))
                return
            }
            if (from >= to) {
                call.response.header(HttpHeaders.ContentRange, "bytes */$wholeLength")
                call.respondText("", status = HttpStatusCode.RequestedRangeNotSatisfiable)
                return
            }
            call.response.header(HttpHeaders.AcceptRanges, "bytes")
            if (range != null) call.response.header(HttpHeaders.ContentRange, "bytes $from-${to - 1}/$wholeLength")
            call.respondBytesWriter(contentType, if (range != null) HttpStatusCode.PartialContent else HttpStatusCode.OK, to - from) {
                paced(from, to, body, entry, breakable = what != "playlist")
            }
        } catch (e: Throwable) {
            entry.aborted = true
            throw e
        } finally {
            if (entry.bytes < entry.total) entry.aborted = true
            entry.ms = (System.nanoTime() - started) / 1_000_000
        }
    }

    private suspend fun ByteWriteChannel.paced(from: Long, to: Long, body: (Long, Long) -> ByteArray, entry: Entry, breakable: Boolean) {
        var next = System.nanoTime()
        var at = from
        while (at < to) {
            // The fault a flaky source has: the connection goes in the middle of a file. A moment first, so that what
            // was sent has arrived (a connection that is reset takes what is still on its way with it).
            if (breakable && cutAfter > 0 && at - from >= cutAfter) {
                delay(100)
                throw IOException("cut off after ${at - from} bytes (the cutAfter knob)")
            }
            val chunk = body(at, minOf(at + CHUNK, to))
            val n = chunk.size
            writeFully(chunk, 0, n)
            flush()
            at += n
            entry.bytes = (at - from).toInt()
            val now = System.nanoTime()
            val own = kBps
            if (own > 0) next = maxOf(next, now - SLACK) + n * 1_000_000L / own else next = now
            var until = next
            val shared = totalKBps
            if (shared > 0) {
                synchronized(paceLock) {
                    sharedNext = maxOf(sharedNext, now - SLACK) + n * 1_000_000L / shared
                    until = maxOf(until, sharedNext)
                }
            }
            val wait = (until - now) / 1_000_000
            if (wait > 0) delay(wait)
        }
    }

    companion object {
        const val MINUTES = 40
        private const val CHUNK = 8 * 1024
        private const val MAX_ENTRIES = 20_000

        /** How far a sender may fall behind its schedule and still catch up (timers are coarse). */
        private const val SLACK = 50_000_000L

        val KEY = "demo-slow-key-01".toByteArray()
        val TS = ContentType("video", "mp2t")
        val M3U8 = ContentType("application", "vnd.apple.mpegurl")
    }
}

fun Route.demoSlowRoutes(slow: DemoSlowSource) {
    val video = slow.video
    val whole = slow.segments.toLong() * video.segmentBytes

    suspend fun ApplicationCall.playlist(text: String) {
        val bytes = text.toByteArray()
        slow.serve(this, "playlist", -1, DemoSlowSource.M3U8, bytes.size.toLong()) { from, to -> bytes.copyOfRange(from.toInt(), to.toInt()) }
    }

    fun ApplicationCall.index(): Int? = parameters["name"]?.removeSuffix(".ts")?.toIntOrNull()?.takeIf { it in 0 until slow.segments }

    get("/demo/slow/index.m3u8") { call.playlist(slow.playlist({ "seg/$it.ts" })) }
    get("/demo/slow/master.m3u8") {
        call.playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2100000,RESOLUTION=${DemoVideo.WIDTH}x${DemoVideo.HEIGHT}\nindex.m3u8\n")
    }
    get("/demo/slow/aes/index.m3u8") { call.playlist(slow.playlist({ "seg/$it.ts" }, "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"")) }
    get("/demo/slow/range/index.m3u8") {
        call.playlist(slow.playlist({ "#EXT-X-BYTERANGE:${video.segmentBytes}@${it.toLong() * video.segmentBytes}\nall.ts" }))
    }

    get("/demo/slow/seg/{name}") {
        val i = call.index() ?: return@get call.respondText("no such segment", status = HttpStatusCode.NotFound)
        slow.serve(call, "segment", i, DemoSlowSource.TS, video.segmentBytes.toLong()) { from, to -> slow.segment(i).copyOfRange(from.toInt(), to.toInt()) }
    }
    get("/demo/slow/aes/seg/{name}") {
        val i = call.index() ?: return@get call.respondText("no such segment", status = HttpStatusCode.NotFound)
        val data = slow.encrypted(i)
        slow.serve(call, "segment", i, DemoSlowSource.TS, data.size.toLong()) { from, to -> data.copyOfRange(from.toInt(), to.toInt()) }
    }
    get("/demo/slow/aes/key.bin") {
        slow.serve(call, "key", -1, ContentType.Application.OctetStream, 16) { from, to -> DemoSlowSource.KEY.copyOfRange(from.toInt(), to.toInt()) }
    }
    // All segments end to end: the file the byte-range playlist points into, and (as film.mpg, a name the engine
    // takes for a video file) a direct link to the whole film.
    for (path in listOf("/demo/slow/range/all.ts", "/demo/slow/film.mpg")) {
        get(path) {
            val start = Regex("bytes=(\\d+)-").find(call.request.headers[HttpHeaders.Range].orEmpty())?.groupValues?.get(1)?.toLongOrNull() ?: 0
            slow.serve(call, "segment", (start / video.segmentBytes).toInt(), DemoSlowSource.TS, whole, slow::slice)
        }
    }

    get("/demo/slow/set") {
        val q = call.request.queryParameters
        q["delayMs"]?.toIntOrNull()?.let { slow.delayMs = it.coerceAtLeast(0) }
        q["connectMs"]?.toIntOrNull()?.let { slow.connectMs = it.coerceAtLeast(0) }
        q["kBps"]?.toIntOrNull()?.let { slow.kBps = it.coerceAtLeast(0) }
        q["totalKBps"]?.toIntOrNull()?.let { slow.totalKBps = it.coerceAtLeast(0) }
        q["cutAfter"]?.toIntOrNull()?.let { slow.cutAfter = it.coerceAtLeast(0) }
        q["refuse"]?.toIntOrNull()?.let { slow.refuse = if (it in 400..599) it else 0 }
        if (q["reset"] == "1") slow.reset()
        call.respondText(slow.logJson(), ContentType.Application.Json)
    }
    get("/demo/slow/log") { call.respondText(slow.logJson(), ContentType.Application.Json) }
}
