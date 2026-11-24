package tvbox.engine.core.config

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
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
        assertThrows(ConfigLoader.LoadException::class.java) {
            runBlocking { loader.load(server.url("/missing.json").toString()) }
        }
    }

    @Test
    fun `non config body becomes LoadException`() {
        server.enqueue(MockResponse().setBody("<html>blocked</html>"))
        assertThrows(ConfigLoader.LoadException::class.java) {
            runBlocking { loader.load(server.url("/a.json").toString()) }
        }
    }
}
