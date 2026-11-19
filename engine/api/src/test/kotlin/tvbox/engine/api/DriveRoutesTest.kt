package tvbox.engine.api

import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.head
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.client.statement.readRawBytes
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.JsonArray
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
import tvbox.engine.api.access.AccessControl
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.drive.DriveService
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore
import java.io.File
import java.net.URLEncoder
import java.util.Base64

/** Drives through the engine's HTTP API: what clients see, what players fetch, and what devices on the LAN get. */
class DriveRoutesTest {
    @TempDir
    lateinit var dir: File

    private lateinit var folder: File
    private val dav = MockWebServer()

    /** Everything the engine answered in a test: no password or token may be in any of it. */
    private val answers = StringBuilder()

    private fun bytes(name: String, size: Int = 30_000) = ByteArray(size) { i -> (name.hashCode() + i * 13).toByte() }

    @BeforeEach
    fun start() {
        folder = File(dir, "片库").apply {
            File(this, "剧集").mkdirs()
            File(this, "剧集/第1集.mp4").writeBytes(bytes("1"))
            File(this, "剧集/第1集.srt").writeText("1\n00:00:01,000 --> 00:00:02,000\n你好\n")
            File(this, "剧集/第2集.mp4").writeBytes(bytes("2"))
        }
        // A WebDAV with an account: one video in its root.
        dav.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.getHeader("Authorization") != "Basic " + Base64.getEncoder().encodeToString("dav-user:dav-password".toByteArray())) {
                    return MockResponse().setResponseCode(401)
                }
                return when (request.method) {
                    "PROPFIND" -> MockResponse().setResponseCode(207).setBody(
                        """<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
                           <D:response><D:href>/dav/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
                           <D:response><D:href>/dav/film.mp4</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>30000</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
                           </D:multistatus>""",
                    )
                    "GET" -> MockResponse().setHeader("Content-Type", "video/mp4").setBody(Buffer().write(bytes("dav")))
                    else -> MockResponse().setResponseCode(405)
                }
            }
        }
        dav.start()
    }

    @AfterEach
    fun stop() = dav.shutdown()

    /** LAN sharing is on and one device ("tv") is paired; [token] is its token. */
    private val access = AccessControl(MemoryStore(), supported = true).also { it.setSharing(true) }
    private val token = (access.pair(access.newCode().code, "tv", "x") as AccessControl.PairResult.Paired).token

    /** The test host's port is 80: the engine's own addresses are on 127.0.0.1:80. */
    private fun withEngine(block: suspend ApplicationTestBuilder.() -> Unit) = testApplication {
        val store = MemoryStore()
        application {
            engineModule(
                Engine(
                    EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
                    ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
                    SiteHttp(OkHttpClient()),
                    proxyBase = "http://127.0.0.1:80/proxy?",
                    store = store,
                ),
                EngineModuleOptions(access = access, drives = DriveService(store, OkHttpClient(), "http://127.0.0.1:80", localFolders = true)),
            )
        }
        block()
        for (secret in listOf("dav-password", "alist-token-xyz")) assertFalse(answers.contains(secret), "the engine gave away $secret")
    }

    private suspend fun HttpResponse.json(): JsonObject = EngineJson.parseToJsonElement(bodyAsText().also { answers.append(it) }).jsonObject

    private suspend fun ApplicationTestBuilder.addDrive(body: String, lan: Boolean = false): HttpResponse = client.post("/api/v1/drives") {
        contentType(ContentType.Application.Json)
        if (lan) lan()
        setBody(body)
    }

    private fun io.ktor.client.request.HttpRequestBuilder.lan() {
        header(HttpHeaders.Host, "192.168.1.5:9978")
        header(HttpHeaders.Authorization, "Bearer $token")
    }

    private fun q(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    private fun local(url: String) = "/" + url.substringAfter("://").substringAfter('/')

    private fun unsigned(url: String) = url.replace(Regex("[&?]tvsig=[^&\\s]*"), "")

    private fun jsonPath(p: String) = p.replace("\\", "\\\\")

    @Test
    fun `drives are added, listed, changed and removed, and never shown with their password or token`() = withEngine {
        val local = addDrive("""{"kind":"local","url":"${jsonPath(folder.path)}"}""")
        assertEquals(HttpStatusCode.Created, local.status)
        val localId = local.json()["id"]!!.jsonPrimitive.content
        val webdav = addDrive("""{"kind":"webdav","name":"家里","url":"${dav.url("/dav/")}","username":"dav-user","password":"dav-password"}""").json()
        assertEquals("true", webdav["hasPassword"]!!.jsonPrimitive.content)
        val davId = webdav["id"]!!.jsonPrimitive.content
        val alist = addDrive("""{"kind":"alist","url":"http://pan.invalid","token":"alist-token-xyz"}""").json()
        assertEquals("true", alist["hasToken"]!!.jsonPrimitive.content)

        val all = EngineJson.parseToJsonElement(client.get("/api/v1/drives").bodyAsText().also { answers.append(it) }).jsonArray
        assertEquals(listOf("片库", "家里", "pan.invalid"), all.map { it.jsonObject["name"]!!.jsonPrimitive.content })
        answers.append(client.get("/api/v1/drives/$davId").bodyAsText())

        val tested = client.post("/api/v1/drives/test") {
            contentType(ContentType.Application.Json)
            setBody("""{"id":"$davId"}""")
        }.json()
        assertEquals("true", tested["ok"]!!.jsonPrimitive.content, tested.toString())
        val wrong = client.post("/api/v1/drives/test") {
            contentType(ContentType.Application.Json)
            setBody("""{"id":"$davId","password":"nope"}""")
        }.json()
        assertEquals("false", wrong["ok"]!!.jsonPrimitive.content)

        val listing = client.get("/api/v1/drives/$davId/list?path=/").json()
        assertEquals("film.mp4", listing["entries"]!!.jsonArray.single().jsonObject["name"]!!.jsonPrimitive.content)
        val play = client.get("/api/v1/drives/$davId/play?path=/film.mp4").json()
        val url = play["url"]!!.jsonPrimitive.content
        assertEquals("http://127.0.0.1:80/drive/$davId/film.mp4", unsigned(url))
        assertArrayEquals(bytes("dav"), client.get(local(url)).readRawBytes(), "the engine adds the account and streams the file")

        val renamed = client.put("/api/v1/drives/$davId") {
            contentType(ContentType.Application.Json)
            setBody("""{"name":"改名"}""")
        }.json()
        assertEquals("改名", renamed["name"]!!.jsonPrimitive.content)
        assertEquals("true", renamed["hasPassword"]!!.jsonPrimitive.content, "a change without a password keeps it")
        assertEquals(HttpStatusCode.NoContent, client.delete("/api/v1/drives/$localId").status)
        assertEquals(HttpStatusCode.NotFound, client.delete("/api/v1/drives/$localId").status)
        assertEquals(HttpStatusCode.NotFound, client.get("/api/v1/drives/nobody/list").status)
        val bad = addDrive("""{"kind":"webdav","url":"ftp://x"}""")
        assertEquals(HttpStatusCode.BadRequest, bad.status)
        assertEquals("BAD_REQUEST", bad.json()["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
    }

    @Test
    fun `a drive folder is a video for detail, play and history, and files stream with ranges`() = withEngine {
        val id = addDrive("""{"kind":"local","url":"${jsonPath(folder.path)}"}""").json()["id"]!!.jsonPrimitive.content
        val site = "drive:$id"
        val detail = client.get("/api/v1/sites/${q(site)}/detail?id=${q("/剧集")}").json()
        assertEquals("剧集", detail["name"]!!.jsonPrimitive.content)
        val episodes = detail["lines"]!!.jsonArray.single().jsonObject["episodes"]!!.jsonArray
        assertEquals(listOf("/剧集/第1集.mp4", "/剧集/第2集.mp4"), episodes.map { it.jsonObject["id"]!!.jsonPrimitive.content })

        val info = client.post("/api/v1/play/resolve") {
            contentType(ContentType.Application.Json)
            setBody("""{"site":"$site","line":"片库","episodeId":"/剧集/第1集.mp4"}""")
        }.json()
        val url = info["url"]!!.jsonPrimitive.content
        assertEquals("http://127.0.0.1:80/drive/$id/%E5%89%A7%E9%9B%86/%E7%AC%AC1%E9%9B%86.mp4", unsigned(url))
        val subtitle = (info["subtitles"] as JsonArray).single().jsonObject
        assertEquals("srt", subtitle["format"]!!.jsonPrimitive.content)

        val whole = client.get(local(url))
        assertEquals(HttpStatusCode.OK, whole.status)
        assertEquals("video/mp4", whole.headers[HttpHeaders.ContentType])
        assertEquals("bytes", whole.headers[HttpHeaders.AcceptRanges])
        assertArrayEquals(bytes("1"), whole.readRawBytes())
        val part = client.get(local(url)) { header(HttpHeaders.Range, "bytes=1000-1999") }
        assertEquals(HttpStatusCode.PartialContent, part.status)
        assertEquals("bytes 1000-1999/30000", part.headers[HttpHeaders.ContentRange])
        assertArrayEquals(bytes("1").copyOfRange(1000, 2000), part.readRawBytes())
        assertEquals(HttpStatusCode.RequestedRangeNotSatisfiable, client.get(local(url)) { header(HttpHeaders.Range, "bytes=40000-") }.status)
        val head = client.head(local(url))
        assertEquals(HttpStatusCode.OK, head.status)
        assertEquals("30000", head.headers[HttpHeaders.ContentLength])
        assertTrue(client.get(local(subtitle["url"]!!.jsonPrimitive.content)).bodyAsText().contains("你好"))
        for (escape in listOf("/drive/$id/..%2F..%2Fsecret", "/drive/$id/%2E%2E/x", "/drive/$id/C:%2FWindows%2Fwin.ini")) {
            assertTrue(client.get(escape).status.value in 400..404, escape)
        }

        // History and resuming use the folder as the video and the file as the episode.
        val put = client.put("/api/v1/history/${q(site)}/${q("/剧集")}") {
            contentType(ContentType.Application.Json)
            setBody("""{"site":"x","vodId":"x","name":"剧集","line":"片库","episodeId":"/剧集/第2集.mp4","episodeName":"第2集","episodeIndex":1,"positionMs":61000,"durationMs":1200000}""")
        }
        assertEquals(HttpStatusCode.OK, put.status)
        val kept = client.get("/api/v1/history/${q(site)}/${q("/剧集")}").json()
        assertEquals("/剧集/第2集.mp4", kept["episodeId"]!!.jsonPrimitive.content)
        assertEquals("61000", kept["positionMs"]!!.jsonPrimitive.content)
    }

    @Test
    fun `a device on the LAN plays drive files by signed addresses and cannot add folders of this machine`() = withEngine {
        val id = addDrive("""{"kind":"local","url":"${jsonPath(folder.path)}"}""").json()["id"]!!.jsonPrimitive.content
        val refused = addDrive("""{"kind":"local","url":"${jsonPath(dir.path)}"}""", lan = true)
        assertEquals(HttpStatusCode.Forbidden, refused.status)
        assertEquals("LOCAL_ONLY", refused.json()["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
        val listing = client.get("/api/v1/drives/$id/list?path=${q("/剧集")}") { lan() }
        assertEquals(HttpStatusCode.OK, listing.status, "a paired device browses the drives")

        for (info in listOf(
            client.post("/api/v1/play/resolve") {
                contentType(ContentType.Application.Json)
                lan()
                setBody("""{"site":"drive:$id","line":"片库","episodeId":"/剧集/第1集.mp4"}""")
            }.json(),
            client.get("/api/v1/drives/$id/play?path=${q("/剧集/第1集.mp4")}") { lan() }.json(),
        )) {
            val url = info["url"]!!.jsonPrimitive.content
            assertTrue(url.startsWith("http://192.168.1.5:9978/drive/$id/") && url.contains("tvsig="), "signed, on the address the device used: $url")
            val sub = (info["subtitles"] as JsonArray).single().jsonObject["url"]!!.jsonPrimitive.content
            assertTrue(sub.startsWith("http://192.168.1.5:9978/drive/$id/") && sub.contains("tvsig="), "the subtitle too: $sub")
            // The player sends no token, only the signed address.
            val video = client.get(local(url)) {
                header(HttpHeaders.Host, "192.168.1.5:9978")
                header(HttpHeaders.Range, "bytes=0-99")
            }
            assertEquals(HttpStatusCode.PartialContent, video.status)
            assertArrayEquals(bytes("1").copyOfRange(0, 100), video.readRawBytes())
            assertEquals(HttpStatusCode.OK, client.get(local(sub)) { header(HttpHeaders.Host, "192.168.1.5:9978") }.status)
            assertEquals(HttpStatusCode.Unauthorized, client.get(local(unsigned(url))) { header(HttpHeaders.Host, "192.168.1.5:9978") }.status, "unsigned: nothing")
            // A signature is for one file only.
            val other = local(url).replace("%E7%AC%AC1%E9%9B%86", "%E7%AC%AC2%E9%9B%86")
            assertEquals(HttpStatusCode.Unauthorized, client.get(other) { header(HttpHeaders.Host, "192.168.1.5:9978") }.status)
        }

        // Sharing off: signed addresses of devices stop working.
        val url = client.get("/api/v1/drives/$id/play?path=${q("/剧集/第1集.mp4")}") { lan() }.json()["url"]!!.jsonPrimitive.content
        access.setSharing(false)
        assertEquals(HttpStatusCode.Forbidden, client.get(local(url)) { header(HttpHeaders.Host, "192.168.1.5:9978") }.status)
    }

    @Test
    fun `a WebDAV file with an account reaches LAN players through the engine, which adds the account`() = withEngine {
        val id = addDrive("""{"kind":"webdav","url":"${dav.url("/dav")}","username":"dav-user","password":"dav-password","proxy":false}""").json()["id"]!!.jsonPrimitive.content
        val url = client.get("/api/v1/drives/$id/play?path=/film.mp4") { lan() }.json()["url"]!!.jsonPrimitive.content
        assertTrue(url.startsWith("http://192.168.1.5:9978/drive/$id/film.mp4?tvsig="), url)
        val video = client.get(local(url)) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertArrayEquals(bytes("dav"), video.readRawBytes())
        assertFalse(dav.takeRequestHeaders().any { it.contains("tvsig") }, "the engine's signature is not passed on to the server")
    }

    private fun MockWebServer.takeRequestHeaders(): List<String> {
        val out = ArrayList<String>()
        while (true) {
            val r = takeRequest(10, java.util.concurrent.TimeUnit.MILLISECONDS) ?: break
            out += r.path.orEmpty()
        }
        return out
    }
}
