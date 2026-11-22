package tvbox.engine.api

import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.client.statement.readRawBytes
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
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
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.cache.StreamCache
import tvbox.engine.core.cache.StreamStore
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore
import java.io.File
import java.net.URLEncoder
import java.util.concurrent.CopyOnWriteArrayList

/** The stream cache through the engine's HTTP API, against a site that serves one film as HLS. */
class StreamCacheRoutesTest {
    @TempDir
    lateinit var dir: File

    private val site = MockWebServer()
    private val asked = CopyOnWriteArrayList<String>()
    private lateinit var cache: StreamCache

    @Volatile private var refuseSegments = false

    private fun bytes(name: String) = ByteArray(40_000) { i -> (name.hashCode() + i * 7).toByte() }

    private val film = buildString {
        appendLine("#EXTM3U")
        appendLine("#EXT-X-TARGETDURATION:10")
        for (i in 0 until 10) appendLine("#EXTINF:10.0,").appendLine("seg$i.ts?token=abc")
        // An ad the config's rule removes.
        appendLine("#EXT-X-DISCONTINUITY")
        appendLine("#EXTINF:7.5,").appendLine("/ads/ad/1.ts")
        appendLine("#EXTINF:7.6666,").appendLine("/ads/ad/2.ts")
        appendLine("#EXT-X-DISCONTINUITY")
        for (i in 10 until 20) appendLine("#EXTINF:10.0,").appendLine("seg$i.ts?token=abc")
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
                    path == "/api" -> MockResponse().setBody("""{"list":[{"vod_id":7,"vod_name":"片名","vod_play_from":"线路","vod_play_url":"第1集${'$'}${site.url("/ads/index.m3u8")}"}]}""")
                    path == "/ads/index.m3u8" -> MockResponse().setBody(film)
                    path == "/ads/master.m3u8" -> MockResponse().setBody("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nindex.m3u8\n")
                    path == "/ads/live.m3u8" -> MockResponse().setBody("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\nlive1.ts\n#EXTINF:10.0,\nlive2.ts\n")
                    path.endsWith(".ts") && refuseSegments -> MockResponse().setResponseCode(403)
                    path.endsWith(".ts") -> MockResponse().setHeader("Content-Type", "video/mp2t").setBody(Buffer().write(bytes(path.substringAfterLast('/'))))
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
        cache.close()
        site.shutdown()
    }

    /** LAN sharing is on and one device ("tv") is paired; [token] is its token. */
    private val access = tvbox.engine.api.access.AccessControl(MemoryStore(), supported = true).also { it.setSharing(true) }
    private val token = (access.pair(access.newCode().code, "tv", "x") as tvbox.engine.api.access.AccessControl.PairResult.Paired).token

    /** An engine with the stream cache and the site's config loaded. The engine's own urls use port 80, the test host's. */
    private fun withEngine(block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        application {
            engineModule(
                Engine(
                    EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
                    ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
                    SiteHttp(OkHttpClient()),
                    proxyBase = "http://127.0.0.1:80/proxy?",
                    store = MemoryStore(),
                    streamCache = cache,
                ),
                EngineModuleOptions(access = access),
            )
        }
        val created = client.post("/api/v1/subscriptions") {
            contentType(ContentType.Application.Json)
            setBody("""{"url":"${site.url("/tv.json")}"}""")
        }
        val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
        client.post("/api/v1/subscriptions/$id/activate")
        block()
    }

    private suspend fun ApplicationTestBuilder.json(path: String): JsonObject = EngineJson.parseToJsonElement(client.get(path).bodyAsText()).jsonObject

    private suspend fun ApplicationTestBuilder.resolve(host: String? = null, direct: Boolean = false): JsonObject = EngineJson.parseToJsonElement(
        client.post("/api/v1/play/resolve") {
            contentType(ContentType.Application.Json)
            if (host != null) {
                header(HttpHeaders.Host, host)
                header(HttpHeaders.Authorization, "Bearer $token")
            }
            setBody("""{"site":"cms","line":"线路","episodeId":"${site.url("/ads/index.m3u8")}","direct":$direct}""")
        }.bodyAsText(),
    ).jsonObject

    /** The path and query of an engine url, for the test client. */
    private fun local(url: String) = "/" + url.substringAfter("://").substringAfter('/')

