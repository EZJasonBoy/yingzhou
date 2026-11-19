package tvbox.engine.js

import com.google.gson.JsonParser
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.net.ConfigNetwork
import java.net.InetAddress
import java.net.UnknownHostException

/** `req` of JS spiders follows the active config's `hosts` and `headers`, like every request of the engine's client. */
class JsHttpNetworkTest {
    @Test
    fun `req resolves with the config's hosts and sends the config's headers`() {
        val server = MockWebServer()
        server.start()
        try {
            val network = ConfigNetwork(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> =
                    ConfigNetwork.literal(hostname)?.let { listOf(it) } ?: throw UnknownHostException(hostname)
            })
            val http = JsHttp(network.install(OkHttpClient.Builder()).build())
            val url = "http://js.test:${server.port}/x"
            assertEquals(JsHttp.ERROR, http.request(url, "{}"), "an unknown name")

            network.onConfig(TvboxConfig(hosts = mapOf("js.test" to "127.0.0.1"), headersJson = """[{"host":"js.test","header":{"User-Agent":"from-config"}}]"""))
            server.enqueue(MockResponse().setBody("hello"))
            val answer = JsonParser.parseString(http.request(url, """{"headers":{"User-Agent":"from-spider"}}""")).asJsonObject
            assertEquals("hello", answer.get("content").asString)
            assertEquals("from-config", server.takeRequest().getHeader("User-Agent"))
        } finally {
            server.shutdown()
        }
    }
}
