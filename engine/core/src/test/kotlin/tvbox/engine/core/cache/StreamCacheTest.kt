package tvbox.engine.core.cache

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.cache.StreamCache.Answer
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class StreamCacheTest {
    @TempDir
    lateinit var dir: File

    private val server = MockWebServer()
    private val origin = Origin()
    private lateinit var cache: StreamCache

    /** A source of segments `/v/<name>`: every file has its own bytes, and it notes what it is asked. */
    private class Origin : Dispatcher() {
        val asked = CopyOnWriteArrayList<RecordedRequest>()
        @Volatile var size = 50_000
        @Volatile var takesRanges = true
        @Volatile var refuse = false

        /** Answers every request with a web page and status 200, as sites do for expired or foreign visitors. */
        @Volatile var page = false

        /** Bytes per 20 ms; 0 sends at once. */
        @Volatile var trickle = 0L

        /** Requests that are cut off after half the body, counted down. */
        val cuts = AtomicInteger()

        /** A file whose answers are a long time coming, and how long (ms). */
        @Volatile var late: Pair<String, Long>? = null

        fun bytes(name: String): ByteArray = ByteArray(size) { i -> (name.hashCode() + i * 31 + i / 251).toByte() }

        fun paths(): List<String> = asked.map { it.requestUrl!!.encodedPath.substringAfterLast('/') }

        fun of(name: String): List<RecordedRequest> = asked.filter { it.requestUrl!!.encodedPath.endsWith("/$name") }

        override fun dispatch(request: RecordedRequest): MockResponse {
            asked += request
            if (refuse) return MockResponse().setResponseCode(403)
            if (page) return MockResponse().setHeader("Content-Type", "text/html").setBody("\n<!DOCTYPE html><html><body>链接已过期</body></html>")
            val all = bytes(request.requestUrl!!.encodedPath.substringAfterLast('/'))
            val range = if (takesRanges) request.getHeader("Range")?.let { Regex("bytes=(\\d+)-(\\d*)").find(it) } else null
            val response = if (range != null) {
                val from = range.groupValues[1].toInt()
                if (from >= all.size) return MockResponse().setResponseCode(416).setHeader("Content-Range", "bytes */${all.size}")
                val to = minOf(range.groupValues[2].toIntOrNull() ?: (all.size - 1), all.size - 1)
                MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes $from-$to/${all.size}").setBody(Buffer().write(all, from, to - from + 1))
            } else {
                MockResponse().setHeader("Accept-Ranges", "bytes").setBody(Buffer().write(all))
            }
            if (trickle > 0) response.throttleBody(trickle, 20, TimeUnit.MILLISECONDS)
            late?.let { (name, ms) -> if (request.requestUrl!!.encodedPath.endsWith("/$name")) response.setHeadersDelay(ms, TimeUnit.MILLISECONDS) }
            if (cuts.getAndUpdate { if (it > 0) it - 1 else 0 } > 0) response.socketPolicy = SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY
            return response
        }
    }

    @BeforeEach
    fun start() {
        server.dispatcher = origin
        server.start()
        cache = StreamCache(OkHttpClient(), StreamStore(File(dir, "stream")))
    }

    @AfterEach
    fun stop() {
        // Downloads still under way hold files open, which the temporary folder could then not be deleted with.
        cache.close()
        server.shutdown()
    }

    private val source get() = server.url("/v/index.m3u8").toString()

    private fun text(count: Int, seconds: Int = 4, line: (Int) -> String = { "seg$it.ts" }) = buildString {
        append("#EXTM3U\n#EXT-X-TARGETDURATION:$seconds\n")
        repeat(count) { append("#EXTINF:$seconds.0,\n${line(it)}\n") }
        append("#EXT-X-ENDLIST\n")
    }

    /** Hands the playlist to the cache as the engine does; the session's id. */
    private fun open(text: String, key: String? = "k1", headers: Map<String, String> = emptyMap(), agent: String? = null, on: StreamCache = cache): String {
        val rewritten = on.playlist(source, source, text, headers, key, agent, "http://engine/hls/")
        assertNotNull(rewritten, "the playlist is taken into the cache")
        return Regex("http://engine/hls/([^/]+)/").find(rewritten!!)!!.groupValues[1]
    }

    private suspend fun read(answer: Answer, from: Long = 0, to: Long = -1): ByteArray = when (answer) {
        is Answer.Stored -> answer.file.readBytes().let { if (to < 0) it.copyOfRange(from.toInt(), it.size) else it.copyOfRange(from.toInt(), to.toInt()) }
        is Answer.Arriving -> {
            val out = ByteArrayOutputStream()
            try {
                answer.copyTo(from, to) { bytes, n -> out.write(bytes, 0, n) }
            } finally {
                answer.close()
            }
            out.toByteArray()
        }
        else -> throw AssertionError("no file: $answer")
    }

    private suspend fun eventually(what: String, check: () -> Boolean) {
        withTimeout(10_000) {
            while (!check()) delay(20)
        }
        assertTrue(check(), what)
    }

    private fun stored(session: String, vararg numbers: Int): Boolean = numbers.all { cache.isStored(session, it) }

    /** Asks for a file only to see what kind of answer comes. */
    private suspend fun answer(session: String, number: Int, on: StreamCache = cache): Answer = on.open(session, number).also { if (it is Answer.Arriving) it.close() }

    /** Reads the segments [from]..[to] one after the other, as a player that is watching does. */
    private suspend fun watch(session: String, from: Int, to: Int) {
        for (number in from..to) read(cache.open(session, number))
    }

    @Test
    fun `a segment is fetched once, handed on while it arrives, and served from the store afterwards`() = runBlocking {
        cache.aheadMs = 0
        val id = open(text(3))
        val first = cache.open(id, 0)
        assertTrue(first is Answer.Arriving)
        assertEquals(origin.size.toLong(), (first as Answer.Arriving).length, "the first answer waits for the source and knows the size")
        assertArrayEquals(origin.bytes("seg0.ts"), read(first))

        eventually("the finished download becomes a stored file") { stored(id, 0) }
        val again = cache.open(id, 0)
        assertEquals("video/mp2t", (again as Answer.Stored).type)
        assertArrayEquals(origin.bytes("seg0.ts"), read(again))
        assertEquals(1, origin.of("seg0.ts").size, "asked for once")
        assertEquals(origin.size.toLong(), cache.store.stats().bytes)
    }

    @Test
    fun `a player reads a file while it is still arriving`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 200_000
        origin.trickle = 10_000 // 200 kB take 400 ms
        val id = open(text(2))
        val answer = cache.open(id, 0) as Answer.Arriving
        val started = System.nanoTime()
        var firstBytesAt = 0L
        val out = ByteArrayOutputStream()
        answer.copyTo(0, -1) { bytes, n ->
            if (firstBytesAt == 0L) firstBytesAt = System.nanoTime()
            out.write(bytes, 0, n)
        }
        answer.close()
        val took = (System.nanoTime() - started) / 1_000_000
        assertArrayEquals(origin.bytes("seg0.ts"), out.toByteArray())
        assertTrue((firstBytesAt - started) / 1_000_000 < took / 2, "the first bytes came long before the last ($took ms in all)")
    }

    @Test
    fun `the next segments are fetched ahead, as far as the window goes and no further`() = runBlocking {
        cache.aheadMs = 12_000 // three segments of four seconds
        val id = open(text(20))
        // A look at the start of a stream, and the segment after it, set nothing off: players look at every quality
        // of a master playlist like that.
        read(cache.open(id, 0))
        read(cache.open(id, 1))
        delay(300)
        assertEquals(setOf("seg0.ts", "seg1.ts"), origin.paths().toSet())
        // Going on to a third segment is watching.
        read(cache.open(id, 2))
        eventually("three segments ahead are in the store") { stored(id, 3, 4, 5) }
        delay(300)
        assertEquals((0..5).map { "seg$it.ts" }.toSet(), origin.paths().toSet(), "nothing beyond the window")

        // The player moves on by one: the window moves with it, and what is stored is not asked for again.
        read(cache.open(id, 3))
        eventually("the window moved") { origin.paths().contains("seg6.ts") }
        delay(300)
        assertEquals((0..6).map { "seg$it.ts" }, origin.paths().sorted())
    }

    @Test
    fun `reading ahead reaches further the longer the player goes on`() = runBlocking {
        cache.aheadMs = 600_000
        val id = open(text(60))
        watch(id, 0, 2)
        // Two steps on: thirty seconds ahead, which is eight segments of four seconds.
        eventually("eight ahead") { stored(id, *(3..10).toList().toIntArray()) }
        delay(300)
        assertFalse(origin.paths().contains("seg11.ts"))
        // One more step: fifteen seconds more.
        read(cache.open(id, 3))
        eventually("further") { stored(id, 14, 15) }
        delay(300)
        assertFalse(origin.paths().contains("seg16.ts"))
    }

    @Test
    fun `a stream that is only looked at is not fetched once the player lets go of it`() = runBlocking {
        cache.aheadMs = 600_000
        origin.size = 1_000_000
        origin.trickle = 5_000 // 250 kB/s: a segment takes four seconds
        val id = open(text(20))
        // A player opens the first two segments of every quality of a master playlist, reads the start of the first…
        val first = cache.open(id, 0) as Answer.Arriving
        val second = cache.open(id, 1) as Answer.Arriving
        assertEquals(1_000, read(first, 0, 1_000).size)
        // …and lets go of the ones it did not choose.
        second.close()
        // Left alone, a quarter of each segment would have come in a second.
        delay(1_000)
        assertEquals(0, cache.arrived(id, 0) + cache.arrived(id, 1), "the downloads are given up and what had come is dropped")
        assertEquals(0, cache.store.stats().files)
        assertEquals(emptySet<String>(), origin.paths().toSet() - setOf("seg0.ts", "seg1.ts"), "and nothing is read ahead")

        // A player that comes back for it is served like any other.
        origin.trickle = 0
        assertArrayEquals(origin.bytes("seg0.ts"), read(cache.open(id, 0)))
    }

    @Test
    fun `a segment whose download was given up can be asked for again at once`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 600_000
        val id = open(text(40))
        watch(id, 0, 2)
        origin.trickle = 5_000 // 250 kB/s
        // The player jumps: it opens the segment there and the one after, whose download waits for the first.
        val target = cache.open(id, 20) as Answer.Arriving
        val next = cache.open(id, 21) as Answer.Arriving
        delay(200)
        // It jumps again before much has come, and then straight back.
        target.close()
        next.close()
        val elsewhere = cache.open(id, 30) as Answer.Arriving
        val back = cache.open(id, 20)
        val after = cache.open(id, 21)
        elsewhere.close()
        origin.trickle = 0
        assertArrayEquals(origin.bytes("seg20.ts"), read(back), "the download that was under way")
        assertArrayEquals(origin.bytes("seg21.ts"), read(after), "the download that had not begun")
    }

    @Test
    fun `a segment the player jumps to is fetched in pieces over several connections`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 1_000_000
        val id = open(text(40))
        // The first segment: nothing is known about the source yet. The start is asked for alone; its answer says
        // how long the file is, and the rest follows in pieces.
        assertArrayEquals(origin.bytes("seg0.ts"), read(cache.open(id, 0)))
        val first = origin.of("seg0.ts").map { it.getHeader("Range")!! }
        assertEquals("bytes=0-262143", first.first())
        assertEquals(setOf("bytes=0-262143", "bytes=262144-508095", "bytes=508096-754047", "bytes=754048-999999"), first.toSet())

        // Later the source is known to take ranges and how big its segments are: all the pieces at once, the last
        // one to wherever the file ends.
        assertArrayEquals(origin.bytes("seg30.ts"), read(cache.open(id, 30)))
        assertEquals(setOf("bytes=0-249999", "bytes=250000-499999", "bytes=500000-749999", "bytes=750000-"), origin.of("seg30.ts").map { it.getHeader("Range") }.toSet())
        eventually("stored") { stored(id, 30) }
        assertArrayEquals(origin.bytes("seg30.ts"), read(cache.open(id, 30)), "and the pieces were put together in the right order")

        // A segment much smaller than the others: the pieces past its end find nothing, and that is all right.
        origin.size = 300_000
        assertArrayEquals(origin.bytes("seg20.ts"), read(cache.open(id, 20)))
        // And one much bigger: the last piece carries the surplus.
        origin.size = 2_500_000
        assertArrayEquals(origin.bytes("seg10.ts"), read(cache.open(id, 10)))
    }

    @Test
    fun `a source that ignores ranges still gives the whole file, in one go`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 1_000_000
        origin.takesRanges = false
        val id = open(text(40))
        assertArrayEquals(origin.bytes("seg0.ts"), read(cache.open(id, 0)))
        assertEquals("bytes=0-262143", origin.of("seg0.ts").single().getHeader("Range"), "the answer to the first piece was the whole file, and it was taken")
        // Having learnt that, the next jump asks plainly.
        assertArrayEquals(origin.bytes("seg30.ts"), read(cache.open(id, 30)))
        assertNull(origin.of("seg30.ts").single().getHeader("Range"))
    }

    @Test
    fun `while the player waits for the segment it jumped to, nothing else is asked of the source`() = runBlocking {
        cache.aheadMs = 8_000
        origin.size = 300_000
        val id = open(text(40))
        watch(id, 0, 2)
        eventually("read-ahead done") { stored(id, 3, 4) }
        origin.asked.clear()
        origin.trickle = 15_000 // the 300 kB segment takes 400 ms
        val target = cache.open(id, 20) as Answer.Arriving
        // The player opens the next segment at once, as players do: it is answered, but its fetch has to wait.
        val next = cache.open(id, 21) as Answer.Arriving
        delay(150)
        assertEquals(setOf("seg20.ts"), origin.paths().toSet(), "only the segment that is waited for")
        assertArrayEquals(origin.bytes("seg20.ts"), read(target))
        assertArrayEquals(origin.bytes("seg21.ts"), read(next))
        // The player goes on from there: the read-ahead follows it to the new place.
        read(cache.open(id, 22))
        eventually("then the read-ahead from the new place") { stored(id, 23, 24) }
        assertFalse(origin.paths().contains("seg5.ts"), "and nothing more for the place the player left")
    }

    @Test
    fun `downloads under way stand still while the player waits for the segment it jumped to`() = runBlocking {
        cache.aheadMs = 4_000 // one segment ahead
        origin.size = 1_000_000
        val id = open(text(40))
        watch(id, 0, 2)
        eventually("the first read-ahead is done") { stored(id, 3) }
        origin.trickle = 10_000 // 500 kB/s on each connection
        // The player moves on: segment 4 is fetched ahead, which takes two seconds. It is more than half way when…
        answer(id, 3)
        eventually("segment 4 is well on its way") { cache.arrived(id, 4) >= 550_000 }
        // …the player jumps, to a segment the source takes a second to begin answering for.
        origin.late = "seg30.ts" to 1_000L
        val jumped = cache.open(id, 30) as Answer.Arriving
        delay(150)
        val before = cache.arrived(id, 4)
        delay(600)
        val after = cache.arrived(id, 4)
        assertTrue(after - before < 100_000, "segment 4 stood still while the jump was waited for (it had $before bytes, then $after)")
        assertArrayEquals(origin.bytes("seg30.ts"), read(jumped))
        eventually("and carried on afterwards") { stored(id, 4) }
        assertEquals(1, origin.of("seg4.ts").size, "on the connection it had")
    }

    @Test
    fun `when one connection is too slow for the film, the segments a player waits for come one at a time, each over all the connections`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 1_000_000 // four seconds of film: 250 kB/s
        val id = open(text(40))
        // The first segment tells that the source takes ranges and how big its segments are.
        read(cache.open(id, 0))
        origin.asked.clear()
        origin.trickle = 5_000 // 250 kB/s on each connection: no faster than the film plays
        // The player jumps, and asks for the two segments after it before the first has arrived.
        val a = cache.open(id, 20) as Answer.Arriving
        val b = cache.open(id, 21) as Answer.Arriving
        val c = cache.open(id, 22) as Answer.Arriving
        delay(200)
        assertEquals(setOf("seg20.ts"), origin.paths().toSet())
        assertEquals(4, origin.of("seg20.ts").size, "in four pieces")
        assertArrayEquals(origin.bytes("seg20.ts"), read(a))
        assertArrayEquals(origin.bytes("seg21.ts"), read(b))
        assertArrayEquals(origin.bytes("seg22.ts"), read(c))
        // In the order they are played: each segment's requests come after those of the one before.
        assertEquals(List(4) { "seg20.ts" } + List(4) { "seg21.ts" } + List(4) { "seg22.ts" }, origin.paths())
    }

    @Test
    fun `when a connection is fast enough, the segments a player waits for after a jump are fetched whole, side by side`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 1_000_000
        val id = open(text(40))
        read(cache.open(id, 0))
        origin.asked.clear()
        origin.trickle = 40_000 // 2 MB/s on each connection, eight times what the film takes
        val a = cache.open(id, 20) as Answer.Arriving
        val b = cache.open(id, 21) as Answer.Arriving
        val c = cache.open(id, 22) as Answer.Arriving
        assertArrayEquals(origin.bytes("seg20.ts"), read(a))
        assertArrayEquals(origin.bytes("seg21.ts"), read(b))
        assertArrayEquals(origin.bytes("seg22.ts"), read(c))
        assertEquals(4, origin.of("seg20.ts").size, "the segment jumped to: in pieces")
        assertEquals(listOf(null), origin.of("seg21.ts").map { it.getHeader("Range") }, "the ones after it: whole")
        assertEquals(listOf(null), origin.of("seg22.ts").map { it.getHeader("Range") })
    }

    @Test
    fun `when several connections bring no more than one, what the player waits for comes whole and one at a time`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 1_000_000
        origin.trickle = 20_000 // 1 MB/s
        val id = open(text(40))
        // The first segment: its start alone, then the rest in pieces, since nothing is known yet.
        assertArrayEquals(origin.bytes("seg0.ts"), read(cache.open(id, 0)))
        assertTrue(origin.of("seg0.ts").size > 2)
        // Say the pieces had brought no more together than the start did alone (as on a line that is itself the
        // limit; the test's source cannot share a line out among its answers, so the samples are put in by hand).
        val session = cache.session(id)!!
        // Let the first segment's own measurements land first, then push every one of them out of the kept samples
        // (StreamCache keeps the latest three of each kind).
        delay(200)
        repeat(3) { session.sample(rate = 1000.0, busy = 1.0) }
        repeat(3) { session.sample(rate = 260.0, busy = 4.0) }
        assertEquals(false, session.parallelHelps)
        origin.asked.clear()
        // Then a jump is fetched on one connection, and the segment after it when that has arrived.
        val a = cache.open(id, 20) as Answer.Arriving
        val b = cache.open(id, 21) as Answer.Arriving
        delay(200)
        assertEquals(listOf("seg20.ts"), origin.paths())
        assertArrayEquals(origin.bytes("seg20.ts"), read(a))
        assertArrayEquals(origin.bytes("seg21.ts"), read(b))
        assertEquals(listOf("seg20.ts", "seg21.ts"), origin.paths())
        assertEquals(listOf(null, null), origin.asked.map { it.getHeader("Range") })
    }

    @Test
    fun `what the source is like is told from what one connection brings alone and what several bring together`() {
        fun session() = StreamCache.Session("id", "stream", null, emptyList(), emptyMap(), null)
        val s = session()
        assertNull(s.parallelHelps)
        s.sample(rate = 500.0, busy = 1.0)
        assertNull(s.parallelHelps, "one connection alone: nothing to compare it with yet")
        // Four at once, each nearly as fast as one alone: the source is slow per connection, and more connections bring more.
        s.sample(rate = 480.0, busy = 4.0)
        assertEquals(true, s.parallelHelps)
        // Four at once sharing what one had: the line is the limit. One such moment does not change the verdict…
        s.sample(rate = 130.0, busy = 3.9)
        assertEquals(true, s.parallelHelps)
        // …but when that is all there has been lately, it does.
        s.sample(rate = 125.0, busy = 4.0)
        s.sample(rate = 128.0, busy = 4.0)
        assertEquals(false, s.parallelHelps)
        // Neither alone nor really together: says nothing either way.
        s.sample(rate = 400.0, busy = 1.5)
        assertEquals(false, s.parallelHelps)
        // And back, as soon as several bring more again.
        s.sample(rate = 450.0, busy = 3.0)
        assertEquals(true, s.parallelHelps)

        // A burst on a lone connection (what had piled up arriving at once) does not make the source look as if
        // one connection were as good as four.
        val slow = session()
        slow.sample(rate = 200.0, busy = 1.0)
        slow.sample(rate = 200.0, busy = 4.0)
        slow.sample(rate = 2000.0, busy = 1.0)
        assertEquals(true, slow.parallelHelps)

        // And whether one connection keeps up with the film (here 250 bytes a millisecond).
        assertFalse(s.slowPerConnection, "not known while the film's size is not")
        s.learn(250.0)
        s.sample(rate = 300.0, busy = 1.0)
        assertTrue(s.slowPerConnection)
        s.sample(rate = 600.0, busy = 1.0)
        assertFalse(s.slowPerConnection)
    }

    @Test
    fun `the playlist's headers go to the source, and the player's user agent when they name none`() = runBlocking {
        cache.aheadMs = 0
        val id = open(text(2), headers = mapOf("Referer" to "https://site.test/", "Cookie" to "a=1"), agent = "libmpv")
        read(cache.open(id, 0))
        val request = origin.of("seg0.ts").single()
        assertEquals("https://site.test/", request.getHeader("Referer"))
        assertEquals("a=1", request.getHeader("Cookie"))
        assertEquals("libmpv", request.getHeader("User-Agent"))

        val own = open(text(2) { "other$it.ts" }, key = "k2", headers = mapOf("user-agent" to "Custom/1"), agent = "libmpv")
        read(cache.open(own, 0))
        assertEquals("Custom/1", origin.of("other0.ts").single().getHeader("User-Agent"))
    }

    @Test
    fun `byte ranges of one file are fetched as ranges and kept apart`() = runBlocking {
        cache.aheadMs = 0
        val playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"all.mp4\",BYTERANGE=\"1000@0\"\n" +
            "#EXTINF:4,\n#EXT-X-BYTERANGE:20000@1000\nall.mp4\n#EXTINF:4,\n#EXT-X-BYTERANGE:5000\nall.mp4\n#EXT-X-ENDLIST\n"
        val id = open(playlist)
        val all = origin.bytes("all.mp4")
        assertArrayEquals(all.copyOfRange(0, 1000), read(cache.open(id, 0)))
        assertArrayEquals(all.copyOfRange(1000, 21000), read(cache.open(id, 1)))
        assertArrayEquals(all.copyOfRange(21000, 26000), read(cache.open(id, 2)))
        assertEquals(listOf("bytes=0-999", "bytes=1000-20999", "bytes=21000-25999"), origin.asked.map { it.getHeader("Range") })
        eventually("three files") { cache.store.stats().files == 3 }
        assertEquals(26_000, cache.store.stats().bytes)
    }

    @Test
    fun `a connection that drops is picked up where it stopped`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 400_000
        val id = open(text(6))
        watch(id, 0, 2)
        // The next segment is fetched ahead, and its connection breaks half way.
        origin.cuts.set(1)
        cache.aheadMs = 4_000
        answer(id, 2)
        eventually("fetched all the same") { stored(id, 3) }
        cache.aheadMs = 0
        assertArrayEquals(origin.bytes("seg3.ts"), read(cache.open(id, 3)))
        val requests = origin.of("seg3.ts")
        assertEquals(2, requests.size)
        assertNull(requests[0].getHeader("Range"))
        assertTrue(Regex("bytes=[1-9]\\d*-").matches(requests[1].getHeader("Range")!!), "carried on from the bytes it had: ${requests[1].getHeader("Range")}")

        // A source that drops the line again and again, but gives a little more each time, gets there in the end.
        origin.cuts.set(6)
        cache.aheadMs = 4_000
        answer(id, 3)
        eventually("fetched in seven goes") { stored(id, 4) }
        assertArrayEquals(origin.bytes("seg4.ts"), read(cache.open(id, 4)))
        assertEquals(7, origin.of("seg4.ts").size)
    }

    @Test
    fun `a source that refuses the engine sends the player to the source, and after two refusals the stream is left alone`() = runBlocking {
        cache.aheadMs = 0
        origin.refuse = true
        val id = open(text(3))
        val first = cache.open(id, 0)
        assertTrue(first is Answer.Redirect, "$first")
        assertEquals(server.url("/v/seg0.ts").toString(), (first as Answer.Redirect).url)
        assertTrue(cache.open(id, 1) is Answer.Redirect)
        // Now every file goes straight to the source, without asking it first.
        val before = origin.asked.size
        assertTrue(cache.open(id, 2) is Answer.Redirect)
        assertEquals(before, origin.asked.size)
        // And the playlist is handed out untouched for a while.
        assertNull(cache.playlist(source, source, text(3), emptyMap(), "k1", null, "http://engine/hls/"))
        assertEquals(0, cache.store.stats().files)
    }

    @Test
    fun `a web page where the video should be is not kept, and the player is sent to the source`() = runBlocking {
        cache.aheadMs = 0
        origin.page = true
        val id = open(text(3))
        assertTrue(cache.open(id, 0) is Answer.Redirect)
        assertTrue(cache.open(id, 1) is Answer.Redirect)
        assertEquals(0, cache.store.stats().files)
        assertNull(cache.playlist(source, source, text(3), emptyMap(), "k1", null, "http://engine/hls/"), "a source that answers the engine like this is left to the player")
    }

    @Test
    fun `a key is kept only when it is sixteen bytes`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 16
        val good = open("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"good.key\"\n#EXTINF:4,\nseg0.ts\n#EXT-X-ENDLIST\n")
        assertArrayEquals(origin.bytes("good.key"), read(cache.open(good, 0)))
        eventually("kept") { stored(good, 0) }
        assertEquals("application/octet-stream", (cache.open(good, 0) as Answer.Stored).type)

        origin.size = 40
        val bad = open("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"bad.key\"\n#EXTINF:4,\nseg0.ts\n#EXT-X-ENDLIST\n", key = "k2")
        assertTrue(runCatching { read(cache.open(bad, 0)) }.isFailure)
        assertFalse(stored(bad, 0))
        assertTrue(answer(bad, 0) is Answer.Redirect, "asked again, the player is sent to the source for it")
    }

    @Test
    fun `a file the source lost is refused once and the rest still comes from the cache`() = runBlocking {
        cache.aheadMs = 0
        val id = open(text(3))
        read(cache.open(id, 0))
        origin.refuse = true
        // The player was already promised this file; the download fails under it.
        val broken = cache.open(id, 1) as Answer.Arriving
        assertTrue(runCatching { read(broken) }.isFailure)
        // Asked again (players retry), it is sent to the source.
        assertTrue(cache.open(id, 1) is Answer.Redirect)
        origin.refuse = false
        assertArrayEquals(origin.bytes("seg2.ts"), read(cache.open(id, 2)))
    }

    @Test
    fun `tokens and hosts that change between visits find the same files`() = runBlocking {
        cache.aheadMs = 0
        val first = open(text(2) { "seg$it.ts?sign=aaa&t=1" })
        read(cache.open(first, 1))
        eventually("stored") { stored(first, 1) }
        // Another day: the site resolves the episode to new tokens.
        val second = open(text(2) { "seg$it.ts?sign=bbb&t=2" })
        assertEquals(first, second, "the same files make the same playlist")
        assertTrue(cache.open(second, 1) is Answer.Stored)
        read(cache.open(second, 0))
        assertEquals("sign=bbb&t=2", origin.of("seg0.ts").single().requestUrl!!.encodedQuery, "what is missing is fetched with the new address")
        // Another episode with files of the same names has a store of its own.
        val other = open(text(2) { "seg$it.ts" }, key = "k2")
        assertTrue(answer(other, 1) is Answer.Arriving)
    }

    @Test
    fun `coverage says which parts of the film are stored`() = runBlocking {
        cache.aheadMs = 0
        val id = open(text(10))
        assertNull(cache.coverage("nobody"))
        watch(id, 0, 1)
        watch(id, 6, 7)
        eventually("the four segments") { stored(id, 0, 1, 6, 7) }
        val coverage = cache.coverage("k1")!!
        assertEquals(40_000, coverage.durationMs)
        assertEquals(listOf(listOf(0L, 8_000L), listOf(24_000L, 32_000L)), coverage.ranges.map { it.toList() })
    }

    @Test
    fun `live playlists and a cache that is switched off are left alone`() {
        assertNull(cache.playlist(source, source, "#EXTM3U\n#EXTINF:4,\nlive1.ts\n#EXTINF:4,\nlive2.ts\n", emptyMap(), null, null, "http://engine/hls/"))
        cache.enabled = false
        assertNull(cache.playlist(source, source, text(3), emptyMap(), null, null, "http://engine/hls/"))
    }

    @Test
    fun `an engine that is started again still knows the playlists it handed out`() = runBlocking {
        cache.aheadMs = 0
        val id = open(text(3), headers = mapOf("Referer" to "https://site.test/"))
        read(cache.open(id, 0))
        eventually("stored") { stored(id, 0) }

        val restarted = StreamCache(OkHttpClient(), StreamStore(File(dir, "stream")))
        restarted.aheadMs = 0
        assertTrue(restarted.open(id, 0) is Answer.Stored)
        assertArrayEquals(origin.bytes("seg1.ts"), read(restarted.open(id, 1)))
        assertEquals("https://site.test/", origin.of("seg1.ts").single().getHeader("Referer"))
        assertTrue(restarted.open("nonsense-00000000", 0) is Answer.Failed)
        restarted.close()
    }

    @Test
    fun `clearing empties the store`() = runBlocking {
        cache.aheadMs = 0
        val id = open(text(3))
        read(cache.open(id, 0))
        read(cache.open(id, 1))
        eventually("stored") { cache.store.stats().files == 2 }
        assertEquals(2L * origin.size, cache.clear())
        assertEquals(0, cache.store.stats().bytes)
        assertTrue(answer(id, 0) is Answer.Arriving, "what is asked for again is fetched again")
    }

    @Test
    fun `a range of a stored or arriving file can be read`() = runBlocking {
        cache.aheadMs = 0
        origin.size = 100_000
        val id = open(text(2))
        val bytes = origin.bytes("seg0.ts")
        assertArrayEquals(bytes.copyOfRange(30_000, 70_000), read(cache.open(id, 0), 30_000, 70_000))
        eventually("stored") { stored(id, 0) }
        assertArrayEquals(bytes.copyOfRange(99_000, 100_000), read(cache.open(id, 0), 99_000))
    }
}
