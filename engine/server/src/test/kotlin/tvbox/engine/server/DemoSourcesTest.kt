package tvbox.engine.server

import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.net.SiteHttp
import java.net.InetAddress
import java.net.ServerSocket

/**
 * The demo's sites for switching sources, 演示豆瓣 and 演示失效站, served on a port of their own the way the --demo
 * engine serves them, and what the checker makes of them.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class DemoSourcesTest {
    private val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
    private val base = "http://127.0.0.1:$port"
    private val server = embeddedServer(CIO, port = port, host = "127.0.0.1") { routing { demoRoutes(DemoSite()) } }
    private val http = OkHttpClient()

    @BeforeAll
    fun start() {
        server.start(wait = false)
    }

    @AfterAll
    fun stop() {
        server.stop(100, 1000)
    }

    private fun engine() = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(http, ConfigLocator("$base/file/")),
        SiteHttp(http),
        proxyBase = "$base/proxy?",
    )

    private suspend fun demoEngine() = engine().also { it.activate(it.addSubscription("$base/demo/config.json", null).id) }

    private fun call(path: String, referer: String? = null, method: String = "GET"): Pair<Int, ByteArray> {
        val request = Request.Builder().url(base + path).method(method, null).apply { if (referer != null) header("Referer", referer) }.build()
        return http.newCall(request).execute().use { it.code to it.body!!.bytes() }
    }

    @Test
    fun `douban posters are served only with douban's referer, and every request is logged`() {
        assertEquals(204, call("/demo/douban/log", method = "DELETE").first)
        assertEquals(418, call("/demo/douban/poster/4.png").first)
        assertEquals(418, call("/demo/douban/poster/4.png", referer = "https://example.test/").first)
        val (status, png) = call("/demo/douban/poster/4.png", referer = DemoDouban.REFERER)
        assertEquals(200, status)
        assertArrayEquals(byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte()), png.copyOf(4))

        val log = Json.parseToJsonElement(String(call("/demo/douban/log").second)).jsonObject
        assertEquals(2, log["withReferer"]!!.jsonPrimitive.int)
        assertEquals(1, log["withoutReferer"]!!.jsonPrimitive.int)
        val hits = log["hits"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf(418, 418, 200), hits.map { it["status"]!!.jsonPrimitive.int })
        assertEquals(listOf("", "https://example.test/", DemoDouban.REFERER), hits.map { it["referer"]!!.jsonPrimitive.content })
        assertEquals(listOf(4, 4, 4), hits.map { it["n"]!!.jsonPrimitive.int })

        call("/demo/douban/log", method = "DELETE")
        val cleared = Json.parseToJsonElement(String(call("/demo/douban/log").second)).jsonObject
        assertEquals(0, cleared["withReferer"]!!.jsonPrimitive.int)
        assertEquals(0, cleared["hits"]!!.jsonArray.size)
    }

    @Test
    fun `演示豆瓣's cards are found by their title on 演示站, and their posters name the referer`() = runBlocking {
        val engine = demoEngine()
        val sites = engine.sites()
        assertEquals(listOf("demo_douban", "demo_dead"), sites.takeLast(2).map { it.key })
        val douban = sites.first { it.key == "demo_douban" }
        assertFalse(douban.searchable)
        assertFalse(douban.changeable)
        val dead = sites.first { it.key == "demo_dead" }
        assertTrue(dead.searchable)
        assertTrue(dead.changeable)
        assertTrue(sites.first { it.key == "demo" }.changeable)

        val home = engine.home("demo_douban")
        assertEquals(2, home.classes.size)
        assertEquals(1, home.list.count { it.id.isEmpty() })
        assertTrue(home.list.filter { it.id.isNotEmpty() }.all { it.id == "msearch:" + it.name }, home.list.toString())
        val pics = home.list.map { it.pic }
        assertTrue(pics.all { it.startsWith("$base/demo/douban/poster/") }, pics.toString())
        assertEquals(1, pics.count { it.endsWith(".png@Headers=%7B%22Referer%22%3A%22https%3A%2F%2Fmovie.douban.com%2F%22%7D") }, pics.toString())
        assertEquals(pics.size - 1, pics.count { it.endsWith(".png@Referer=https://movie.douban.com/") }, pics.toString())
        // Every title is on 演示站, where a search for it finds it under exactly that name.
        for (card in home.list) assertTrue(engine.search("demo", card.name, 1).list.any { it.name == card.name }, card.name)

        val movies = engine.category("demo_douban", home.classes.first().id, 1, emptyMap())
        assertTrue(movies.list.isNotEmpty())
        assertTrue(movies.list.all { it.id.isEmpty() || it.id.startsWith("msearch:") })
    }

    @Test
    fun `演示失效站 has 演示站's titles and episodes, and none of its lines plays`() = runBlocking {
        val engine = demoEngine()
        val good = engine.detail("demo", "1")
        val dead = engine.detail("demo_dead", "1")
        assertEquals(good.name, dead.name)
        assertEquals(listOf("失效直链", "失效解析"), dead.lines.map { it.name })
        val names = good.lines.first().episodes.map { it.name }
        assertTrue(names.size > 1)
        dead.lines.forEach { line -> assertEquals(names, line.episodes.map { it.name }) }
        assertTrue(dead.lines[0].episodes.all { it.id.startsWith("http://127.0.0.1:1/") })
        val failed = assertThrows(EngineException::class.java) {
            runBlocking { engine.resolvePlay(PlayRequest("demo_dead", "失效解析", dead.lines[1].episodes.first().id)) }
        }
        assertEquals("PLAY_FAILED", failed.code)
        assertEquals(engine.search("demo", "星河", 1).list.map { it.name }, engine.search("demo_dead", "星河", 1).list.map { it.name })
    }

    @Test
    fun `the checker passes 演示豆瓣 as a recommendation site and leaves out what it is told to`() = runBlocking {
        val options = Checker.Options(only = setOf("cms"), skip = DemoSite.SELF_CHECK_SKIP)
        val results = Checker(engine(), options) {}.run(listOf("$base/demo/config.json"))
        val sites = results.single().sites.associateBy { it.key }
        val douban = sites.getValue("demo_douban")
        assertEquals("pass", douban.verdict, douban.toString())
        assertEquals(Checker.RECOMMENDATION, douban.message)
        assertTrue(douban.items > 0)
        assertEquals(0, douban.lines)
        val dead = sites.getValue("demo_dead")
        assertEquals("skipped", dead.verdict)
        assertEquals(DemoSite.SELF_CHECK_SKIP.getValue("demo_dead"), dead.message)
        assertEquals("pass", sites.getValue("demo").verdict)
        assertTrue(Checker.ok(results, strict = true), results.toString())
    }

    @Test
    fun `the first video the checker opens is not a search by title`() {
        assertEquals(2, Checker.firstToOpen(listOf("msearch:甲", "", "7", "8")))
        assertEquals(1, Checker.firstToOpen(listOf(" ", "msearch", "msearch:乙")))
        assertNull(Checker.firstToOpen(listOf("msearch:甲", "", " ")))
        assertNull(Checker.firstToOpen(emptyList()))
    }
}
