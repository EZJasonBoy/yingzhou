package tvbox.engine.api

import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.access.LanAnnouncer
import tvbox.engine.api.access.LanListeners
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore
import java.net.ServerSocket

/**
 * LAN sharing as every platform does it ([LanListeners]): listeners per address started and stopped with the switch
 * and with the network, the announcer told where the engine is, and the platform told when sharing starts and stops
 * (the Android app's foreground service). The last test runs real servers on this machine's LAN address.
 */
class LanListenersTest {
    private class FakeAnnouncer : LanAnnouncer {
        val updates = ArrayList<List<String>>()
        override fun update(addresses: List<String>, name: String, port: Int) {
            updates += addresses
        }
        override val announced: Boolean get() = updates.lastOrNull()?.isNotEmpty() == true
    }

    private class Listener(val ip: String) : AutoCloseable {
        var closed = false
        override fun close() {
            closed = true
        }
    }

    private class Setup(sharing: Boolean = false, vararg ips: String) {
        val access = AccessControl(MemoryStore(), supported = true).also { it.setSharing(sharing) }
        var ips = ips.toList()
        val started = ArrayList<Listener>()
        val refuse = HashSet<String>()
        val announcer = FakeAnnouncer()
        val sharingEvents = ArrayList<Boolean>()
        val lan = LanListeners(
            access, 9978, "映舟 · 测试",
            listen = { ip ->
                if (ip in refuse) throw java.io.IOException("address in use")
                Listener(ip).also { started += it }
            },
            announcer = announcer,
            addresses = { this.ips },
            log = {},
            onSharing = { sharingEvents += it },
            refreshSeconds = 3600,
        )
        fun open() = started.filter { !it.closed }.map { it.ip }
    }

    @Test
    fun `off by default nothing listens, and switching on listens on every address and announces them`() {
        val s = Setup(sharing = false, "192.168.1.5", "10.0.0.7")
        s.lan.start()
        assertTrue(s.started.isEmpty(), "nothing listens on the network while sharing is off")
        assertFalse(s.lan.status().listening)
        assertTrue(s.sharingEvents.isEmpty())

        s.access.setSharing(true)
        s.lan.apply(true)
        assertEquals(listOf("192.168.1.5", "10.0.0.7"), s.open())
        val status = s.lan.status()
        assertTrue(status.listening)
        assertEquals(listOf("http://192.168.1.5:9978", "http://10.0.0.7:9978"), status.addresses)
        assertTrue(status.discoverable)
        assertEquals(listOf("192.168.1.5", "10.0.0.7"), s.announcer.updates.last())
        assertEquals(listOf(true), s.sharingEvents, "the platform hears that sharing started, once")
        assertTrue(s.access.currentCode() != null, "a pairing code is showing")

        // Applying the same switch again changes nothing and is not reported again.
        s.lan.apply(true)
        assertEquals(2, s.started.size)
        assertEquals(listOf(true), s.sharingEvents)

        s.access.setSharing(false)
        s.lan.apply(false)
        assertTrue(s.open().isEmpty(), "every extra listener is stopped")
        assertEquals(emptyList<String>(), s.announcer.updates.last(), "and the announcement withdrawn")
        assertFalse(s.lan.status().listening)
        assertFalse(s.lan.status().discoverable)
        assertEquals(listOf(true, false), s.sharingEvents)
        s.lan.stop()
    }

    @Test
    fun `a saved switch that is on starts sharing at start`() {
        val s = Setup(sharing = true, "192.168.1.5")
        s.lan.start()
        assertEquals(listOf("192.168.1.5"), s.open())
        assertEquals(listOf(true), s.sharingEvents)
        s.lan.stop()
        assertTrue(s.open().isEmpty())
    }

    @Test
    fun `addresses that come and go are followed`() {
        val s = Setup(sharing = true, "192.168.1.5")
        s.lan.start()
        // Wi-Fi changes: the old address goes, a new one comes, and a cable is plugged in.
        s.ips = listOf("192.168.2.9", "10.0.0.7")
        s.lan.apply(true)
        assertEquals(listOf("192.168.2.9", "10.0.0.7"), s.open())
        assertTrue(s.started.first { it.ip == "192.168.1.5" }.closed)
        assertEquals(listOf("192.168.2.9", "10.0.0.7"), s.announcer.updates.last())
        // No network at all: sharing stays on, but nothing listens and nothing is announced.
        s.ips = emptyList()
        s.lan.apply(true)
        assertTrue(s.open().isEmpty())
        assertFalse(s.lan.status().listening)
        assertFalse(s.lan.status().discoverable)
        assertEquals(listOf(true), s.sharingEvents, "losing the network does not switch sharing off")
        s.lan.stop()
    }

