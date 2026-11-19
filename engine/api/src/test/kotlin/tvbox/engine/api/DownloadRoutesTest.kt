package tvbox.engine.api

import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.prepareGet
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsChannel
import io.ktor.client.statement.bodyAsText
import io.ktor.client.statement.readRawBytes
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import io.ktor.utils.io.readUTF8Line
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.cache.StreamCache
import tvbox.engine.core.cache.StreamStore
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.download.DownloadManager
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/** Downloads through the engine's HTTP API: a site with a film as HLS (with an ad the config removes) and a live list. */
class DownloadRoutesTest {
    @TempDir
    lateinit var dir: File

    private val site = MockWebServer()
    private val asked = CopyOnWriteArrayList<String>()
    private lateinit var cache: StreamCache
    private lateinit var downloads: DownloadManager

    private fun ts(name: String) = ByteArray(40_000) { i -> if (i % 188 == 0) 0x47 else (name.hashCode() + i * 7).toByte() }

    private val film = buildString {
        appendLine("#EXTM3U")
        appendLine("#EXT-X-TARGETDURATION:10")
        for (i in 0 until 6) appendLine("#EXTINF:10.0,").appendLine("seg$i.ts?token=abc")
        appendLine("#EXT-X-DISCONTINUITY")
        appendLine("#EXTINF:7.5,").appendLine("/ads/ad/1.ts")
        appendLine("#EXTINF:7.6666,").appendLine("/ads/ad/2.ts")
        appendLine("#EXT-X-DISCONTINUITY")
        for (i in 6 until 12) appendLine("#EXTINF:10.0,").appendLine("seg$i.ts?token=abc")
        appendLine("#EXT-X-ENDLIST")
    }

    @BeforeEach
    fun start() {
        site.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl!!.encodedPath
                asked += path
                return when {
                    path == "/tv.json" -> MockResponse().setBody(
                        """{"sites":[{"key":"cms","type":1,"api":"${site.url("/api")}"}],"rules":[{"name":"ad","hosts":["/ads/"],"regex":["15.1666"]}]}""",
                    )
                    path == "/api" -> MockResponse().setBody(
                        """{"list":[{"vod_id":7,"vod_name":"片名","vod_play_from":"线路","vod_play_url":"第1集${'$'}${site.url("/ads/index.m3u8")}#直播${'$'}${site.url("/ads/live.m3u8")}"}]}""",
                    )
                    path == "/ads/index.m3u8" -> MockResponse().setBody(film)
                    path == "/ads/live.m3u8" -> MockResponse().setBody("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\nlive1.ts\n")
                    path.endsWith(".ts") && path.startsWith("/ads/seg") -> MockResponse().setHeader("Content-Type", "video/mp2t").setBody(Buffer().write(ts(path.substringAfterLast('/'))))
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        site.start()
        cache = StreamCache(OkHttpClient(), StreamStore(File(dir, "stream")))
        cache.aheadMs = 0
    }

    @AfterEach
    fun stop() {
        downloads.close()
        cache.close()
        runCatching { site.shutdown() }
    }

    private val access = tvbox.engine.api.access.AccessControl(MemoryStore(), supported = true).also { it.setSharing(true) }
    private val token = (access.pair(access.newCode().code, "tv", "x") as tvbox.engine.api.access.AccessControl.PairResult.Paired).token

    private fun withEngine(block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        val engine = Engine(
            EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
            ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
            SiteHttp(OkHttpClient()),
            proxyBase = "http://127.0.0.1:80/proxy?",
            store = MemoryStore(),
            streamCache = cache,
        )
        downloads = DownloadManager(
            OkHttpClient(), cache.store, File(dir, "downloads.json"), resolver = { engine.resolvePlay(it) }, cleaner = engine::cleanPlaylist,
            localBase = "http://127.0.0.1:80", exportDir = { File(dir, "exports") }, reserveBytes = 0,
        )
        engine.downloads = downloads
        downloads.start()
        application { engineModule(engine, EngineModuleOptions(access = access)) }
        val created = client.post("/api/v1/subscriptions") {
            contentType(ContentType.Application.Json)
            setBody("""{"url":"${site.url("/tv.json")}"}""")
        }
        val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
        client.post("/api/v1/subscriptions/$id/activate")
        block()
    }

    private suspend fun ApplicationTestBuilder.json(path: String): JsonObject = EngineJson.parseToJsonElement(client.get(path).bodyAsText()).jsonObject

    private suspend fun ApplicationTestBuilder.add(episode: String, name: String): JsonObject = EngineJson.parseToJsonElement(
        client.post("/api/v1/downloads") {
            contentType(ContentType.Application.Json)
            setBody("""{"items":[{"site":"cms","line":"线路","episodeId":"${site.url(episode)}","vodId":"7","title":"片名","episodeName":"$name"}]}""")
        }.bodyAsText(),
    ).jsonObject["items"]!!.jsonArray.single().jsonObject

    private suspend fun ApplicationTestBuilder.waitFor(id: String): JsonObject {
        repeat(500) {
            val item = json("/api/v1/downloads")["items"]!!.jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == id }
            if (item["state"]!!.jsonPrimitive.content in setOf("done", "failed")) return item
            delay(20)
        }
        throw AssertionError("the download did not end")
    }

