package tvbox.engine.api

import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.ApplicationTestBuilder
import io.ktor.server.testing.testApplication
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readText
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.access.AccessControl.PairResult
import tvbox.engine.api.remote.RemoteHub
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore

/**
 * The LAN remote control: the hub by itself, then over its WebSockets with the access rules in front.
 *
 * As in [AccessTest], the test host connects from "localhost" and "a phone on the LAN" is a foreign Host header:
 * nothing here crosses a real network, and no browser is involved (the page's side is in the web remote's own check).
 */
class RemoteTest {
    private val lanHost = "192.168.1.5:9978"

    private fun engine() = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:80/proxy?",
    )

    private fun access(sharing: Boolean = true) = AccessControl(MemoryStore(), supported = true).also { it.setSharing(sharing) }

    private fun AccessControl.pairDevice(name: String = "手机"): PairResult.Paired = pair(newCode().code, name, "192.168.1.20") as PairResult.Paired

    // ---- the hub by itself ----

    private class FakePeer : RemoteHub.Peer {
        val sent = ArrayList<JsonObject>()
        var closed: Pair<Int, String>? = null

        override fun send(text: String) {
            sent += EngineJson.parseToJsonElement(text).jsonObject
        }

        override fun close(code: Int, reason: String) {
            if (closed == null) closed = code to reason
        }

        fun last(type: String): JsonObject? = sent.lastOrNull { it.str("type") == type }
    }

    private val hello = """{"type":"hello","id":"tv-1","name":"客厅电脑","platform":"windows","form":"tv","version":"0.4.0"}"""

    @Test
    fun `a screen is listed, its state reaches controllers at once and on every change, commands and answers find their way`() {
        val hub = RemoteHub(clock = { 42 })
        val screenPeer = FakePeer()
        val screen = hub.screenConnected(hello, AccessControl.LOCAL, screenPeer)
        assertEquals("welcome", screenPeer.sent.single().str("type"))
        screen.receive("""{"type":"state","state":{"title":"首页","page":"browse"}}""")

        val info = hub.screens().single()
        assertEquals("tv-1", info.id)
        assertEquals("客厅电脑", info.name)
        assertEquals("tv", info.form)
        assertEquals("首页", info.title)
        assertEquals(42, info.connectedAt)
        assertEquals(0, info.controllers)

        // A controller gets the screen and the latest state before anything else.
        val phone = FakePeer()
        val controller = hub.controllerConnected("tv-1", "dev1", "我的手机", phone)
        assertEquals(listOf("screen", "state"), phone.sent.map { it.str("type") })
        assertEquals("客厅电脑", phone.sent[0]["screen"]!!.jsonObject.str("name"))
        assertEquals("首页", phone.sent[1]["state"]!!.jsonObject.str("title"))
        assertEquals(1, screenPeer.last("controllers")!!["count"]!!.jsonPrimitive.int)
        assertEquals("我的手机", screenPeer.last("controllers")!!["names"]!!.jsonArray.single().jsonPrimitive.content)
        assertEquals(1, hub.screens().single().controllers)

        screen.receive("""{"type":"state","state":{"title":"星河往事 · 第3集","player":{"paused":false,"position":1000}}}""")
        assertEquals("星河往事 · 第3集", phone.sent.last()["state"]!!.jsonObject.str("title"))

        // A command goes to the screen with who sent it; the answer comes back to that controller only.
        val other = FakePeer()
        hub.controllerConnected("tv-1", "dev2", "平板", other)
        controller.receive("""{"type":"command","id":"7","name":"key","args":{"key":"down"}}""")
        val command = screenPeer.last("command")!!
        assertEquals("key", command.str("name"))
        assertEquals("down", command["args"]!!.jsonObject.str("key"))
        assertEquals("7", command.str("id"))
        assertEquals(controller.session, command.str("from"))
        val otherSeen = other.sent.size
        screen.receive("""{"type":"result","to":"${controller.session}","id":"7","ok":false,"message":"现在没有在播放"}""")
        val result = phone.sent.last()
        assertEquals("result", result.str("type"))
        assertEquals("7", result.str("id"))
        assertEquals("false", result["ok"]!!.jsonPrimitive.content)
        assertEquals("现在没有在播放", result.str("message"))
        assertEquals(otherSeen, other.sent.size, "the other controller hears nothing of it")

        // What is not a command is dropped; a ping is answered.
        val before = screenPeer.sent.size
        controller.receive("""{"type":"state","state":{"title":"假的"}}""")
        controller.receive("""{"type":"command"}""")
        controller.receive("not json")
        assertEquals(before, screenPeer.sent.size)
        controller.receive("""{"type":"ping"}""")
        assertEquals("pong", phone.sent.last().str("type"))

        // A controller leaves: the screen hears the new count.
        controller.closed()
        assertEquals(1, screenPeer.last("controllers")!!["count"]!!.jsonPrimitive.int)

        // The screen drops: off the list, its controllers are told and let go.
        screen.closed()
        assertTrue(hub.screens().isEmpty())
        assertEquals("gone", other.sent.last().str("type"))
        assertEquals(RemoteHub.GONE, other.closed!!.first)
    }

    @Test
    fun `an answer's data goes to the controller that asked, as the screen wrote it, and only an object`() {
        val hub = RemoteHub()
        val screenPeer = FakePeer()
        val screen = hub.screenConnected(hello, AccessControl.LOCAL, screenPeer)
        val phone = FakePeer()
        val asking = hub.controllerConnected("tv-1", "dev1", "我的手机", phone)
        val other = FakePeer()
        hub.controllerConnected("tv-1", "dev2", "平板", other)
        val otherSeen = other.sent.size

        asking.receive("""{"type":"command","id":"d1","name":"diag.log","args":{"after":3,"limit":2}}""")
        val command = screenPeer.last("command")!!
        assertEquals("diag.log", command.str("name"))
        assertEquals(3, command["args"]!!.jsonObject["after"]!!.jsonPrimitive.int)
        val data = """{"entries":[{"seq":4,"time":"2026-11-22T12:00:00.000Z","level":"warn","module":"播放器","message":"缓冲见底","detail":{"线路":"线路 2"}}],"next":4,"nested":{"a":[1,2,{"b":null}]}}"""
        screen.receive("""{"type":"result","to":"${asking.session}","id":"d1","ok":true,"message":"","data":$data}""")
        val result = phone.sent.last()
        assertEquals("result", result.str("type"))
        assertEquals("d1", result.str("id"))
        assertEquals("true", result["ok"]!!.jsonPrimitive.content)
        assertEquals(EngineJson.parseToJsonElement(data), result["data"], "passed on untouched")
        assertNull(result["to"], "who it was for stays in the engine")
        assertEquals(otherSeen, other.sent.size, "the other controller hears nothing of it")

        // A failure may carry data too.
        screen.receive("""{"type":"result","to":"${asking.session}","id":"d2","ok":false,"message":"密码不对","data":{"locked":true}}""")
        assertEquals("false", phone.sent.last()["ok"]!!.jsonPrimitive.content)
        assertEquals("true", phone.sent.last()["data"]!!.jsonObject["locked"]!!.jsonPrimitive.content)

        // Data that is not an object is dropped, the answer still arrives; an answer without data has none.
        for ((i, wrong) in listOf("[1,2]", "\"text\"", "42", "null", "true").withIndex()) {
            screen.receive("""{"type":"result","to":"${asking.session}","id":"w$i","ok":true,"data":$wrong}""")
            val answer = phone.sent.last()
            assertEquals("w$i", answer.str("id"), wrong)
            assertFalse(answer.containsKey("data"), "$wrong is not passed on")
        }
        screen.receive("""{"type":"result","to":"${asking.session}","id":"old","ok":true,"message":"好了"}""")
        assertEquals(setOf("type", "id", "ok", "message"), phone.sent.last().keys, "an answer as before")
        assertEquals(otherSeen, other.sent.size)
    }

    @Test
    fun `only a client that registered itself can be driven`() {
        val hub = RemoteHub()
        // A client that has not switched the remote control on never connects: there is nothing to drive.
        val refused = assertThrows(RemoteHub.Refused::class.java) { hub.controllerConnected("tv-1", "dev1", "手机", FakePeer()) }
        assertEquals(RemoteHub.NO_SCREEN, refused.code)

        val screen = hub.screenConnected(hello, AccessControl.LOCAL, FakePeer())
        hub.controllerConnected("tv-1", "dev1", "手机", FakePeer())
        // And once it switched it off again (its connection ends), neither.
        screen.closed()
        assertEquals(RemoteHub.NO_SCREEN, assertThrows(RemoteHub.Refused::class.java) { hub.controllerConnected("tv-1", "dev1", "手机", FakePeer()) }.code)
    }

    @Test
    fun `hello is checked, a second connection with the same id replaces the first, and there are limits`() {
        val hub = RemoteHub()
        for (bad in listOf("", "not json", """{"type":"state"}""", """{"type":"hello"}""", """{"type":"hello","id":"a b"}""", """{"type":"hello","id":"${"x".repeat(65)}"}""")) {
            assertEquals(RemoteHub.BAD_MESSAGE, assertThrows(RemoteHub.Refused::class.java) { hub.screenConnected(bad, "local", FakePeer()) }.code, bad)
        }
        // Names are cut and cleaned; a screen without one still has one.
        hub.screenConnected("""{"type":"hello","id":"n1","name":"  a\u0007b${"长".repeat(60)}  "}""", "local", FakePeer())
        assertEquals("ab" + "长".repeat(38), hub.screens().single { it.id == "n1" }.name)
        hub.screenConnected("""{"type":"hello","id":"n2"}""", "local", FakePeer())
        assertEquals("映舟", hub.screens().single { it.id == "n2" }.name)

        val firstPeer = FakePeer()
        val first = hub.screenConnected(hello, "local", firstPeer)
        val phone = FakePeer()
        hub.controllerConnected("tv-1", "dev1", "手机", phone)
        val secondPeer = FakePeer()
        hub.screenConnected(hello, "local", secondPeer)
        assertEquals(RemoteHub.REPLACED, firstPeer.closed!!.first)
        assertEquals(RemoteHub.GONE, phone.closed!!.first, "its controllers connect again, to the new one")
        // The old connection ending afterwards does not take the new one off the list.
        first.closed()
        assertEquals(1, hub.screens().count { it.id == "tv-1" })
        assertNull(secondPeer.closed)
        // Nor does state from the old connection reach anybody.
        val late = FakePeer()
        hub.controllerConnected("tv-1", "dev1", "手机", late)
        first.receive("""{"type":"state","state":{"title":"旧的"}}""")
        assertEquals(listOf("screen"), late.sent.map { it.str("type") })

        repeat(RemoteHub.MAX_CONTROLLERS - 1) { hub.controllerConnected("tv-1", "dev1", "手机", FakePeer()) }
        assertEquals(RemoteHub.TOO_MANY, assertThrows(RemoteHub.Refused::class.java) { hub.controllerConnected("tv-1", "dev1", "手机", FakePeer()) }.code)
        repeat(RemoteHub.MAX_SCREENS - 3) { hub.screenConnected("""{"type":"hello","id":"s$it"}""", "local", FakePeer()) }
        assertEquals(RemoteHub.TOO_MANY, assertThrows(RemoteHub.Refused::class.java) { hub.screenConnected("""{"type":"hello","id":"one-more"}""", "local", FakePeer()) }.code)
        // A screen that is already here may still come back.
        hub.screenConnected(hello, "local", FakePeer())
    }

    // ---- over HTTP ----

    private fun remoteTest(access: AccessControl, hub: RemoteHub = RemoteHub(), block: suspend ApplicationTestBuilder.(HttpClient) -> Unit) = testApplication {
        application { engineModule(engine(), EngineModuleOptions(access = access, remote = hub)) }
        block(createClient { install(WebSockets) })
    }

    /**
     * What a browser on the LAN sends to open a socket, as a plain request, to read how it is refused (a WebSocket
     * client only says that the handshake failed; the test client does not let `Upgrade` be set by hand, and the
     * access rules do not look at it). With [socket], then the same through the WebSocket client, which must fail too
     * (a second each in the test host, so not every time).
     */
    private suspend fun HttpClient.handshake(
        path: String, token: String? = null, origin: String? = null, host: String? = lanHost, bearer: String? = null, socket: Boolean = false,
    ): HttpResponse {
        val request: HttpRequestBuilder.() -> Unit = {
            host?.let { header(HttpHeaders.Host, it) }
            header(HttpHeaders.SecWebSocketProtocol, protocols(token))
            origin?.let { header(HttpHeaders.Origin, it) }
            bearer?.let { header(HttpHeaders.Authorization, "Bearer $it") }
        }
        val response = get(path, request)
        if (socket) {
            val opened = runCatching { webSocket(path, request) {} }
            assertTrue(opened.isFailure, "$path: the socket opened although the request is refused with ${response.status}")
        }
        return response
    }

    private fun protocols(token: String?) = listOfNotNull(RemoteHub.PROTOCOL, token?.let { RemoteHub.TOKEN_PROTOCOL + it }).joinToString(", ")

    /** The request of a browser on the LAN: its token as a subprotocol, its page's origin. */
    private fun phone(token: String?): HttpRequestBuilder.() -> Unit = {
        header(HttpHeaders.Host, lanHost)
        header(HttpHeaders.Origin, "http://$lanHost")
        header(HttpHeaders.SecWebSocketProtocol, protocols(token))
    }

    private fun code(body: String) = runCatching { EngineJson.parseToJsonElement(body).jsonObject["error"]?.jsonObject?.str("code") }.getOrNull()

    private suspend fun DefaultClientWebSocketSession.next(type: String): JsonObject = withTimeout(10_000) {
        while (true) {
            val msg = EngineJson.parseToJsonElement((incoming.receive() as Frame.Text).readText()).jsonObject
            if (msg.str("type") == type) return@withTimeout msg
        }
        @Suppress("UNREACHABLE_CODE")
        error("unreachable")
    }

    private suspend fun DefaultClientWebSocketSession.say(text: String) = send(Frame.Text(text))

    @Test
    fun `from another device both sockets need a paired token - none, a wrong one, sharing off`() {
        val access = access()
        remoteTest(access) { ws ->
            val sockets = listOf("/api/v1/remote/screen", "/api/v1/remote/control?screen=tv-1")
            for (path in sockets + "/api/v1/remote/screens") {
                val none = ws.handshake(path, socket = path in sockets)
                assertEquals(HttpStatusCode.Unauthorized, none.status, path)
                assertEquals("UNAUTHORIZED", code(none.bodyAsText()), path)
                for (wrong in listOf("abc.def", "abc", "..", access.pairDevice().let { it.token.dropLast(2) + "xx" })) {
                    assertEquals(HttpStatusCode.Unauthorized, ws.handshake(path, token = wrong).status, "$path with $wrong as a subprotocol")
                    assertEquals(HttpStatusCode.Unauthorized, ws.handshake(path, bearer = wrong).status, "$path with $wrong as a bearer token")
                }
            }
            // A revoked device's token is a wrong one.
            val revoked = access.pairDevice()
            access.revoke(revoked.device.id)
            assertEquals(HttpStatusCode.Unauthorized, ws.handshake(sockets[0], token = revoked.token, socket = true).status)

            // Sharing off: nobody else gets in, token or not.
            val paired = access.pairDevice()
            access.setSharing(false)
            for (path in sockets + "/api/v1/remote/screens") {
                val off = ws.handshake(path, token = paired.token, socket = path == sockets[1])
                assertEquals(HttpStatusCode.Forbidden, off.status, path)
                assertEquals("LAN_SHARING_OFF", code(off.bodyAsText()), path)
            }
            // This machine is not affected by any of it.
            ws.webSocket("/api/v1/remote/screen") {
                say(hello)
                assertEquals("tv-1", next("welcome").str("id"))
            }
        }
    }

    @Test
    fun `the token as a subprotocol is taken on the two sockets only, and is not echoed`() {
        val access = access()
        remoteTest(access) { ws ->
            val token = access.pairDevice().token
            // Anywhere else the header means nothing.
            val sites = ws.get("/api/v1/sites") {
                header(HttpHeaders.Host, lanHost)
                header(HttpHeaders.SecWebSocketProtocol, protocols(token))
            }
            assertEquals(HttpStatusCode.Unauthorized, sites.status)
            val list = ws.get("/api/v1/remote/screens") {
                header(HttpHeaders.Host, lanHost)
                header(HttpHeaders.SecWebSocketProtocol, protocols(token))
            }
            assertEquals(HttpStatusCode.Unauthorized, list.status, "the list is a plain request: a bearer token")
            assertEquals(HttpStatusCode.OK, ws.get("/api/v1/remote/screens") {
                header(HttpHeaders.Host, lanHost)
                header(HttpHeaders.Authorization, "Bearer $token")
            }.status)

            ws.webSocket("/api/v1/remote/screen", request = phone(token)) {
                // Browsers want one of the protocols they offered back; the token is never that one.
                assertEquals(RemoteHub.PROTOCOL, call.response.headers[HttpHeaders.SecWebSocketProtocol])
                say(hello)
                next("welcome")
            }
            // A program can send the usual header instead, and may leave the subprotocol out.
            ws.webSocket("/api/v1/remote/screen", request = {
                header(HttpHeaders.Host, lanHost)
                header(HttpHeaders.Authorization, "Bearer $token")
            }) {
                assertNull(call.response.headers[HttpHeaders.SecWebSocketProtocol])
                say(hello)
                next("welcome")
            }
        }
    }

    @Test
    fun `pages of other sites cannot open the sockets, not even in a browser on this machine`() {
        val access = access()
        remoteTest(access) { ws ->
            val token = access.pairDevice().token
            // On this machine a caller needs no token, which is exactly why the page's origin is checked.
            for (path in listOf("/api/v1/remote/screen", "/api/v1/remote/control?screen=tv-1")) {
                for (origin in listOf("http://evil.example", "http://127.0.0.1:9999", "null")) {
                    val local = ws.handshake(path, origin = origin, host = null, socket = origin == "http://evil.example")
                    assertEquals(HttpStatusCode.Forbidden, local.status, "$path from $origin")
                    assertEquals("BAD_ORIGIN", code(local.bodyAsText()))
                    assertEquals(HttpStatusCode.Forbidden, ws.handshake(path, token = token, origin = origin).status, "$path from $origin with a token")
                }
            }
            // The web remote itself: the origin is the address the engine was reached at.
            ws.webSocket("/api/v1/remote/screen", request = phone(token)) {
                say(hello)
                next("welcome")
            }
            // And the web remote opened in a browser on this machine (no token there).
            ws.webSocket("/api/v1/remote/screen", request = {
                header(HttpHeaders.Host, "127.0.0.1:9978")
                header(HttpHeaders.Origin, "http://127.0.0.1:9978")
            }) {
                say(hello)
                next("welcome")
            }
        }
    }

    @Test
    fun `a screen on this machine is driven by a paired phone on the LAN`() {
        val access = access()
        val hub = RemoteHub()
        remoteTest(access, hub) { ws ->
            val token = access.pairDevice("我的手机").token
            ws.webSocket("/api/v1/remote/screen") {
                val screen = this
                say(hello)
                next("welcome")
                say("""{"type":"state","state":{"title":"首页","page":"browse"}}""")

                // The phone finds the screen in the list (the state went through the hub by then or does so now).
                val listed = withTimeout(5000) {
                    var found: JsonObject? = null
                    while (found == null) {
                        val all = EngineJson.parseToJsonElement(ws.get("/api/v1/remote/screens") {
                            header(HttpHeaders.Host, lanHost)
                            header(HttpHeaders.Authorization, "Bearer $token")
                        }.bodyAsText()).jsonArray
                        found = all.map { it.jsonObject }.firstOrNull { it.str("title") == "首页" }
                    }
                    found
                }
                assertEquals("tv-1", listed.str("id"))
                assertEquals("windows", listed.str("platform"))

                ws.webSocket("/api/v1/remote/control?screen=tv-1", request = phone(token)) {
                    assertEquals("客厅电脑", next("screen")["screen"]!!.jsonObject.str("name"))
                    assertEquals("首页", next("state")["state"]!!.jsonObject.str("title"))
                    assertEquals("我的手机", screen.next("controllers")["names"]!!.jsonArray.single().jsonPrimitive.content)

                    say("""{"type":"command","id":"1","name":"key","args":{"key":"ok"}}""")
                    val command = screen.next("command")
                    assertEquals("ok", command["args"]!!.jsonObject.str("key"))
                    screen.say("""{"type":"result","to":"${command.str("from")}","id":"1","ok":true}""")
                    assertEquals("true", next("result")["ok"]!!.jsonPrimitive.content)

                    screen.say("""{"type":"state","state":{"title":"星河往事 · 第1集","player":{"paused":true}}}""")
                    assertEquals("true", next("state")["state"]!!.jsonObject["player"]!!.jsonObject["paused"]!!.jsonPrimitive.content)

                    say("""{"type":"ping"}""")
                    next("pong")
                }
                // The phone left.
                assertEquals(0, withTimeout(5000) {
                    var count = 1
                    while (count != 0) count = screen.next("controllers")["count"]!!.jsonPrimitive.int
                    count
                })
            }
            // The screen left: it is off the list.
            withTimeout(5000) { while (hub.screens().isNotEmpty()) kotlinx.coroutines.delay(20) }
        }
    }

    @Test
    fun `a long answer with data reaches the phone over the sockets, and a message past the limit still ends the screen`() {
        val access = access()
        remoteTest(access) { ws ->
            val token = access.pairDevice().token
            ws.webSocket("/api/v1/remote/screen") {
                val screen = this
                say(hello)
                next("welcome")
                ws.webSocket("/api/v1/remote/control?screen=tv-1", request = phone(token)) {
                    next("screen")
                    say("""{"type":"command","id":"r","name":"diag.report","args":{}}""")
                    val command = screen.next("command")
                    // The whole diagnostic text, far longer than a message or a command may be.
                    val text = "映舟诊断信息\n" + "日志一行\n".repeat(60 * 1024)
                    screen.say(
                        buildJsonObject {
                            put("type", "result"); put("to", command.str("from")); put("id", "r"); put("ok", true); put("message", "")
                            put("data", buildJsonObject { put("text", text) })
                        }.toString(),
                    )
                    val answer = next("result")
                    assertEquals("r", answer.str("id"))
                    assertEquals(text, answer["data"]!!.jsonObject.str("text"))
                }
                say("""{"type":"result","to":"c1","id":"x","ok":true,"data":{"text":"${"x".repeat(RemoteHub.MAX_SCREEN_MESSAGE)}"}}""")
                assertEquals(CloseReason.Codes.TOO_BIG.code, withTimeout(5000) { closeReason.await() }!!.code)
            }
        }
    }

    @Test
    fun `no such screen, and a screen that goes away, end the controller with a reason`() {
        val access = access()
        remoteTest(access) { ws ->
            val token = access.pairDevice().token
            ws.webSocket("/api/v1/remote/control?screen=nobody", request = phone(token)) {
                assertEquals(RemoteHub.NO_SCREEN.toShort(), withTimeout(5000) { closeReason.await() }!!.code)
            }
            ws.webSocket("/api/v1/remote/screen") {
                // Anything but a hello first ends it.
                say("""{"type":"state","state":{}}""")
                assertEquals(RemoteHub.BAD_MESSAGE.toShort(), withTimeout(5000) { closeReason.await() }!!.code)
            }
            ws.webSocket("/api/v1/remote/control?screen=tv-1", request = phone(token)) {
                assertEquals(RemoteHub.NO_SCREEN.toShort(), withTimeout(5000) { closeReason.await() }!!.code, "that screen never got in")
            }
            val control = ws.webSocketSessionOf("/api/v1/remote/screen") { screen ->
                screen.say(hello)
                screen.next("welcome")
                ws.webSocket("/api/v1/remote/control?screen=tv-1", request = phone(token)) {
                    next("screen")
                    screen.close()
                    next("gone")
                    assertEquals(RemoteHub.GONE.toShort(), withTimeout(5000) { closeReason.await() }!!.code)
                }
            }
            assertNotNull(control)
        }
    }

    @Test
    fun `a connection does not outlive its pairing or LAN sharing`() {
        val access = access()
        val hub = RemoteHub()
        remoteTest(access, hub) { ws ->
            val paired = access.pairDevice()
            ws.webSocket("/api/v1/remote/screen") {
                say(hello)
                next("welcome")
                ws.webSocket("/api/v1/remote/control?screen=tv-1", request = phone(paired.token)) {
                    next("screen")
                    access.revoke(paired.device.id)
                    assertEquals(RemoteHub.NOT_ALLOWED.toShort(), withTimeout(15_000) { closeReason.await() }!!.code)
                }
                val second = access.pairDevice()
                ws.webSocket("/api/v1/remote/control?screen=tv-1", request = phone(second.token)) {
                    next("screen")
                    access.setSharing(false)
                    assertEquals(RemoteHub.NOT_ALLOWED.toShort(), withTimeout(15_000) { closeReason.await() }!!.code)
                }
                // The screen is on this machine: it stays.
                say("""{"type":"ping"}""")
                next("pong")
                assertFalse(hub.screens().isEmpty())
            }
        }
    }

    @Test
    fun `the web remote's page is public and nothing else is served under it`() {
        val access = access()
        remoteTest(access) { ws ->
            val noRedirects = createClient { followRedirects = false }
            val redirect = noRedirects.get("/remote") { header(HttpHeaders.Host, lanHost) }
            assertEquals(HttpStatusCode.Found, redirect.status)
            assertEquals("/remote/", redirect.headers[HttpHeaders.Location])
            for ((file, type) in listOf("" to "text/html", "index.html" to "text/html", "remote.js" to "text/javascript", "remote.css" to "text/css", "icon.svg" to "image/svg+xml", "manifest.webmanifest" to "application/manifest+json")) {
                val res = ws.get("/remote/$file") { header(HttpHeaders.Host, lanHost) }
                assertEquals(HttpStatusCode.OK, res.status, file)
                assertTrue(res.headers[HttpHeaders.ContentType]!!.startsWith(type), "$file: ${res.headers[HttpHeaders.ContentType]}")
                assertTrue(res.headers["Content-Security-Policy"]!!.contains("script-src 'self'"), file)
                assertTrue(res.bodyAsText().isNotEmpty(), file)
            }
            // The page loads nothing from anywhere else and has no inline script.
            val page = ws.get("/remote/").bodyAsText()
            assertFalse(Regex("""(src|href)\s*=\s*["'](https?:)?//""").containsMatchIn(page), "the page refers to another host")
            assertFalse(Regex("""<script(?![^>]*\bsrc=)""").containsMatchIn(page), "inline script")
            for (other in listOf("/remote/nothing.txt", "/remote/..%2Fapplication.conf", "/remote/a/b", "/remote/index.html/x")) {
                assertEquals(HttpStatusCode.NotFound, ws.get(other) { header(HttpHeaders.Host, lanHost) }.status, other)
            }
            // Only reading it is public.
            assertEquals(HttpStatusCode.Unauthorized, ws.get("/remotely") { header(HttpHeaders.Host, lanHost) }.status)
        }
        // An engine without the remote control has neither the page nor the routes.
        testApplication {
            application { engineModule(engine(), EngineModuleOptions(access = access)) }
            assertEquals(HttpStatusCode.NotFound, client.get("/remote/").status)
            assertEquals(HttpStatusCode.NotFound, client.get("/api/v1/remote/screens").status)
        }
    }
}

private fun JsonObject.str(name: String): String? = this[name]?.jsonPrimitive?.takeIf { it.isString }?.content

/** Opens a socket, runs [block] with it and closes it: for when the socket is to be closed from inside another one. */
private suspend fun <T> HttpClient.webSocketSessionOf(path: String, block: suspend (DefaultClientWebSocketSession) -> T): T {
    var result: Result<T>? = null
    webSocket(path) { result = runCatching { block(this) } }
    return result!!.getOrThrow()
}
