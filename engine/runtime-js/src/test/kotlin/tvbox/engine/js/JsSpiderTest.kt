package tvbox.engine.js

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.spider.SpiderLoadException
import tvbox.engine.core.vod.TvboxResult

class JsSpiderTest {
    private lateinit var server: MockWebServer
    private lateinit var env: JsEnvironment
    private val logs = mutableListOf<String>()

    private val listHtml = """
        <html><body><ul>
          <li class="item"><a href="/v/1.html">星河往事</a><img src="/p/1.jpg"></li>
          <li class="item"><a href="/v/2.html">长夜未眠</a><img src="/p/2.jpg"></li>
        </ul></body></html>
    """.trimIndent()

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/list.html" -> MockResponse().setBody(listHtml)
                "/drpy.js" -> MockResponse().setBody(DRPY_SPIDER.replace("__BASE__", base()))
                "/cat.js-spider.js" -> MockResponse().setBody(CAT_SPIDER)
                "/old.js" -> MockResponse().setBody("""__JS_SPIDER__ = { home() { return '{"class":[{"type_id":"9","type_name":"旧式"}]}' } }""")
                "/bytecode.js" -> MockResponse().setBody("//bbAAAA")
                "/probe.js" -> MockResponse().setBody(PROBE_SPIDER)
                "/dead-import.js" -> MockResponse().setBody("import { gbkTool } from '${base()}/gone.js';\nexport default { home() { return gbkTool; } };")
                "/echo" -> MockResponse().setBody("""{"method":"${request.method}","body":${if (request.bodySize > 0) request.body.readUtf8() else "null"},"ua":"${request.getHeader("User-Agent")}"}""")
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
        val http = OkHttpClient()
        env = JsEnvironment(
            modules = JsModules(http, ConfigLocator("http://127.0.0.1:9978/file/")),
            http = JsHttp(http),
            local = MemoryJsLocalStore(),
            proxyUrl = "http://127.0.0.1:9978/proxy",
            log = { logs += it },
        )
    }

    @AfterEach
    fun stop() {
        server.shutdown()
    }

    private fun base() = server.url("/").toString().trimEnd('/')
    private fun site(path: String, key: String = "js") = SiteBean(key = key, name = key, type = 3, api = base() + path)

    @Test
    fun `drpy style spider with sync req, pdfa, pdfh, pd and local storage`() = runBlocking {
        val spider = JsSpider.load(site("/drpy.js"), """{"token":"abc"}""", env)
        try {
            val home = TvboxResult.parseHome("js", spider.home(true)!!)
            assertEquals(listOf("电影"), home.classes.map { it.name })

            val page = TvboxResult.parseList("js", spider.category("1", "2", true, mapOf("year" to "2024"))!!)
            assertEquals(2, page.page)
            assertEquals(listOf("星河往事", "长夜未眠"), page.list.map { it.name })
            assertEquals("${base()}/p/1.jpg", page.list[0].pic, "pd joins relative urls")
            assertEquals("/v/1.html", page.list[0].id)

            val search = TvboxResult.parseList("js", spider.search("星河", false, "1")!!)
            assertEquals("星河", search.list.single().name, "unicode arguments reach the script intact")

            val play = spider.play("线路", "https://cdn.test/a.m3u8", listOf("qq"))!!
            assertTrue(play.contains("\"Referer\":\"r\""), play)
            assertTrue(play.contains("\"flags\":[\"qq\"]"), play)

            // local storage survives between calls of the same engine
            assertEquals("abc", env.local.get("jsRuntime_js_token"))
        } finally {
            spider.destroy()
        }
    }

    @Test
    fun `cat style spider with async req and the bundled cat js (cheerio, CryptoJS)`() = runBlocking {
        val spider = JsSpider.load(site("/cat.js-spider.js", "cat"), """{"host":"${base()}"}""", env)
        try {
            val home = TvboxResult.parseHome("cat", spider.home(true)!!)
            assertEquals(listOf("剧集"), home.classes.map { it.name })
            assertEquals(listOf("星河往事", "长夜未眠"), home.list.map { it.name })

            val search = TvboxResult.parseList("cat", spider.search("abc", false, "1")!!)
            assertEquals("900150983cd24fb0d6963f7d28e17f72", search.list.single().name, "CryptoJS.MD5 from cat.js")

            val detail = TvboxResult.parseDetail("cat", spider.detail("/v/1.html")!!)
            assertEquals("${base()}/v.m3u8", detail.lines.single().episodes.single().id)

            val post = spider.play("x", "post", emptyList())!!
            assertTrue(post.contains("\\\"method\\\":\\\"POST\\\""), post)
            assertTrue(post.contains("\\\"a\\\":1"), post)
        } finally {
            spider.destroy()
        }
    }

    @Test
    fun `legacy __JS_SPIDER__ assignment is treated as a default export`() = runBlocking {
        val spider = JsSpider.load(site("/old.js"), "", env)
        try {
            assertEquals(listOf("旧式"), TvboxResult.parseHome("js", spider.home(true)!!).classes.map { it.name })
        } finally {
            spider.destroy()
        }
    }

    @Test
    fun `proxy do=js goes to the right spider in both conventions`() = runBlocking {
        val runtime = JsRuntime(env)
        val drpy = runtime.create(site("/drpy.js", "drpy"), """{"token":"t"}""")
        val cat = runtime.create(site("/cat.js-spider.js", "cat"), """{"host":"${base()}"}""")
        try {
            // proxy1 to the spider named by siteKey
            val r1 = runtime.proxy(mapOf("do" to "js", "siteKey" to "drpy", "x" to "world"))!!
            assertEquals(200, r1.status)
            assertEquals("hello world", r1.body!!.readBytes().decodeToString())
            assertEquals("1", r1.headers["X-Test"])

            // proxy2 (js2Proxy urls, from=catvod) to the most recently used spider
            cat.home(true)
            val r2 = runtime.proxy(mapOf("do" to "js", "from" to "catvod", "url" to "a/b", "header" to """{"Referer":"r"}"""))!!
            assertEquals("hi", r2.body!!.readBytes().decodeToString(), "buffer 2 is base64")
            assertEquals("text/plain", r2.contentType)
            assertEquals("a|b r", r2.headers["X-Seg"])

            // other proxies are not for the JS runtime
            assertEquals(null, runtime.proxy(mapOf("do" to "jar")))
        } finally {
            drpy.destroy()
            cat.destroy()
        }
    }

    @Test
    fun `missing and bytecode spiders fail with a clear error`() {
        val missing = assertThrows(SpiderLoadException::class.java) { runBlocking { JsSpider.load(site("/nope.js"), "", env) } }
        assertTrue(missing.message!!.contains("cannot download"), missing.message)
        val bytecode = assertThrows(SpiderLoadException::class.java) { runBlocking { JsSpider.load(site("/bytecode.js"), "", env) } }
        assertTrue(bytecode.message!!.contains("bytecode"), bytecode.message)
    }

    @Test
    fun `a rule the parser cannot apply gives nothing instead of throwing, as in TVBox`() = runBlocking {
        val spider = JsSpider.load(site("/probe.js", "probe"), "", env)
        try {
            assertEquals("""{"h":"","a":0,"l":0}""", spider.home(true))
            assertTrue(logs.any { it.contains("pdfh") || it.contains("pd ") }, logs.toString())
        } finally {
            spider.destroy()
        }
    }

    @Test
    fun `a script that throws while answering is the spider's error, not a load failure`() = runBlocking {
        val spider = JsSpider.load(site("/probe.js", "probe"), "", env)
        try {
            val e = assertThrows(SpiderLoadException::class.java) { runBlocking { spider.detail("x") } }
            assertEquals(JsSpider.SPIDER_ERROR, e.code)
            assertTrue(e.message!!.contains("unexpected token") || e.message!!.contains("JSON"), e.message)
        } finally {
            spider.destroy()
        }
    }

    @Test
    fun `a module that cannot be downloaded is named when the script then fails to link`() {
        val e = assertThrows(SpiderLoadException::class.java) { runBlocking { JsSpider.load(site("/dead-import.js"), "", env) } }
        assertEquals("SPIDER_LOAD_FAILED", e.code)
        assertTrue(e.message!!.contains("cannot download ${base()}/gone.js"), e.message)
    }

    @Test
    fun `html parser follows hiker rules`() {
        val p = HtmlParser()
        val html = """<div class="a"><p>one</p><p>two</p><span style="background:url('/bg.png')">x</span></div>"""
        assertEquals("two", p.parseDomForUrl(html, ".a&&p:eq(1)&&Text", ""))
        assertEquals("two", p.parseDomForUrl(html, ".a&&p:eq(-1)&&Text", ""))
        assertEquals("http://h.test/bg.png", p.parseDomForUrl(html, "span&&style", "http://h.test/x/"))
        assertEquals(2, p.parseDomForArray(html, ".a&&p").size)
        assertEquals(listOf("one\$"), p.parseDomForList(html, ".a&&p:eq(0)", "Text", "href", ""))
    }

    companion object {
        private val DRPY_SPIDER = """
            const BASE = '__BASE__';
            export default {
              init(ext) { this.ext = ext; local.set('js', 'token', ext.token); },
              home(filter) { return JSON.stringify({ class: [{ type_id: '1', type_name: '电影' }], list: [] }); },
              category(tid, pg, filter, extend) {
                const html = req(BASE + '/list.html', { headers: { 'User-Agent': 'x' } }).content;
                const items = pdfa(html, '.item');
                return JSON.stringify({
                  page: Number(pg), pagecount: 3,
                  list: items.map(it => ({ vod_id: pdfh(it, 'a&&href'), vod_name: pdfh(it, 'a&&Text'), vod_pic: pd(it, 'img&&src', BASE + '/') })),
                });
              },
              search(wd, quick) { return JSON.stringify({ list: [{ vod_id: '1', vod_name: wd }] }); },
              play(flag, id, flags) { return JSON.stringify({ parse: 0, url: id, header: { Referer: 'r' }, flags }); },
              proxy(params) { return [200, 'text/plain; charset=utf-8', 'hello ' + params.x, { 'X-Test': '1' }]; },
            };
        """.trimIndent()

        private val PROBE_SPIDER = """
            export default {
              home(filter) {
                const html = '<div class="a">x</div>';
                return JSON.stringify({ h: pdfh(html, ''), a: pdfa(html, '').length, l: pdfla(html, '', 'Text', 'href', '').length });
              },
              detail(id) { return JSON.stringify(JSON.parse('<html></html>')); },
            };
        """.trimIndent()

        private val CAT_SPIDER = """
            import { load, Crypto } from 'assets://js/lib/cat.js';
            let host = '';
            async function init(cfg) { host = cfg.ext.host; }
            async function home(filter) {
              const res = await req(host + '/list.html', {});
              const ${'$'} = load(res.content);
              const list = ${'$'}('.item a').map((i, el) => ({ vod_id: ${'$'}(el).attr('href'), vod_name: ${'$'}(el).text() })).get();
              return JSON.stringify({ class: [{ type_id: '1', type_name: '剧集' }], list });
            }
            async function detail(id) {
              return JSON.stringify({ list: [{ vod_id: id, vod_name: 'n', vod_play_from: 'a', vod_play_url: '1${'$'}' + host + '/v.m3u8' }] });
            }
            async function search(wd) { return JSON.stringify({ list: [{ vod_id: '1', vod_name: Crypto.MD5(wd).toString() }] }); }
            async function play(flag, id) {
              const res = await req(host + '/echo', { method: 'post', data: { a: 1 } });
              return JSON.stringify({ parse: 0, url: res.content });
            }
            async function proxy(segs, header) {
              return JSON.stringify({ code: 200, buffer: 2, content: 'aGk=', headers: { 'Content-Type': 'text/plain', 'X-Seg': segs.join('|') + ' ' + header.Referer } });
            }
            export function __jsEvalReturn() { return { init, home, detail, search, play, proxy }; }
        """.trimIndent()
    }
}