    private suspend fun ApplicationTestBuilder.resolve(episode: String, host: String? = null): JsonObject = EngineJson.parseToJsonElement(
        client.post("/api/v1/play/resolve") {
            contentType(ContentType.Application.Json)
            if (host != null) {
                header(HttpHeaders.Host, host)
                header(HttpHeaders.Authorization, "Bearer $token")
            }
            setBody("""{"site":"cms","line":"线路","episodeId":"${site.url(episode)}"}""")
        }.bodyAsText(),
    ).jsonObject

    private fun local(url: String) = "/" + url.substringAfter("://").substringAfter('/')

    private fun unsigned(url: String) = url.replace(Regex("[&?]tvsig=[^&\\s\"]*"), "")

    private fun addresses(playlist: String) = playlist.lines().filter { it.startsWith("http") }

    @Test
    fun `an episode is downloaded through the API and then plays with the site gone`() = withEngine {
        assertEquals("true", json("/api/v1/downloads")["available"]!!.jsonPrimitive.content)
        val item = add("/ads/index.m3u8", "第1集")
        val id = item["id"]!!.jsonPrimitive.content
        assertEquals("第1集", item["episodeName"]!!.jsonPrimitive.content)
        val done = waitFor(id)
        assertEquals("done", done["state"]!!.jsonPrimitive.content, done.toString())
        assertEquals("12", done["parts"]!!.jsonPrimitive.content, "the ad was left out, as when playing")
        assertTrue(asked.none { it.startsWith("/ads/ad/") })
        // Kept in the stream cache's folder, pinned, and counted apart from the cache.
        val stats = json("/api/v1/stream-cache")
        assertEquals("0", stats["bytes"]!!.jsonPrimitive.content)
        assertEquals((12 * 40_000).toString(), stats["pinnedBytes"]!!.jsonPrimitive.content)

        site.shutdown()
        val info = resolve("/ads/index.m3u8")
        assertEquals(id, info["download"]!!.jsonPrimitive.content)
        val url = info["url"]!!.jsonPrimitive.content
        assertEquals("http://127.0.0.1:80/dl/$id/index.m3u8", unsigned(url))
        val playlist = client.get(local(url)).bodyAsText()
        val segments = addresses(playlist)
        assertEquals(12, segments.size, playlist)
        assertTrue(segments.all { unsigned(it).startsWith("http://127.0.0.1:80/dl/$id/") }, playlist)
        assertArrayEquals(ts("seg7.ts"), client.get(local(segments[7])).readRawBytes())
        val part = client.get(local(segments[2])) { header(HttpHeaders.Range, "bytes=10-19") }
        assertEquals(HttpStatusCode.PartialContent, part.status)
        assertArrayEquals(ts("seg2.ts").copyOfRange(10, 20), part.readRawBytes())

        // The whole episode as one file, to save on another device.
        val export = client.get("/dl/$id/export")
        assertEquals(HttpStatusCode.OK, export.status)
        assertTrue(export.headers[HttpHeaders.ContentDisposition]!!.contains("filename*=UTF-8''%E7%89%87%E5%90%8D%20%E7%AC%AC1%E9%9B%86.ts"), export.headers[HttpHeaders.ContentDisposition])
        assertArrayEquals((0 until 12).map { ts("seg$it.ts") }.reduce { a, b -> a + b }, export.readRawBytes())
        // ... or written on the engine's machine.
        val written = EngineJson.parseToJsonElement(client.post("/api/v1/downloads/$id/export") {
            contentType(ContentType.Application.Json)
            setBody("""{"path":"${File(dir, "out").absolutePath.replace("\\", "\\\\")}"}""")
        }.bodyAsText()).jsonObject
        assertEquals(File(File(dir, "out"), "片名 第1集.ts").absolutePath, written["path"]!!.jsonPrimitive.content)
        assertEquals("480000", written["bytes"]!!.jsonPrimitive.content)

        assertEquals(HttpStatusCode.NoContent, client.delete("/api/v1/downloads/$id").status)
        assertEquals(0, json("/api/v1/downloads")["items"]!!.jsonArray.size)
        assertEquals(HttpStatusCode.NotFound, client.get(local(url)).status)
        assertEquals("0", json("/api/v1/stream-cache")["pinnedBytes"]!!.jsonPrimitive.content)
    }

