package tvbox.engine.core.config

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertInstanceOf
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ConfigParserTest {

    @Test
    fun `sloppy real-world config parses like TVBox`() {
        val text = """
            // configs often carry comments and trailing commas in arrays (Gson reads those as null)
            {
              "spider": "http://x/a.jar;md5;abc",
              "wallpaper": "http://x/wp",
              "sites": [
                {"key": "cms", "name": " 采集 ", "type": 1, "api": "http://x/api.php/provide/vod/"},
                {"key": "js1", "type": 3, "api": "http://x/a.js", "ext": {"a": 1}, "searchable": 0},
                {"key": "py_a", "type": 3, "api": "http://x/a.py", "filterable": 0},
                {"key": "csp_A", "type": 3, "api": "csp_A", "jar": "http://x/b.jar", "timeout": "15"},
                {"key": "remote", "type": 4, "api": "http://x/t4"},
                {"key": "bad", "type": 3},
              ],
              "parses": [{"name": "p1", "url": "http://p/?url=", "type": 1, "ext": {"flag": ["qq"]}}],
              "flags": ["qq", "youku"],
              "hosts": ["a.com=b.com=c", "broken"],
              "lives": [{"name": "l1", "url": "http://live.txt"}]
            }
        """.trimIndent()

        val doc = ConfigParser.parse(text)
        val config = assertInstanceOf(ConfigDocument.Single::class.java, doc).config

        assertEquals("http://x/a.jar;md5;abc", config.spider)
        assertEquals(listOf("cms", "js1", "py_a", "csp_A", "remote"), config.sites.map { it.key })

        val (cms, js, py, jar, remote) = config.sites
        assertEquals("采集", cms.name)
        assertEquals(SiteRuntime.CMS, cms.runtime)
        assertEquals("js1", js.name, "name defaults to key")
        assertEquals(SiteRuntime.JS, js.runtime)
        assertEquals(0, js.searchable)
        assertEquals("""{"a":1}""", js.ext)
        assertEquals(1, py.filterable, "py_ sites are always filterable")
        assertEquals(SiteRuntime.PY, py.runtime)
        assertEquals(SiteRuntime.JAR, jar.runtime)
        assertEquals(15, jar.timeout, "numeric strings are accepted")
        assertEquals(SiteRuntime.REMOTE, remote.runtime)

        assertEquals(1, config.parses.size)
        assertEquals("""{"flag":["qq"]}""", config.parses[0].ext)
        assertEquals(listOf("qq", "youku"), config.flags)
        assertEquals(mapOf("a.com" to "b.com=c"), config.hosts)
        assertTrue(config.livesJson.contains("live.txt"))
    }

    @Test
    fun `urls without sites is a repository`() {
        val text = """{"urls": [{"name": "A", "url": "http://a"}, "http://b", {"api": "http://c"}, {"name": "empty"}]}"""
        val repo = assertInstanceOf(ConfigDocument.Repository::class.java, ConfigParser.parse(text))
        assertEquals(
            listOf(RepoEntry("A", "http://a"), RepoEntry("http://b", "http://b"), RepoEntry("http://c", "http://c")),
            repo.entries,
        )
    }

    @Test
    fun `text around the json object is ignored`() {
        val doc = ConfigParser.parse("junk before {\"sites\": []} junk after")
        assertInstanceOf(ConfigDocument.Single::class.java, doc)
    }

    @Test
    fun `missing sites is rejected`() {
        assertThrows(ConfigParser.InvalidConfigException::class.java) { ConfigParser.parse("""{"lives": []}""") }
        assertThrows(ConfigParser.InvalidConfigException::class.java) { ConfigParser.parse("not json at all") }
    }
}
