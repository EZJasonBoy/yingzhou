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
        val rules = SniffRules.parse(
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
        assertFalse(SniffRules.parse("not json").isMedia("https://x.com/", "https://x.com/page"))
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
