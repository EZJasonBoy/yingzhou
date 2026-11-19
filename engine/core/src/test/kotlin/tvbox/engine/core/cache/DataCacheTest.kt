package tvbox.engine.core.cache

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.serializer
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.ConfigSummary
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.JsonFileStore
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Copies of configs and site answers: a start that does not wait for the network, and pages that survive without it. */
class DataCacheTest {
    @TempDir lateinit var dir: File
    private val server = MockWebServer()

    /** What the server answers by path; a missing path is a 500, as from a server that is down. */
    private val pages = HashMap<String, String>()

    /** Delay before the subscription is answered. */
    @Volatile private var configDelayMs = 0L
    @Volatile private var down = false
    private val asked = AtomicInteger()

    @BeforeEach
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                asked.incrementAndGet()
                val path = request.requestUrl!!.encodedPath
                val query = request.requestUrl!!.query.orEmpty()
                if (down) return MockResponse().setResponseCode(500)
                val body = pages[if (path.startsWith("/site")) "$path?$query" else path] ?: return MockResponse().setResponseCode(500)
                return MockResponse().setBody(body).setHeadersDelay(if (path == "/tv.json") configDelayMs else 0, TimeUnit.MILLISECONDS)
            }
        }
        server.start()
        pages["/tv.json"] = config("甲")
        site("a", "一")
        site("b", "二")
    }

    @AfterEach
    fun stop() = server.shutdown()

    private fun url(path: String) = server.url(path).toString()

    private fun config(name: String) =
        """{"sites":[{"key":"a","name":"$name","type":1,"api":"${url("/site-a")}"},{"key":"b","name":"乙","type":1,"api":"${url("/site-b")}"}]}"""

    /** A CMS site whose home, first category page and detail all carry [mark]. */
    private fun site(key: String, mark: String) {
        pages["/site-$key?"] = """{"class":[{"type_id":"1","type_name":"电影$mark"}],"list":[{"vod_id":"1","vod_name":"首页$mark"}]}"""
        pages["/site-$key?ac=detail&t=1&pg=1&f="] = """{"page":1,"pagecount":3,"list":[{"vod_id":"1","vod_name":"分类$mark"}]}"""
        pages["/site-$key?ac=detail&ids=1"] = """{"list":[{"vod_id":"1","vod_name":"详情$mark","vod_play_from":"线","vod_play_url":"第1集${'$'}http://v.test/1.m3u8"}]}"""
    }

    private fun engine(): Engine {
        val cache = DataCache(File(dir, "cache"))
        return Engine(
            EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
            ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/"), cache),
            SiteHttp(OkHttpClient()),
            proxyBase = "http://127.0.0.1:9978/proxy?",
            store = JsonFileStore(File(dir, "store")),
            cache = cache,
        )
    }

    private suspend fun settled(engine: Engine): ConfigSummary {
        repeat(100) {
            val s = engine.config()
            if (!s.refreshing) return s
            delay(50)
        }
        error("the refresh did not end")
    }

    @Test
    fun `an engine restarted while the subscription's server is down serves the config and the pages seen before`() = runBlocking {
        val first = engine()
        first.activate(first.addSubscription(url("/tv.json"), null).id)
        assertEquals("首页一", first.home("a").list.single().name)
        assertEquals("分类一", first.category("a", "1", 1, emptyMap()).list.single().name)
        assertEquals("详情一", first.detail("a", "1").name)
        assertEquals("首页二", first.home("b").list.single().name, "another site, its own answer")

        down = true
        val second = engine()
        val restored = second.restore()!!.getOrThrow()
        assertTrue(restored.stored)
        assertTrue(restored.fetchedAt > 0)
        assertEquals(listOf("甲", "乙"), second.sites().map { it.name })
        assertEquals("首页一", second.home("a").list.single().name)
        assertEquals("分类一", second.category("a", "1", 1, emptyMap()).list.single().name)
        assertEquals("详情一", second.detail("a", "1").name)
        assertEquals("首页二", second.home("b").list.single().name)
        // What was never seen cannot be served, and neither can search.
        assertThrows(EngineException::class.java) { runBlocking { second.category("a", "1", 2, emptyMap()) } }
        assertThrows(EngineException::class.java) { runBlocking { second.search("a", "x", 1) } }
        // Asked for a fresh answer, the engine does not pretend to have one.
        assertThrows(EngineException::class.java) { runBlocking { second.home("a", refresh = true) } }

        val after = settled(second)
        assertTrue(after.stored, "still the copy")
        assertTrue(after.refreshError.contains("500"), after.refreshError)
        assertThrows(EngineException::class.java) { runBlocking { second.reloadConfig() } }
        assertEquals(listOf("甲", "乙"), second.sites().map { it.name }, "a failed reload keeps the config in use")
    }

    @Test
    fun `a start from the copy does not wait for a slow server, and the fresh config replaces it only when it differs`() = runBlocking {
        val first = engine()
        first.activate(first.addSubscription(url("/tv.json"), null).id)
        assertEquals("首页一", first.home("a").list.single().name)

        // Same text: confirmed, nothing is replaced.
        configDelayMs = 700
        val second = engine()
        val started = System.currentTimeMillis()
        val restored = second.restore()!!.getOrThrow()
        assertTrue(System.currentTimeMillis() - started < 500, "took ${System.currentTimeMillis() - started} ms")
        assertTrue(restored.stored && restored.refreshing)
        val confirmed = settled(second)
        assertFalse(confirmed.stored)
        assertEquals("", confirmed.refreshError)
        assertTrue(confirmed.fetchedAt >= restored.fetchedAt)

        // The subscription changed on the server: the copy first, then the new config, and none of the old pages.
        configDelayMs = 300
        pages["/tv.json"] = config("改名了")
        site("a", "新")
        val third = engine()
        third.restore()!!.getOrThrow()
        assertEquals("甲", third.sites().first().name)
        assertEquals("首页一", third.home("a").list.single().name, "the kept page of the kept config")
        settled(third)
        assertEquals("改名了", third.sites().first().name)
        assertEquals("首页新", third.home("a").list.single().name, "a changed config does not find the old config's pages")
    }

    @Test
    fun `reload downloads the config again, and refresh asks the site again`() = runBlocking {
        val engine = engine()
        val summary = engine.activate(engine.addSubscription(url("/tv.json"), null).id)
        assertFalse(summary.stored)
        assertEquals("首页一", engine.home("a").list.single().name)

        site("a", "变")
        val before = asked.get()
        assertEquals("首页一", engine.home("a").list.single().name, "young enough: the site is not asked")
        assertEquals(before, asked.get())
        assertEquals("首页变", engine.home("a", refresh = true).list.single().name)
        assertEquals("首页变", engine.home("a").list.single().name, "the fresh answer replaced the kept one")
        assertEquals("详情变", engine.detail("a", "1", refresh = true).name)

        pages["/tv.json"] = config("重载")
        assertEquals("重载", engine.reloadConfig().let { engine.sites().first().name })

        // The cache can be looked at and emptied; the config in use stays.
        val info = engine.cacheInfo()
        assertTrue(info.bytes > 0 && info.areas.keys.containsAll(listOf("config", "site")), info.toString())
        assertEquals(0, engine.clearCache().entries)
        assertEquals("重载", engine.sites().first().name)
        assertNull(DataCache(File(dir, "cache")).get(DataCache.CONFIG, url("/tv.json")))
    }

    @Test
    fun `an old answer is served at once while a new one is fetched, and an empty one is not kept`() = runBlocking {
        var now = 1_000L
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val data = SiteDataCache(DataCache(File(dir, "c"), now = { now }), scope, now = { now })
        val calls = AtomicInteger()
        suspend fun ask(refresh: Boolean = false, answer: String? = null): String =
            data.get("k", 100, refresh, String.serializer(), { it.isNotEmpty() }) {
                calls.incrementAndGet()
                answer ?: throw IllegalStateException("site is down")
            }

        assertEquals("", ask(answer = ""), "passed on")
        assertEquals("one", ask(answer = "one"), "the empty answer was not kept")
        assertEquals("one", ask(answer = "two"))
        assertEquals(2, calls.get())

        now += 200
        assertEquals("one", ask(answer = "two"), "stale, but here now")
        repeat(100) { if (calls.get() < 3) delay(20) }
        delay(50)
        assertEquals("two", ask(answer = "three"), "the background fetch replaced it")
        now += 200
        assertEquals("two", ask(), "a failing site leaves the kept answer")
        delay(100)
        assertEquals("two", ask())
        assertThrows(IllegalStateException::class.java) { runBlocking { ask(refresh = true) } }
        scope.coroutineContext[kotlinx.coroutines.Job]!!.cancel()
    }

    @Test
    fun `the cache is bounded and survives a restart`() {
        var now = 0L
        val root = File(dir, "bounded")
        val cache = DataCache(root, maxAreaBytes = 20_000, memoryEntries = 5, now = { now })
        repeat(200) { i ->
            now += 1
            cache.put(DataCache.SITE, "k$i", "x".repeat(1000))
        }
        cache.put(DataCache.CONFIG, "sub", "config text")
        val info = cache.info()
        assertTrue(info.areas.getValue("site").bytes <= 20_000 + 40 * 1100, info.toString())
        assertEquals("x".repeat(1000), DataCache(root).get(DataCache.SITE, "k199")!!.text, "read back from disk")
        assertEquals("config text", DataCache(root).get(DataCache.CONFIG, "sub")!!.text)
        cache.clear(DataCache.SITE)
        assertNull(cache.get(DataCache.SITE, "k199"))
        assertEquals("config text", cache.get(DataCache.CONFIG, "sub")!!.text)

        // Without a directory everything stays in memory.
        val memory = DataCache(null)
        memory.put(DataCache.SITE, "a", "1")
        assertEquals("1", memory.get(DataCache.SITE, "a")!!.text)
        assertEquals(1, memory.info().entries)
        memory.clear()
        assertNull(memory.get(DataCache.SITE, "a"))
    }
}
