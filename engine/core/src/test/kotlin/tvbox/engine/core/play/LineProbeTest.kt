package tvbox.engine.core.play

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import tvbox.engine.core.EngineException
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.model.ProbeLine
import tvbox.engine.core.model.ProbeRequest
import tvbox.engine.core.model.ProbeResult
import tvbox.engine.core.model.ProbeState
import tvbox.engine.core.model.SniffRequest
import tvbox.engine.core.net.SiteHttp
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class LineProbeTest {
    private val server = MockWebServer()

    /** Paths as the server got them, with the Range and Referer they came with. */
    private val requests = ConcurrentLinkedQueue<RecordedRequest>()

    /** Short budgets, so that a test waits fractions of a second where the engine waits seconds. */
    private val budgets = LineProbe.Budgets(resolveMs = 2_000, firstByteMs = 2_000, readMs = 400, requestMs = 6_000)

    @BeforeEach
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val path = request.requestUrl!!.encodedPath
                return when (path) {
                    "/master.m3u8" -> playlist(
                        "#EXTM3U\n" +
                            "#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720,CODECS=\"avc1.4d401f,mp4a.40.2\"\nlow.m3u8\n" +
                            "#EXT-X-STREAM-INF:BANDWIDTH=4000000,AVERAGE-BANDWIDTH=9000000,RESOLUTION=1920x1080\nhigh.m3u8\n" +
                            "#EXT-X-STREAM-INF:BANDWIDTH=9900000\nnosize.m3u8\n",
                    )
                    "/high.m3u8" -> playlist("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg/h0.ts\n#EXTINF:6,\nseg/h1.ts\n#EXT-X-ENDLIST\n")
                    "/low.m3u8" -> playlist("#EXTM3U\n#EXTINF:6,\nseg/l0.ts\n#EXT-X-ENDLIST\n")
                    "/plain.m3u8" -> playlist("#EXTM3U\n#EXTINF:6,\nseg/p0.ts\n#EXT-X-ENDLIST\n")
                    "/slow.m3u8" -> playlist("#EXTM3U\n#EXTINF:6,\nseg/slow.ts\n#EXT-X-ENDLIST\n")
                    "/empty.m3u8" -> playlist("#EXTM3U\n#EXT-X-ENDLIST\n")
                    "/hang.m3u8" -> { Thread.sleep(3_000); playlist("#EXTM3U\n#EXTINF:6,\nseg/p0.ts\n#EXT-X-ENDLIST\n") }
                    "/seg/slow.ts" -> MockResponse().setBody(Buffer().write(ByteArray(400 * 1024))).throttleBody(8 * 1024, 100, TimeUnit.MILLISECONDS)
                    "/film.mp4" -> MockResponse().setResponseCode(206).setBody(Buffer().write(ByteArray(200 * 1024)))
                    "/forbidden.mp4" -> MockResponse().setResponseCode(403)
                    "/page.mp4" -> MockResponse().setBody("<!DOCTYPE html><html><body>视频不存在</body></html>")
                    "/error.mp4" -> MockResponse().setBody("""{"code":403,"msg":"forbidden"}""")
                    else -> if (path.startsWith("/seg/")) MockResponse().setBody(Buffer().write(ByteArray(64 * 1024))) else MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
    }

    @AfterEach
    fun stop() {
        server.shutdown()
    }

    private fun playlist(text: String) = MockResponse().setHeader("Content-Type", "application/vnd.apple.mpegurl").setBody(text)

    private fun url(path: String) = server.url(path).toString()

    private fun paths() = requests.map { it.requestUrl!!.encodedPath }

    private var now = 1_000_000L

    private fun lineProbe(b: LineProbe.Budgets = budgets) = LineProbe(SiteHttp(OkHttpClient()), PLAYLIST_BASE, budgets = b, clock = { now })

    private val resolved = AtomicInteger()

    /** A CMS line: the episode id is the address. */
    private val direct: suspend (PlayRequest) -> PlayInfo = { resolved.incrementAndGet(); PlayInfo(kind = "direct", url = it.episodeId) }

    private fun LineProbe.run(vararg lines: Pair<String, String>, resolve: suspend (PlayRequest) -> PlayInfo = direct): List<ProbeResult> =
        runBlocking { probe(ProbeRequest("cms", lines.map { ProbeLine(it.first, it.second) }), "scope", resolve).toList() }

    @Test
    fun `a line that does not open is dead and says why, without numbers it could not measure`() {
        val failing: suspend (PlayRequest) -> PlayInfo = {
            if (it.line == "坏解析") throw EngineException.SiteFailed("PLAY_FAILED", "parser returned no url")
            PlayInfo(kind = "direct", url = it.episodeId)
        }
        val results = lineProbe().run(
            "拒绝连接" to "http://127.0.0.1:1/dead/1.m3u8",
            "不存在" to url("/gone.m3u8"),
            "禁止" to url("/forbidden.mp4"),
            "网页" to url("/page.mp4"),
            "坏解析" to "https://page.test/1",
            "空列表" to url("/empty.m3u8"),
            resolve = failing,
        ).associateBy { it.line } + lineProbe().run("报错" to url("/error.mp4")).associateBy { it.line }
        assertEquals(7, results.size)
        assertEquals("连不上", results.getValue("拒绝连接").reason)
        assertEquals("404", results.getValue("不存在").reason)
        assertEquals("被拒绝", results.getValue("禁止").reason)
        assertEquals("不是视频", results.getValue("网页").reason)
        assertEquals("不是视频", results.getValue("报错").reason)
        assertEquals("解析失败", results.getValue("坏解析").reason)
        assertEquals("播放列表是空的", results.getValue("空列表").reason)
        for (r in results.values) {
            assertEquals(ProbeState.DEAD, r.state, r.toString())
            assertNotNull(r.resolveMs, r.toString())
            assertNull(r.firstByteMs, r.toString())
            assertNull(r.bytesPerSecond, r.toString())
            assertNull(r.width, r.toString())
        }
        assertEquals("", results.getValue("坏解析").kind)
    }

    @Test
    fun `a master playlist is measured at its highest variant, whose size is reported`() {
        val r = lineProbe().run("线路一" to url("/master.m3u8")).single()
        assertEquals(ProbeState.OK, r.state, r.toString())
        assertEquals(0, r.index)
        assertEquals("hls", r.kind)
        assertEquals(1920, r.width)
        assertEquals(1080, r.height)
        assertNotNull(r.resolveMs)
        assertNotNull(r.firstByteMs)
        assertTrue((r.bytesPerSecond ?: 0) > LineProbe.needed(1920, 1080), r.toString())
        assertEquals("", r.reason)
        assertEquals(listOf("/master.m3u8", "/high.m3u8", "/seg/h0.ts"), paths())
        // A segment is read from its start, not asked for a range.
        assertNull(requests.last().getHeader("Range"))
    }

    @Test
    fun `a file is read with a range request, and HLS behind the engine's playlist address with its headers`() {
        val wrapped = PlayResolver.playlistUrl(PLAYLIST_BASE, url("/plain.m3u8"), mapOf("Referer" to "https://site.test/")) + "&k=0123abcd"
        val results = lineProbe().run("直链" to url("/film.mp4"), "包装" to wrapped).associateBy { it.line }
        val file = results.getValue("直链")
        assertEquals(ProbeState.OK, file.state, file.toString())
        assertEquals("file", file.kind)
        assertNull(file.width)
        assertEquals("bytes=0-${512 * 1024 - 1}", requests.first { it.path == "/film.mp4" }.getHeader("Range"))
        val hls = results.getValue("包装")
        assertEquals(ProbeState.OK, hls.state, hls.toString())
        assertEquals("hls", hls.kind)
        assertEquals("https://site.test/", requests.first { it.path == "/plain.m3u8" }.getHeader("Referer"))
        assertEquals("https://site.test/", requests.first { it.path == "/seg/p0.ts" }.getHeader("Referer"))
    }

    @Test
    fun `a line slower than its resolution needs is slow`() {
        val r = lineProbe().run("慢线路" to url("/slow.m3u8")).single()
        assertEquals(ProbeState.SLOW, r.state, r.toString())
        assertEquals("网速不够", r.reason)
        assertEquals("hls", r.kind)
        val speed = r.bytesPerSecond!!
        assertTrue(speed in 20_000 until LineProbe.needed(null, null), "about 80 KB/s: $speed")
        assertNotNull(r.firstByteMs)
    }

    @Test
    fun `only six lines are tested, the others are skipped at once`() {
        val lines = (1..8).map { "线路$it" to url("/plain.m3u8?n=$it") }.toTypedArray()
        val results = lineProbe().run(*lines)
        assertEquals(8, results.size)
        assertEquals(listOf(6, 7), results.take(2).map { it.index }, "the skipped lines are known first")
        assertEquals(listOf("线路7", "线路8"), results.take(2).map { it.line })
        results.take(2).forEach { assertEquals(ProbeState.SKIPPED, it.state); assertNull(it.resolveMs) }
        assertEquals((0..5).toSet(), results.drop(2).map { it.index }.toSet())
        results.drop(2).forEach { assertEquals(ProbeState.OK, it.state, it.toString()) }
        assertEquals(6, resolved.get())
        assertEquals(6, paths().count { it == "/plain.m3u8" })
    }

    @Test
    fun `results come in the order the lines finish`() {
        val delays = mapOf("慢" to 700L, "快" to 0L, "中" to 300L)
        val results = lineProbe().run("慢" to url("/plain.m3u8?a"), "快" to url("/plain.m3u8?b"), "中" to url("/plain.m3u8?c")) {
            delay(delays.getValue(it.line))
            PlayInfo(kind = "direct", url = it.episodeId)
        }
        assertEquals(listOf("快", "中", "慢"), results.map { it.line })
        assertEquals(listOf(1, 2, 0), results.map { it.index })
    }

    @Test
    fun `a result is reused for five minutes without resolving or fetching again`() {
        val probe = lineProbe()
        val first = probe.run("线路一" to url("/master.m3u8"), "线路二" to "http://127.0.0.1:1/x.m3u8")
        val fetched = requests.size
        val again = probe.run("线路二" to "http://127.0.0.1:1/x.m3u8", "线路一" to url("/master.m3u8"))
        assertEquals(2, resolved.get(), "nothing resolved again")
        assertEquals(fetched, requests.size, "nothing fetched again")
        // Same results, at the places the lines have in this request.
        assertEquals(first.associate { it.line to it.copy(index = 0) }, again.associate { it.line to it.copy(index = 0) })
        assertEquals(mapOf("线路二" to 0, "线路一" to 1), again.associate { it.line to it.index })

        now += 5 * 60_000 + 1
        probe.run("线路一" to url("/master.m3u8"))
        assertEquals(3, resolved.get())
        assertEquals(fetched + 3, requests.size)
    }

    @Test
    fun `a host that failed to connect twice is not tried again for two minutes`() {
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val probe = lineProbe(budgets.copy(parallel = 1))
        val down = probe.run("一" to "http://127.0.0.1:$port/a.m3u8", "二" to "http://127.0.0.1:$port/b.m3u8")
        assertEquals(listOf("连不上", "连不上"), down.map { it.reason })

        // The host is back, but it is not asked within the two minutes.
        val back = MockWebServer().apply {
            dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest) = MockResponse().setBody(Buffer().write(ByteArray(64 * 1024)))
            }
            start(InetAddress.getByName("127.0.0.1"), port)
        }
        try {
            val skipped = probe.run("三" to "http://127.0.0.1:$port/c.mp4", "别处" to url("/plain.m3u8"))
            assertEquals(ProbeState.DEAD, skipped[0].state)
            assertEquals("连不上", skipped[0].reason)
            assertEquals(0, back.requestCount)
            assertEquals(ProbeState.OK, skipped[1].state, "other hosts are tried")

            now += 2 * 60_000
            val retried = probe.run("三" to "http://127.0.0.1:$port/c.mp4").single()
            assertEquals(ProbeState.OK, retried.state, retried.toString())
            assertEquals(1, back.requestCount)
        } finally {
            back.shutdown()
        }
    }

    @Test
    fun `a page that needs sniffing is reported as it is, without opening it`() {
        val r = lineProbe().run("嗅探" to "https://page.test/1") {
            PlayInfo(kind = "sniff", sniff = SniffRequest("https://jx.test/?url=https://page.test/1"), parsedBy = "演示嗅探")
        }.single()
        assertEquals(ProbeState.SNIFF, r.state)
        assertEquals("演示嗅探", r.parsedBy)
        assertEquals("", r.kind)
        assertEquals("", r.reason)
        assertTrue(requests.isEmpty())
    }

    @Test
    fun `lines not back when the probe's time is up are slow, even a spider that blocks its thread`() {
        val started = System.nanoTime()
        val results = lineProbe(budgets.copy(requestMs = 1_200)).run(
            // A spider blocks its thread and does not stop when cancelled; the probe does not wait for it.
            "卡住" to url("/plain.m3u8?b"),
            "片源慢" to url("/hang.m3u8"),
            "正常" to url("/plain.m3u8?c"),
        ) {
            if (it.line == "卡住") Thread.sleep(3_000)
            PlayInfo(kind = "direct", url = it.episodeId)
        }
        val ms = (System.nanoTime() - started) / 1_000_000
        assertTrue(ms < 2_500, "finished on time: $ms ms")
        assertEquals(listOf("正常", "卡住", "片源慢"), results.map { it.line }, "the late ones last, in the order of the request")
        assertEquals(ProbeState.OK, results[0].state)
        for (late in results.drop(1)) {
            assertEquals(ProbeState.SLOW, late.state, late.toString())
            assertEquals("超时", late.reason)
            assertNull(late.firstByteMs)
        }
        assertNull(results[1].resolveMs)
        assertNotNull(results[2].resolveMs, "what was known when time ran out")
    }

    @Test
    fun `a line whose address takes longer than its budget is dead`() {
        val r = lineProbe(budgets.copy(resolveMs = 300)).run("解析慢" to url("/plain.m3u8")) {
            delay(2_000)
            PlayInfo(kind = "direct", url = it.episodeId)
        }.single()
        assertEquals(ProbeState.DEAD, r.state)
        assertEquals("解析超时", r.reason)
        assertTrue(r.resolveMs!! in 300L until 1_500L, r.toString())
        assertTrue(requests.isEmpty())
    }

    @Test
    fun `cancelling the probe stops it, and no further line is fetched`() = runBlocking {
        val lines = (1..6).map { ProbeLine("线路$it", url("/hang.m3u8?n=$it")) }
        val got = ConcurrentLinkedQueue<ProbeResult>()
        val job = launch(Dispatchers.IO) {
            lineProbe().probe(ProbeRequest("cms", lines), "scope", direct).collect { got += it }
        }
        val until = System.nanoTime() + 2_000_000_000L
        while (requests.size < 3 && System.nanoTime() < until) delay(20)
        delay(100)
        assertEquals(3, requests.size, "three lines at a time")
        job.cancel()
        job.join()
        // The first three answer after 3 s; had the probe gone on, the others would be asked for then.
        delay(3_500)
        assertEquals(3, requests.size, "the other three were never asked for: ${requests.map { it.path }}")
        assertEquals(3, resolved.get())
        assertTrue(got.isEmpty(), got.toString())
    }

    private companion object {
        const val PLAYLIST_BASE = "http://127.0.0.1:9978/m3u8?"
    }
}
