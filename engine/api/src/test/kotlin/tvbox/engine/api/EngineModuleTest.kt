package tvbox.engine.api

import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.Assertions.assertTrue

class EngineModuleTest {
    private fun engine() = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:9978/proxy?",
    )

    @Test
    fun `browse, search stream and play against a fake CMS site`() {
        val upstream = MockWebServer().apply { start() }
        try {
            val api = upstream.url("/api.php/provide/vod/").toString()
            val jx = upstream.url("/jx?url=").toString()
            upstream.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val url = request.requestUrl!!
                    val body = when {
                        url.encodedPath == "/tv.json" -> """{"sites":[{"key":"cms","name":"采集","type":1,"api":"$api"},{"key":"js","type":3,"api":"http://x/a.js"}],"parses":[{"name":"jx","type":1,"url":"$jx"}]}"""
                        url.encodedPath == "/jx" -> """{"data":{"url":"https://cdn.test/real.m3u8","header":{"Referer":"https://site.test/"}}}"""
                        url.queryParameter("ids") == "7" -> """{"list":[{"vod_id":7,"vod_name":"片名","vod_play_from":"直链$$${'$'}网页","vod_play_url":"第1集${'$'}https://cdn.test/a/index.m3u8#第2集${'$'}https://cdn.test/b/index.m3u8$$${'$'}第1集${'$'}https://page.test/play/1"}]}"""
                        url.queryParameter("wd") != null -> """{"list":[{"vod_id":7,"vod_name":"片名","vod_remarks":"HD"}]}"""
                        url.queryParameter("t") == "1" -> """{"page":"2","pagecount":5,"total":"90","list":[{"vod_id":"8","vod_name":"另一部"}]}"""
                        else -> """{"class":[{"type_id":"1","type_name":"电影"}],"filters":{"1":[{"key":"year","name":"年份","value":[{"n":"2024","v":"2024"}]}]},"list":[]}"""
                    }
                    return MockResponse().setBody(body)
                }
            }

            testApplication {
                application { engineModule(engine()) }
                val created = client.post("/api/v1/subscriptions") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"url":"${upstream.url("/tv.json")}"}""")
                }
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
                client.post("/api/v1/subscriptions/$id/activate")

                val home = EngineJson.parseToJsonElement(client.get("/api/v1/sites/cms/home").bodyAsText()).jsonObject
                assertEquals("电影", home["classes"]!!.jsonArray[0].jsonObject["name"]!!.jsonPrimitive.content)
                assertEquals(1, home["filters"]!!.jsonObject["1"]!!.jsonArray.size)

                val page = EngineJson.parseToJsonElement(client.get("/api/v1/sites/cms/category?tid=1&pg=2&f=%7B%22year%22%3A%222024%22%7D").bodyAsText()).jsonObject
                assertEquals("5", page["pageCount"]!!.jsonPrimitive.content)
                assertEquals("另一部", page["list"]!!.jsonArray[0].jsonObject["name"]!!.jsonPrimitive.content)
                val categoryRequest = generateSequence { upstream.takeRequest(1, java.util.concurrent.TimeUnit.SECONDS) }
                    .first { it.requestUrl!!.queryParameter("t") == "1" }.requestUrl!!
                assertEquals("detail", categoryRequest.queryParameter("ac"))
                assertEquals("2024", categoryRequest.queryParameter("year"))
                assertEquals("""{"year":"2024"}""", categoryRequest.queryParameter("f"))

                val detail = EngineJson.parseToJsonElement(client.get("/api/v1/sites/cms/detail?id=7").bodyAsText()).jsonObject
                val lines = detail["lines"]!!.jsonArray
                assertEquals(listOf("直链", "网页"), lines.map { it.jsonObject["name"]!!.jsonPrimitive.content })
                assertEquals(2, lines[0].jsonObject["episodes"]!!.jsonArray.size)

                val direct = EngineJson.parseToJsonElement(client.post("/api/v1/play/resolve") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"site":"cms","line":"直链","episodeId":"https://cdn.test/a/index.m3u8"}""")
                }.bodyAsText()).jsonObject
                assertEquals("direct", direct["kind"]!!.jsonPrimitive.content)
                assertEquals("https://cdn.test/a/index.m3u8", direct["url"]!!.jsonPrimitive.content)

                val parsed = EngineJson.parseToJsonElement(client.post("/api/v1/play/resolve") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"site":"cms","line":"网页","episodeId":"https://page.test/play/1"}""")
                }.bodyAsText()).jsonObject
                assertEquals("https://cdn.test/real.m3u8", parsed["url"]!!.jsonPrimitive.content)
                assertEquals("https://site.test/", parsed["headers"]!!.jsonObject["Referer"]!!.jsonPrimitive.content)
                assertEquals("jx", parsed["parsedBy"]!!.jsonPrimitive.content)

                val stream = client.get("/api/v1/search/stream?wd=%E7%89%87").bodyAsText()
                assertTrue(stream.contains("event: results"), stream)
                assertTrue(stream.contains("\"name\":\"片名\""), stream)
                assertTrue(stream.trimEnd().lines().takeLast(2).first().startsWith("event: end"), stream)
                // The js site is not searchable yet, so only the CMS site takes part.
                assertTrue(stream.contains("\"sites\":1"), stream)

                val unsupported = client.get("/api/v1/sites/js/home")
                assertEquals(HttpStatusCode.NotImplemented, unsupported.status)
            }
        } finally {
            upstream.shutdown()
        }
    }

    @Test
    fun `info and proxy probe`() = testApplication {
        application { engineModule(engine()) }
        val info = EngineJson.parseToJsonElement(client.get("/api/v1/info").bodyAsText()).jsonObject
        assertEquals("tvbox-engine", info["name"]!!.jsonPrimitive.content)
        assertEquals("1", info["protocol"]!!.jsonPrimitive.content)
        assertEquals("ok", client.get("/proxy?do=ck").bodyAsText())
    }

    @Test
    fun `sites before any subscription is a conflict`() = testApplication {
        application { engineModule(engine()) }
        val res = client.get("/api/v1/sites")
        assertEquals(HttpStatusCode.Conflict, res.status)
        assertEquals("NO_CONFIG", EngineJson.parseToJsonElement(res.bodyAsText()).jsonObject["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
    }

    @Test
    fun `subscribe to a repository, activate, list sites`() {
        val upstream = MockWebServer().apply { start() }
        try {
            val configUrl = upstream.url("/b.json").toString()
            upstream.enqueue(MockResponse().setBody("""{"urls":[{"name":"B","url":"$configUrl"}]}"""))
            upstream.enqueue(MockResponse().setBody("""{"sites":[{"key":"a","name":"A","type":1,"api":"http://x"},{"key":"j","type":3,"api":"http://x/j.js"}]}"""))

            testApplication {
                application { engineModule(engine()) }
                val created = client.post("/api/v1/subscriptions") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"url":"${upstream.url("/repo.json")}"}""")
                }
                assertEquals(HttpStatusCode.Created, created.status)
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content

                val summary = EngineJson.parseToJsonElement(client.post("/api/v1/subscriptions/$id/activate").bodyAsText()).jsonObject
                assertEquals(configUrl, summary["url"]!!.jsonPrimitive.content)
                assertEquals("2", summary["sites"]!!.jsonPrimitive.content)
                assertEquals(1, summary["repos"]!!.jsonArray.size)

                val sites = EngineJson.parseToJsonElement(client.get("/api/v1/sites").bodyAsText()).jsonArray
                assertEquals(listOf("cms", "js"), sites.map { it.jsonObject["runtime"]!!.jsonPrimitive.content })
            }
        } finally {
            upstream.shutdown()
        }
    }
}
