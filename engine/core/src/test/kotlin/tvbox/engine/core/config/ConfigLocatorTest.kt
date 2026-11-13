package tvbox.engine.core.config

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.util.UriUtil

class ConfigLocatorTest {
    private val locator = ConfigLocator("http://127.0.0.1:9978/file/")

    @Test
    fun `bare host gets http scheme`() {
        val loc = locator.locate("a.com/tv")
        assertEquals("http://a.com/tv", loc.fetchUrl)
        assertNull(loc.key)
        assertFalse(loc.isClan)
    }

    @Test
    fun `pk suffix is split off as key`() {
        val loc = locator.locate("https://a.com/x.json;pk;key1")
        assertEquals("https://a.com/x.json", loc.fetchUrl)
        assertEquals("key1", loc.key)
    }

    @Test
    fun `empty pk is no key`() {
        assertNull(locator.locate("https://a.com/x.json;pk;").key)
    }

    @Test
    fun `a path on the engine's machine is a local file`() {
        assertEquals("http://127.0.0.1:9978/file/C:/tv/多仓.json", locator.locate("""C:\tv\多仓.json""").fetchUrl)
        assertEquals("http://127.0.0.1:9978/file/C:/tv/a.json", locator.locate("C:/tv/a.json;pk;k").fetchUrl)
        assertEquals("http://127.0.0.1:9978/file/home/me/a.json", locator.locate("/home/me/a.json").fetchUrl)
        assertTrue(locator.locate("/home/me/a.json").isClan)
        assertEquals("http://127.0.0.1:9978/file//C:/tv/a.json", locator.locate("file:///C:/tv/a.json").fetchUrl)
    }

    @Test
    fun `clan localhost maps to local file base`() {
        val loc = locator.locate("clan://localhost/tv/a.json")
        assertEquals("http://127.0.0.1:9978/file/tv/a.json", loc.fetchUrl)
        assertTrue(loc.isClan)
        assertEquals("http://127.0.0.1:9978/file/tv/a.json", locator.locate("file://tv/a.json").fetchUrl)
    }

    @Test
    fun `clan remote host maps to its file server`() {
        assertEquals(
            "http://192.168.1.2:9978/file/tv/a.json",
            locator.locate("clan://192.168.1.2:9978/tv/a.json").fetchUrl,
        )
    }

    @Test
    fun `relative paths in content are resolved against the config url`() {
        val loc = locator.locate("http://a.com/x/y.json")
        val fixed = locator.fixContent(loc, """{"spider":"./spider.jar","js":"../lib/a.js"}""")
        assertEquals("""{"spider":"http://a.com/x/spider.jar","js":"http://a.com/lib/a.js"}""", fixed)
    }

    @Test
    fun `clan references in content are rewritten for clan configs`() {
        val loc = locator.locate("clan://192.168.1.2:9978/tv/a.json")
        val fixed = locator.fixContent(loc, """{"spider":"clan://localhost/tv/a.jar"}""")
        assertEquals("""{"spider":"http://192.168.1.2:9978/file/tv/a.jar"}""", fixed)
    }

    @Test
    fun `uri resolution tolerates unicode hosts and empty paths`() {
        assertEquals("http://肥猫.com/", UriUtil.resolve("http://肥猫.com/", "./"))
        assertEquals("http://a.com/", UriUtil.resolve("http://a.com", "./"))
        assertEquals("http://a.com/a/", UriUtil.resolve("http://a.com/a/b/c.json?x=1", "../"))
        assertEquals("https://b.com/z", UriUtil.resolve("http://a.com/a/", "https://b.com/z"))
    }
}
