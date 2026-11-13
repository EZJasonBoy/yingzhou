package tvbox.engine.core.store

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import java.util.concurrent.TimeUnit
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.FavoriteEntry
import tvbox.engine.core.model.HistoryEntry
import tvbox.engine.core.net.SiteHttp
import java.io.File

class StoreTest {
    @TempDir
    lateinit var dir: File

    @Test
    fun `history keeps the latest entry per video, newest first, and survives a reload`() {
        var now = 1000L
        val library = Library(JsonFileStore(dir), clock = { now })
        library.putHistory(HistoryEntry("a", "1", "One", positionMs = 10))
        now = 2000
        library.putHistory(HistoryEntry("b", "2", "Two"))
        now = 3000
        library.putHistory(HistoryEntry("a", "1", "One", episodeIndex = 3, positionMs = 99))

        val reloaded = Library(JsonFileStore(dir))
        assertEquals(listOf("1", "2"), reloaded.history().map { it.vodId })
        assertEquals(99, reloaded.historyFor("a", "1")!!.positionMs)
        assertEquals(3000, reloaded.historyFor("a", "1")!!.updatedAt)
    }

    @Test
    fun `history is capped`() {
        var now = 0L
        val library = Library(MemoryStore(), clock = { now++ }, maxHistory = 3)
        (1..5).forEach { library.putHistory(HistoryEntry("s", "$it", "v$it")) }
        assertEquals(listOf("5", "4", "3"), library.history().map { it.vodId })
    }

    @Test
    fun `re-adding a favorite keeps its added time`() {
        var now = 100L
        val library = Library(JsonFileStore(dir), clock = { now })
        library.putFavorite(FavoriteEntry("s", "1", "Old name"))
        now = 500
        library.putFavorite(FavoriteEntry("s", "1", "New name"))
        val fav = Library(JsonFileStore(dir)).favoriteFor("s", "1")!!
        assertEquals("New name", fav.name)
        assertEquals(100, fav.addedAt)
        assertTrue(library.removeFavorite("s", "1"))
        assertNull(Library(JsonFileStore(dir)).favoriteFor("s", "1"))
    }

    @Test
    fun `a corrupt file is set aside instead of crashing`() {
        File(dir, "history.json").writeText("{not json")
        assertTrue(Library(JsonFileStore(dir)).history().isEmpty())
        assertTrue(File(dir, "history.json.broken").exists())
    }

    @Test
    fun `engine restores the active subscription after a restart`() = runBlocking {
        val server = MockWebServer().apply { start() }
        try {
            repeat(2) { server.enqueue(MockResponse().setBody("""{"sites":[{"key":"a","type":1,"api":"http://x"}]}""")) }
            val url = server.url("/tv.json").toString()

            val first = engine(JsonFileStore(dir))
            val sub = first.addSubscription(url, "我的订阅")
            first.activate(sub.id)

            val second = engine(JsonFileStore(dir))
            assertEquals(listOf("我的订阅"), second.subscriptions().map { it.name })
            val restored = second.restore()!!.getOrThrow()
            assertEquals(url, restored.url)
            assertEquals(listOf("a"), second.sites().map { it.key })
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `config waits for the restore after a restart, reports its failure and retries`() = runBlocking {
        val server = MockWebServer().apply { start() }
        try {
            val body = """{"sites":[{"key":"a","type":1,"api":"http://x"}]}"""
            server.enqueue(MockResponse().setBody(body))
            val url = server.url("/tv.json").toString()
            val first = engine(JsonFileStore(dir))
            first.activate(first.addSubscription(url, null).id)

            // Restarted engine: a client asks while the (slow) restore is still loading.
            server.enqueue(MockResponse().setBody(body).setHeadersDelay(500, TimeUnit.MILLISECONDS))
            val second = engine(JsonFileStore(dir))
            val restoring = async(Dispatchers.IO) { second.restore() }
            delay(100)
            assertEquals(url, second.config().url)
            assertEquals(url, restoring.await()!!.getOrThrow().url)
            assertEquals(2, server.requestCount, "the waiting client shares the restore instead of loading again")

            // The subscription is unreachable at the next start: the waiting client hears why, and asking again retries.
            server.enqueue(MockResponse().setResponseCode(500).setHeadersDelay(500, TimeUnit.MILLISECONDS))
            val third = engine(JsonFileStore(dir))
            val failing = async(Dispatchers.IO) { third.restore() }
            delay(100)
            val e = assertThrows(EngineException::class.java) { runBlocking { third.config() } }
            assertEquals("CONFIG_LOAD_FAILED", e.code)
            assertTrue(failing.await()!!.isFailure)
            assertEquals(3, server.requestCount)
            server.enqueue(MockResponse().setBody(body))
            assertEquals(url, third.config().url)
            assertEquals(4, server.requestCount)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `config without any saved subscription is NO_CONFIG`() = runBlocking {
        val e = assertThrows(EngineException::class.java) { runBlocking { engine(MemoryStore()).config() } }
        assertEquals("NO_CONFIG", e.code)
    }

    private fun engine(store: EngineStore) = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:9978/proxy?",
        store = store,
    )
}
