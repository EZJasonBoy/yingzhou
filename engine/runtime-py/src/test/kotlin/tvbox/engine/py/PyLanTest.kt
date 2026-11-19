package tvbox.engine.py

import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.api.EngineJson
import tvbox.engine.api.EngineModuleOptions
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.engineModule
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore
import java.io.File

/**
 * A paired LAN device plays a Python spider's proxied line: the play answer it gets carries a signed address on the
 * engine's LAN name, and its player (which has no token) can open it; the spider's localProxy answers.
 */
class PyLanTest {
    @TempDir
    lateinit var dir: File

    private val lanHost = "192.168.1.5:9978"

    @Test
    fun `a paired device's player opens a python spider's proxy address with the signature alone`() {
        val manager = PythonManager(File(dir, "python"), OkHttpClient(), embedded = null).also { it.relocate() }
        assumeTrue(manager.current() != null, "no Python 3.8+ found (set TVBOX_PYTHON): skipped")
        val upstream = MockWebServer()
        upstream.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/tv.json" -> MockResponse().setBody("""{"sites":[{"key":"pyvod","name":"Py","type":3,"api":"${upstream.url("/vod.py")}","ext":{"api":"x"}}]}""")
                "/vod.py" -> MockResponse().setBody(PyLanTest::class.java.getResourceAsStream("/py/vod.py")!!.readBytes().toString(Charsets.UTF_8))
                else -> MockResponse().setResponseCode(404)
            }
        }
        upstream.start()
        val http = OkHttpClient()
        val locator = ConfigLocator("http://127.0.0.1:80/file/")
        val runtime = PyRuntime(manager, PyScripts(http, locator, File(dir, "spiders")), "http://127.0.0.1:80/proxy")
        try {
            val engine = Engine(
                EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
                ConfigLoader(http, locator),
                SiteHttp(http),
                proxyBase = "http://127.0.0.1:80/proxy?",
                runtimes = listOf(runtime),
            )
            val access = AccessControl(MemoryStore(), supported = true).also { it.setSharing(true) }
            testApplication {
                application { engineModule(engine, EngineModuleOptions(access = access)) }
                val created = client.post("/api/v1/subscriptions") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"url":"${upstream.url("/tv.json")}"}""")
                }
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
                client.post("/api/v1/subscriptions/$id/activate")

                val pair = client.post("/api/v1/pair") {
                    header(HttpHeaders.Host, lanHost)
                    contentType(ContentType.Application.Json)
                    setBody("""{"code":"${access.codeOrNew().code}","name":"客厅电视"}""")
                }
                val token = EngineJson.parseToJsonElement(pair.bodyAsText()).jsonObject["token"]!!.jsonPrimitive.content

                // The device sees the Python site and resolves its proxied line.
                val sites = EngineJson.parseToJsonElement(client.get("/api/v1/sites") {
                    header(HttpHeaders.Host, lanHost)
                    header(HttpHeaders.Authorization, "Bearer $token")
                }.bodyAsText()).jsonArray
                assertEquals("py", sites.single().jsonObject["runtime"]!!.jsonPrimitive.content)
                val play = EngineJson.parseToJsonElement(client.post("/api/v1/play/resolve") {
                    header(HttpHeaders.Host, lanHost)
                    header(HttpHeaders.Authorization, "Bearer $token")
                    contentType(ContentType.Application.Json)
                    setBody("""{"site":"pyvod","line":"代理","episodeId":"e7"}""")
                }.bodyAsText()).jsonObject
                val url = play["url"]!!.jsonPrimitive.content
                assertTrue(url.startsWith("http://$lanHost/proxy?do=py&siteKey=pyvod&id=e7") && "tvsig=" in url, url)

                // Its player has no token: the signature is enough.
                val media = client.get(url.removePrefix("http://$lanHost")) { header(HttpHeaders.Host, lanHost) }
                assertEquals(HttpStatusCode.OK, media.status, media.bodyAsText())
                assertEquals("proxied e7 by pyvod", media.bodyAsText())
                // Without the signature it is refused.
                val unsigned = client.get(url.removePrefix("http://$lanHost").substringBefore("&tvsig=")) { header(HttpHeaders.Host, lanHost) }
                assertEquals(HttpStatusCode.Unauthorized, unsigned.status)
            }
        } finally {
            runtime.close()
            upstream.shutdown()
        }
    }
}
