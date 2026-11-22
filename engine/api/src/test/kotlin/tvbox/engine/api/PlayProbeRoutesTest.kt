package tvbox.engine.api

import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.ConcurrentLinkedQueue

/** `POST /api/v1/play/probe` (线路体检) against a fake CMS site whose lines are served by a MockWebServer. */
class PlayProbeRoutesTest {
    private val upstream = MockWebServer()
    private val paths = ConcurrentLinkedQueue<String>()

    @BeforeEach
    fun start() {
        upstream.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl!!.encodedPath
                paths += path
                return when (path) {
                    "/tv.json" -> MockResponse().setBody("""{"sites":[{"key":"cms","name":"采集","type":1,"api":"${upstream.url("/api.php/provide/vod/")}"}]}""")
                    "/master.m3u8" -> MockResponse().setBody("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x720\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\nhigh.m3u8\n")
                    "/high.m3u8", "/low.m3u8" -> MockResponse().setBody("#EXTM3U\n#EXTINF:6,\nseg0.ts\n#EXT-X-ENDLIST\n")
                    "/seg0.ts" -> MockResponse().setBody(Buffer().write(ByteArray(128 * 1024)))
                    "/hang.m3u8" -> {
                        Thread.sleep(3_000)
                        MockResponse().setBody("#EXTM3U\n#EXTINF:6,\nseg0.ts\n#EXT-X-ENDLIST\n")
                    }
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        upstream.start()
    }

    @AfterEach
    fun stop() {
        upstream.shutdown()
    }

    private fun engine(port: Int = 9978) = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:$port/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:$port/proxy?",
    )

    private suspend fun activated(engine: Engine) = engine.also { it.activate(it.addSubscription(upstream.url("/tv.json").toString(), null).id) }

    /** The events of an SSE answer as (name, data) pairs. */
    private fun events(text: String): List<Pair<String, String>> = text.split("\n\n").filter { it.isNotBlank() }.mapNotNull { block ->
        val lines = block.lines()
        val name = lines.firstOrNull { it.startsWith("event: ") }?.removePrefix("event: ") ?: return@mapNotNull null
        name to lines.first { it.startsWith("data: ") }.removePrefix("data: ")
    }

    @Test
    fun `every line gets a line event as it finishes, then end`() {
        val engine = runBlocking { activated(engine()) }
        testApplication {
            application { engineModule(engine) }
            val response = client.post("/api/v1/play/probe") {
                contentType(ContentType.Application.Json)
                setBody(
                    """{"site":"cms","lines":[
                    |{"line":"高清","episodeId":"${upstream.url("/master.m3u8")}"},
                    |{"line":"失效","episodeId":"http://127.0.0.1:1/dead/1.m3u8"},
                    |{"line":"不存在","episodeId":"${upstream.url("/gone.m3u8")}"}],"direct":false}""".trimMargin(),
                )
            }
            assertEquals(HttpStatusCode.OK, response.status)
            assertTrue(response.headers["Content-Type"]!!.startsWith("text/event-stream"), response.headers.toString())
            val text = response.bodyAsText()
            val events = events(text)
            assertEquals(listOf("line", "line", "line", "end"), events.map { it.first }, text)
            assertEquals("{}", events.last().second)
            val lines = events.dropLast(1).map { EngineJson.parseToJsonElement(it.second).jsonObject }.associateBy { it.str("line") }

            val ok = lines.getValue("高清")
            assertEquals(0, ok["index"]!!.jsonPrimitive.int)
            assertEquals("ok", ok.str("state"))
            assertEquals("hls", ok.str("kind"))
            assertEquals(1920, ok["width"]!!.jsonPrimitive.int)
            assertEquals(1080, ok["height"]!!.jsonPrimitive.int)
            for (key in listOf("resolveMs", "firstByteMs", "bytesPerSecond")) assertTrue(key in ok, "$key in $ok")
            assertEquals("", ok.str("parsedBy"))
            assertEquals("", ok.str("reason"))
            // The engine's playlist address was looked into: its source was asked, highest variant first.
            assertTrue(paths.containsAll(listOf("/master.m3u8", "/high.m3u8", "/seg0.ts")), paths.toString())
            assertFalse("/low.m3u8" in paths)

            val dead = lines.getValue("失效")
            assertEquals(1, dead["index"]!!.jsonPrimitive.int)
            assertEquals("dead", dead.str("state"))
            assertEquals("连不上", dead.str("reason"))
            assertEquals("", dead.str("kind"))
            assertTrue("resolveMs" in dead)
            // Numbers it could not measure are left out, not 0.
            for (key in listOf("width", "height", "firstByteMs", "bytesPerSecond")) assertFalse(key in dead, "$key in $dead")
            assertEquals("404", lines.getValue("不存在").str("reason"))
        }
    }

    @Test
    fun `without a config or the site the probe is refused before it starts`() {
        testApplication {
            application { engineModule(engine()) }
            val none = client.post("/api/v1/play/probe") {
                contentType(ContentType.Application.Json)
                setBody("""{"site":"cms","lines":[]}""")
            }
            assertEquals(HttpStatusCode.Conflict, none.status)
        }
        val engine = runBlocking { activated(engine()) }
        testApplication {
            application { engineModule(engine) }
            val unknown = client.post("/api/v1/play/probe") {
                contentType(ContentType.Application.Json)
                setBody("""{"site":"nope","lines":[{"line":"一","episodeId":"x"}]}""")
            }
            assertEquals(HttpStatusCode.NotFound, unknown.status)
            val empty = client.post("/api/v1/play/probe") {
                contentType(ContentType.Application.Json)
                setBody("""{"site":"cms","lines":[]}""")
            }
            assertEquals(listOf("end"), events(empty.bodyAsText()).map { it.first })
        }
    }

    @Test
    fun `a client that goes away stops the probe, and no further line is fetched`() {
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val engine = runBlocking { activated(engine(port)) }
        val server = embeddedServer(CIO, port = port, host = "127.0.0.1") { engineModule(engine) }.start(wait = false)
        try {
            val lines = (1..6).joinToString(",") { """{"line":"线路$it","episodeId":"${upstream.url("/hang.m3u8?n=$it")}"}""" }
            val request = Request.Builder().url("http://127.0.0.1:$port/api/v1/play/probe")
                .post("""{"site":"cms","lines":[$lines]}""".toRequestBody("application/json".toMediaType())).build()
            val call = OkHttpClient().newCall(request)
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) = Unit
                override fun onResponse(call: Call, response: Response) = response.close()
            })
            val until = System.nanoTime() + 2_000_000_000L
            while (paths.count { it == "/hang.m3u8" } < 3 && System.nanoTime() < until) Thread.sleep(20)
            assertEquals(3, paths.count { it == "/hang.m3u8" }, "three lines at a time: $paths")
            call.cancel()
            // The first three answer after 3 s; had the probe gone on, the other three would be asked for then.
            Thread.sleep(4_000)
            assertEquals(3, paths.count { it == "/hang.m3u8" }, "nothing more after the client left: $paths")
        } finally {
            server.stop(100, 1_000)
        }
    }

    private fun JsonObject.str(key: String) = this[key]!!.jsonPrimitive.content
}
