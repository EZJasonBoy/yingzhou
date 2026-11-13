package tvbox.engine.core.config

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
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.EngineStore
import tvbox.engine.core.store.JsonFileStore
import tvbox.engine.core.store.MemoryStore
import java.io.File

/** A multi-repository subscription whose entries are multi-repository lists themselves ("多仓" inside "多仓"). */
class NestedRepoTest {
    private val server = MockWebServer()
    private val pages = HashMap<String, String>()
    private fun url(path: String) = server.url(path).toString()

    @BeforeEach
    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                pages[request.path]?.let { MockResponse().setBody(it) } ?: MockResponse().setResponseCode(404)
        }
        server.start()
        fun config(key: String) = """{"sites":[{"key":"$key","type":1,"api":"http://x"}]}"""
        fun repo(vararg entries: Pair<String, String>) =
            """{"urls":[${entries.joinToString(",") { (name, path) -> """{"name":"$name","url":"${url(path)}"}""" }}]}"""
        pages["/top"] = repo("单仓" to "/plain", "多仓甲" to "/group-a", "多仓乙" to "/group-b", "死循环" to "/loop")
        pages["/plain"] = config("plain")
        // The first entry of 多仓甲 is dead; the second works.
        pages["/group-a"] = repo("坏的" to "/dead", "甲一" to "/a1", "甲二" to "/a2")
        pages["/a1"] = config("a1")
        pages["/a2"] = config("a2")
        // 多仓乙 holds another list.
        pages["/group-b"] = repo("更深" to "/group-c")
        pages["/group-c"] = repo("丙一" to "/c1")
        pages["/c1"] = config("c1")
        pages["/loop"] = repo("自己" to "/loop")
    }

    @AfterEach
    fun stop() = server.shutdown()

    private fun engine(store: EngineStore = MemoryStore()) = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:9978/proxy?",
        store = store,
    )

    @Test
    fun `choosing a nested repository opens it and loads its first working entry`() = runBlocking {
        val engine = engine()
        val id = engine.addSubscription(url("/top"), null).id
        assertEquals(url("/plain"), engine.activate(id).url)

        val summary = engine.activate(id, url("/group-a"))
        assertEquals(url("/a1"), summary.url, "the dead first entry is skipped")
        assertEquals(listOf("a1"), engine.sites().map { it.key })
        assertEquals(
            listOf("单仓" to 0, "多仓甲" to 0, "坏的" to 1, "甲一" to 1, "甲二" to 1, "多仓乙" to 0, "死循环" to 0),
            summary.repos.map { it.name to it.depth },
        )
        val group = summary.repos.first { it.name == "多仓甲" }
        assertTrue(group.group)
        assertEquals(group.url, summary.repos.first { it.name == "甲二" }.parent)

        // Its entries can now be chosen directly, and stay listed after switching away.
        assertEquals(url("/a2"), engine.activate(id, url("/a2")).url)
        val back = engine.activate(id, url("/plain"))
        assertEquals(url("/plain"), back.url)
        assertTrue(back.repos.any { it.name == "甲二" })
    }

    @Test
    fun `lists inside lists are followed, lists of themselves are not`() = runBlocking {
        val engine = engine()
        val id = engine.addSubscription(url("/top"), null).id
        val summary = engine.activate(id, url("/group-b"))
        assertEquals(url("/c1"), summary.url)
        assertEquals(2, summary.repos.first { it.name == "丙一" }.depth)

        val e = assertThrows(EngineException::class.java) { runBlocking { engine.activate(id, url("/loop")) } }
        assertTrue(e.message!!.contains("lists itself"), e.message)
        assertEquals(url("/c1"), engine.summary().url, "a failed switch keeps the current config")
    }

    @Test
    fun `an entry the user picked is not replaced when it is dead`() = runBlocking {
        val engine = engine()
        val id = engine.addSubscription(url("/top"), null).id
        engine.activate(id, url("/group-a"))
        assertThrows(EngineException::class.java) { runBlocking { engine.activate(id, url("/dead")) } }
        assertThrows(EngineException.NotFound::class.java) { runBlocking { engine.activate(id, url("/never-listed")) } }
        Unit
    }

    @Test
    fun `a nested choice is restored after a restart`(@TempDir dir: File) = runBlocking {
        val first = engine(JsonFileStore(dir))
        val id = first.addSubscription(url("/top"), null).id
        first.activate(id, url("/group-b"))

        val second = engine(JsonFileStore(dir))
        val restored = second.restore()!!.getOrThrow()
        assertEquals(url("/c1"), restored.url)
        assertEquals(listOf("更深", "丙一"), restored.repos.filter { it.depth > 0 }.map { it.name })
    }

    @Test
    fun `a subscription whose first entry is dead falls through to the next`() = runBlocking {
        pages["/top"] = pages["/top"]!!.replace(url("/plain"), url("/gone"))
        val engine = engine()
        val id = engine.addSubscription(url("/top"), null).id
        assertEquals(url("/a1"), engine.activate(id).url)
    }
}
