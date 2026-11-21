package tvbox.engine.core.download

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
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
import tvbox.engine.core.cache.StreamStore
import tvbox.engine.core.model.DownloadExportResult
import tvbox.engine.core.model.DownloadItem
import tvbox.engine.core.model.DownloadLocation
import tvbox.engine.core.model.DownloadRequest
import tvbox.engine.core.model.DownloadSettingsUpdate
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.PlayRequest
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** The download queue against a made-up site: HLS (plain, AES-128 with a map, a master), a live playlist, a direct file. */
class DownloadManagerTest {
    @TempDir
    lateinit var dir: File

    private val site = MockWebServer()
    private val asked = CopyOnWriteArrayList<RecordedRequest>()
    private val managers = CopyOnWriteArrayList<DownloadManager>()
    private lateinit var store: StreamStore

    /** Delay before every segment's body, and how fast the direct file comes (bytes per 50 ms; 0 unlimited). */
    @Volatile private var segmentDelayMs = 0L
    @Volatile private var fileRate = 0L

    /** Only addresses with this token get segments; others get 403. */
    @Volatile private var token = "a"

    /** Segments (by path) refused with this status; 0: none. */
    private val refused = ConcurrentHashMap<String, Int>()

    private val key = "0123456789abcdef".toByteArray()
    private val segments = 10

    /** A segment: MPEG-TS sync bytes every 188 bytes, the rest made from the name. */
    private fun ts(name: String, size: Int = 30_000) = ByteArray(size) { i -> if (i % 188 == 0) 0x47 else (name.hashCode() + i * 7).toByte() }

    private val film = (0 until segments).map { ts("seg$it") }
    private val fragments = (0 until 4).map { ByteArray(20_000) { i -> (it * 31 + i).toByte() } }
    private val init = ByteArray(800) { (it * 3).toByte() }
    private val file = ByteArray(2_000_000) { i -> if (i == 0) 0 else (i * 13).toByte() }.also { "\u0000\u0000\u0000\u0018ftypisom".toByteArray().copyInto(it) }

