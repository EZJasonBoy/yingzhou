package tvbox.engine.core.play

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.model.SniffRequest
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.site.RawPlay

class SniffTest {
    @Test
    fun `sniff rules follow TVBox host rules, filters and the video regex`() {
        val rules = PlayRules.parse(
            """[{"host":"www.djuu.com","rule":["mp4.djuu.com","m4a"]},
               {"host":"v.example.com","filter":["ad.example.com"]},
               {"name":"ads","hosts":["lz"],"regex":["#EXT-X-DISCONTINUITY"]}]""",
        )
        assertTrue(rules.isMedia("https://www.djuu.com/play/1", "https://mp4.djuu.com/a/b.m4a?x"))
        assertTrue(rules.isMedia("https://www.djuu.com/play/1", "https://mp4.djuu.com/stream/123/m4a"), "host rule without an extension")
        assertFalse(rules.isMedia("https://other.com/play/1", "https://mp4.djuu.com/stream/123/m4a"), "rules only apply to their host")
        assertTrue(rules.isMedia("https://other.com/", "https://cdn.example.org/video/index.m3u8"))
        assertFalse(rules.isMedia("https://v.example.com/", "https://ad.example.com/clip/a1234567890.mp4"), "filtered on that host")
        assertFalse(rules.isMedia("https://x.com/", "https://jx.example.com/?url=http://a.com/b.m3u8"), "parser pages are not media")
        assertFalse(rules.isMedia("https://x.com/", "blob:https://x.com/123"))
        assertFalse(PlayRules.parse("not json").isMedia("https://x.com/", "https://x.com/page"))
    }

    @Test
    fun `hosts with regex split into ad patterns and sniff rules, plus scripts and excludes`() {
        val rules = PlayRules.parse(
            """[{"name":"量非","hosts":["lz","ffzy"],"regex":["#EXT-X-DISCONTINUITY\r*\n*#EXTINF:6.666667,[\\s\\S]*?#EXT-X-DISCONTINUITY","15.1666","-17.66"]},
               {"name":"bdys","hosts":["bytetos.com"],"regex":["/tos-cn"],"exclude":[".m3u8"]},
               {"name":"点击","hosts":["www.maolvys.com"],"script":["document.querySelector('.play').click()"]}]""",
        )
        assertEquals(3, rules.adsFor("https://vip.lzcdn2.com/20240101/abc/index.m3u8").size, "ad patterns match hosts by substring")
        assertTrue(rules.adsFor("https://other.com/index.m3u8").isEmpty())
        assertTrue(rules.isMedia("https://page.test/", "https://p3.bytetos.com/obj/tos-cn-v/abc"), "a sniff rule on the media host")
        assertFalse(rules.isMedia("https://page.test/", "https://p3.bytetos.com/obj/tos-cn-v/abc.m3u8"), "excluded")
        assertEquals(listOf("document.querySelector('.play').click()"), rules.scriptsFor("https://www.maolvys.com/play/1.html"))
        assertTrue(rules.scriptsFor("https://other.com/").isEmpty())
    }

    @Test
    fun `a sniff parser is resolved on the engine when it can sniff`() = runBlocking {
        val asked = mutableListOf<SniffRequest>()
        val sniffer = object : Sniffer {
            override suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult? {
                asked += request
                val candidates = listOf("https://jx.test/page.html", "https://cdn.test/hls/abcdefghijk/index.m3u8")
                return candidates.firstOrNull(isMedia)?.let { SniffResult(it, mapOf("Referer" to "https://jx.test/")) }
            }
        }
        val resolver = PlayResolver(SiteHttp(OkHttpClient()), "http://127.0.0.1:9978/proxy?", sniffer)
        val raw = RawPlay(url = "https://site.test/v/1", parse = 1, headers = mapOf("User-Agent" to "ua"), playUrl = "https://jx.test/?url=")
        val info = resolver.resolve(raw, TvboxConfig())
        assertEquals("direct", info.kind)
        assertEquals("https://cdn.test/hls/abcdefghijk/index.m3u8", info.url)
        assertEquals(mapOf("User-Agent" to "ua", "Referer" to "https://jx.test/"), info.headers)
        assertEquals("https://jx.test/?url=https://site.test/v/1", asked.single().pageUrl)

        // Without a sniffer the page goes to the client.
        val plain = PlayResolver(SiteHttp(OkHttpClient()), "http://127.0.0.1:9978/proxy?").resolve(raw, TvboxConfig())
        assertEquals("sniff", plain.kind)

        // A sniffer that finds nothing fails the play with a clear message.
        val empty = PlayResolver(SiteHttp(OkHttpClient()), "", object : Sniffer {
            override suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult? = null
        })
        val e = assertThrows(PlayResolveException::class.java) { runBlocking { empty.resolve(raw, TvboxConfig()) } }
        assertTrue(e.message!!.contains("sniffing"))
    }
}
