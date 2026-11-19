package tvbox.engine.core.cache

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import tvbox.engine.core.play.HlsRewriter
import tvbox.engine.core.play.HlsRewriter.Kind
import tvbox.engine.core.play.HlsRewriter.Resource
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/**
 * Video-on-demand HLS through the engine: the playlists the engine hands to players name the engine instead of the
 * source ([HlsRewriter]), and what players then ask for is fetched once, kept in a [StreamStore] and served from
 * there. It exists to make seeking in slow streams quick:
 *
 * - what was fetched once is served from disk at once, without asking the source;
 * - ahead of the segment a player last asked for, the next [aheadMs] of the film are fetched over up to
 *   [connections] connections, which are kept open and used again;
 * - a segment a player jumps to and has to wait for is fetched in pieces over several connections when the source
 *   takes byte ranges, and nothing else is fetched from that source until it has arrived (or a moment has passed);
 * - a player is answered before the source is: a file that is still on its way is handed on as it comes in.
 *
 * When the source will not give the engine a file, the player is sent to the source itself ([Answer.Redirect]).
 */
class StreamCache(
    client: OkHttpClient,
    val store: StreamStore,
    private val now: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    /** Off: playlists are left to point at the source (what is in the store stays there). */
    @Volatile var enabled = true

    /** How much of the film after the segment a player last asked for is fetched ahead. */
    @Volatile var aheadMs = 180_000L

    /** Requests to one stream's source that may run at the same time. */
    @Volatile var connections = 4

    /**
     * One connection per request: sources that are slow are usually slow per connection, and a few requests on one
     * HTTP/2 connection would share its speed. The connections are kept and used again.
     */
    private val http: OkHttpClient = client.newBuilder()
        .protocols(listOf(Protocol.HTTP_1_1))
        .connectionPool(ConnectionPool(8, 3, TimeUnit.MINUTES))
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val sessions = LinkedHashMap<String, Session>()
    private val downloads = HashMap<String, Download>()

    /** When the source last refused a file (by store path), and which streams it refuses altogether. */
    private val refusedAt = HashMap<String, Long>()
    private val bypassedAt = HashMap<String, Long>()

    /** A playlist handed out: the files a player may ask for, under the numbers the playlist gave them. */
    class Session internal constructor(
        val id: String,
        /** The folder in the store. */
        val stream: String,
        /** What `/play/resolve` called the episode, when the playlist came from there. */
        val key: String?,
        @Volatile internal var resources: List<Resource>,
        @Volatile internal var headers: Map<String, String>,
        @Volatile internal var userAgent: String?,
    ) {
        /** Numbers of the segments in playing order, and the place of each number in that order (-1: not a segment). */
        internal val segments: IntArray = resources.indices.filter { resources[it].kind == Kind.SEGMENT }.toIntArray()
        internal val place: IntArray = IntArray(resources.size) { -1 }.also { p -> segments.forEachIndexed { i, n -> p[n] = i } }

        /** The place of the segment a player asked for last; where the player jumped to last, and when. */
        @Volatile internal var head = -1
        @Volatile internal var askedAt = 0L
        @Volatile internal var jumpTo = -1
        @Volatile internal var jumpAt = 0L

        /** How many times since the last jump the player has asked for the segment after the one before. */
        @Volatile internal var steps = 0

        /** The download a player is waiting for, which the stream's other downloads make way for; and since when. */
        @Volatile internal var waitedFor: Download? = null
        @Volatile internal var waitedSince = 0L

        /** The source has answered at least one request; how often it refused before that. */
        @Volatile internal var proven = false
        @Volatile internal var refusals = 0
        @Volatile internal var bypass = false

        /** Whether the source answers byte ranges with those bytes; null until it has been seen to. */
        @Volatile internal var ranges: Boolean? = null

        /** About how many bytes a millisecond of this stream takes (from the segments fetched so far); 0 unknown. */
        @Volatile internal var bytesPerMs = 0.0

        internal fun learn(rate: Double) {
            bytesPerMs = if (bytesPerMs == 0.0) rate else bytesPerMs * 0.7 + rate * 0.3
        }

        /** Answers from the source whose bodies are being read right now. */
        internal val receiving = java.util.concurrent.atomic.AtomicInteger()

        /** How many bytes a millisecond one connection to the source brought the last time; 0 unknown. */
        @Volatile internal var connectionRate = 0.0

        /**
         * The last few times a connection was the only one busy: what it brought. And the last few times several
         * were busy at once: what they brought together.
         */
        private val alone = DoubleArray(RATES)
        private var aloneSeen = 0
        private val together = DoubleArray(RATES)
        private var togetherSeen = 0

        /** An answer of some size has been read at [rate], while on average [busy] answers were being read. */
        @Synchronized
        internal fun sample(rate: Double, busy: Double) {
            connectionRate = rate
            if (busy < 1.3) alone[aloneSeen++ % RATES] = rate else if (busy >= 1.7) together[togetherSeen++ % RATES] = rate * busy
        }

        /**
         * One connection cannot keep up with the film (or only just): a segment fetched on one connection would
         * arrive slower than it plays.
         */
        internal val slowPerConnection: Boolean get() = connectionRate > 0 && bytesPerMs > 0 && connectionRate < SLOW * bytesPerMs

        /**
         * Whether several connections bring more than one does. They do when the source is slow per connection, and
         * do not when the line itself is the limit: then requests side by side only take from each other, and what
         * is needed first should be fetched alone. Null until both have been seen.
         *
         * It leans towards yes — the slowest of the recent "alone" against the best of the recent "together" — because
         * being wrong the other way costs more: a source that is slow per connection fetched on one connection.
         */
        internal val parallelHelps: Boolean? @Synchronized get() {
            if (aloneSeen == 0 || togetherSeen == 0) return null
            val one = (0 until minOf(aloneSeen, RATES)).minOf { alone[it] }
            val several = (0 until minOf(togetherSeen, RATES)).maxOf { together[it] }
            return several >= PARALLEL_GAIN * one
        }

        internal fun segmentAt(place: Int): Resource = resources[segments[place]]
    }

    /** What a player's request for a file gets. */
    sealed class Answer {
        /** The whole file is in the store. */
        class Stored(val file: File, val type: String) : Answer()

        /** The file is on its way; [copyTo] hands on what there is and waits for the rest. [close] when done with it. */
        class Arriving internal constructor(private val cache: StreamCache, private val download: Download, val type: String) : Answer() {
            /** The size, when the source has said it; -1 otherwise. */
            val length: Long get() = download.progress.value.total

            /** Writes bytes [from, to) of the file ([to] -1: to its end) as they arrive. Fails when the download does. */
            suspend fun copyTo(from: Long, to: Long, write: suspend (ByteArray, Int) -> Unit) = cache.tail(download, from, to, write)

            private val closed = java.util.concurrent.atomic.AtomicBoolean()

            /** Once is enough; more does no harm. */
            fun close() {
                if (closed.compareAndSet(false, true)) cache.release(download)
            }
        }

        /** The engine could not get it: ask the source yourself. */
        class Redirect(val url: String) : Answer()

        class Failed(val status: Int, val message: String) : Answer()
    }

    /** Cached parts of a film, for a seek bar: [ranges] are `[startMs, endMs]` pairs in order. */
    class Coverage(val durationMs: Long, val ranges: List<LongArray>)

    // ---- playlists ----

    /**
     * The media playlist [text] of [source] (already cleaned; relative addresses resolve against [baseUrl]) for a
     * player that reaches this cache under [base], e.g. `http://127.0.0.1:9978/hls/`. Null when the playlist is live,
     * the cache is off, or the source has refused the engine lately: the caller hands out [text] as it is.
     */
    fun playlist(source: String, baseUrl: String, text: String, headers: Map<String, String>, key: String?, userAgent: String?, base: String): String? {
        if (!enabled) return null
        val rewritten = HlsRewriter.rewrite(text, baseUrl) ?: return null
        val stream = HlsRewriter.sha1(if (key != null) "$key|${HlsRewriter.path(source)}" else source).take(20)
        val id = stream + "-" + rewritten.fingerprint.take(8)
        synchronized(lock) {
            if (now() - (bypassedAt[stream] ?: 0) < BYPASS_MS) return null
            val known = sessions[id]
            if (known != null) {
                // The same files, perhaps under new addresses (tokens that expire) and headers.
                known.resources = rewritten.resources
                known.headers = headers
                if (userAgent != null) known.userAgent = userAgent
            } else {
                sessions[id] = Session(id, stream, key, rewritten.resources, headers, userAgent)
                while (sessions.size > MAX_SESSIONS) sessions.remove(sessions.keys.first())
            }
        }
        // For an engine that is started again while a player still holds this playlist.
        runCatching { store.writeNote(stream, NOTE, json.encodeToString(Note.serializer(), Note(id, key, headers, userAgent, rewritten.resources.map(::noted)))) }
        return rewritten.render("$base$id/")
    }

    /** The playlist handed out under [id]: from memory, or from the note in the store that an earlier run left. */
    internal fun session(id: String): Session? {
        synchronized(lock) { sessions[id] }?.let { return it }
        val note = runCatching { store.readNote(id.substringBefore('-'), NOTE)?.let { json.decodeFromString(Note.serializer(), it) } }.getOrNull() ?: return null
        if (note.id != id) return null
        val restored = Session(id, id.substringBefore('-'), note.key, note.resources.map(::resource), note.headers, note.userAgent)
        return synchronized(lock) { sessions.getOrPut(id) { restored } }
    }

    // ---- what players ask for ----

    /** A player asks for file [number] of playlist [sessionId]. [userAgent] is the player's own, used when the playlist's headers name none. */
    suspend fun open(sessionId: String, number: Int, userAgent: String? = null): Answer {
        val s = session(sessionId) ?: return Answer.Failed(404, "no such playlist; open the video again")
        val r = s.resources.getOrNull(number) ?: return Answer.Failed(404, "no such file in the playlist")
        if (userAgent != null && s.userAgent == null) s.userAgent = userAgent
        val place = s.place[number]
        if (place >= 0) asked(s, place)
        val path = path(s, r)
        var joined: Download? = null
        var first = false
        var waited = false
        while (joined == null) {
            store.file(s.stream, r.name)?.let {
                pump(s)
                return Answer.Stored(it, typeOf(r, null))
            }
            val leaving: Download? = synchronized(lock) {
                if (s.bypass || !enabled || now() - (refusedAt[path] ?: 0) < REFUSED_MS) return fallback(r)
                val known = downloads[path]
                if (known != null && known.cancelled) {
                    known
                } else {
                    joined = (known ?: Download(s, number, r, store.partFile(s.stream, r.name)).also { downloads[path] = it }).also { it.readers++ }
                    first = !s.proven
                    null
                }
            }
            if (leaving == null) break
            // The download of this file was given up a moment ago and is still letting go of it: a new one begins
            // when it has. (Joining it would hand the player a download that is about to fail.)
            if (waited) return fallback(r)
            waited = true
            withTimeoutOrNull(LEAVING_MS) { leaving.progress.first { it.done || it.error != null } }
            synchronized(lock) { settle(leaving) }
        }
        val download = joined ?: return fallback(r)
        pump(s)
        if (first) {
            // Nothing has come from this source yet: hear what it says before promising the player anything.
            val p = try {
                withTimeoutOrNull(FIRST_ANSWER_MS) { download.progress.first { it.answered || it.done || it.error != null } }
            } catch (e: Throwable) {
                // The player went away while it waited.
                release(download)
                throw e
            }
            if (p?.error != null) {
                release(download)
                return fallback(r)
            }
        }
        return Answer.Arriving(this, download, typeOf(r, download.progress.value.type))
    }

    private fun fallback(r: Resource): Answer =
        // A player sent to the source would ask for the whole file, not the range the playlist meant.
        if (r.start >= 0) Answer.Failed(502, "the source did not answer") else Answer.Redirect(r.url)

    /** Notes where the player is; a request that is not the segment after the last one is a jump. */
    private fun asked(s: Session, place: Int) {
        val t = now()
        synchronized(lock) {
            val sequential = s.head >= 0 && (place == s.head || place == s.head + 1)
            if (sequential) {
                if (place > s.head) {
                    s.head = place
                    s.steps++
                }
            } else {
                s.head = place
                s.steps = 0
                s.jumpTo = place
                s.jumpAt = t
                s.waitedFor = null
                // What was being fetched for the place the player left is given up, unless it is nearly there or
                // will be wanted here too.
                var end = place
                var ahead = 0L
                while (end + 1 < s.segments.size && ahead < aheadMs) ahead += s.segmentAt(++end).durationMs.coerceAtLeast(1)
                for (d in downloads.values.toList()) {
                    val at = s.place.getOrElse(d.number) { -1 }
                    if (d.session.stream != s.stream || d.readers > 0 || d.finished || at < 0 || at in place..end) continue
                    if (!halfThere(d)) giveUp(d)
                }
            }
            s.askedAt = t
        }
    }

    /** Starts what should run now: what players wait for, then the read-ahead, within [connections]. */
    private fun pump(s: Session) {
        if (!enabled) return
        val starting = ArrayList<Download>()
        var again = 0L
        synchronized(lock) {
            // A finished file that could not be given its name when it finished (see settle) gets another try.
            for (d in downloads.values.filter { it.session.stream == s.stream && it.finished && it.readers == 0 }) settle(d)
            val mine = downloads.values.filter { it.session.stream == s.stream }
            val target = if (s.jumpTo >= 0) downloads[path(s, s.segmentAt(s.jumpTo))] else null
            val held = target != null && !target.finished && now() - s.jumpAt < GATE_MS
            // How what a player waits for is fetched depends on what the source is like (see Session):
            // - several connections bring more than one (or nothing is known yet): the segment jumped to is fetched
            //   in pieces over all the connections. The segments the player wants next are fetched whole and side
            //   by side when one connection keeps up with the film — that brings most, and in a steady flow, which
            //   matters because a player acts on a seek only when the read it is waiting in returns. When one
            //   connection does not keep up they come one at a time, in playing order, each in pieces.
            // - several connections bring no more than one (the line is the limit): everything the player waits
            //   for comes one at a time, in playing order, each on one connection and with the line to itself.
            val pieces = s.ranges != false && s.parallelHelps != false
            val inOrder = s.parallelHelps == false || (s.ranges != false && s.slowPerConnection)
            var urgent = mine.any { it.started && !it.finished && it.alone }
            for (d in mine.filter { !it.started && it.readers > 0 }.sortedBy { it.number }) {
                val segment = d.resource.kind == Kind.SEGMENT
                // While a player waits for the segment it jumped to, only that segment (and keys, maps) is fetched;
                // and that segment waits for nothing.
                if (segment && d !== target && (held || (inOrder && urgent))) continue
                d.alone = segment && (d === target || inOrder)
                d.fanOut = d.alone && pieces
                d.started = true
                starting += d
                if (d.alone) {
                    urgent = true
                    s.waitedFor = d
                    s.waitedSince = now()
                }
            }
            if (held) {
                again = s.jumpAt + GATE_MS - now()
            } else if (inOrder && urgent) {
                // The line is the player's for the moment; reading ahead carries on when it has its segment.
            } else if (s.head >= 0 && !s.bypass) {
                // Reading ahead begins when the player has gone on from one segment to the next twice, and reaches
                // further the longer it goes on: a player that only looks at the start of a stream — every quality
                // of a master playlist is looked at like that — does not set off minutes of downloads.
                val reach = if (s.steps < 2) 0 else minOf(aheadMs, AHEAD_STEP_MS * s.steps)
                var running = mine.count { it.started && !it.finished }
                var ahead = 0L
                var place = s.head + 1
                while (place < s.segments.size && ahead < reach && place - s.head <= FAR_AHEAD && running < connections) {
                    val r = s.segmentAt(place)
                    ahead += r.durationMs.coerceAtLeast(1)
                    val path = path(s, r)
                    val known = downloads[path]
                    if (known != null) {
                        if (!known.started) {
                            known.started = true
                            starting += known
                            running++
                        }
                    } else if (!store.has(s.stream, r.name) && now() - (refusedAt[path] ?: 0) >= REFUSED_MS) {
                        val d = Download(s, s.segments[place], r, store.partFile(s.stream, r.name))
                        d.started = true
                        downloads[path] = d
                        starting += d
                        running++
                    }
                    place++
                }
            }
        }
        for (d in starting) scope.launch { run(d) }
        if (again > 0) scope.launch {
            delay(again + 10)
            pump(s)
        }
    }

    // ---- fetching ----

    internal class Progress(
        /** Bytes there are from the start of the file without a gap. */
        val written: Long = 0,
        val total: Long = -1,
        val type: String? = null,
        /** The source has answered (well). */
        val answered: Boolean = false,
        val done: Boolean = false,
        val error: String? = null,
    ) {
        fun copy(written: Long = this.written, total: Long = this.total, type: String? = this.type, answered: Boolean = this.answered, done: Boolean = this.done, error: String? = this.error) =
            Progress(written, total, type, answered, done, error)
    }

    internal class Download(val session: Session, val number: Int, val resource: Resource, val part: File) {
        val progress = MutableStateFlow(Progress())

        /** Guarded by the cache's lock. */
        var readers = 0
        var started = false

        /** A player waits for it: while it is under way the stream's other downloads make way. */
        @Volatile var alone = false

        /** Fetch it in pieces over several connections. */
        @Volatile var fanOut = false
        @Volatile var cancelled = false
        val calls = CopyOnWriteArrayList<Call>()
        val finished: Boolean get() = progress.value.let { it.done || it.error != null }

        fun cancel() {
            cancelled = true
            calls.forEach { it.cancel() }
        }
    }

    /** A stretch [from, to) of a file that one request fetches; [to] -1 is "to the end, wherever that is". */
    private class Piece(val from: Long, @Volatile var to: Long) {
        @Volatile var received = 0L
        val complete: Boolean get() = to >= 0 && from + received >= to
    }

    /** The source will not give the file (or gave something else): asking again is no use. */
    private class Refused(val code: Int, message: String = "HTTP $code") : IOException(message)

    /** The start of a web page or of JSON: `<!DOCTYPE`, `<html`, `<?xml`, `{"`. Video, audio and keys do not start like this. */
    private fun looksLikeText(bytes: ByteArray, length: Int): Boolean {
        var i = 0
        if (length >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) i = 3
        while (i < length && (bytes[i] == ' '.code.toByte() || bytes[i] == '\n'.code.toByte() || bytes[i] == '\r'.code.toByte() || bytes[i] == '\t'.code.toByte())) i++
        val head = String(bytes, i, minOf(length - i, 9), Charsets.ISO_8859_1).lowercase()
        return head.startsWith("<!doctype") || head.startsWith("<html") || head.startsWith("<?xml") || head.startsWith("<head") || head.startsWith("<body") || head.startsWith("{\"")
    }

    private suspend fun run(d: Download) {
        val s = d.session
        val r = d.resource
        var failure: String? = null
        var refused = false
        try {
            withContext(Dispatchers.IO) {
                RandomAccessFile(d.part, "rw").use { file ->
                    file.setLength(0)
                    val pieces = CopyOnWriteArrayList<Piece>()
                    val fetch = Fetch(d, file.channel, pieces)
                    // How big the file is: said by the playlist (a byte range), or guessed from the segments before.
                    val exact = r.length >= 0
                    val size = if (exact) r.length else if (r.kind == Kind.SEGMENT) (s.bytesPerMs * r.durationMs).toLong() else 0L
                    if (!d.fanOut || s.ranges == false || (exact && size <= SMALL)) {
                        pieces += Piece(0, r.length)
                        fetch.piece(pieces[0])
                    } else if (s.ranges == true && size > SMALL) {
                        // The source takes ranges and the size is known near enough: all the pieces at once. The last
                        // one runs to the end of the file, wherever that turns out to be.
                        val n = pieceCount(size)
                        for (i in 0 until n) pieces += Piece(i * (size / n), if (i < n - 1) (i + 1) * (size / n) else if (exact) size else -1)
                        coroutineScope { for (p in pieces) launch { fetch.piece(p) } }
                    } else {
                        // Nothing is known: the start first, alone. Its answer says how long the file is and whether
                        // ranges work, and how fast it comes says what one connection brings by itself; then the
                        // rest, in pieces side by side when that can be done (which says what several bring).
                        val head = Piece(0, if (exact) minOf(PROBE, size) else PROBE)
                        pieces += head
                        fetch.piece(head)
                        val total = d.progress.value.total
                        if (fetch.ended || total in 0..head.to) {
                            // The file ended inside the first piece, or the source sent all of it regardless.
                        } else if (total < 0 || s.ranges != true || s.parallelHelps == false) {
                            pieces += Piece(head.to, total)
                            fetch.piece(pieces[1])
                        } else {
                            val n = pieceCount(total - head.to)
                            val each = (total - head.to + n - 1) / n
                            for (i in 0 until n) pieces += Piece(head.to + i * each, minOf(total, head.to + (i + 1) * each))
                            coroutineScope { for (p in pieces.drop(1)) launch { fetch.piece(p) } }
                        }
                    }
                    val p = d.progress.value
                    if (p.total >= 0 && p.written < p.total) throw IOException("the source sent ${p.written} of ${p.total} bytes")
                    // An AES-128 key is sixteen bytes; anything else under a key's address is an error in disguise.
                    if (r.kind == Kind.KEY && p.written != 16L) throw Refused(200, "the source sent ${p.written} bytes for a key")
                    if (r.kind == Kind.SEGMENT && !exact && r.durationMs > 0 && p.written > 0) s.learn(p.written.toDouble() / r.durationMs)
                }
            }
        } catch (e: Refused) {
            failure = e.message
            refused = true
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            failure = if (d.cancelled) "cancelled" else e.message ?: e.javaClass.simpleName
        }
        if (failure == null) {
            d.progress.update { it.copy(total = it.written, done = true) }
        } else {
            d.progress.update { it.copy(error = failure) }
            if (!d.cancelled) log("stream cache: ${r.url.substringBefore('?')}: $failure")
        }
        synchronized(lock) {
            if (failure != null && !d.cancelled) {
                refusedAt[path(s, r)] = now()
                if (!s.proven && ++s.refusals >= 2) {
                    // The source answers players but not the engine (it may tell them apart): leave this stream alone.
                    s.bypass = true
                    bypassedAt[s.stream] = now()
                }
            }
            settle(d)
        }
        // Also after a download that was given up: its connection is free for what is wanted now.
        pump(s)
    }

    /** The requests of one download: each [piece] is fetched, written where it belongs and tried again when the connection drops. */
    private inner class Fetch(val d: Download, val channel: FileChannel, val pieces: List<Piece>) {
        /** Where the resource begins in the source's file. */
        private val base = if (d.resource.start >= 0) d.resource.start else 0L

        /** The end of the file has been seen (by the piece that reached it). */
        @Volatile var ended = false

        /** One piece gave up: the others stop too. */
        @Volatile private var failed = false

        init {
            if (d.resource.length >= 0) d.progress.update { it.copy(total = d.resource.length) }
        }

        fun piece(p: Piece) {
            try {
                fetch(p)
            } catch (e: Throwable) {
                failed = true
                d.calls.forEach { it.cancel() }
                throw e
            }
        }

        private fun fetch(p: Piece) {
            // Broken connections in a row that brought nothing, and broken connections in all: a source that drops
            // the line now and then but keeps delivering is worth more patience than one that delivers nothing.
            var barren = 0
            var broken = 0
            while (!p.complete) {
                if (d.cancelled || failed) throw IOException("cancelled")
                val at = p.from + p.received
                // A whole file from its start needs no range; everything else asks for its bytes.
                val ranged = base + at > 0 || p.to >= 0
                val request = Request.Builder().url(d.resource.url).apply {
                    d.session.headers.forEach { (k, v) -> runCatching { header(k, v) } }
                    if (d.session.headers.keys.none { it.equals("User-Agent", true) }) d.session.userAgent?.let { ua -> runCatching { header("User-Agent", ua) } }
                    if (ranged) header("Range", "bytes=${base + at}-" + if (p.to >= 0) "${base + p.to - 1}" else "")
                }.build()
                val call = http.newCall(request)
                d.calls += call
                try {
                    call.execute().use { response ->
                        when {
                            // Asked for bytes past the end: the file is shorter than was thought.
                            response.code == 416 -> {
                                p.to = at
                                ended = true
                            }
                            !response.isSuccessful -> throw Refused(response.code)
                            else -> receive(p, at, ranged, response)
                        }
                    }
                } catch (e: Refused) {
                    throw e
                } catch (e: IOException) {
                    barren = if (p.from + p.received > at) 0 else barren + 1
                    if (d.cancelled || failed || barren > RETRIES || ++broken > MAX_BREAKS) throw e
                } finally {
                    d.calls -= call
                }
            }
        }

        /** Writes the body where it belongs in the file. */
        private fun receive(p: Piece, at: Long, ranged: Boolean, response: Response) {
            val body = response.body ?: throw IOException("the source sent nothing")
            val partial = response.code == 206
            // "bytes 0-262143/1550812": the size of the source's file.
            val whole = if (partial) response.header("Content-Range")?.substringAfterLast('/')?.trim()?.toLongOrNull() else body.contentLength().takeIf { it >= 0 }
            // A source that ignores ranges sends its file from the first byte: what comes before ours is thrown away,
            // and when ours is the start, the rest is taken while it is there.
            val skip = if (partial) 0L else base + at
            val s = d.session
            if (partial) {
                s.ranges = true
            } else if (ranged) {
                // (A whole file in answer to a range that lies past its end says nothing about ranges.)
                if (whole == null || base + at < whole) s.ranges = false
                if (skip == 0L && d.resource.length < 0) p.to = -1
            } else if (s.ranges == null && response.header("Accept-Ranges").equals("bytes", ignoreCase = true)) {
                s.ranges = true
            }
            d.progress.update {
                it.copy(
                    total = if (it.total < 0 && whole != null && d.resource.length < 0) whole - base else it.total,
                    type = it.type ?: response.header("Content-Type"),
                )
            }
            val began = System.nanoTime()
            // How many answers were being read while this one was, on average: for telling what one connection
            // brings alone from what several bring together.
            var busy = 0L
            var reads = 0
            var stood = false
            val position: Long
            s.receiving.incrementAndGet()
            try {
                position = copy(p, at, body.byteStream(), ByteArray(64 * 1024), skipFirst = skip, response = response, onRead = {
                    busy += s.receiving.get()
                    reads++
                }, onStood = { stood = true })
            } finally {
                s.receiving.decrementAndGet()
            }
            // How fast a connection to this source is, from answers big and slow enough to tell. One that stood still
            // on the way says nothing: what piled up meanwhile came in a rush afterwards.
            val ms = (System.nanoTime() - began) / 1e6
            if (!stood && position - at >= RATE_SAMPLE && ms >= RATE_MIN_MS && reads > 0) s.sample((position - at) / ms, busy.toDouble() / reads)
            if (p.to >= 0 && position >= p.to) return
            // The answer ended before the piece did: that is the end of the file, unless the answer was cut short.
            val expected = d.progress.value.total
            if (if (expected >= 0) position < expected else p.to >= 0) throw IOException("the source closed the connection early")
            p.to = position
            ended = true
        }

        /** Reads the answer's body into the file from [at] on; where it got to. */
        private fun copy(p: Piece, at: Long, input: java.io.InputStream, buffer: ByteArray, skipFirst: Long, response: Response, onRead: () -> Unit, onStood: () -> Unit): Long {
            val s = d.session
            var skip = skipFirst
            var position = at
            while (p.to < 0 || position < p.to) {
                // While a player waits for another segment, this one stands still: the source stops sending when
                // nobody reads, and the line is the waited-for segment's alone.
                if (standsStill(d)) {
                    s.receiving.decrementAndGet()
                    try {
                        while (standsStill(d) && !d.cancelled && !failed) Thread.sleep(20)
                    } finally {
                        s.receiving.incrementAndGet()
                    }
                    onStood()
                }
                val n = input.read(buffer)
                if (n < 0) break
                onRead()
                if (d.cancelled) throw IOException("cancelled")
                // A page saying "expired" or "forbidden" with status 200 is not video, and must not be kept as if it were.
                if (position == 0L && skip == 0L && looksLikeText(buffer, n)) throw Refused(response.code, "the source sent a page instead of the file")
                var offset = 0
                var length = n
                if (skip > 0) {
                    val dropped = minOf(skip, length.toLong()).toInt()
                    skip -= dropped
                    offset += dropped
                    length -= dropped
                }
                if (p.to >= 0) length = minOf(length.toLong(), p.to - position).toInt()
                if (length <= 0) continue
                val bytes = ByteBuffer.wrap(buffer, offset, length)
                var written = position
                while (bytes.hasRemaining()) written += channel.write(bytes, written)
                position += length
                p.received = position - p.from
                advance()
            }
            return position
        }

        /**
         * How far the file reaches without a gap, for those who read it while it arrives. The first bytes are also
         * what shows that the source does give the engine this stream.
         */
        private fun advance() {
            var reached = 0L
            for (p in pieces.sortedBy { it.from }) {
                if (p.from != reached) break
                reached += p.received
                if (!p.complete) break
            }
            d.session.proven = true
            d.progress.update { if (reached > it.written || !it.answered) it.copy(written = maxOf(reached, it.written), answered = true) else it }
        }
    }

    /** Whether [d] should hold still for now: another segment of its stream is what a player is waiting for. */
    private fun standsStill(d: Download): Boolean {
        val s = d.session
        val waited = s.waitedFor ?: return false
        return waited !== d && !d.alone && d.resource.kind == Kind.SEGMENT && !waited.finished && now() - s.waitedSince < GATE_MS
    }

    /** Caller holds [lock]. A finished download becomes a stored file once nobody reads its `.part` any more; a failed one goes. */
    private fun settle(d: Download) {
        if (!d.finished || d.readers > 0) return
        val path = path(d.session, d.resource)
        if (downloads[path] !== d) return
        if (d.progress.value.done) {
            // Windows will not rename a file someone still has open; then it stays a download until they are done.
            if (store.commit(d.session.stream, d.resource.name)) downloads.remove(path)
        } else {
            store.discard(d.session.stream, d.resource.name)
            downloads.remove(path)
        }
    }

    internal fun release(d: Download) {
        synchronized(lock) {
            d.readers--
            // A player that lets go of a segment in a stream it has only looked at (see pump) is not coming back for
            // it: every quality of a master playlist is opened like that before one is chosen. In a stream that is
            // being watched the download goes on — the player's next jump sorts out what is still wanted (see asked).
            if (d.readers == 0 && !d.finished && d.session.steps < 2 && d.resource.kind == Kind.SEGMENT && !halfThere(d)) giveUp(d)
            settle(d)
        }
    }

    private fun halfThere(d: Download): Boolean = d.progress.value.let { it.total > 0 && it.written >= it.total / 2 }

    /**
     * Caller holds [lock]. Stops a download nobody reads. One that is under way ends by itself in a moment and is
     * forgotten then (see run and settle); one that had not begun is forgotten here, or the next player to ask for
     * the file would be handed a download that fails as soon as it starts.
     */
    private fun giveUp(d: Download) {
        d.cancel()
        if (d.started) return
        val path = path(d.session, d.resource)
        if (downloads[path] === d) downloads.remove(path)
    }

    internal suspend fun tail(d: Download, from: Long, to: Long, write: suspend (ByteArray, Int) -> Unit) = withContext(Dispatchers.IO) {
        var file: RandomAccessFile? = null
        try {
            val buffer = ByteArray(64 * 1024)
            var position = from
            while (to < 0 || position < to) {
                val p = d.progress.value
                val limit = if (to < 0) p.written else minOf(p.written, to)
                if (position < limit) {
                    val f = file ?: openForReading(d).also { file = it }
                    f.seek(position)
                    val n = f.read(buffer, 0, minOf(buffer.size.toLong(), limit - position).toInt())
                    if (n <= 0) throw IOException("the cached file is shorter than it should be")
                    write(buffer, n)
                    position += n
                } else if (p.error != null) {
                    throw IOException("the source failed: ${p.error}")
                } else if (p.done) {
                    break
                } else {
                    d.progress.first { it.written > position || it.done || it.error != null }
                }
            }
        } finally {
            runCatching { file?.close() }
        }
    }

    /**
     * The download's file while it is one, else the stored file it has become (a reader that let go of the download
     * before reading it finds it there: same bytes, another name).
     */
    private fun openForReading(d: Download): RandomAccessFile = try {
        RandomAccessFile(d.part, "r")
    } catch (e: java.io.FileNotFoundException) {
        RandomAccessFile(store.file(d.session.stream, d.resource.name) ?: throw e, "r")
    }

    // ---- looking at it ----

    /** Which parts of the film that `/play/resolve` called [key] are in the store. Null when no player has its playlist. */
    fun coverage(key: String): Coverage? {
        val s = synchronized(lock) { sessions.values.filter { it.key == key }.maxByOrNull { it.askedAt } } ?: return null
        val names = store.names(s.stream)
        val ranges = ArrayList<LongArray>()
        var total = 0L
        for (number in s.segments) {
            val r = s.resources[number]
            total = maxOf(total, r.startMs + r.durationMs)
            if (r.name !in names) continue
            val last = ranges.lastOrNull()
            if (last != null && last[1] >= r.startMs) last[1] = r.startMs + r.durationMs else ranges += longArrayOf(r.startMs, r.startMs + r.durationMs)
        }
        return Coverage(total, ranges)
    }

    /** Stops every download and waits until their files are closed. The cache is of no use afterwards. */
    fun close() {
        enabled = false
        synchronized(lock) { downloads.values.forEach { it.cancel() } }
        val job = scope.coroutineContext[Job]!!
        // A download whose request was cancelled is over as soon as it has closed its file.
        runBlocking {
            job.children.toList().forEach {
                it.cancel()
                it.join()
            }
        }
        job.cancel()
    }

    /** Whether file [number] of a playlist is in the store, without counting as a request for it. */
    fun isStored(sessionId: String, number: Int): Boolean {
        val s = session(sessionId) ?: return false
        return s.resources.getOrNull(number)?.let { store.has(s.stream, it.name) } == true
    }

    /** How many bytes of file [number] of a playlist are there, from its start without a gap: stored, or arrived so far. */
    fun arrived(sessionId: String, number: Int): Long {
        val s = session(sessionId) ?: return 0
        val r = s.resources.getOrNull(number) ?: return 0
        synchronized(lock) { downloads[path(s, r)] }?.let { return it.progress.value.written }
        return store.file(s.stream, r.name)?.length() ?: 0
    }

    /** Empties the store (see [StreamStore.clear]); what players are being sent right now stays until they are done. */
    fun clear(): Long {
        val busy = synchronized(lock) { downloads.values.map { it.session.stream to it.resource.name }.toSet() }
        return store.clear { stream, name -> (stream to name) in busy }
    }

    private fun path(s: Session, r: Resource) = s.stream + "/" + r.name

    /** Into how many pieces a file of [size] bytes that a player waits for is split. */
    private fun pieceCount(size: Long): Int = minOf(connections.toLong(), size / PIECE_MIN).toInt().coerceAtLeast(1)

    private fun typeOf(r: Resource, fromSource: String?): String = when {
        r.kind == Kind.KEY -> "application/octet-stream"
        fromSource != null && !fromSource.startsWith("text/") -> fromSource
        r.ext == "ts" -> "video/mp2t"
        r.ext == "m4s" || r.ext == "mp4" || r.ext == "m4v" -> "video/mp4"
        r.ext == "aac" -> "audio/aac"
        r.ext == "vtt" || r.ext == "webvtt" -> "text/vtt"
        else -> "application/octet-stream"
    }

    @Serializable
    private class Note(val id: String, val key: String? = null, val headers: Map<String, String> = emptyMap(), val userAgent: String? = null, val resources: List<NotedResource>)

    @Serializable
    private class NotedResource(val k: String, val u: String, val s: Long = -1, val l: Long = -1, val t: Long = 0, val d: Long = 0, val n: String, val e: String)

    private fun noted(r: Resource) = NotedResource(r.kind.name, r.url, r.start, r.length, r.startMs, r.durationMs, r.name, r.ext)

    private fun resource(n: NotedResource) = Resource(Kind.valueOf(n.k), n.u, n.s, n.l, n.t, n.d, n.n, n.e)

    private companion object {
        val json = Json { ignoreUnknownKeys = true }
        const val NOTE = "playlist.json"
        const val MAX_SESSIONS = 24

        /** How long at most a segment a player waits for has the source to itself. */
        const val GATE_MS = 6_000L

        /** How long the first request to a source may take before the player is answered anyway. */
        const val FIRST_ANSWER_MS = 12_000L

        /** How long a player's request waits for a download that was just given up to let go of its file. */
        const val LEAVING_MS = 3_000L

        /** A file the source refused is not asked for again for this long; a stream that refuses the engine is left to players. */
        const val REFUSED_MS = 60_000L
        const val BYPASS_MS = 10 * 60_000L

        /**
         * A request whose connection breaks is made again, carrying on where it stopped: up to [RETRIES] times in a
         * row when nothing came of it, and [MAX_BREAKS] times in all for one stretch of a file.
         */
        const val RETRIES = 2
        const val MAX_BREAKS = 12

        /** Read-ahead never goes further than this many segments. */
        const val FAR_AHEAD = 600

        /** Read-ahead reaches this much further for every segment the player goes on to, up to `aheadMs`. */
        const val AHEAD_STEP_MS = 15_000L

        /** A file a player waits for: the first request takes this much, the rest is split into pieces no smaller than [PIECE_MIN]. */
        const val PROBE = 256L * 1024
        const val PIECE_MIN = 192L * 1024

        /** Too small to be worth splitting. */
        const val SMALL = 384L * 1024

        /** A connection that brings less than this many times what the film takes is too slow to fetch segments whole while a player waits. */
        const val SLOW = 1.5

        /** Answers of at least this many bytes that took at least this long say how fast a connection is. */
        const val RATE_SAMPLE = 128L * 1024
        const val RATE_MIN_MS = 50.0

        /** Several connections "bring more" than one when together they bring at least this many times as much. */
        const val PARALLEL_GAIN = 1.4

        /** How many of the latest speed samples of each kind are kept. */
        const val RATES = 3
    }
}
