package tvbox.engine.core.net

import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.EngineSettings
import tvbox.engine.core.store.JsonFileStore
import java.io.File
import java.io.IOException

class GithubProxyTest {
    private val raw = "https://raw.githubusercontent.com/me/tv/main/a.json"

    @Test
    fun `a proxy in front of a github address is recognised in its usual shapes`() {
        assertEquals(raw, GithubProxy.direct("https://gh-proxy.org/$raw"))
        assertEquals(raw, GithubProxy.direct("https://ghfast.top/https://raw.githubusercontent.com/me/tv/main/a.json"))
        assertEquals(raw, GithubProxy.direct("https://gh-proxy.com/raw.githubusercontent.com/me/tv/main/a.json"), "without a scheme")
        assertEquals(raw, GithubProxy.direct("https://gh-proxy.com/https:/raw.githubusercontent.com/me/tv/main/a.json"), "one slash lost on the way")
        assertEquals(raw, GithubProxy.direct(raw), "a github address stands for itself")
        assertEquals(
            "https://github.com/me/tv/releases/download/v1/x.jar",
            GithubProxy.direct("http://proxy.test:8080/https://github.com/me/tv/releases/download/v1/x.jar"),
        )
        assertNull(GithubProxy.direct("https://example.com/tv/a.json"))
        assertNull(GithubProxy.direct("https://example.com/mirror/raw.githubusercontent.com/me/tv/main/a.json"), "not right after the host")
        assertNull(GithubProxy.direct("https://github.com.evil.test/x"))
        assertEquals(
            "https://github.com/raw.githubusercontent.com/x/y",
            GithubProxy.direct("https://github.com/raw.githubusercontent.com/x/y"),
            "a path on github itself is not a proxy",
        )
    }

    @Test
    fun `off goes to github, on goes through the chosen proxy`() {
        val proxy = GithubProxy()
        assertEquals(raw, proxy.route("https://gh-proxy.org/$raw"), "off by default: the config's proxy is taken off")
        assertEquals("https://example.com/a.json", proxy.route("https://example.com/a.json"))

        proxy.enabled = true
        proxy.prefix = "my.proxy.test"
        assertEquals("https://my.proxy.test/$raw", proxy.route("https://gh-proxy.org/$raw"), "the user's proxy, not the config's")
        assertEquals("https://my.proxy.test/$raw", proxy.route(raw))
        assertEquals("https://example.com/a.json", proxy.route("https://example.com/a.json"), "other sites are left alone")
    }

    /** Answers by host, standing in for the network. */
    private class Net(val answer: (String) -> Int?) : Interceptor {
        val asked = ArrayList<String>()
        override fun intercept(chain: Interceptor.Chain): Response {
            val url = chain.request().url.toString()
            asked += url
            val code = answer(url) ?: throw IOException("unreachable: $url")
            return Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(code).message("x")
                .body("body of $url".toResponseBody()).build()
        }
    }

    private fun get(proxy: GithubProxy, net: Net, url: String): Pair<Int, String> {
        val client = OkHttpClient.Builder().addInterceptor(proxy).addInterceptor(net).build()
        return client.newCall(Request.Builder().url(url).build()).execute().use { it.code to it.body!!.string() }
    }

    @Test
    fun `requests follow the setting, and a failing proxy falls back to github`() {
        val written = "https://gh-proxy.org/$raw"

        // Off: the dead proxy the subscription names is never asked.
        val off = Net { if (it.startsWith("https://raw.githubusercontent.com/")) 200 else 404 }
        assertEquals(200 to "body of $raw", get(GithubProxy(), off, written))
        assertEquals(listOf(raw), off.asked)

        // On: through the user's proxy.
        val on = Net { 200 }
        assertEquals(200, get(GithubProxy(enabled = true, prefix = "https://p.test/"), on, written).first)
        assertEquals(listOf("https://p.test/$raw"), on.asked)

        // On, but the proxy does not have it, or is down: github gets a try.
        val missing = Net { if (it.startsWith("https://p.test/")) 404 else 200 }
        assertEquals(200 to "body of $raw", get(GithubProxy(enabled = true, prefix = "https://p.test/"), missing, raw))
        assertEquals(listOf("https://p.test/$raw", raw), missing.asked)
        val down = Net { if (it.startsWith("https://p.test/")) null else 200 }
        assertEquals(200, get(GithubProxy(enabled = true, prefix = "https://p.test/"), down, raw).first)

        // Anything else is untouched.
        val other = Net { 200 }
        get(GithubProxy(enabled = true), other, "https://example.com/a.json")
        assertEquals(listOf("https://example.com/a.json"), other.asked)
    }

