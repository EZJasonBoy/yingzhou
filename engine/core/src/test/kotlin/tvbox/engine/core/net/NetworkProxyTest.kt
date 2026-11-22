package tvbox.engine.core.net

import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.EngineException
import tvbox.engine.core.model.EngineSettings
import java.net.InetAddress
import java.net.Proxy

class NetworkProxyTest {
    @Test
    fun `only selected purposes use the proxy and local services remain reachable`() {
        MockWebServer().use { upstream ->
            MockWebServer().use { forwarder ->
                upstream.start()
                forwarder.start()
                val dns = object : Dns {
                    override fun lookup(hostname: String): List<InetAddress> = listOf(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
                }
                val base = OkHttpClient.Builder().proxy(Proxy.NO_PROXY).dns(dns).build()
                val routing = NetworkProxy()
                val config = routing.client(base, NetworkProxy.CONFIG)
                val modules = routing.client(base, NetworkProxy.MODULES)
                val playback = routing.client(base, NetworkProxy.PLAYBACK)
                val publicUrl = "http://source.example:${upstream.port}/file"
                fun fetch(client: OkHttpClient, url: String = publicUrl): String? =
                    client.newCall(Request.Builder().url(url).build()).execute().use { it.body?.string() }

                val endpoint = "127.0.0.1:${forwarder.port}"
                val settings = routing.apply(EngineSettings(httpProxy = "http://$endpoint/", proxyScopes = listOf("config", "config")))
                assertEquals(listOf("config"), settings.proxyScopes)
                assertEquals(endpoint, settings.httpProxy)
                forwarder.enqueue(MockResponse().setBody("via proxy"))
                assertEquals("via proxy", fetch(config))
                assertTrue(forwarder.takeRequest().requestLine.contains(publicUrl))
                for (client in listOf(modules, playback)) {
                    upstream.enqueue(MockResponse().setBody("direct"))
                    assertEquals("direct", fetch(client))
                }
                upstream.enqueue(MockResponse().setBody("local"))
                assertEquals("local", fetch(config, upstream.url("/demo").toString()))

                routing.apply(settings.copy(proxyScopes = listOf("modules", "playback")))
                upstream.enqueue(MockResponse().setBody("direct again"))
                assertEquals("direct again", fetch(config))
                for (client in listOf(modules, playback)) {
                    forwarder.enqueue(MockResponse().setBody("via proxy"))
                    assertEquals("via proxy", fetch(client))
                }
            }
        }
    }

    @Test
    fun `invalid proxy cannot replace a working policy and IPv6 and local addresses are understood`() {
        val routing = NetworkProxy()
        val valid = routing.apply(EngineSettings(httpProxy = "[::1]:8080", proxyScopes = listOf("modules")))
        assertEquals("[::1]:8080", valid.httpProxy)
        for (invalid in listOf("host", "host:0", "host:65536", "localhost:80/path", "socks://localhost:80", "http://secret@host:80")) {
            assertThrows(EngineException.BadRequest::class.java) { routing.apply(valid.copy(httpProxy = invalid)) }
            assertEquals(valid.httpProxy, routing.endpoint(NetworkProxy.MODULES))
        }
        for (name in listOf("localhost", "nas", "screen.local", "10.0.1.2", "127.0.0.5", "172.16.1.2", "192.168.2.3", "[::1]", "[fd00::2]")) assertTrue(NetworkProxy.isLocal(name), name)
        for (name in listOf("open.example", "11.1.1.1", "2001:4860:4860::8888")) assertFalse(NetworkProxy.isLocal(name), name)
    }
}
