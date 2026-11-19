package tvbox.engine.api

import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
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
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.api.access.AccessControl
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore

/**
 * Subtitles and danmaku around a play answer. The upstream is a type-4 (HTTP) spider whose `play` answer names
 * subtitles (`subs`, `subt`) and danmaku, plus the files themselves.
 */
class MediaExtrasRoutesTest {
    private val gbkSrt = "1\r\n00:00:01,000 --> 00:00:02,000\r\n第一句字幕\r\n".toByteArray(charset("GBK"))
    private val ass = "[Script Info]\nScriptType: v4.00+\n\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,双语\n"

    private class Upstream(val server: MockWebServer, val requests: MutableList<RecordedRequest>)

    private fun upstream(): Upstream {
        val server = MockWebServer()
        val requests = java.util.Collections.synchronizedList(ArrayList<RecordedRequest>())
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val url = request.requestUrl!!
                return when (url.encodedPath) {
                    "/tv.json" -> MockResponse().setBody(
                        """{"sites":[{"key":"r","name":"远程","type":4,"api":"${server.url("/spider")}"}],"danmaku":"${server.url("/dmapi")}?name={name}&ep={episode}"}""",
                    )
                    // Episode 1 comes with danmaku (Bilibili's comment XML), episode 2 without.
                    "/spider" -> {
                        val danmaku = if (url.queryParameter("play") == "1") ",\"danmaku\":\"${server.url("/dm/1.xml")}\"" else ""
                        MockResponse().setBody(
                            """{"parse":0,"url":"https://cdn.test/v/1.mp4","header":{"Referer":"https://site.test/"},
                                "subs":[{"name":"中文","lang":"zh","format":"application/x-subrip","url":"${server.url("/subs/1")}"}],
                                "subt":"${server.url("/subs/2")}#双语.ass"$danmaku}""",
                        )
                    }
                    "/dm/1.xml" -> MockResponse().setBody("""<i><d p="1.5,1,25,16777215">站点弹幕</d><d p="0.5,5,25,255">顶部</d></i>""")
                    "/dmapi" -> MockResponse().setBody("""{"comments":[{"p":"3,1,16777215,u","m":"接口弹幕：${url.queryParameter("name")} ${url.queryParameter("ep")}"}]}""")
                    // Only with the play answer's Referer, like many sites.
                    "/subs/1" -> if (request.getHeader("Referer") == "https://site.test/") MockResponse().setBody(Buffer().write(gbkSrt)) else MockResponse().setResponseCode(403)
                    "/subs/2" -> MockResponse().setBody(ass)
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        return Upstream(server, requests)
    }

    /** LAN sharing is on and one device is paired: its token. */
    private val access = AccessControl(MemoryStore(), supported = true).also { it.setSharing(true) }
    private val token = (access.pair(access.newCode().code, "tv", "x") as AccessControl.PairResult.Paired).token

    private fun withEngine(block: suspend ApplicationTestBuilder.(Upstream) -> Unit) {
        val up = upstream()
        try {
            testApplication {
                application {
                    engineModule(
                        Engine(
                            EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
                            ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
                            SiteHttp(OkHttpClient()),
                            proxyBase = "http://127.0.0.1:80/proxy?",
                        ),
                        EngineModuleOptions(access = access),
                    )
                }
                val created = client.post("/api/v1/subscriptions") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"url":"${up.server.url("/tv.json")}"}""")
                }
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
                client.post("/api/v1/subscriptions/$id/activate")
                block(up)
            }
        } finally {
            up.server.shutdown()
        }
    }

    private suspend fun ApplicationTestBuilder.resolve(host: String? = null, episode: String = "1"): JsonObject = EngineJson.parseToJsonElement(
        client.post("/api/v1/play/resolve") {
            contentType(ContentType.Application.Json)
            if (host != null) {
                header(HttpHeaders.Host, host)
                header(HttpHeaders.Authorization, "Bearer $token")
            }
            setBody("""{"site":"r","line":"线路","episodeId":"$episode"}""")
        }.bodyAsText(),
    ).jsonObject

    private suspend fun ApplicationTestBuilder.danmaku(episode: String, host: String? = null) = client.get(
        "/api/v1/danmaku?site=r&line=%E7%BA%BF%E8%B7%AF&episodeId=$episode&title=%E7%89%87%E5%90%8D&episode=%E7%AC%AC${episode}%E9%9B%86",
    ) {
        if (host != null) {
            header(HttpHeaders.Host, host)
            header(HttpHeaders.Authorization, "Bearer $token")
        }
    }

    private suspend fun ApplicationTestBuilder.settings(body: String) = client.put("/api/v1/settings") {
        contentType(ContentType.Application.Json)
        setBody(body)
    }

    /** An absolute engine address as a path for the test client. */
    private fun local(url: String) = "/" + url.substringAfter("://").substringAfter('/')

    private fun unsigned(url: String) = url.replace(Regex("[&?]tvsig=[^&\\s]*"), "")

    @Test
    fun `the site's subtitles come as engine addresses that serve UTF-8 with the site's headers`() = withEngine { up ->
        // `subt` first, as TVBoxOS takes it before `subs`.
        val subtitles = resolve()["subtitles"]!!.jsonArray.map { it.jsonObject }.reversed()
        assertEquals(listOf("中文", "双语"), subtitles.map { it["name"]!!.jsonPrimitive.content })
        assertEquals(listOf("zh", ""), subtitles.map { it["lang"]!!.jsonPrimitive.content })
        assertEquals(listOf("srt", "ass"), subtitles.map { it["format"]!!.jsonPrimitive.content })
        val urls = subtitles.map { it["url"]!!.jsonPrimitive.content }
        assertTrue(urls.all { it.startsWith("http://127.0.0.1:80/subtitle?url=") }, urls.toString())

        val srt = client.get(local(urls[0]))
        assertEquals(HttpStatusCode.OK, srt.status)
        assertEquals("1\n00:00:01,000 --> 00:00:02,000\n第一句字幕\n", srt.bodyAsText())
        assertTrue(srt.headers[HttpHeaders.ContentType]!!.contains("utf-8"))
        assertEquals("https://site.test/", up.requests.last { it.requestUrl!!.encodedPath == "/subs/1" }.getHeader("Referer"), "with the play answer's headers")

        val second = client.get(local(urls[1]))
        assertEquals(ass, second.bodyAsText())
        assertTrue(second.headers[HttpHeaders.ContentType]!!.startsWith("text/x-ssa"))
    }

    @Test
    fun `a subtitle the engine cannot get is a gateway error, and the address must be http`() = withEngine { up ->
        val missing = client.get("/subtitle?url=" + java.net.URLEncoder.encode(up.server.url("/subs/none").toString(), "UTF-8"))
        assertEquals(HttpStatusCode.BadGateway, missing.status)
        assertEquals(HttpStatusCode.BadRequest, client.get("/subtitle?url=file%3A%2F%2F%2Fetc%2Fpasswd").status)
    }

    @Test
    fun `a subtitle file from the client comes back as UTF-8 in a format the player reads`() = withEngine {
        suspend fun convert(name: String, bytes: ByteArray) = client.post("/api/v1/subtitle/convert") {
            contentType(ContentType.Application.Json)
            setBody("""{"name":"$name","data":"${tvbox.engine.core.util.Base64Compat.encode(bytes)}"}""")
        }
        val srt = EngineJson.parseToJsonElement(convert("电影.srt", gbkSrt).bodyAsText()).jsonObject
        assertEquals("srt", srt["format"]!!.jsonPrimitive.content)
        assertEquals("1\n00:00:01,000 --> 00:00:02,000\n第一句字幕\n", srt["text"]!!.jsonPrimitive.content)
        val lrc = EngineJson.parseToJsonElement(convert("歌.lrc", "[00:01.00]一句".toByteArray()).bodyAsText()).jsonObject
        assertEquals("srt", lrc["format"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.BadRequest, convert("空.srt", ByteArray(0)).status)
    }

    @Test
    fun `a paired device on the LAN gets subtitle addresses its player can open without a token`() = withEngine {
        val urls = resolve(host = "192.168.1.5:9978")["subtitles"]!!.jsonArray.map { it.jsonObject["url"]!!.jsonPrimitive.content }.reversed()
        assertTrue(urls.all { it.startsWith("http://192.168.1.5:9978/subtitle?") && it.contains("tvsig=") }, urls.toString())

        // The player: the LAN address, no token.
        val opened = client.get(local(urls[0])) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.OK, opened.status)
        assertTrue(opened.bodyAsText().contains("第一句字幕"))

        val unsignedRequest = client.get(local(unsigned(urls[0]))) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.Unauthorized, unsignedRequest.status, "without the signature a LAN player gets nothing")
        val otherFile = client.get(local(urls[0]).replace("%2Fsubs%2F1", "%2Fsubs%2F2")) { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.Unauthorized, otherFile.status, "the signature covers the address it was made for")
    }

    // ---- danmaku ----

    @Test
    fun `the site's danmaku address is kept with the episode and served in one form`() = withEngine { up ->
        val info = resolve(episode = "1")
        assertEquals(up.server.url("/dm/1.xml").toString(), info["danmaku"]!!.jsonPrimitive.content, "where they come from, for display")
        val list = EngineJson.parseToJsonElement(danmaku("1").bodyAsText()).jsonObject
        assertEquals("site", list["source"]!!.jsonPrimitive.content)
        assertEquals(2, list["count"]!!.jsonPrimitive.content.toInt())
        val items = list["items"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("顶部", "站点弹幕"), items.map { it["text"]!!.jsonPrimitive.content }, "by time")
        assertEquals(listOf("top", "scroll"), items.map { it["mode"]!!.jsonPrimitive.content })
        assertEquals(listOf(500L, 1500L), items.map { it["time"]!!.jsonPrimitive.content.toLong() })
        assertEquals(255, items[0]["color"]!!.jsonPrimitive.content.toInt())
    }

    @Test
    fun `the config's danmaku API is asked only once the user switched it on`() = withEngine { up ->
        resolve(episode = "2")
        val off = EngineJson.parseToJsonElement(danmaku("2").bodyAsText()).jsonObject
        assertEquals("", off["source"]!!.jsonPrimitive.content)
        assertEquals(0, off["count"]!!.jsonPrimitive.content.toInt())
        assertTrue(up.requests.none { it.requestUrl!!.encodedPath == "/dmapi" }, "nothing went to the API")

        val services = EngineJson.parseToJsonElement(client.get("/api/v1/danmaku/services").bodyAsText()).jsonObject
        assertEquals(up.server.url("/dmapi").toString() + "?name={name}&ep={episode}", services["configApi"]!!.jsonPrimitive.content)
        assertEquals("false", services["configApiEnabled"]!!.jsonPrimitive.content)

        settings("""{"danmakuConfigApi":true}""")
        val on = EngineJson.parseToJsonElement(danmaku("2").bodyAsText()).jsonObject
        assertEquals("config", on["source"]!!.jsonPrimitive.content)
        assertEquals("接口弹幕：片名 第2集", on["items"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content)
        // The site's own danmaku still come first.
        resolve(episode = "1")
        assertEquals("site", EngineJson.parseToJsonElement(danmaku("1").bodyAsText()).jsonObject["source"]!!.jsonPrimitive.content)
    }

    @Test
    fun `the user's own service is a setting, kept only when it is an http address`() = withEngine {
        val saved = EngineJson.parseToJsonElement(settings("""{"danmakuApi":"  https://dm.example/token  "}""").bodyAsText()).jsonObject
        assertEquals("https://dm.example/token", saved["danmakuApi"]!!.jsonPrimitive.content)
        assertEquals("false", saved["danmakuConfigApi"]!!.jsonPrimitive.content, "the other switch is left as it was")
        val bad = EngineJson.parseToJsonElement(settings("""{"danmakuApi":"file:///etc"}""").bodyAsText()).jsonObject
        assertEquals("", bad["danmakuApi"]!!.jsonPrimitive.content)
    }

    @Test
    fun `a danmaku file from the client is read in any of the forms, and one with none is refused`() = withEngine {
        suspend fun parse(bytes: ByteArray) = client.post("/api/v1/danmaku/parse") {
            contentType(ContentType.Application.Json)
            setBody("""{"name":"弹幕.xml","data":"${tvbox.engine.core.util.Base64Compat.encode(bytes)}"}""")
        }
        val xml = """<?xml version="1.0" encoding="GBK"?><i><d p="2,1,25,16777215">本地文件</d></i>""".toByteArray(charset("GBK"))
        val list = EngineJson.parseToJsonElement(parse(xml).bodyAsText()).jsonObject
        assertEquals("file", list["source"]!!.jsonPrimitive.content)
        assertEquals("弹幕.xml", list["from"]!!.jsonPrimitive.content)
        assertEquals("本地文件", list["items"]!!.jsonArray.single().jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals(HttpStatusCode.BadRequest, parse("hello".toByteArray()).status)
    }

    @Test
    fun `a paired device on the LAN gets the danmaku with its token`() = withEngine {
        resolve(host = "192.168.1.5:9978", episode = "1")
        val lan = danmaku("1", host = "192.168.1.5:9978")
        assertEquals(HttpStatusCode.OK, lan.status)
        assertEquals("site", EngineJson.parseToJsonElement(lan.bodyAsText()).jsonObject["source"]!!.jsonPrimitive.content)
        val noToken = client.get("/api/v1/danmaku?site=r&episodeId=1") { header(HttpHeaders.Host, "192.168.1.5:9978") }
        assertEquals(HttpStatusCode.Unauthorized, noToken.status)
    }
}