    @Test
    fun `a probe fetches the file from github and through each proxy as written, whatever the setting`() = runBlocking {
        val file = "https://raw.githubusercontent.com/me/tv/abc123/.gitattributes"
        val asked = java.util.concurrent.CopyOnWriteArrayList<String>()
        val net = Interceptor { chain ->
            val url = chain.request().url.toString()
            asked += url
            fun answer(code: Int, body: String) = Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(code)
                .message("x").body(body.toResponseBody()).build()
            when {
                url == file || url.startsWith("https://good.test/") -> answer(200, "* text=auto\n*.jar binary\n")
                // A proxy that answers every address with its own page.
                url.startsWith("https://page.test/") -> answer(200, "<html>this proxy is closed</html>")
                url.startsWith("https://busy.test/") -> answer(503, "busy")
                else -> throw IOException("unreachable")
            }
        }
        // The setting points at good.test: a probe of the others must not end up there.
        val client = OkHttpClient.Builder().addInterceptor(GithubProxy(enabled = true, prefix = "https://good.test/")).addInterceptor(net).build()

        val results = GithubProxy.probe(SiteHttp(client), listOf("busy.test", "https://page.test", "https://dead.test/", "https://good.test/", "https://good.test", " "), file = file)

        assertEquals(listOf("", "https://busy.test/", "https://page.test/", "https://dead.test/", "https://good.test/"), results.map { it.prefix }, "github first, then each once")
        assertEquals(listOf(true, false, false, false, true), results.map { it.ok })
        assertTrue("503" in results[1].error, results[1].error)
        assertTrue("not with the file" in results[2].error, results[2].error)
        assertTrue("dead.test" in results[3].error, results[3].error)
        assertTrue(results.all { it.ms >= 0 })
        assertEquals(results.map { it.prefix + file }.toSet(), asked.toSet(), "each address asked as written, nothing rerouted")
    }

    @Test
    fun `the presets are proxies of the usual shape, the default among them`() {
        assertTrue(GithubProxy.PRESETS.any { it.prefix == GithubProxy.DEFAULT_PREFIX })
        for (p in GithubProxy.PRESETS) {
            assertEquals(GithubProxy.normalize(p.prefix), p.prefix)
            assertEquals(raw, GithubProxy.direct(p.prefix + raw), "the engine recognises ${p.name} in a subscription's addresses")
        }
        assertEquals(GithubProxy.PRESETS.size, GithubProxy.PRESETS.map { it.prefix }.toSet().size)
    }

    @Test
    fun `the engine keeps the setting and says where the config really comes from`(@TempDir dir: File) = runBlocking {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = MockResponse().setBody("""{"sites":[{"key":"a","type":1,"api":"http://x"}]}""")
        }
        server.start()
        try {
            fun engine(proxy: GithubProxy): Engine {
                val client = OkHttpClient.Builder().addInterceptor(proxy).build()
                return Engine(
                    EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
                    ConfigLoader(client, ConfigLocator("http://127.0.0.1:9978/file/")),
                    SiteHttp(client),
                    proxyBase = "http://127.0.0.1:9978/proxy?",
                    store = JsonFileStore(dir),
                    githubProxy = proxy,
                )
            }
            val first = engine(GithubProxy())
            assertEquals(EngineSettings(), first.settings(), "off unless the user turns it on")
            // A blank prefix falls back to the default one; a bare host gets a scheme and a slash.
            assertEquals(GithubProxy.DEFAULT_PREFIX, first.updateSettings(EngineSettings(githubProxy = true, githubProxyPrefix = " ")).githubProxyPrefix)
            val local = server.url("/").toString()
            val saved = first.updateSettings(EngineSettings(githubProxy = true, githubProxyPrefix = local.removePrefix("http://").trimEnd('/')))
            assertEquals("https://" + local.removePrefix("http://"), saved.githubProxyPrefix)

            // After a restart the setting is back and drives the interceptor.
            val proxy = GithubProxy()
            val second = engine(proxy)
            assertEquals(true, second.settings().githubProxy)
            assertEquals(true, proxy.enabled)
            assertEquals(saved.githubProxyPrefix, proxy.prefix)

            // The summary names both the address as written and the one really asked.
            proxy.prefix = local
            val id = second.addSubscription("https://gh-proxy.org/$raw", null).id
            val summary = second.activate(id)
            assertEquals("https://gh-proxy.org/$raw", summary.url)
            assertEquals(local + raw, summary.fetchedUrl)
            assertEquals("/$raw", server.takeRequest().path)
        } finally {
            server.shutdown()
        }
    }
}
