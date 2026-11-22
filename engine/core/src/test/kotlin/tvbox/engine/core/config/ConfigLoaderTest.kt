package tvbox.engine.core.config

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

class ConfigLoaderTest {
    private lateinit var server: MockWebServer
    private val loader = ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/"))

    @BeforeEach
    fun start() {
        server = MockWebServer().apply { start() }
    }

    @AfterEach
    fun stop() {
        server.shutdown()
    }

    @Test
    fun `encrypted config with relative spider path`() = runBlocking {
        val json = """{"spider":"./spider.jar","sites":[{"key":"a","type":1,"api":"http://x/api.php"}]}"""
        val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec("k1".padEnd(16, '0').toByteArray(), "AES"))
        server.enqueue(MockResponse().setBody(cipher.doFinal(json.toByteArray()).joinToString("") { "%02x".format(it) }))

        val url = server.url("/tv/config.json").toString()
        val result = loader.load("$url;pk;k1")

        val config = assertInstanceOf(ConfigDocument.Single::class.java, result.document).config
        assertEquals(server.url("/tv/spider.jar").toString(), config.spider)
        assertEquals(ConfigLoader.USER_AGENT, server.takeRequest().getHeader("User-Agent"))
    }

    @Test
    fun `http error becomes LoadException`() {
        server.enqueue(MockResponse().setResponseCode(404))
        val error = assertThrows(ConfigLoader.LoadException::class.java) {
            runBlocking { loader.load(server.url("/missing.json?token=private").toString()) }
        }
        assertEquals("config.fetch", error.diagnostic?.stage)
        assertEquals("IOException: HTTP 404", error.diagnostic?.cause)
        assertFalse("private" in error.message.orEmpty())
    }

    @Test
    fun `non config body becomes LoadException`() {
        server.enqueue(MockResponse().setBody("<html>blocked</html>"))
        val error = assertThrows(ConfigLoader.LoadException::class.java) {
            runBlocking { loader.load(server.url("/a.json?token=private").toString()) }
        }
        assertEquals("config.parse", error.diagnostic?.stage)
        assertEquals("InvalidConfigException: subscription returned a web page", error.diagnostic?.cause)
        assertFalse("private" in error.message.orEmpty())
    }

    @Test
    fun `DNS and timeouts show the network stage without reporting the subscription address`() {
        val errors = listOf(UnknownHostException("private.example").apply { initCause(Exception("platform private detail")) }, SocketTimeoutException("private timeout"))
        for (cause in errors) {
            val http = OkHttpClient.Builder().addInterceptor { throw cause }.build()
            val loader = ConfigLoader(http, ConfigLocator("http://127.0.0.1:9978/file/"))
            val error = assertThrows(ConfigLoader.LoadException::class.java) {
                runBlocking { loader.load("https://private.example/?token=private") }
            }
            assertEquals("config.fetch", error.diagnostic?.stage)
            assertEquals("network", error.diagnostic?.kind)
            assertEquals(cause.javaClass.simpleName, error.diagnostic?.cause)
            assertFalse("private" in error.message.orEmpty())
        }
    }
}
