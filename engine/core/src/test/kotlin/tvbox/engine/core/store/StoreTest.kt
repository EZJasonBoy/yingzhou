package tvbox.engine.core.store

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
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

    private fun engine(store: EngineStore) = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:9978/proxy?",
        store = store,
    )
}
