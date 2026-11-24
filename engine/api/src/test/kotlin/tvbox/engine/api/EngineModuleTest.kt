package tvbox.engine.api

import io.ktor.client.request.delete
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
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.boolean
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
                // HLS goes through the engine's playlist endpoint (ad cleaning).
                assertEquals("http://127.0.0.1:9978/m3u8?url=https%3A%2F%2Fcdn.test%2Fa%2Findex.m3u8", direct["url"]!!.jsonPrimitive.content)

                val parsed = EngineJson.parseToJsonElement(client.post("/api/v1/play/resolve") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"site":"cms","line":"网页","episodeId":"https://page.test/play/1"}""")
                }.bodyAsText()).jsonObject
                assertTrue(parsed["url"]!!.jsonPrimitive.content.startsWith("http://127.0.0.1:9978/m3u8?url=https%3A%2F%2Fcdn.test%2Freal.m3u8&h="))
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
    fun `live channels say how many days they can be played back, and catchup gives the address of a past range`() {
        val upstream = MockWebServer().apply { start() }
        try {
            upstream.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                    "/tv.json" -> MockResponse().setBody("""{"sites":[],"lives":[{"name":"直播","type":0,"url":"${upstream.url("/tv.m3u")}"}]}""")
                    "/tv.m3u" -> MockResponse().setBody(
                        "#EXTM3U\n" +
                            "#EXTINF:-1 group-title=\"组\" catchup=\"append\" catchup-days=\"3\" catchup-source=\"?s={utc}&e={utcend}\",回看台\n" +
                            "proxy://do=live&id=1\n" +
                            "#EXTINF:-1 group-title=\"组\",普通台\nhttp://a.test/2.m3u8\n",
                    )
                    else -> MockResponse().setResponseCode(404)
                }
            }
            // The LAN client below is a paired device.
            val access = tvbox.engine.api.access.AccessControl(tvbox.engine.core.store.MemoryStore(), supported = true).also { it.setSharing(true) }
            val token = (access.pair(access.newCode().code, "tv", "x") as tvbox.engine.api.access.AccessControl.PairResult.Paired).token
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
                    setBody("""{"url":"${upstream.url("/tv.json")}"}""")
                }
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
                client.post("/api/v1/subscriptions/$id/activate")

                val channels = EngineJson.parseToJsonElement(client.get("/api/v1/live/0").bodyAsText()).jsonObject["groups"]!!.jsonArray[0].jsonObject["channels"]!!.jsonArray
                assertEquals(listOf("3", "0"), channels.map { it.jsonObject["catchupDays"]!!.jsonPrimitive.content })
                assertTrue(channels.none { "catchup" in it.jsonObject["urls"]!!.jsonArray[0].jsonObject }, "the rule stays in the engine")

                val start = System.currentTimeMillis() - 2 * 3_600_000L
                val end = start + 1_800_000L
                val channel = java.net.URLEncoder.encode("回看台", "UTF-8")
                val catchup = EngineJson.parseToJsonElement(
                    client.get("/api/v1/live/0/catchup?channel=$channel&group=%E7%BB%84&line=0&start=$start&end=$end") {
                        header(HttpHeaders.Host, "192.168.1.5:9978")
                        header(HttpHeaders.Authorization, "Bearer $token")
                    }.bodyAsText(),
                ).jsonObject
                val catchupUrl = catchup["url"]!!.jsonPrimitive.content
                assertTrue(catchupUrl.contains("&tvsig="), "signed, so a player on the LAN can open it: $catchupUrl")
                assertEquals(
                    "http://192.168.1.5:9978/proxy?do=live&id=1&s=${start / 1000}&e=${end / 1000}",
                    catchupUrl.substringBefore("&tvsig="),
                    "the engine's own address, as the LAN client reaches it",
                )
                assertEquals("0", catchup["line"]!!.jsonPrimitive.content)

                val plain = client.get("/api/v1/live/0/catchup?channel=%E6%99%AE%E9%80%9A%E5%8F%B0&start=$start&end=$end")
                assertEquals(HttpStatusCode.BadRequest, plain.status, "a channel without catch-up")
                assertEquals(HttpStatusCode.BadRequest, client.get("/api/v1/live/0/catchup?channel=$channel&start=x&end=$end").status)
                assertEquals(HttpStatusCode.NotFound, client.get("/api/v1/live/0/catchup?channel=nope&start=$start&end=$end").status)
            }
        } finally {
            upstream.shutdown()
        }
    }

    @Test
    fun `sites say whether sources may switch to them, and a detail without an id gets the one asked for`() {
        val upstream = MockWebServer().apply { start() }
        try {
            val api = upstream.url("/api.php/provide/vod/").toString()
            upstream.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val url = request.requestUrl!!
                    val body = when {
                        url.encodedPath == "/tv.json" ->
                            """{"sites":[{"key":"a","name":"A","type":1,"api":"$api"},{"key":"douban","name":"豆瓣","type":1,"api":"$api","changeable":0},""" +
                                """{"key":"b","name":"B","type":1,"api":"$api","changeable":1}]}"""
                        // A detail without vod_id, as some sites send it.
                        url.queryParameter("ids") != null -> """{"list":[{"vod_name":"片名","vod_play_from":"直链","vod_play_url":"第1集${'$'}https://cdn.test/a.m3u8"}]}"""
                        else -> """{"class":[],"list":[{"vod_id":"msearch:片名","vod_name":"片名"},{"vod_name":"无编号"}]}"""
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

                val sites = EngineJson.parseToJsonElement(client.get("/api/v1/sites").bodyAsText()).jsonArray
                assertEquals(
                    listOf("a" to true, "douban" to false, "b" to true),
                    sites.map { it.jsonObject["key"]!!.jsonPrimitive.content to it.jsonObject["changeable"]!!.jsonPrimitive.boolean },
                )

                val home = EngineJson.parseToJsonElement(client.get("/api/v1/sites/douban/home").bodyAsText()).jsonObject
                assertEquals(listOf("msearch:片名", ""), home["list"]!!.jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.content })

                val detail = EngineJson.parseToJsonElement(client.get("/api/v1/sites/a/detail?id=vod%2F42").bodyAsText()).jsonObject
                assertEquals("vod/42", detail["id"]!!.jsonPrimitive.content)
                assertEquals("片名", detail["name"]!!.jsonPrimitive.content)
            }
        } finally {
            upstream.shutdown()
        }
    }

    @Test
    fun `history and favorites round trip, including ids with slashes`() = testApplication {
        application { engineModule(engine()) }
        val id = java.net.URLEncoder.encode("https://site.test/vod/1", "UTF-8")
        val put = client.put("/api/v1/history/s/$id") {
            contentType(ContentType.Application.Json)
            setBody("""{"site":"ignored","vodId":"ignored","name":"片","episodeIndex":2,"positionMs":61000}""")
        }
        assertEquals(HttpStatusCode.OK, put.status)
        val entry = EngineJson.parseToJsonElement(client.get("/api/v1/history/s/$id").bodyAsText()).jsonObject
        assertEquals("https://site.test/vod/1", entry["vodId"]!!.jsonPrimitive.content)
        assertEquals("61000", entry["positionMs"]!!.jsonPrimitive.content)
        assertEquals(1, EngineJson.parseToJsonElement(client.get("/api/v1/history").bodyAsText()).jsonArray.size)

        client.put("/api/v1/favorites/s/$id") {
            contentType(ContentType.Application.Json)
            setBody("""{"site":"s","vodId":"x","name":"片"}""")
        }
        assertEquals(HttpStatusCode.OK, client.get("/api/v1/favorites/s/$id").status)
        client.delete("/api/v1/favorites/s/$id")
        assertEquals(HttpStatusCode.NotFound, client.get("/api/v1/favorites/s/$id").status)
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
    @Test
    fun `playlists are cleaned with the config's ad rules, and LAN clients get reachable urls`() {
        val upstream = MockWebServer().apply { start() }
        try {
            val playlist = buildString {
                appendLine("#EXTM3U")
                appendLine("#EXT-X-TARGETDURATION:10")
                for (i in 0 until 10) appendLine("#EXTINF:10.0,").appendLine("seg$i.ts")
                appendLine("#EXT-X-DISCONTINUITY")
                appendLine("#EXTINF:7.5,").appendLine("/ads/ad/1.ts")
                appendLine("#EXTINF:7.6666,").appendLine("/ads/ad/2.ts")
                appendLine("#EXT-X-DISCONTINUITY")
                for (i in 10 until 20) appendLine("#EXTINF:10.0,").appendLine("seg$i.ts")
                appendLine("#EXT-X-ENDLIST")
            }
            upstream.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                    "/tv.json" -> MockResponse().setBody(
                        """{"sites":[{"key":"cms","type":1,"api":"${upstream.url("/api")}"}],"rules":[{"name":"ad","hosts":["/ads/"],"regex":["15.1666"]}]}""",
                    )
                    "/ads/index.m3u8" -> MockResponse().setBody(playlist)
                    else -> MockResponse().setResponseCode(404)
                }
            }
            // The LAN client below is a paired device.
            val access = tvbox.engine.api.access.AccessControl(tvbox.engine.core.store.MemoryStore(), supported = true).also { it.setSharing(true) }
            val token = (access.pair(access.newCode().code, "tv", "x") as tvbox.engine.api.access.AccessControl.PairResult.Paired).token
            testApplication {
                // The engine's own urls use the port it listens on (80 in the test host).
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
                    setBody("""{"url":"${upstream.url("/tv.json")}"}""")
                }
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
                client.post("/api/v1/subscriptions/$id/activate")

                val source = upstream.url("/ads/index.m3u8").toString()
                val cleaned = client.get("/m3u8?url=" + java.net.URLEncoder.encode(source, "UTF-8")).bodyAsText()
                assertTrue(!cleaned.contains("/ads/ad/"), cleaned)
                assertTrue(cleaned.contains(upstream.url("/ads/seg19.ts").toString()), "segments are absolute")

                val noRedirects = createClient { followRedirects = false }
                val broken = noRedirects.get("/m3u8?url=" + java.net.URLEncoder.encode("http://127.0.0.1:1/x.m3u8", "UTF-8"))
                assertEquals(HttpStatusCode.Found, broken.status, "unreachable playlists send the player to the original")

                val lan = EngineJson.parseToJsonElement(client.post("/api/v1/play/resolve") {
                    contentType(ContentType.Application.Json)
                    header(HttpHeaders.Host, "192.168.1.5:9978")
                    header(HttpHeaders.Authorization, "Bearer $token")
                    setBody("""{"site":"cms","line":"x","episodeId":"https://cdn.test/a/index.m3u8"}""")
                }.bodyAsText()).jsonObject
                assertTrue(lan["url"]!!.jsonPrimitive.content.startsWith("http://192.168.1.5:9978/m3u8?url="), lan.toString())
            }
        } finally {
            upstream.shutdown()
        }
    }

    @Test
    fun `saved subscriptions keep when they were last used and can be renamed`() {
        val upstream = MockWebServer().apply { start() }
        try {
            upstream.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = MockResponse().setBody("""{"sites":[]}""")
            }
            testApplication {
                application { engineModule(engine()) }
                suspend fun add(path: String): String {
                    val created = client.post("/api/v1/subscriptions") {
                        contentType(ContentType.Application.Json)
                        setBody("""{"url":"${upstream.url(path)}"}""")
                    }
                    return EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
                }
                suspend fun list() = EngineJson.parseToJsonElement(client.get("/api/v1/subscriptions").bodyAsText()).jsonArray.map { it.jsonObject }
                fun usedAt(o: kotlinx.serialization.json.JsonObject) = o["usedAt"]?.jsonPrimitive?.content?.toLong() ?: 0L
                val a = add("/a.json")
                val b = add("/b.json")
                assertEquals(a, add("/a.json"), "the same address is not saved twice")
                assertTrue(list().all { usedAt(it) == 0L }, "nothing loaded yet")

                val before = System.currentTimeMillis()
                client.post("/api/v1/subscriptions/$b/activate")
                val used = list().associate { it["id"]!!.jsonPrimitive.content to usedAt(it) }
                assertTrue(used[b]!! >= before, "b loaded: $used")
                assertEquals(0L, used[a])

                val renamed = client.put("/api/v1/subscriptions/$a") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"name":"  家里的  "}""")
                }
                assertEquals("家里的", EngineJson.parseToJsonElement(renamed.bodyAsText()).jsonObject["name"]!!.jsonPrimitive.content)
                assertEquals("家里的", list().first { it["id"]!!.jsonPrimitive.content == a }["name"]!!.jsonPrimitive.content)
                val reset = client.put("/api/v1/subscriptions/$a") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"name":""}""")
                }
                assertEquals(
                    upstream.url("/a.json").toString(),
                    EngineJson.parseToJsonElement(reset.bodyAsText()).jsonObject["name"]!!.jsonPrimitive.content,
                    "a blank name goes back to the address",
                )
                val missing = client.put("/api/v1/subscriptions/nope") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"name":"x"}""")
                }
                assertEquals(HttpStatusCode.NotFound, missing.status)
            }
        } finally {
            upstream.shutdown()
        }
    }
}
