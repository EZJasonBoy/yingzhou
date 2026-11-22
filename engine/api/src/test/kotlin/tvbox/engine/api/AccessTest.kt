package tvbox.engine.api

import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.access.AccessControl.PairResult
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.URLEncoder

/**
 * LAN access: which routes need what, pairing, tokens and signed media addresses.
 *
 * The test host connects from "localhost", so "another device" is simulated with a foreign Host header: the engine
 * counts a caller as local only when it comes from loopback AND addressed the engine by a loopback name. The one
 * test that comes from a non-loopback address uses a real socket on this machine's LAN address, which is still the
 * same machine: nothing here crosses a real network.
 */
class AccessTest {
    private val lanHost = "192.168.1.5:9978"

    private fun engine(port: Int = 80) = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:$port/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:$port/proxy?",
    )

    private class Clock(var now: Long = 1_000_000_000_000L)

    private fun access(clock: Clock = Clock(), sharing: Boolean = true) =
        AccessControl(MemoryStore(), supported = true, clock = { clock.now }).also { it.setSharing(sharing) }

    /** Pairs through the API as a LAN device; returns the token. */
    private suspend fun ApplicationTestBuilder.pairOverApi(access: AccessControl): String {
        val code = access.codeOrNew().code
        val res = client.post("/api/v1/pair") {
            header(HttpHeaders.Host, lanHost)
            contentType(ContentType.Application.Json)
            setBody("""{"code":"$code","name":"客厅电视"}""")
        }
        assertEquals(HttpStatusCode.OK, res.status, res.bodyAsText())
        return EngineJson.parseToJsonElement(res.bodyAsText()).jsonObject["token"]!!.jsonPrimitive.content
    }

    private fun code(body: String) = EngineJson.parseToJsonElement(body).jsonObject["error"]?.jsonObject?.get("code")?.jsonPrimitive?.content

    @Test
    fun `every class of route needs a token from another device, and nothing from this machine`() {
        val access = access()
        testApplication {
            application { engineModule(engine(), EngineModuleOptions(access = access)) }
            val routes = listOf(
                "/api/v1/sites",
                "/api/v1/history",
                "/api/v1/settings",
                "/proxy?do=ck",
                "/m3u8?url=" + URLEncoder.encode("http://127.0.0.1:1/x.m3u8", "UTF-8"),
                "/some/route/added/later",
            )
            val noRedirects = createClient { followRedirects = false }
            for (route in routes) {
                // From this machine: never refused for want of a token.
                val local = noRedirects.get(route)
                assertNotEquals(HttpStatusCode.Unauthorized, local.status, route)
                assertNotEquals(HttpStatusCode.Forbidden, local.status, route)
                // From the LAN without a token: refused, and the route never ran.
                val remote = noRedirects.get(route) { header(HttpHeaders.Host, lanHost) }
                assertEquals(HttpStatusCode.Unauthorized, remote.status, route)
                assertEquals("UNAUTHORIZED", code(remote.bodyAsText()), route)
                assertEquals("Bearer", remote.headers[HttpHeaders.WWWAuthenticate])
                val forged = noRedirects.get(route) {
                    header(HttpHeaders.Host, lanHost)
                    header(HttpHeaders.Authorization, "Bearer abc.def")
                }
                assertEquals(HttpStatusCode.Unauthorized, forged.status, route)
            }
            // A local Host header with a port is still local; 127.0.0.1 and [::1] too.
            assertEquals(HttpStatusCode.OK, client.get("/api/v1/settings") { header(HttpHeaders.Host, "127.0.0.1:9978") }.status)
            assertEquals(HttpStatusCode.OK, client.get("/api/v1/settings") { header(HttpHeaders.Host, "[::1]:9978") }.status)
            // A page in a local browser that reaches 127.0.0.1 under its own name is not local.
            assertEquals(HttpStatusCode.Unauthorized, client.get("/api/v1/settings") { header(HttpHeaders.Host, "evil.example:9978") }.status)

            // Public: engine info and pairing.
            assertEquals(HttpStatusCode.OK, client.get("/api/v1/info") { header(HttpHeaders.Host, lanHost) }.status)

            val token = pairOverApi(access)
            for (route in routes) {
                val res = noRedirects.get(route) {
                    header(HttpHeaders.Host, lanHost)
                    header(HttpHeaders.Authorization, "Bearer $token")
                }
                assertNotEquals(HttpStatusCode.Unauthorized, res.status, route)
                assertNotEquals(HttpStatusCode.Forbidden, res.status, route)
            }
            assertEquals("客厅电视", access.devices().single().name)
            assertEquals("localhost", access.devices().single().lastAddress)
        }
    }

    @Test
    fun `a refused request does not reach the route`() {
        val access = access()
        testApplication {
            application { engineModule(engine(), EngineModuleOptions(access = access)) }
            client.put("/api/v1/history/s/1") {
                contentType(ContentType.Application.Json)
                setBody("""{"site":"s","vodId":"1","name":"片"}""")
            }
            val res = client.delete("/api/v1/history/s/1") { header(HttpHeaders.Host, lanHost) }
            assertEquals(HttpStatusCode.Unauthorized, res.status)
            assertEquals(HttpStatusCode.OK, client.get("/api/v1/history/s/1").status, "the history is still there")
            val post = client.post("/api/v1/subscriptions") {
                header(HttpHeaders.Host, lanHost)
                contentType(ContentType.Application.Json)
                setBody("""{"url":"http://example.test/tv.json"}""")
            }
            assertEquals(HttpStatusCode.Unauthorized, post.status)
            assertEquals("[]", client.get("/api/v1/subscriptions").bodyAsText())
        }
    }

    @Test
    fun `with sharing off nobody else gets in, token or not, and pairing is refused`() {
        val access = access()
        testApplication {
            application { engineModule(engine(), EngineModuleOptions(access = access)) }
            val token = pairOverApi(access)
            access.setSharing(false)
            val res = client.get("/api/v1/sites") {
                header(HttpHeaders.Host, lanHost)
                header(HttpHeaders.Authorization, "Bearer $token")
            }
            assertEquals(HttpStatusCode.Forbidden, res.status)
            assertEquals("LAN_SHARING_OFF", code(res.bodyAsText()))
            val pair = client.post("/api/v1/pair") {
                header(HttpHeaders.Host, lanHost)
                contentType(ContentType.Application.Json)
                setBody("""{"code":"123456"}""")
            }
            assertEquals(HttpStatusCode.Forbidden, pair.status)
            // This machine is not affected.
            assertEquals(HttpStatusCode.OK, client.get("/api/v1/settings").status)
        }
    }

    @Test
    fun `the default access (Android app) lets only this machine in`() = testApplication {
        application { engineModule(engine()) }
        assertEquals(HttpStatusCode.OK, client.get("/api/v1/settings").status)
        assertEquals(HttpStatusCode.Forbidden, client.get("/api/v1/settings") { header(HttpHeaders.Host, lanHost) }.status)
        assertEquals(HttpStatusCode.OK, client.get("/api/v1/info") { header(HttpHeaders.Host, lanHost) }.status)
        val lan = EngineJson.parseToJsonElement(client.get("/api/v1/lan").bodyAsText()).jsonObject
        assertEquals("false", lan["supported"]!!.jsonPrimitive.content)
    }

    @Test
    fun `only this machine manages sharing and devices, even with a token`() {
        val access = access()
        testApplication {
            application { engineModule(engine(), EngineModuleOptions(access = access)) }
            val token = pairOverApi(access)
            for ((method, path) in listOf("GET" to "/api/v1/lan", "POST" to "/api/v1/lan/code", "PUT" to "/api/v1/lan", "DELETE" to "/api/v1/lan/devices/x")) {
                val res = client.request(path) {
                    this.method = io.ktor.http.HttpMethod.parse(method)
                    header(HttpHeaders.Host, lanHost)
                    header(HttpHeaders.Authorization, "Bearer $token")
                    contentType(ContentType.Application.Json)
                    setBody("""{"enabled":false}""")
                }
                assertTrue(res.status == HttpStatusCode.Forbidden || res.status == HttpStatusCode.NotFound, "$method $path: ${res.status}")
            }
            assertTrue(access.sharing)

            // Locally: status with a code and the device, revoke, switch off.
            val status = EngineJson.parseToJsonElement(client.get("/api/v1/lan").bodyAsText()).jsonObject
            assertEquals("true", status["enabled"]!!.jsonPrimitive.content)
            assertEquals(6, status["code"]!!.jsonPrimitive.content.length)
            val id = status["devices"]!!.jsonArray.single().jsonObject["id"]!!.jsonPrimitive.content
            assertEquals(HttpStatusCode.NoContent, client.delete("/api/v1/lan/devices/$id").status)
            val revoked = client.get("/api/v1/sites") {
                header(HttpHeaders.Host, lanHost)
                header(HttpHeaders.Authorization, "Bearer $token")
            }
            assertEquals(HttpStatusCode.Unauthorized, revoked.status)
            val off = client.put("/api/v1/lan") {
                contentType(ContentType.Application.Json)
                setBody("""{"enabled":false}""")
            }
            assertEquals("false", EngineJson.parseToJsonElement(off.bodyAsText()).jsonObject["enabled"]!!.jsonPrimitive.content)
            assertFalse(access.sharing)
        }
    }

    @Test
    fun `pairing - happy path, one-time code, wrong codes, expiry`() {
        val clock = Clock()
        val codes = mutableListOf<String>()
        val access = access(clock).also { it.onCode = { c, _ -> codes += c } }

        // An empty code makes the engine show one (a headless engine prints it).
        assertEquals(PairResult.CodeRequired, access.pair("", "tv", "10.0.0.2"))
        val code = codes.single()
        assertEquals(6, code.length)
        assertEquals(PairResult.CodeRequired, access.pair("", "tv", "10.0.0.2"))
        assertEquals(1, codes.size, "a code that is still good is not replaced")

        val wrong = if (code == "000000") "000001" else "000000"
        assertEquals(PairResult.Wrong(4), access.pair(wrong, "tv", "10.0.0.2"))
        val paired = access.pair(" ${code.substring(0, 3)} ${code.substring(3)} ", "客厅电视", "10.0.0.2") as PairResult.Paired
        assertEquals("客厅电视", paired.device.name)
        assertNotNull(access.deviceForToken(paired.token))
        assertFalse(paired.device.tokenHash.contains(paired.token.substringAfter('.')), "only a hash is kept")
        assertNull(access.deviceForToken(paired.token.dropLast(1) + "x"))
        assertNull(access.deviceForToken(paired.token.substringBefore('.')))

        // One-time: the same code again is wrong.
        assertTrue(access.pair(code, "other", "10.0.0.3") is PairResult.Wrong)

        // Expiry.
        val next = access.newCode().code
        clock.now += AccessControl.CODE_TTL_MS
        assertTrue(access.pair(next, "late", "10.0.0.4") is PairResult.Wrong)
        assertNull(access.currentCode())
        assertEquals(1, access.devices().size)
    }

    @Test
    fun `wrong codes lock pairing for everybody, longer each time`() {
        val clock = Clock()
        val access = access(clock)
        val code = access.newCode().code
        val wrong = if (code == "000000") "000001" else "000000"
        repeat(4) { assertTrue(access.pair(wrong, "x", "a") is PairResult.Wrong) }
        val locked = access.pair(wrong, "x", "a") as PairResult.Locked
        assertEquals(AccessControl.LOCK_BASE_MS, locked.retryAfterMs)
        // The code is burnt, and even a right code is refused while locked.
        assertNull(access.currentCode())
        clock.now += 1000
        assertTrue(access.pair(code, "x", "a") is PairResult.Locked)
        clock.now += AccessControl.LOCK_BASE_MS
        val second = access.newCode().code
        val wrong2 = if (second == "000000") "000001" else "000000"
        repeat(4) { access.pair(wrong2, "x", "a") }
        assertEquals(2 * AccessControl.LOCK_BASE_MS, (access.pair(wrong2, "x", "a") as PairResult.Locked).retryAfterMs)
        clock.now += 2 * AccessControl.LOCK_BASE_MS
        val third = access.newCode().code
        assertTrue(access.pair(third, "x", "a") is PairResult.Paired)
    }

    @Test
    fun `the lock is reported over the API with Retry-After`() {
        val access = access()
        testApplication {
            application { engineModule(engine(), EngineModuleOptions(access = access)) }
            val code = access.newCode().code
            val wrong = if (code == "000000") "000001" else "000000"
            var last: io.ktor.client.statement.HttpResponse? = null
            repeat(5) {
                last = client.post("/api/v1/pair") {
                    header(HttpHeaders.Host, lanHost)
                    contentType(ContentType.Application.Json)
                    setBody("""{"code":"$wrong"}""")
                }
            }
            assertEquals(HttpStatusCode.TooManyRequests, last!!.status)
            assertEquals("60", last!!.headers[HttpHeaders.RetryAfter])
            assertEquals("PAIR_LOCKED", code(last!!.bodyAsText()))
        }
    }

    @Test
    fun `signatures - bound to the address, the device, GET and the expiry`() {
        val clock = Clock()
        val access = access(clock)
        val device = (access.pair(access.newCode().code, "tv", "x") as PairResult.Paired).device
        val exp = clock.now + 3600_000
        val url = access.sign("http://192.168.1.5:9978/m3u8?url=https%3A%2F%2Fcdn.test%2Fa.m3u8&h=eyJ4IjoxfQ", device.id, exp)
        fun check(u: String, loopback: Boolean = false): AccessControl.Grant? {
            val rest = u.substringAfter("9978")
            return access.checkSignature(rest.substringBefore('?'), rest.substringAfter('?', ""), loopback)
        }
        assertEquals(AccessControl.Grant(device.id, exp / 1000 * 1000), check(url))
        // Parameters in another order are the same address.
        val sig = url.substringAfter("tvsig=")
        assertNotNull(check("http://x:9978/m3u8?h=eyJ4IjoxfQ&tvsig=$sig&url=https://cdn.test/a.m3u8"))
        // Another value, an added parameter, another path, a repeated parameter, two signatures: refused.
        assertNull(check(url.replace("a.m3u8", "b.m3u8")))
        assertNull(check("$url&siteKey=evil"))
        assertNull(check(url.replace("/m3u8?", "/proxy?")))
        assertNull(check(url.replace("url=", "url=https%3A%2F%2Fevil.test%2F&url=")))
        assertNull(check("$url&tvsig=$sig"))
        assertNull(check(url.substringBefore("&tvsig=")))
        val mac = sig.substringAfterLast('.')
        val changedFirst = if (mac.first() == 'A') 'B' else 'A'
        assertNull(check(url.removeSuffix(mac) + changedFirst + mac.drop(1)))
        // Expired.
        clock.now = exp
        assertNull(check(url))
        clock.now = exp - 1000
        assertNotNull(check(url))
        // Revoked device, sharing off.
        access.setSharing(false)
        assertNull(check(url))
        access.setSharing(true)
        access.revoke(device.id)
        assertNull(check(url))
        // Never for the API, and never through dot segments.
        val local = AccessControl.LOCAL
        assertNull(check(access.sign("http://x:9978/api/v1/history", local, exp), loopback = true))
        assertNull(check(access.sign("http://x:9978/API/v1/history", local, exp), loopback = true))
        assertNull(check(access.sign("http://x:9978//api/v1/history", local, exp), loopback = true))
        assertNull(check(access.sign("http://x:9978/m3u8/../api/v1/history", local, exp), loopback = true))
        // A signature for this machine is good only from this machine.
        val forLocal = access.sign("http://x:9978/proxy?do=js&a=1", local, exp)
        assertNotNull(check(forLocal, loopback = true))
        assertNull(check(forLocal, loopback = false))
    }

    @Test
    fun `play answers for a device carry signed addresses that its player can use without the header`() {
        val upstream = MockWebServer().apply { start() }
        try {
            val master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nhigh/index.m3u8\n"
            upstream.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                    "/tv.json" -> MockResponse().setBody("""{"sites":[{"key":"cms","type":1,"api":"${upstream.url("/api")}"}]}""")
                    "/master.m3u8" -> MockResponse().setBody(master)
                    else -> MockResponse().setResponseCode(404)
                }
            }
            val access = access()
            testApplication {
                application { engineModule(engine(), EngineModuleOptions(access = access)) }
                val created = client.post("/api/v1/subscriptions") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"url":"${upstream.url("/tv.json")}"}""")
                }
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content
                client.post("/api/v1/subscriptions/$id/activate")
                val token = pairOverApi(access)
                val deviceId = access.devices().single().id

                val play = EngineJson.parseToJsonElement(client.post("/api/v1/play/resolve") {
                    header(HttpHeaders.Host, lanHost)
                    header(HttpHeaders.Authorization, "Bearer $token")
                    contentType(ContentType.Application.Json)
                    setBody("""{"site":"cms","line":"x","episodeId":"${upstream.url("/master.m3u8")}"}""")
                }.bodyAsText()).jsonObject
                val url = play["url"]!!.jsonPrimitive.content
                assertTrue(url.startsWith("http://$lanHost/m3u8?url="), url)
                assertTrue(url.contains("&tvsig=") && url.contains(".$deviceId."), url)

                // The player has no token: the signature is enough, for exactly this address.
                val path = url.removePrefix("http://$lanHost")
                val playlist = client.get(path) { header(HttpHeaders.Host, lanHost) }
                assertEquals(HttpStatusCode.OK, playlist.status, playlist.bodyAsText())
                val variants = playlist.bodyAsText().lines().filter { it.startsWith("http") }
                assertEquals(2, variants.size)
                for (v in variants) {
                    assertTrue(v.startsWith("http://$lanHost/m3u8?") && v.contains("tvsig="), v)
                }
                // Variant playlists inherit the signature's expiry and work without the header too.
                // (The fake CDN has no variant playlists, so the engine sends the player to the original: 302.)
                val noRedirects = createClient { followRedirects = false }
                val variant = noRedirects.get(variants[0].removePrefix("http://$lanHost")) { header(HttpHeaders.Host, lanHost) }
                assertEquals(HttpStatusCode.Found, variant.status)

                assertEquals(HttpStatusCode.Unauthorized, client.get(path.replace("master", "other")) { header(HttpHeaders.Host, lanHost) }.status)
                assertEquals(HttpStatusCode.Unauthorized, client.post(path) { header(HttpHeaders.Host, lanHost) }.status)

                // Revoked: the signed addresses stop working too.
                access.revoke(deviceId)
                assertEquals(HttpStatusCode.Unauthorized, client.get(path) { header(HttpHeaders.Host, lanHost) }.status)

                // This machine gets addresses it can use even when its player sends another Host header.
                val local = EngineJson.parseToJsonElement(client.post("/api/v1/play/resolve") {
                    header(HttpHeaders.Host, "127.0.0.1:80")
                    contentType(ContentType.Application.Json)
                    setBody("""{"site":"cms","line":"x","episodeId":"${upstream.url("/master.m3u8")}"}""")
                }.bodyAsText()).jsonObject["url"]!!.jsonPrimitive.content
                assertTrue(local.startsWith("http://127.0.0.1:80/m3u8?") && local.contains(".local."), local)
                val viaCdnHost = client.get(local.removePrefix("http://127.0.0.1:80")) { header(HttpHeaders.Host, "cdn.test") }
                assertEquals(HttpStatusCode.OK, viaCdnHost.status)
            }
        } finally {
            upstream.shutdown()
        }
    }

    @Test
    fun `a caller from a non-loopback address is not local, whatever Host it sends`() {
        // This machine's own LAN address: a real socket, but still the same machine.
        val lanIp = NetworkInterface.getNetworkInterfaces().toList()
            .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { !it.isLinkLocalAddress }?.hostAddress
        assumeTrue(lanIp != null, "no LAN address on this machine")
        val port = ServerSocket(0).use { it.localPort }
        val access = access()
        val server = embeddedServer(CIO, port = port, host = lanIp!!) { engineModule(engine(port), EngineModuleOptions(access = access)) }.start(wait = false)
        try {
            val http = OkHttpClient()
            fun get(path: String, host: String? = null, token: String? = null): Int {
                val b = Request.Builder().url("http://$lanIp:$port$path")
                host?.let { b.header("Host", it) }
                token?.let { b.header("Authorization", "Bearer $it") }
                return http.newCall(b.build()).execute().use { it.code }
            }
            assertEquals(401, get("/api/v1/settings"))
            assertEquals(401, get("/api/v1/settings", host = "127.0.0.1:$port"), "a loopback Host header from elsewhere is not enough")
            assertEquals(200, get("/api/v1/info"))
            val token = (access.pair(access.newCode().code, "pc", "x") as PairResult.Paired).token
            assertEquals(200, get("/api/v1/settings", token = token))
            assertEquals(403, get("/api/v1/lan", host = "127.0.0.1:$port", token = token), "managing sharing is for this machine only")
            // A signature made for this machine does not work from the network.
            val local = access.sign("http://$lanIp:$port/proxy?do=ck", AccessControl.LOCAL, System.currentTimeMillis() + 60_000)
            assertEquals(401, get(local.substringAfter(":$port")))
        } finally {
            server.stop(100, 500)
        }
    }
}