    /** An engine url without the signature the engine adds for whoever asked (see AccessPlugin). */
    private fun unsigned(url: String) = url.replace(Regex("[&?]tvsig=[^&\\s]*"), "")

    private fun segments(playlist: String) = playlist.lines().filter { it.startsWith("http") }

    @Test
    fun `a resolved film plays from the cache - playlist, segments, coverage, emptying`() = withEngine {
        val info = resolve()
        val key = info["cache"]!!.jsonPrimitive.content
        val url = info["url"]!!.jsonPrimitive.content
        assertEquals(16, key.length)
        assertTrue(url.startsWith("http://127.0.0.1:80/m3u8?url=") && unsigned(url).endsWith("&k=$key"), url)

        val playlist = client.get(local(url)).bodyAsText()
        val lines = segments(playlist)
        assertEquals(20, lines.size, "the ad is gone and every segment is the engine's: $playlist")
        assertTrue(lines.all { Regex("http://127\\.0\\.0\\.1:80/hls/[0-9a-f]+-[0-9a-f]+/\\d+\\.ts").matches(unsigned(it)) }, playlist)
        assertFalse(playlist.contains("token=abc") || playlist.contains(":${site.port}"), "nothing of the source is left in it")

        // A segment comes from the source once, then from the store; a range of it can be asked for.
        val first = client.get(local(lines[3]))
        assertEquals(HttpStatusCode.OK, first.status)
        assertArrayEquals(bytes("seg3.ts"), first.readRawBytes())
        repeat(250) { if (cache.store.stats().files < 1) delay(20) }
        val again = client.get(local(lines[3]))
        assertEquals("video/mp2t", again.headers[HttpHeaders.ContentType])
        assertArrayEquals(bytes("seg3.ts"), again.readRawBytes())
        assertEquals(1, asked.count { it == "/ads/seg3.ts" })
        val part = client.get(local(lines[3])) { header(HttpHeaders.Range, "bytes=100-299") }
        assertEquals(HttpStatusCode.PartialContent, part.status)
        assertEquals("bytes 100-299/40000", part.headers[HttpHeaders.ContentRange])
        assertArrayEquals(bytes("seg3.ts").copyOfRange(100, 300), part.readRawBytes())
        assertEquals(HttpStatusCode.RequestedRangeNotSatisfiable, client.get(local(lines[3])) { header(HttpHeaders.Range, "bytes=50000-") }.status)

        val stats = json("/api/v1/stream-cache")
        assertEquals("true", stats["available"]!!.jsonPrimitive.content)
        assertEquals("40000", stats["bytes"]!!.jsonPrimitive.content)
        assertEquals("1", stats["streams"]!!.jsonPrimitive.content)
        val coverage = json("/api/v1/stream-cache/coverage?key=$key")
        assertEquals("200000", coverage["durationMs"]!!.jsonPrimitive.content)
        assertEquals("[[30000,40000]]", coverage["ranges"].toString())
        assertEquals("[]", json("/api/v1/stream-cache/coverage?key=nobody")["ranges"].toString())

        val emptied = EngineJson.parseToJsonElement(client.delete("/api/v1/stream-cache").bodyAsText()).jsonObject
        assertEquals("0", emptied["bytes"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.NotFound, client.get("/hls/nonsense-0/1.ts").status)
    }

    @Test
    fun `a device on the LAN gets the cache under the address it reached the engine by`() = withEngine {
        val info = resolve(host = "192.168.1.5:9978")
        val url = info["url"]!!.jsonPrimitive.content
        assertTrue(url.startsWith("http://192.168.1.5:9978/m3u8?url="), url)
        assertTrue(url.contains("tvsig="), "a player on the LAN gets a signed address: $url")
        // The player sends no token, only the signed address.
        val playlist = client.get(local(url)) { header(HttpHeaders.Host, "192.168.1.5:9978") }.bodyAsText()
        assertTrue(segments(playlist).isNotEmpty() && segments(playlist).all { it.startsWith("http://192.168.1.5:9978/hls/") && it.contains("tvsig=") }, playlist)
        val segment = client.get(local(segments(playlist).first())) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.OK, segment.status, "a signed segment address works without a token")
        val unsignedSegment = client.get(local(unsigned(segments(playlist).first()))) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.Unauthorized, unsignedSegment.status, "without the signature a LAN player gets nothing")
        // The same film asked for on the machine itself is the same playlist under the local address.
        val own = client.get(local(url)).bodyAsText()
        assertEquals(unsigned(playlist).replace("192.168.1.5:9978", "127.0.0.1:80"), unsigned(own))
    }

    @Test
    fun `the variants of a master playlist carry the film's key, and live playlists are not cached`() = withEngine {
        val master = client.get("/m3u8?url=" + URLEncoder.encode(site.url("/ads/master.m3u8").toString(), "UTF-8") + "&k=abc123").bodyAsText()
        val variant = master.lines().single { it.startsWith("http") }
        assertTrue(variant.startsWith("http://127.0.0.1:80/m3u8?url=") && unsigned(variant).endsWith("&k=abc123"), master)
        val media = client.get(local(variant)).bodyAsText()
        assertTrue(segments(media).all { it.contains("/hls/") }, media)
        client.get(local(segments(media).first())).readRawBytes()
        kotlinx.coroutines.withTimeout(5_000) {
            while (json("/api/v1/stream-cache/coverage?key=abc123")["ranges"].toString() != "[[0,10000]]") delay(20)
        }

        val live = client.get("/m3u8?url=" + URLEncoder.encode(site.url("/ads/live.m3u8").toString(), "UTF-8")).bodyAsText()
        assertTrue(segments(live).all { it.startsWith(site.url("/ads/").toString()) }, live)
    }

    @Test
    fun `settings are changed one at a time, and switching the cache off leaves the source's own addresses`() = withEngine {
        val before = json("/api/v1/settings")
        assertEquals("[]", before["proxyScopes"].toString())
        assertEquals("true", before["streamCache"]!!.jsonPrimitive.content)
        assertEquals("2048", before["streamCacheMaxMB"]!!.jsonPrimitive.content)

        val sized = EngineJson.parseToJsonElement(client.put("/api/v1/settings") {
            contentType(ContentType.Application.Json)
            setBody("""{"streamCacheMaxMB":5120,"httpProxy":"http://localhost:7890/","proxyScopes":["config"]}""")
        }.bodyAsText()).jsonObject
        assertEquals("5120", sized["streamCacheMaxMB"]!!.jsonPrimitive.content)
        assertEquals(before["githubProxyPrefix"], sized["githubProxyPrefix"], "what was not sent stays")
        assertEquals(5120L * 1024 * 1024, cache.store.maxBytes)
        // A client that knows nothing of the cache saves its own settings: the cache's stay.
        val other = EngineJson.parseToJsonElement(client.put("/api/v1/settings") {
            contentType(ContentType.Application.Json)
            setBody("""{"githubProxy":true,"githubProxyPrefix":"https://my.proxy.test/"}""")
        }.bodyAsText()).jsonObject
        assertEquals("5120", other["streamCacheMaxMB"]!!.jsonPrimitive.content)
        assertEquals("true", other["githubProxy"]!!.jsonPrimitive.content)
        assertEquals("localhost:7890", other["httpProxy"]!!.jsonPrimitive.content)
        assertEquals("[\"config\"]", other["proxyScopes"].toString())
        // Sizes out of all proportion are brought back into range.
        val tiny = EngineJson.parseToJsonElement(client.put("/api/v1/settings") {
            contentType(ContentType.Application.Json)
            setBody("""{"streamCacheMaxMB":1,"githubProxy":false}""")
        }.bodyAsText()).jsonObject
        assertEquals("200", tiny["streamCacheMaxMB"]!!.jsonPrimitive.content)

        val playlistUrl = local(resolve()["url"]!!.jsonPrimitive.content)
        val cached = segments(client.get(playlistUrl).bodyAsText())
        client.put("/api/v1/settings") {
            contentType(ContentType.Application.Json)
            setBody("""{"streamCache":false}""")
        }
        val info = resolve()
        assertEquals("", info["cache"]!!.jsonPrimitive.content)
        assertFalse(info["url"]!!.jsonPrimitive.content.contains("&k="))
        val plain = client.get(local(info["url"]!!.jsonPrimitive.content)).bodyAsText()
        assertTrue(segments(plain).all { it.startsWith(site.url("/ads/seg").toString()) }, plain)
        // A player that still holds the earlier playlist is sent to the source.
        val late = createClient { followRedirects = false }.get(local(cached[5]))
        assertEquals(HttpStatusCode.Found, late.status)
        assertEquals(site.url("/ads/seg5.ts?token=abc").toString(), late.headers[HttpHeaders.Location])
        assertEquals("false", json("/api/v1/stream-cache")["enabled"]!!.jsonPrimitive.content)
    }

    @Test
    fun `a source that refuses the engine - the player is sent to the source`() = withEngine {
        val lines = segments(client.get(local(resolve()["url"]!!.jsonPrimitive.content)).bodyAsText())
        refuseSegments = true
        val answer = createClient { followRedirects = false }.get(local(lines[0]))
        assertEquals(HttpStatusCode.Found, answer.status)
        assertEquals(site.url("/ads/seg0.ts?token=abc").toString(), answer.headers[HttpHeaders.Location])
    }

    @Test
    fun `an engine without a stream cache says so and hands out playlists as before`() = testApplication {
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
        assertEquals("false", EngineJson.parseToJsonElement(client.get("/api/v1/stream-cache").bodyAsText()).jsonObject["available"]!!.jsonPrimitive.content)
        val playlist = client.get("/m3u8?url=" + URLEncoder.encode(site.url("/ads/index.m3u8").toString(), "UTF-8")).bodyAsText()
        assertTrue(segments(playlist).all { it.startsWith(site.url("/ads/").toString()) }, playlist)
        assertEquals(HttpStatusCode.NotFound, client.get("/hls/x-y/0.ts").status)
        assertEquals(0, EngineJson.parseToJsonElement(client.get("/api/v1/stream-cache/coverage?key=k").bodyAsText()).jsonObject["ranges"]!!.jsonArray.size)
    }

    @Test
    fun `a direct request leaves the segments at the source, with the cached address to fall back to`() = withEngine {
        val info = resolve(host = "192.168.1.5:9978", direct = true)
        val url = info["url"]!!.jsonPrimitive.content
        val relay = info["relay"]!!.jsonPrimitive.content
        val key = info["cache"]!!.jsonPrimitive.content
        assertTrue(unsigned(url).endsWith("&d=1") && !url.contains("&k="), url)
        assertTrue(url.contains("tvsig=") && relay.contains("tvsig="), "both are signed for the LAN player: $url / $relay")
        assertTrue(relay.startsWith("http://192.168.1.5:9978/m3u8?url=") && unsigned(relay).endsWith("&k=$key"), relay)

        // The playlist is still cleaned here; its segments are the source's own.
        val playlist = client.get(local(url)) { header(HttpHeaders.Host, "192.168.1.5:9978") }.bodyAsText()
        assertEquals(20, segments(playlist).size, "the ad is gone: $playlist")
        assertTrue(segments(playlist).all { it.startsWith(site.url("/ads/seg").toString()) && it.contains("token=abc") }, playlist)
        assertEquals(0, cache.store.stats().streams, "nothing went into the stream cache")

        // A master playlist passes the mark on to its variants.
        val master = client.get("/m3u8?url=" + URLEncoder.encode(site.url("/ads/master.m3u8").toString(), "UTF-8") + "&d=1").bodyAsText()
        val variant = master.lines().single { it.startsWith("http") }
        assertTrue(unsigned(variant).endsWith("&d=1"), master)
        assertTrue(segments(client.get(local(variant)).bodyAsText()).all { it.startsWith(site.url("/ads/").toString()) })

        // The fallback plays from the cache as before.
        val relayed = client.get(local(relay)) { header(HttpHeaders.Host, "192.168.1.5:9978") }.bodyAsText()
        assertTrue(segments(relayed).all { it.startsWith("http://192.168.1.5:9978/hls/") }, relayed)

        // With the cache off there is nothing to fall back to: the direct address is all there is.
        client.put("/api/v1/settings") {
            contentType(ContentType.Application.Json)
            setBody("""{"streamCache":false}""")
        }
        val off = resolve(direct = true)
        assertEquals("", off["relay"]!!.jsonPrimitive.content)
        assertEquals("", off["cache"]!!.jsonPrimitive.content)
        assertTrue(unsigned(off["url"]!!.jsonPrimitive.content).endsWith("&d=1"))
    }
}
