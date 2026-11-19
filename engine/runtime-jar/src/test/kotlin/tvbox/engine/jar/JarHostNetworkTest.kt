package tvbox.engine.jar

import com.github.catvod.net.OkHttp
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotSame
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.net.ConfigNetwork
import tvbox.engine.jarhost.HostBridge
import java.net.InetAddress
import java.net.UnknownHostException

/** What jar spiders request through the host's `com.github.catvod.net.OkHttp` follows the active config. */
class JarHostNetworkTest {
    private val server = MockWebServer()

    /** No name exists outside the config's `hosts`. */
    private val nothing = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> =
            ConfigNetwork.literal(hostname)?.let { listOf(it) } ?: throw UnknownHostException(hostname)
    }
    private val network = ConfigNetwork(nothing)

    @BeforeEach
    fun start() {
        server.start()
        HostBridge.baseClient = network.install(OkHttpClient.Builder()).build()
        OkHttp.reset()
    }

    @AfterEach
    fun stop() {
        HostBridge.baseClient = null
        OkHttp.reset()
        server.shutdown()
    }

    @Test
    fun `the host's http helper resolves with the config's hosts and sends the config's headers`() {
        fun url(host: String) = "http://$host:${server.port}/x"
        assertEquals("", OkHttp.string(url("jar.test")), "an unknown name: the helper answers with nothing")

        network.onConfig(TvboxConfig(hosts = mapOf("jar.test" to "127.0.0.1"), headersJson = """[{"host":"jar.test","header":{"X-Config":"1"}}]"""))
        server.enqueue(MockResponse().setBody("one"))
        assertEquals("one", OkHttp.string(url("jar.test")))
        assertEquals("1", server.takeRequest().getHeader("X-Config"))

        // Names a spider adds to the helper's own table are looked up in it first, then by the engine.
        OkHttp.dns().addAll(listOf("added.test=jar.test"))
        server.enqueue(MockResponse().setBody("two"))
        assertEquals("two", OkHttp.string(url("added.test")))
        assertNull(server.takeRequest().getHeader("X-Config"), "the request is still for added.test")

        // Spiders have their own dispatcher: cancelAll() from a spider leaves the engine's requests alone.
        assertNotSame(HostBridge.baseClient.dispatcher, OkHttp.client().dispatcher)

        network.onConfig(null)
        assertEquals("", OkHttp.string(url("jar.test")), "the config is gone, and so is the name")
    }
}
