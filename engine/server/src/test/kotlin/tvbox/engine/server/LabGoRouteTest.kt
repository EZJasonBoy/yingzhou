package tvbox.engine.server

import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.cache.DataCache
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.JsonFileStore
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class LabGoRouteTest {
    private val source = "http://映舟.test"
    private val endpoint = "http://127.0.0.1:9980/config.json"
    private val locator = ConfigLocator("http://127.0.0.1:9978/file/")
    private val responses = ConcurrentHashMap<String, String>()
    private val http = OkHttpClient.Builder().addInterceptor { chain ->
        val request = chain.request()
        val body = responses[request.url.toString()]
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(if (body == null) 503 else 200)
            .message("fixture").body(body.orEmpty().toResponseBody()).build()
    }.build()

    @Test
    fun `matches one exact HTTP URL allowing IDNs and a default port`() {
        val route = labGoRoute(source, null)!!
        assertEquals(endpoint, route("HTTP://${source.toHttpUrl().host}:80/"))
        for (other in listOf("$source/path", "$source/?q=1", "$source/#section", "https://映舟.test/", "http://@映舟.test/", "http://viewer@映舟.test/")) {
            assertNull(route(other), other)
        }
        val query = labGoRoute("$source/Sub?q=One", "9999")!!
        assertEquals("http://127.0.0.1:9999/config.json", query("$source/Sub?q=One"))
        assertNull(query("$source/sub?q=One"))
        assertNull(query("$source/Sub?q=one"))
    }

    @Test
    fun `routing requires an absolute source without userinfo and a valid port`() {
        assertNull(labGoRoute(null, null))
        assertNull(labGoRoute("", "9987"))
        for (port in listOf("0", "65536", "host:9987", "")) {
            assertThrows(IllegalArgumentException::class.java) { labGoRoute(source, port) }
        }
        for (invalid in listOf("映舟.test", "file:///config.json", "http://viewer@映舟.test/", "http://@映舟.test/")) {
            assertThrows(IllegalArgumentException::class.java) { labGoRoute(invalid, null) }
        }
    }

    @Test
    fun `config copies are isolated by original source and the paired port`() = runBlocking {
        val cache = DataCache()
        fun loader(origin: String?, port: String? = null) = ConfigLoader(http, locator, cache, labGoRoute(origin, port))
        val second = "http://other.test/sub"
        val firstLoader = loader(source)
        val secondLoader = loader(second)
        responses[endpoint] = """{"sites":[],"label":"first"}"""
        val first = firstLoader.load(source)
        assertTrue(firstLoader.hasCopy(source))
        assertFalse(secondLoader.hasCopy(second))
        assertFalse(loader(source, "9981").hasCopy(source))
        assertFalse(loader(null).hasCopy(endpoint))
        assertFalse(loader(null).hasCopy(source))
        responses[endpoint] = """{"sites":[],"label":"second"}"""
        val next = secondLoader.load(second)
        assertEquals(first.text, firstLoader.load(source, stored = true).text)
        assertEquals(next.text, secondLoader.load(second, stored = true).text)
    }

    @Test
    fun `a restart without routing loads the saved original source and its own site answers`(@TempDir dir: File) = runBlocking {
        fun engine(route: ((String) -> String?)?): Engine {
            val cache = DataCache(File(dir, "cache"))
            return Engine(
                EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
                ConfigLoader(http, locator, cache, route), SiteHttp(http), proxyBase = "http://127.0.0.1:9978/proxy?",
                store = JsonFileStore(File(dir, "store")), cache = cache,
            )
        }
        fun config(api: String) = """{"sites":[{"key":"demo","name":"Demo","type":4,"api":"$api"}]}"""
        fun home(label: String) = """{"list":[{"vod_id":"1","vod_name":"$label"}]}"""
        val relay = "http://127.0.0.1:9980/t4/demo"
        val homeUrl = "$relay?filter=true"
        responses[endpoint] = config("./t4/demo")
        responses[homeUrl] = home("Go")
        val routed = engine(labGoRoute(source, null))
        val active = routed.activate(routed.addSubscription(source, null).id)
        assertEquals(source, active.url)
        assertEquals(endpoint, active.fetchedUrl)
        assertEquals("Go", routed.home("demo").list.single().name)

        responses[source.toHttpUrl().toString()] = config(relay)
        responses[homeUrl] = home("Original")
        val plain = engine(null)
        assertEquals(source, plain.subscriptions().single().url)
        val restored = plain.restore()!!.getOrThrow()
        assertFalse(restored.stored)
        assertEquals(source, restored.fetchedUrl)
        assertEquals("Original", plain.home("demo").list.single().name)
    }
}