    @Test
    fun `a paired device on the LAN plays the download through signed addresses`() = withEngine {
        val id = add("/ads/index.m3u8", "第1集")["id"]!!.jsonPrimitive.content
        assertEquals("done", waitFor(id)["state"]!!.jsonPrimitive.content)
        val info = resolve("/ads/index.m3u8", host = "192.168.1.5:9978")
        val url = info["url"]!!.jsonPrimitive.content
        assertTrue(url.startsWith("http://192.168.1.5:9978/dl/$id/index.m3u8?tvsig="), url)
        // The player sends no token, only the signed address.
        val playlist = client.get(local(url)) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.OK, playlist.status)
        val segments = addresses(playlist.bodyAsText())
        assertTrue(segments.isNotEmpty() && segments.all { it.startsWith("http://192.168.1.5:9978/dl/$id/") && it.contains("tvsig=") }, segments.toString())
        val segment = client.get(local(segments[0])) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.OK, segment.status, "a signed address works without a token")
        assertArrayEquals(ts("seg0.ts"), segment.readRawBytes())
        assertEquals(HttpStatusCode.Unauthorized, client.get(local(unsigned(segments[0]))) { header(HttpHeaders.Host, "192.168.1.5:9978") }.status)
        assertEquals(HttpStatusCode.Unauthorized, client.get(local(unsigned(url))) { header(HttpHeaders.Host, "192.168.1.5:9978") }.status)
        // A signature is for that address only.
        val other = segments[1].substringBefore('?') + "?" + segments[0].substringAfter('?')
        assertEquals(HttpStatusCode.Unauthorized, client.get(local(other)) { header(HttpHeaders.Host, "192.168.1.5:9978") }.status)
        // The API wants the token like every other.
        assertEquals(HttpStatusCode.Unauthorized, client.get("/api/v1/downloads") { header(HttpHeaders.Host, "192.168.1.5:9978") }.status)
        val listed = client.get("/api/v1/downloads") {
            header(HttpHeaders.Host, "192.168.1.5:9978")
            header(HttpHeaders.Authorization, "Bearer $token")
        }
        assertEquals(HttpStatusCode.OK, listed.status)
        // The export can be fetched with the token, from another device.
        val export = client.get("/dl/$id/export") {
            header(HttpHeaders.Host, "192.168.1.5:9978")
            header(HttpHeaders.Authorization, "Bearer $token")
        }
        assertEquals(HttpStatusCode.OK, export.status)
        assertEquals(12 * 40_000, export.readRawBytes().size)
    }

    @Test
    fun `live streams are refused, settings, events, pause and resume`() = withEngine {
        val live = add("/ads/live.m3u8", "直播")
        val failed = waitFor(live["id"]!!.jsonPrimitive.content)
        assertEquals("failed", failed["state"]!!.jsonPrimitive.content)
        assertTrue(failed["error"]!!.jsonPrimitive.content.contains("直播"), failed.toString())
        val resumed = EngineJson.parseToJsonElement(client.post("/api/v1/downloads/${live["id"]!!.jsonPrimitive.content}/resume").bodyAsText()).jsonObject
        assertTrue(resumed["state"]!!.jsonPrimitive.content in setOf("queued", "running", "failed"))

        val settings = json("/api/v1/downloads/settings")
        assertEquals("true", settings["available"]!!.jsonPrimitive.content)
        assertEquals("2", settings["concurrency"]!!.jsonPrimitive.content)
        assertEquals(cache.store.root.absolutePath, settings["path"]!!.jsonPrimitive.content)
        assertTrue(settings["freeBytes"]!!.jsonPrimitive.content.toLong() > 0)
        val changed = EngineJson.parseToJsonElement(client.put("/api/v1/downloads/settings") {
            contentType(ContentType.Application.Json)
            setBody("""{"concurrency":3}""")
        }.bodyAsText()).jsonObject
        assertEquals("3", changed["concurrency"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.BadRequest, client.put("/api/v1/downloads/settings") {
            contentType(ContentType.Application.Json)
            setBody("""{"dir":"not/absolute"}""")
        }.status)

        // The list as events: the first one comes at once.
        val first = client.prepareGet("/api/v1/downloads/events").execute { response ->
            val channel = response.bodyAsChannel()
            listOf(channel.readUTF8Line(), channel.readUTF8Line())
        }
        assertEquals("event: downloads", first[0])
        assertTrue(first[1]!!.startsWith("data: {\"available\":true,\"items\":[{"), first[1])

        assertEquals(HttpStatusCode.NotFound, client.post("/api/v1/downloads/nonsense/pause").status)
        val id = add("/ads/index.m3u8", "第1集")["id"]!!.jsonPrimitive.content
        val paused = EngineJson.parseToJsonElement(client.post("/api/v1/downloads/$id/pause").bodyAsText()).jsonObject
        assertTrue(paused["state"]!!.jsonPrimitive.content in setOf("paused", "done"), paused.toString())
        client.post("/api/v1/downloads/$id/resume")
        assertEquals("done", waitFor(id)["state"]!!.jsonPrimitive.content)
    }

    @Test
    fun `an engine that does not download says so`() = testApplication {
        downloads = DownloadManager(OkHttpClient(), cache.store, null, resolver = { error("unused") }, localBase = "http://127.0.0.1:80")
        application {
            engineModule(
                Engine(
                    EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
                    ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
                    SiteHttp(OkHttpClient()),
                    proxyBase = "http://127.0.0.1:80/proxy?",
                ),
            )
        }
        assertEquals("false", EngineJson.parseToJsonElement(client.get("/api/v1/downloads").bodyAsText()).jsonObject["available"]!!.jsonPrimitive.content)
        assertEquals("false", EngineJson.parseToJsonElement(client.get("/api/v1/downloads/settings").bodyAsText()).jsonObject["available"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.NotImplemented, client.post("/api/v1/downloads") {
            contentType(ContentType.Application.Json)
            setBody("""{"items":[]}""")
        }.status)
        assertEquals(HttpStatusCode.NotFound, client.get("/dl/x/index.m3u8").status)
    }
}
