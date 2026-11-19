package tvbox.engine.js

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp

/** `lives` entries of `type: 3` whose spider is a script: the list comes from its `live(url)`. */
class JsLiveTest {
    private lateinit var server: MockWebServer
    private lateinit var env: JsEnvironment
    private val http = OkHttpClient()

    /** What this engine's `/proxy` is called in the tests; TVBox's own is port 9978. */
    private val proxy = "http://127.0.0.1:19978/proxy"

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/tv.json" -> MockResponse().setBody(config())
                "/live.js" -> MockResponse().setBody(PLAIN_LIVE)
                "/live-cat.js" -> MockResponse().setBody(CAT_LIVE)
                "/site.js" -> MockResponse().setBody(SITE)
                "/list.txt" -> MockResponse().setBody("列表,#genre#\n列表台,proxy://do=js&ch=9\n")
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
        env = JsEnvironment(
            modules = JsModules(http, ConfigLocator("http://127.0.0.1:19978/file/")),
            http = JsHttp(http),
            local = MemoryJsLocalStore(),
            proxyUrl = proxy,
        )
    }

    @AfterEach
    fun stop() {
        server.shutdown()
    }

    private fun base() = server.url("/").toString().trimEnd('/')

    private fun config() = """{
        "sites": [{"key":"站","name":"站","type":3,"api":"${base()}/site.js"}],
        "lives": [
          {"name":"脚本 直播","type":3,"api":"${base()}/live.js","ext":{"group":"脚本"}},
          {"name":"猫","type":3,"api":"${base()}/live-cat.js","url":"http://list.test/cat"},
          {"name":"只管代理","type":3,"api":"${base()}/site.js","url":"${base()}/list.txt"},
          {"name":"没有列表","type":3,"api":"${base()}/site.js","url":"x"}
        ]
    }"""

    private fun engine() = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(http, ConfigLocator("http://127.0.0.1:19978/file/")),
        SiteHttp(http),
        proxyBase = "$proxy?",
        runtimes = listOf(JsRuntime(env)),
    )

    @Test
    fun `live asks the script, which gets its own address when the entry names no list`() = runBlocking {
        val plain = JsSpider.load(SiteBean(key = "live_a", name = "a", type = 3, api = base() + "/live.js"), """{"group":"组"}""", env)
        val cat = JsSpider.load(SiteBean(key = "live_演示", name = "演示", type = 3, api = base() + "/live-cat.js"), "", env)
        val site = JsSpider.load(SiteBean(key = "s", name = "s", type = 3, api = base() + "/site.js"), "", env)
        try {
            assertEquals("组,#genre#\n直连台,${base()}/live.js\n代理台,$proxy?do=js&ch=1\n协议台,proxy://do=js&ch=2", plain.live(""))
            assertTrue(plain.live("http://list.test/a.txt")!!.contains("直连台,http://list.test/a.txt\n"), "a list address goes to the script as it is")

            // A list handed back as an object arrives as JSON; js2Proxy names the spider by its key, encoded.
            val json = cat.live("http://list.test/cat")!!
            assertTrue(json.startsWith("""[{"group":"猫","channels":[{"name":"http://list.test/cat","urls":["$proxy?do=js&from=catvod&siteType=3&siteKey=live_%E6%BC%94%E7%A4%BA&header="""), json)

            assertNull(site.live(""), "a script without live() has no list")
        } finally {
            plain.destroy()
            cat.destroy()
            site.destroy()
        }
    }

    @Test
    fun `the engine loads script lives, and their proxy addresses come back to the script that served them`() = runBlocking {
        val engine = engine()
        engine.activate(engine.addSubscription(server.url("/tv.json").toString(), null).id)

        val sources = engine.liveSources()
        assertEquals(listOf("js", "js", "js", "js"), sources.map { it.spider })
        assertTrue(sources.all { it.supported })

        // The plain script: three ways of naming an address, two of them its own proxy.
        val key = "live_%E8%84%9A%E6%9C%AC+%E7%9B%B4%E6%92%AD"
        val list = engine.liveList(0)
        assertEquals("脚本", list.groups.single().name, "init got the ext")
        assertEquals(
            listOf("${base()}/live.js", "$proxy?do=js&ch=1&siteKey=$key", "$proxy?do=js&ch=2&siteKey=$key"),
            list.groups.single().channels.map { it.urls.single().url },
        )

        // The cat script got the entry's url, and its js2Proxy address already carries its key.
        val cat = engine.liveList(1).groups.single().channels.single()
        assertEquals("http://list.test/cat", cat.name)
        assertTrue(cat.urls.single().url.contains("&siteKey=live_%E7%8C%AB&"), cat.urls.single().url)
        assertEquals(1, Regex("siteKey=").findAll(cat.urls.single().url).count(), "an address that names its spider is left alone")

        // Another script is used in between, as when the user browses a site: it is now the one used last.
        assertTrue(engine.home("站").classes.isNotEmpty())
        suspend fun ask(url: String): String {
            val params = url.substringAfter('?').split('&').associate {
                java.net.URLDecoder.decode(it.substringBefore('='), "UTF-8") to java.net.URLDecoder.decode(it.substringAfter('='), "UTF-8")
            }
            return engine.proxy(params)!!.body!!.readBytes().decodeToString()
        }
        assertEquals("plain 2", ask(list.groups.single().channels[2].urls.single().url))
        assertEquals("cat ch|1 r", ask(cat.urls.single().url))
        assertEquals("site 2", ask("$proxy?do=js&ch=2"), "without a key the script used last answers, as in TVBox")

        // A script with no live(): the entry's url is the list (TVBox downloads it), the script serves its channels.
        val relay = engine.liveList(2).groups.single().channels.single()
        assertEquals("列表台", relay.name)
        assertEquals("site 9", ask(relay.urls.single().url))
        assertTrue(relay.urls.single().url.endsWith("&siteKey=live_%E5%8F%AA%E7%AE%A1%E4%BB%A3%E7%90%86"), relay.urls.single().url)

        // Neither a list from the script nor an address to download one from.
        val empty = runCatching { engine.liveList(3) }.exceptionOrNull()
        assertTrue(empty is EngineException && empty.code == "LIVE_FAILED", empty.toString())
    }

    private companion object {
        /** A default export; `live` shows the three ways a script names an address. */
        val PLAIN_LIVE = """
            let group = '';
            export default {
              init(ext) { group = ext.group; },
              live(url) {
                return [group + ',#genre#', '直连台,' + url, '代理台,' + getProxy(true) + '&ch=1', '协议台,proxy://do=js&ch=2'].join('\n');
              },
              proxy(params) { return [200, 'text/plain', 'plain ' + params.ch]; },
            };
        """.trimIndent()

        /** The cat kind: async, knows its key, and answers with an object instead of text. */
        val CAT_LIVE = """
            let key = '';
            async function init(cfg) { key = cfg.skey; }
            async function live(url) {
              return [{ group: '猫', channels: [{ name: url, urls: [js2Proxy(true, 3, key, 'ch/1', { Referer: 'r' })] }] }];
            }
            async function proxy(segs, header) {
              return JSON.stringify({ code: 200, buffer: 0, content: 'cat ' + segs.join('|') + ' ' + header.Referer, headers: { 'Content-Type': 'text/plain' } });
            }
            export function __jsEvalReturn() { return { init, live, proxy }; }
        """.trimIndent()

        /** A site's script: no `live`, but a proxy of its own. */
        val SITE = """
            export default {
              home() { return JSON.stringify({ class: [{ type_id: '1', type_name: '电影' }] }); },
              proxy(params) { return [200, 'text/plain', 'site ' + params.ch]; },
            };
        """.trimIndent()
    }
}
