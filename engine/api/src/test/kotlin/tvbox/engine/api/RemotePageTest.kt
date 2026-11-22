package tvbox.engine.api

import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.testApplication
import okhttp3.OkHttpClient
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.remote.RemoteHub
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.MemoryStore

/**
 * The web console's files under `/remote/`: the page modules in `pages/` are served like the page itself (public,
 * with the CSP), from a fixed list, and nothing else is reachable under that folder.
 */
class RemotePageTest {
    private val lanHost = "192.168.1.5:9978"
    private val pages = listOf("sources", "data", "logs", "settings")

    private fun engine() = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:80/proxy?",
    )

    private fun pageTest(block: suspend io.ktor.server.testing.ApplicationTestBuilder.() -> Unit) = testApplication {
        val access = AccessControl(MemoryStore(), supported = true).also { it.setSharing(true) }
        application { engineModule(engine(), EngineModuleOptions(access = access, remote = RemoteHub())) }
        block()
    }

    @Test
    fun `the console's page modules are served with the CSP to a phone that has not paired`() = pageTest {
        for (name in pages) {
            val res = client.get("/remote/pages/$name.js") { header(HttpHeaders.Host, lanHost) }
            assertEquals(HttpStatusCode.OK, res.status, name)
            assertTrue(res.headers[HttpHeaders.ContentType]!!.startsWith("text/javascript"), "$name: ${res.headers[HttpHeaders.ContentType]}")
            val csp = res.headers["Content-Security-Policy"]!!
            assertTrue(csp.contains("script-src 'self'") && csp.contains("style-src 'self'") && csp.contains("default-src 'none'"), "$name: $csp")
            assertEquals("nosniff", res.headers["X-Content-Type-Options"], name)
            val body = res.bodyAsText()
            // A module that default-exports its page; it never builds markup from strings (names come from third parties).
            assertTrue(body.contains("export default"), name)
            assertFalse(body.contains("innerHTML") || body.contains("insertAdjacentHTML") || body.contains("eval("), "$name builds markup from strings")
        }
    }

    @Test
    fun `the core script loads exactly the modules that are served`() = pageTest {
        val core = client.get("/remote/remote.js") { header(HttpHeaders.Host, lanHost) }.bodyAsText()
        val loaded = Regex("""MODULE_PAGES\s*=\s*\[([^\]]*)]""").find(core)?.groupValues?.get(1)
            ?.let { Regex("""'([a-z]+)'""").findAll(it).map { m -> m.groupValues[1] }.toList() }
        assertEquals(pages, loaded)
        assertFalse(core.contains("innerHTML") || core.contains("insertAdjacentHTML"), "the core builds markup from strings")
        // The page has no inline style either: the CSP would drop it.
        val page = client.get("/remote/") { header(HttpHeaders.Host, lanHost) }.bodyAsText()
        assertFalse(Regex("""\sstyle\s*=""").containsMatchIn(page), "inline style in the page")
        assertFalse(Regex("""<style""").containsMatchIn(page), "a style element in the page")
    }

    @Test
    fun `nothing else under the pages folder is served`() = pageTest {
        val others = listOf(
            "/remote/pages/", "/remote/pages", "/remote/pages/nothing.js", "/remote/pages/logs", "/remote/pages/LOGS.js",
            "/remote/pages/..%2Findex.html", "/remote/pages/%2E%2E%2Fremote.js", "/remote/pages/logs.js/x", "/remote/pages/a/logs.js",
            "/remote/logs.js", "/remote/pages.js", "/remote/remote.js/pages/logs.js",
        )
        for (path in others) {
            assertEquals(HttpStatusCode.NotFound, client.get(path) { header(HttpHeaders.Host, lanHost) }.status, path)
        }
        // Only reading is public: the same paths with another method still need a token.
        assertEquals(HttpStatusCode.Unauthorized, client.post("/remote/pages/logs.js") { header(HttpHeaders.Host, lanHost) }.status)
    }
}