    @Test
    fun `an address that cannot be listened on is reported and tried again`() {
        val s = Setup(sharing = true, "192.168.1.5", "10.0.0.7")
        s.refuse += "10.0.0.7"
        s.lan.start()
        assertEquals(listOf("192.168.1.5"), s.open())
        assertTrue("10.0.0.7:9978 无法监听" in s.lan.status().error, s.lan.status().error)
        assertEquals(listOf("192.168.1.5"), s.announcer.updates.last(), "only where it listens")
        s.refuse.clear()
        s.lan.apply(true)
        assertEquals(listOf("192.168.1.5", "10.0.0.7"), s.open())
        assertEquals("", s.lan.status().error)
        s.lan.stop()
    }

    @Test
    fun `bound to every address (--lan) it starts no servers of its own but still announces`() {
        val access = AccessControl(MemoryStore(), supported = true, forced = true)
        val started = ArrayList<String>()
        val announcer = FakeAnnouncer()
        val lan = LanListeners(access, 9978, "n", boundToAll = true, listen = { started += it; AutoCloseable {} }, announcer = announcer, addresses = { listOf("192.168.1.5") }, log = {})
        lan.start()
        assertTrue(started.isEmpty())
        assertTrue(lan.status().listening)
        assertEquals(listOf("http://192.168.1.5:9978"), lan.status().addresses)
        assertEquals(listOf("192.168.1.5"), announcer.updates.last())
        lan.stop()
    }

    @Test
    fun `the switch in the app starts a real listener on the LAN address, where devices must pair`() {
        val lanIp = LanListeners.lanAddresses().firstOrNull()
        assumeTrue(lanIp != null, "no LAN address on this machine")
        val port = ServerSocket(0).use { it.localPort }
        val access = AccessControl(MemoryStore(), supported = true)
        val engine = Engine(
            EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
            ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:$port/file/")),
            SiteHttp(OkHttpClient()),
            proxyBase = "http://127.0.0.1:$port/proxy?",
        )
        val module: io.ktor.server.application.Application.() -> Unit = { engineModule(engine, EngineModuleOptions(access = access)) }
        val sharing = ArrayList<Boolean>()
        val lan = LanListeners(
            access, port, "test",
            listen = { ip -> embeddedServer(CIO, port = port, host = ip, module = module).start(wait = false).let { s -> AutoCloseable { s.stop(100, 500) } } },
            addresses = { listOf(lanIp!!) },
            log = {},
            onSharing = { sharing += it },
        )
        val local = embeddedServer(CIO, port = port, host = "127.0.0.1", module = module).start(wait = false)
        lan.start()
        val http = OkHttpClient()
        fun call(url: String, method: String = "GET", body: String? = null, token: String? = null): Pair<Int, String> {
            val b = Request.Builder().url(url).method(method, body?.toRequestBody("application/json".toMediaType()))
            token?.let { b.header("Authorization", "Bearer $it") }
            return runCatching { http.newCall(b.build()).execute().use { it.code to it.body!!.string() } }.getOrDefault(-1 to "")
        }
        try {
            assertEquals(-1, call("http://$lanIp:$port/api/v1/info").first, "nothing on the LAN address while sharing is off")
            val on = call("http://127.0.0.1:$port/api/v1/lan", "PUT", """{"enabled":true}""")
            assertEquals(200, on.first, on.second)
            val status = EngineJson.parseToJsonElement(on.second).jsonObject
            assertEquals("true", status["listening"]!!.jsonPrimitive.content)
            assertEquals(listOf(true), sharing)
            val code = status["code"]!!.jsonPrimitive.content

            assertEquals(200, call("http://$lanIp:$port/api/v1/info").first)
            assertEquals(401, call("http://$lanIp:$port/api/v1/sites").first, "another device needs a token")
            val paired = call("http://$lanIp:$port/api/v1/pair", "POST", """{"code":"$code","name":"tv"}""")
            assertEquals(200, paired.first, paired.second)
            val token = EngineJson.parseToJsonElement(paired.second).jsonObject["token"]!!.jsonPrimitive.content
            assertEquals(200, call("http://$lanIp:$port/api/v1/settings", token = token).first)
            assertEquals(403, call("http://$lanIp:$port/api/v1/lan", "PUT", """{"enabled":false}""", token = token).first, "only the device itself switches sharing")

            assertEquals(200, call("http://127.0.0.1:$port/api/v1/lan", "PUT", """{"enabled":false}""").first)
            assertEquals(listOf(true, false), sharing)
            assertEquals(-1, call("http://$lanIp:$port/api/v1/info").first, "the LAN listener is gone again")
            assertEquals(200, call("http://127.0.0.1:$port/api/v1/info").first, "the app's own address was never interrupted")
        } finally {
            lan.stop()
            local.stop(100, 500)
        }
    }
}