    private fun encrypt(data: ByteArray, sequence: Long): ByteArray = Cipher.getInstance("AES/CBC/PKCS5Padding").run {
        init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(DownloadExport.sequenceIv(sequence)))
        doFinal(data)
    }

    private fun playlist(lines: List<String>, endless: Boolean = false, head: String = "") = buildString {
        appendLine("#EXTM3U")
        appendLine("#EXT-X-TARGETDURATION:10")
        appendLine("#EXT-X-MEDIA-SEQUENCE:0")
        if (head.isNotEmpty()) appendLine(head)
        for (l in lines) appendLine("#EXTINF:10.0,").appendLine(l)
        if (!endless) appendLine("#EXT-X-ENDLIST")
    }

    @BeforeEach
    fun start() {
        site.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                asked += request
                val path = request.requestUrl!!.encodedPath
                val query = request.requestUrl!!.query.orEmpty()
                refused[path]?.let { return MockResponse().setResponseCode(it) }
                return when {
                    path == "/film/index.m3u8" -> MockResponse().setBody(playlist((0 until segments).map { "seg$it.ts?token=" + query.substringAfter("token=") }))
                    path.startsWith("/film/seg") -> {
                        if (!query.contains("token=$token")) return MockResponse().setResponseCode(403)
                        val i = path.removePrefix("/film/seg").removeSuffix(".ts").toInt()
                        MockResponse().setHeader("Content-Type", "video/mp2t").setBody(Buffer().write(film[i])).setBodyDelay(segmentDelayMs, TimeUnit.MILLISECONDS)
                    }
                    path == "/aes/index.m3u8" -> MockResponse().setBody(playlist((0 until segments).map { "seg$it.ts" }, head = "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\""))
                    path.startsWith("/aes/seg") -> {
                        val i = path.removePrefix("/aes/seg").removeSuffix(".ts").toInt()
                        MockResponse().setBody(Buffer().write(encrypt(film[i], i.toLong())))
                    }
                    path == "/aes/key.bin" || path == "/fmp4/key.bin" -> MockResponse().setBody(Buffer().write(key))
                    // fragmented MP4 with a map and a key whose IV is written out
                    path == "/fmp4/index.m3u8" -> MockResponse().setBody(
                        playlist((0 until 4).map { "frag$it.m4s" }, head = "#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x000000000000000000000000000000FF"),
                    )
                    path == "/fmp4/init.mp4" -> MockResponse().setBody(Buffer().write(init))
                    path.startsWith("/fmp4/frag") -> {
                        val i = path.removePrefix("/fmp4/frag").removeSuffix(".m4s").toInt()
                        val c = Cipher.getInstance("AES/CBC/PKCS5Padding").apply {
                            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(ByteArray(16).also { it[15] = 0xFF.toByte() }))
                        }
                        MockResponse().setBody(Buffer().write(c.doFinal(fragments[i])))
                    }
                    path == "/master.m3u8" -> MockResponse().setBody(
                        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2500000\nfilm/index.m3u8?token=a\n",
                    )
                    path == "/split/master.m3u8" -> MockResponse().setBody(
                        """#EXTM3U
                            |#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Another",URI="other.m3u8"
                            |#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Chinese, stereo",DEFAULT=YES,URI="audio.m3u8"
                            |#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="a"
                            |video.m3u8
                        """.trimMargin(),
                    )
                    path == "/split/video.m3u8" -> MockResponse().setBody(playlist(listOf("shared.ts?video")))
                    path == "/split/audio.m3u8" -> MockResponse().setBody(playlist(listOf("shared.ts?audio")))
                    path == "/split/shared.ts" -> MockResponse().setBody(Buffer().write(ts(query)))
                    path == "/low/index.m3u8" -> MockResponse().setBody(playlist(listOf("never.ts")))
                    path == "/live.m3u8" -> MockResponse().setBody(playlist(listOf("live1.ts", "live2.ts"), endless = true))
                    path == "/page.ts" -> MockResponse().setBody(playlist(listOf("notts.ts")))
                    path == "/notts.ts" -> MockResponse().setBody(Buffer().write(ByteArray(5000) { 0x11 }))
                    path == "/film.mp4" -> fileAnswer(request)
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        site.start()
        store = StreamStore(File(dir, "stream"))
    }

    @AfterEach
    fun stop() {
        managers.forEach { runCatching { it.close() } }
        site.shutdown()
    }

    /** The direct file, with byte ranges, as fast as [fileRate] says. */
    private fun fileAnswer(request: RecordedRequest): MockResponse {
        val range = request.getHeader("Range")?.let { Regex("bytes=(\\d+)-(\\d*)").find(it) }
        val from = range?.groupValues?.get(1)?.toInt() ?: 0
        val to = range?.groupValues?.get(2)?.toIntOrNull()?.plus(1) ?: file.size
        val response = if (range != null) {
            MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes $from-${to - 1}/${file.size}")
        } else {
            MockResponse()
        }
        response.setHeader("Content-Type", "video/mp4").setBody(Buffer().write(file, from, to - from))
        if (fileRate > 0) response.throttleBody(fileRate, 50, TimeUnit.MILLISECONDS)
        return response
    }

    private val resolved = AtomicInteger()

    /** What `/play/resolve` would say: HLS through the engine's playlist address, files as they are. */
    private fun resolve(req: PlayRequest): PlayInfo {
        resolved.incrementAndGet()
        val url = site.url(req.episodeId.replace("{token}", token)).toString()
        return when {
            req.episodeId == "sniff" -> PlayInfo(kind = "sniff")
            req.episodeId.endsWith(".mp4") -> PlayInfo(kind = "direct", url = url)
            else -> PlayInfo(kind = "direct", url = "http://127.0.0.1:1/m3u8?url=" + URLEncoder.encode(url, "UTF-8") + "&k=key-" + req.episodeId.hashCode(), cache = "key-" + req.episodeId.hashCode())
        }
    }

    private fun manager(
        stateFile: File? = File(dir, "downloads.json"),
        free: Long = Long.MAX_VALUE,
        resolver: suspend (PlayRequest) -> PlayInfo = { resolve(it) },
        start: Boolean = true,
        dispatcher: CoroutineDispatcher = Dispatchers.IO,
    ): DownloadManager = DownloadManager(
        OkHttpClient(), store, stateFile, resolver = resolver, localBase = "http://127.0.0.1:1",
        exportDir = { File(dir, "exports") }, reserveBytes = 1_000, freeSpace = { free }, dispatcher = dispatcher,
    ).also {
        managers += it
        if (start) it.start()
    }

    private fun request(episode: String, name: String = episode) = DownloadRequest(site = "s", line = "线路", episodeId = episode, vodId = "1", title = "片名", episodeName = name)

    private suspend fun DownloadManager.until(id: String, timeoutMs: Long = 15_000, what: (DownloadItem) -> Boolean): DownloadItem {
        val end = System.currentTimeMillis() + timeoutMs
        while (true) {
            val item = get(id)
            if (what(item)) return item
            if (System.currentTimeMillis() > end) throw AssertionError("timed out; the download is $item")
            delay(20)
        }
    }

    private suspend fun DownloadManager.finished(id: String) = until(id) { it.state == "done" || it.state == "failed" }

    private fun segmentRequests(): List<String> = asked.map { it.requestUrl!!.encodedPath }.filter { it.startsWith("/film/seg") }

    @Test
    fun `an HLS episode is fetched whole, pinned, and plays from the engine without the network`(): Unit = runBlocking {
        val m = manager()
        val item = m.add(listOf(request("/film/index.m3u8?token={token}", "第1集"))).single()
        assertTrue(item.state in setOf("queued", "running"), item.state)
        val done = m.finished(item.id)
        assertEquals("done", done.state, done.error)
        assertEquals("hls", done.kind)
        assertEquals(1.0, done.progress)
        assertEquals(segments, done.parts)
        assertEquals(segments * 30_000L, done.bytes)
        assertEquals(100_000L, done.durationMs)
        assertEquals(segments, segmentRequests().size, "every segment once")

        val play = m.offlinePlay(PlayRequest("s", "线路", "/film/index.m3u8?token={token}"))
        assertNotNull(play)
        assertEquals("http://127.0.0.1:1/dl/${item.id}/index.m3u8", play!!.url)
        assertEquals(item.id, play.download)
        assertNull(m.offlinePlay(PlayRequest("s", "线路", "/other.m3u8")))

        site.shutdown()
        val text = m.offlinePlaylist(item.id, "http://engine/dl/${item.id}/")!!
        val lines = text.lines().filter { it.startsWith("http") }
        assertEquals((0 until segments).map { "http://engine/dl/${item.id}/$it.ts" }, lines)
        assertTrue(text.contains("#EXT-X-ENDLIST"))
        for (i in 0 until segments) {
            val (f, type) = m.offlineFile(item.id, "$i.ts")!!
            assertEquals("video/mp2t", type)
            assertArrayEquals(film[i], f.readBytes())
        }
        assertNull(m.offlineFile(item.id, "99.ts"))
        val stats = store.stats()
        assertEquals(segments * 30_000L, stats.pinnedBytes)
        assertEquals(0L, stats.bytes, "a download does not count towards the cache")
    }

    @Test
    fun `a download's files stay when the cache is trimmed or emptied`(): Unit = runBlocking {
        // Something the stream cache keeps for a player: an ordinary stream.
        store.partFile("watched", "a").writeBytes(ByteArray(50_000))
        assertTrue(store.commit("watched", "a"))
        val m = manager()
        val id = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        assertEquals("done", m.finished(id).state)
        store.maxBytes = 10_000
        assertEquals(0L, store.stats().bytes, "the cache over its cap gives up its own files")
        assertEquals(segments * 30_000L, store.stats().pinnedBytes)
        store.clear()
        assertNotNull(m.offlinePlay(PlayRequest("s", "线路", "/film/index.m3u8?token={token}")), "the download is still whole")
        // A store opened again (the engine started again) knows the stream is pinned.
        val again = StreamStore(store.root, maxBytes = 10_000)
        again.trim()
        assertEquals(segments * 30_000L, again.stats().pinnedBytes)

        m.delete(id)
        assertFalse(m.list().any { it.id == id })
        assertEquals(0L, store.stats().pinnedBytes)
        assertEquals(0, store.root.listFiles()!!.count { it.isDirectory && it.name != "watched" }, "the download's folder is gone")
    }

    @Test
    fun `at most the configured number run at once, and the rest wait their turn`(): Unit = runBlocking {
        segmentDelayMs = 150
        val m = manager()
        assertEquals(2, m.settings().concurrency)
        val ids = m.add(listOf(request("/film/index.m3u8?token={token}&n=1"), request("/aes/index.m3u8"), request("/film/index.m3u8?token={token}&n=3"))).map { it.id }
        var most = 0
        while (m.list().any { it.state == "queued" || it.state == "running" }) {
            most = maxOf(most, m.list().count { it.state == "running" })
            delay(10)
        }
        assertEquals(2, most)
        assertTrue(ids.all { m.get(it).state == "done" })

        // The same episode twice is one download.
        assertEquals(ids[0], m.add(listOf(request("/film/index.m3u8?token={token}&n=1"))).single().id)
        assertEquals(1, m.updateSettings(DownloadSettingsUpdate(concurrency = 1)).concurrency)
        assertEquals(5, m.updateSettings(DownloadSettingsUpdate(concurrency = 99)).concurrency)
    }

    @Test
    fun `a download that was running when the engine stopped carries on, without fetching again what it had`(): Unit = runBlocking {
        segmentDelayMs = 300
        val state = File(dir, "downloads.json")
        val first = manager(state)
        val id = first.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        first.until(id) { it.partsDone >= 4 }
        first.close()
        val had = store.names(streamDir().name).size
        assertTrue(had in 4 until segments, "stopped half way: $had files")
        val second = manager(state, start = false)
        assertEquals("queued", second.get(id).state, "it was running: it goes on at the next start")
        assertEquals(had, second.get(id).partsDone)
        second.start()
        assertEquals("done", second.finished(id).state)
        // What had arrived is not asked for again; only what was under way when it stopped may be.
        val twice = segmentRequests().groupingBy { it }.eachCount().filterValues { it > 1 }
        assertTrue(twice.size <= DownloadManager.CONNECTIONS && twice.values.all { it == 2 }, "asked again: $twice")
        assertEquals(segments, store.names(streamDir().name).size)
    }

    @Test
    fun `pause and resume, and a paused download stays paused after a restart`(): Unit = runBlocking {
        segmentDelayMs = 200
        val state = File(dir, "downloads.json")
        val m = manager(state)
        val id = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        m.until(id) { it.partsDone >= 2 }
        assertEquals("paused", m.pause(id).state)
        delay(300)
        val count = segmentRequests().size
        delay(500)
        assertEquals(count, segmentRequests().size, "nothing is fetched while it is paused")
        assertEquals(0L, m.get(id).speed)
        m.close()
        val again = manager(state)
        assertEquals("paused", again.get(id).state)
        assertTrue(again.resume(id).state in setOf("queued", "running"))
        assertEquals("done", again.finished(id).state)
    }

    @Test
    fun `pause and resume before the download coroutine has started`(): Unit = runBlocking {
        val executor = Executors.newSingleThreadExecutor()
        val ready = CountDownLatch(1)
        executor.submit { ready.await() }
        executor.asCoroutineDispatcher().use { dispatcher ->
            val manager = manager(dispatcher = dispatcher)
            try {
                val id = manager.add(listOf(request("/film.mp4"))).single().id
                assertEquals("paused", manager.pause(id).state)
                manager.resume(id)
                assertEquals(0, resolved.get())
                ready.countDown()
                val done = manager.finished(id)
                assertEquals("done", done.state, done.error)
                assertEquals(1, resolved.get())
            } finally {
                ready.countDown()
                manager.close()
            }
        }
    }

    @Test
    fun `HLS with an AES-128 key and an initialisation map`(): Unit = runBlocking {
        val m = manager()
        val id = m.add(listOf(request("/fmp4/index.m3u8", "第2集"))).single().id
        val done = m.finished(id)
        assertEquals("done", done.state, done.error)
        assertEquals(6, done.parts, "map, key and four fragments")
        val text = m.offlinePlaylist(id, "http://e/dl/$id/")!!
        assertTrue(text.contains("#EXT-X-MAP:URI=\"http://e/dl/$id/0.mp4\""), text)
        assertTrue(text.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"http://e/dl/$id/1.key\",IV=0x000000000000000000000000000000FF"), text)
        assertArrayEquals(key, m.offlineFile(id, "1.key")!!.first.readBytes())
        assertEquals("application/octet-stream", m.offlineFile(id, "1.key")!!.second)
        assertArrayEquals(init, m.offlineFile(id, "0.mp4")!!.first.readBytes())

        // Exported: the map, then every fragment decrypted.
        val export = m.exportOf(id)
        assertEquals("mp4", export.format)
        assertEquals("片名 第2集.mp4", export.fileName)
        val out = ByteArrayOutputStream()
        export.write(out)
        assertArrayEquals(init + fragments.reduce { a, b -> a + b }, out.toByteArray())
    }

    @Test
    fun `export of plain and AES-128 HLS gives the same MPEG-TS file`(): Unit = runBlocking {
        val m = manager()
        val (plain, aes) = m.add(listOf(request("/film/index.m3u8?token={token}", "普通"), request("/aes/index.m3u8", "加密"))).map { it.id }
        assertEquals("done", m.finished(plain).state)
        assertEquals("done", m.finished(aes).state)
        val expected = film.reduce { a, b -> a + b }
        val folder = File(dir, "out").also { it.mkdirs() }
        val a = m.export(plain, folder.absolutePath)
        val b = m.export(aes, folder.absolutePath)
        assertEquals("ts", a.format)
        assertEquals(File(folder, "片名 普通.ts").absolutePath, a.path)
        assertEquals(File(folder, "片名 加密.ts").absolutePath, b.path)
        assertArrayEquals(expected, File(a.path).readBytes())
        assertArrayEquals(expected, File(b.path).readBytes(), "decrypted with the key and each segment's sequence number")
        assertEquals(expected.size.toLong(), b.bytes)
        // Again into the same folder: a new name, nothing overwritten.
        assertEquals(File(folder, "片名 普通 (2).ts").absolutePath, m.export(plain, folder.absolutePath).path)
        // With no folder: the export folder.
        assertTrue(m.export(plain).path.startsWith(File(dir, "exports").absolutePath))
    }

    @Test
    fun `segments that are not MPEG-TS cannot be joined without ffmpeg`(): Unit = runBlocking {
        val m = manager()
        val id = m.add(listOf(request("/page.ts"))).single().id
        assertEquals("done", m.finished(id).state)
        val error = runCatching { m.exportOf(id) }.exceptionOrNull()
        assertTrue(error?.message?.contains("ffmpeg") == true, "${error?.message}")
        assertNotNull(m.offlinePlay(PlayRequest("s", "线路", "/page.ts")), "it still plays")
    }

    @Test
    fun `a direct file is fetched with ranges and resumes where it stopped`(): Unit = runBlocking {
        fileRate = 64 * 1024
        val m = manager()
        val id = m.add(listOf(request("/film.mp4"))).single().id
        val running = m.until(id) { it.bytes > 300_000 }
        assertEquals("file", running.kind)
        assertEquals(file.size.toLong(), running.totalBytes)
        assertTrue(running.speed > 0, "a running download has a speed")
        m.pause(id)
        delay(200)
        val had = m.get(id).bytes
        assertTrue(had in 300_000 until file.size, "$had")
        fileRate = 0
        m.resume(id)
        val done = m.finished(id)
        assertEquals("done", done.state, done.error)
        val ranges = asked.filter { it.requestUrl!!.encodedPath == "/film.mp4" }.map { it.getHeader("Range") }
        assertEquals("bytes=0-", ranges.first())
        assertTrue(ranges.drop(1).any { it != null && it != "bytes=0-" && it.removePrefix("bytes=").removeSuffix("-").toLong() >= 300_000 }, "it went on from where it was: $ranges")
        val play = m.offlinePlay(PlayRequest("s", "线路", "/film.mp4"))!!
        assertEquals("http://127.0.0.1:1/dl/$id/film.mp4", play.url, "the kind of file comes from its first bytes")
        assertArrayEquals(file, m.offlineFile(id, "film.mp4")!!.first.readBytes())
        val exported = m.export(id, File(dir, "x.mp4").absolutePath)
        assertEquals("mp4", exported.format)
        assertArrayEquals(file, File(exported.path).readBytes())
    }

    @Test
    fun `a direct file carries on after a restart from what it had`(): Unit = runBlocking {
        fileRate = 64 * 1024
        val state = File(dir, "downloads.json")
        val first = manager(state)
        val id = first.add(listOf(request("/film.mp4"))).single().id
        first.until(id) { it.bytes > 200_000 }
        first.close()
        fileRate = 0
        val second = manager(state)
        assertEquals("done", second.finished(id).state)
        val ranges = asked.filter { it.requestUrl!!.encodedPath == "/film.mp4" }.map { it.getHeader("Range") }
        assertTrue(ranges.last()!!.removePrefix("bytes=").removeSuffix("-").toLong() >= 200_000, "$ranges")
        assertArrayEquals(file, second.offlineFile(id, "film.mp4")!!.first.readBytes())
    }

    @Test
    fun `a live stream is refused`(): Unit = runBlocking {
        val m = manager()
        val id = m.add(listOf(request("/live.m3u8"))).single().id
        val failed = m.finished(id)
        assertEquals("failed", failed.state)
        assertTrue(failed.error.contains("直播"), failed.error)
        assertTrue(asked.none { it.requestUrl!!.encodedPath.startsWith("/live") && it.requestUrl!!.encodedPath.endsWith(".ts") })
    }

    @Test
    fun `a master playlist downloads its best variant`(): Unit = runBlocking {
        val m = manager()
        val id = m.add(listOf(request("/master.m3u8"))).single().id
        assertEquals("done", m.finished(id).state)
        assertEquals(segments, segmentRequests().size)
        assertTrue(asked.none { it.requestUrl!!.encodedPath == "/low/index.m3u8" })
    }

    @Test
    fun `separate default audio and video play offline after restart`(): Unit = runBlocking {
        val first = manager()
        val episode = "/split/master.m3u8"
        val id = first.add(listOf(request(episode))).single().id
        val done = first.finished(id)
        assertEquals("done", done.state, done.error)
        assertEquals(2, done.partsDone)
        assertEquals(10_000L, done.durationMs)
        assertTrue(asked.none { it.requestUrl!!.encodedPath == "/split/other.m3u8" })
        first.close()
        site.shutdown()

        val restored = manager()
        assertNotNull(restored.offlinePlay(PlayRequest("s", "线路", episode)))
        val base = "http://engine/dl/$id/"
        val master = restored.offlinePlaylist(id, base)!!
        assertTrue(master.contains("URI=\"${base}audio.m3u8\""), master)
        assertTrue(master.lineSequence().any { it == "${base}video.m3u8" }, master)
        for (track in listOf("video", "audio")) {
            val playlist = restored.offlinePlaylist(id, base, "$track.m3u8")!!
            val uri = playlist.lines().single { it.startsWith(base) }
            assertArrayEquals(ts(track), restored.offlineFile(id, uri.removePrefix(base))!!.first.readBytes())
        }
        assertNull(restored.offlinePlaylist(id, base, "other.m3u8"))
        assertTrue(runCatching { restored.exportOf(id) }.exceptionOrNull()?.message.orEmpty().contains("独立音轨"))
    }

    @Test
    fun `a refused file switches to the freshly resolved HLS address and headers`(): Unit = runBlocking {
        val attempts = AtomicInteger()
        val manager = manager(resolver = {
            if (attempts.getAndIncrement() == 0) PlayInfo(kind = "direct", url = site.url("/expired.mp4").toString())
            else resolve(PlayRequest("s", "线路", "/film/index.m3u8?token={token}")).copy(headers = mapOf("Referer" to "https://episode.example/"))
        })
        val id = manager.add(listOf(request("/expired.mp4"))).single().id
        val done = manager.finished(id)
        assertEquals("done", done.state, done.error)
        assertEquals("hls", done.kind)
        assertEquals(2, attempts.get())
        assertEquals(1, asked.count { it.requestUrl!!.encodedPath == "/expired.mp4" })
        val hls = asked.filter { it.requestUrl!!.encodedPath.startsWith("/film/") }
        assertEquals(segments + 1, hls.size)
        assertTrue(hls.all { it.getHeader("Referer") == "https://episode.example/" })
    }

    @Test
    fun `an address that expired half way is resolved again, once`(): Unit = runBlocking {
        segmentDelayMs = 50
        val m = manager()
        val id = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        m.until(id) { it.partsDone >= 2 }
        token = "b"
        val done = m.finished(id)
        assertEquals("done", done.state, done.error)
        assertEquals(2, resolved.get())
        assertEquals(segments, store.names(streamDir().name).size)
    }

    @Test
    fun `a source that keeps refusing fails with the reason, and trying again resolves the episode anew`(): Unit = runBlocking {
        refused["/film/seg3.ts"] = 404
        val m = manager()
        val id = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        val failed = m.finished(id)
        assertEquals("failed", failed.state)
        assertTrue(failed.error.contains("HTTP 404"), failed.error)
        assertEquals(2, resolved.get(), "resolved again before giving up")
        assertTrue(failed.partsDone < segments, "${failed.partsDone}")
        refused.clear()
        m.resume(id)
        assertEquals("done", m.finished(id).state)
        assertEquals(3, resolved.get())
    }

    @Test
    fun `lines that need sniffing on the client, a resolver that fails, and a full disk`(): Unit = runBlocking {
        val m = manager(free = 500)
        val sniff = m.add(listOf(request("sniff"))).single().id
        assertTrue(m.finished(sniff).error.contains("嗅探"))
        val full = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        val error = m.finished(full).error
        assertTrue(error.contains("磁盘空间不足"), error)
        assertTrue(segmentRequests().isEmpty())

        val broken = manager(stateFile = null, resolver = { throw IllegalStateException("站点挂了") })
        val id = broken.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        assertEquals("解析失败：站点挂了", broken.finished(id).error)
    }

    @Test
    fun `a download whose files were removed behind its back no longer plays offline`(): Unit = runBlocking {
        val m = manager()
        val id = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        assertEquals("done", m.finished(id).state)
        streamDir().listFiles()!!.first { it.name.startsWith("s") }.delete()
        assertNull(m.offlinePlay(PlayRequest("s", "线路", "/film/index.m3u8?token={token}")))
        assertEquals("failed", m.get(id).state)
    }

    @Test
    fun `settings - another folder for new downloads`(): Unit = runBlocking {
        val m = manager()
        val other = File(dir, "elsewhere")
        val info = m.updateSettings(DownloadSettingsUpdate(dir = other.absolutePath))
        assertEquals(other.absolutePath, info.path)
        assertEquals(store.root.absolutePath, info.defaultPath)
        val id = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        assertEquals("done", m.finished(id).state)
        assertEquals(segments, streamDir(other).listFiles()!!.count { it.name.startsWith("s") })
        assertEquals(0L, store.stats().pinnedBytes)
        assertNotNull(m.offlinePlay(PlayRequest("s", "线路", "/film/index.m3u8?token={token}")))
        assertTrue(runCatching { m.updateSettings(DownloadSettingsUpdate(dir = "relative/path")) }.isFailure)
        assertEquals(store.root.absolutePath, m.updateSettings(DownloadSettingsUpdate(dir = "")).path)
    }

    @Test
    fun `a device without folders of its own - locations to choose from, and exports handed to the system`(): Unit = runBlocking {
        val card = File(dir, "card").also { it.mkdirs() }
        val published = ArrayList<String>()
        val m = DownloadManager(
            OkHttpClient(), store, File(dir, "downloads.json"), resolver = { resolve(it) }, localBase = "http://127.0.0.1:1",
            exportDir = { File(dir, "exports") }, reserveBytes = 1_000, freeSpace = { 5_000_000 },
            locations = {
                listOf(
                    DownloadLocation("内部存储", "", store.root.absolutePath, freeBytes = 5_000_000),
                    DownloadLocation("SD 卡", card.absolutePath, card.absolutePath, freeBytes = 1_000, removable = true),
                )
            },
            publish = { export ->
                val out = java.io.ByteArrayOutputStream()
                val bytes = export.write(out)
                published += export.fileName
                DownloadExportResult("Download/映舟/${export.fileName}", bytes, export.format, uri = "content://media/downloads/1")
            },
        ).also { managers += it; it.start() }
        val info = m.settings()
        assertEquals(listOf("内部存储", "SD 卡"), info.locations.map { it.name })
        assertTrue(info.locations[1].removable)
        // Choosing a location is choosing its folder.
        assertEquals(card.absolutePath, m.updateSettings(DownloadSettingsUpdate(dir = info.locations[1].dir)).path)
        assertEquals(store.root.absolutePath, m.updateSettings(DownloadSettingsUpdate(dir = info.locations[0].dir)).path)

        val id = m.add(listOf(request("/film/index.m3u8?token={token}"))).single().id
        assertEquals("done", m.finished(id).state)
        // No path: the system gets it; a path still writes the file there.
        val shared = m.export(id)
        assertEquals("content://media/downloads/1", shared.uri)
        assertEquals("Download/映舟/" + published.single(), shared.path)
        assertTrue(published.single().startsWith("片名") && published.single().endsWith(".ts"))
        assertEquals(film.sumOf { it.size }.toLong(), shared.bytes)
        assertFalse(File(dir, "exports").exists(), "nothing written into a folder of the engine's own")
        val folder = File(dir, "out").also { it.mkdirs() }
        val file = m.export(id, folder.absolutePath)
        assertEquals("", file.uri)
        assertTrue(File(file.path).isFile)
    }

    /** The folder of the one download in the store at [root] (for looking at its files). */
    private fun streamDir(root: File = store.root): File = root.listFiles()!!.single { it.isDirectory && it.name != "watched" }
}
