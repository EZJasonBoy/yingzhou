package tvbox.engine.core.play

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class M3u8CleanerTest {
    private fun playlist(vararg blocks: List<Pair<String, String>>, discontinuity: Boolean = true): String = buildString {
        append("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.key\"\n")
        blocks.forEachIndexed { i, block ->
            if (i > 0 && discontinuity) append("#EXT-X-DISCONTINUITY\n")
            for ((d, uri) in block) append("#EXTINF:$d,\n$uri\n")
        }
        append("#EXT-X-ENDLIST\n")
    }

    private fun main(range: IntRange) = range.map { "10.000000" to "seg%04d.ts".format(it) }

    @Test
    fun `relative uris become absolute and the key too`() {
        val r = M3u8Cleaner.clean(playlist(main(0..2)), "https://cdn.test/v/1/index.m3u8", emptyList(), heuristic = false)
        assertEquals(0, r.removed)
        assertTrue(r.text.contains("\nhttps://cdn.test/v/1/seg0000.ts\n"), r.text)
        assertTrue(r.text.contains("URI=\"https://cdn.test/v/1/key.key\""), r.text)
        assertTrue(r.text.trimEnd().endsWith("#EXT-X-ENDLIST"))
    }

    @Test
    fun `a duration pattern removes the ad block by first segment or total, and -n by the last`() {
        val ad = listOf("3.000000" to "/ad/a1.ts", "4.166666" to "/ad/a2.ts", "8.000000" to "/ad/a3.ts")
        val text = playlist(main(0..9), ad, main(10..19))
        val byTotal = M3u8Cleaner.clean(text, "https://cdn.test/v/index.m3u8", listOf("15.1666"), heuristic = false)
        assertEquals(3, byTotal.removed)
        assertFalse(byTotal.text.contains("/ad/"), byTotal.text)
        assertTrue(byTotal.text.contains("seg0019.ts"))

        val byLast = M3u8Cleaner.clean(text, "https://cdn.test/v/index.m3u8", listOf("-8.0"), heuristic = false)
        assertEquals(3, byLast.removed)
        assertEquals(0, M3u8Cleaner.clean(text, "https://cdn.test/v/index.m3u8", listOf("9.99"), heuristic = false).removed)
    }

    @Test
    fun `an EXT pattern removes what it matches but keeps the end tag`() {
        val ad = listOf("6.666667" to "https://ads.test/x1.ts", "6.666667" to "https://ads.test/x2.ts")
        val text = playlist(main(0..9), ad, main(10..19))
        val pattern = "#EXT-X-DISCONTINUITY\r*\n*#EXTINF:6.666667,[\\s\\S]*?#EXT-X-DISCONTINUITY"
        val r = M3u8Cleaner.clean(text, "https://cdn.test/v/index.m3u8", listOf(pattern), heuristic = false)
        assertEquals(2, r.removed)
        assertFalse(r.text.contains("ads.test"), r.text)
        assertTrue(r.text.contains("#EXT-X-ENDLIST"))
    }

    @Test
    fun `the heuristic only cuts minority segments spliced in with a discontinuity`() {
        val ad = listOf("5.0" to "https://ads.test/creative/0001.ts", "5.0" to "https://ads.test/creative/0002.ts")
        val spliced = M3u8Cleaner.clean(playlist(main(0..9), ad, main(10..19)), "https://cdn.test/v/index.m3u8", emptyList(), heuristic = true)
        assertEquals(2, spliced.removed)
        assertFalse(spliced.text.contains("ads.test"))

        // Same foreign segments without a discontinuity are left alone.
        val plain = M3u8Cleaner.clean(playlist(main(0..9), ad, main(10..19), discontinuity = false), "https://cdn.test/v/index.m3u8", emptyList(), heuristic = true)
        assertEquals(0, plain.removed)

        // Growing segment numbers (seg9.ts, seg10.ts...) are one path, not ads.
        val unpadded = (0..30).map { "10.0" to "seg$it.ts" }
        val r = M3u8Cleaner.clean(playlist(unpadded.take(12), unpadded.drop(12)), "https://cdn.test/v/index.m3u8", emptyList(), heuristic = true)
        assertEquals(0, r.removed)
    }

    @Test
    fun `cleaning that would remove most of the playlist is abandoned`() {
        val text = playlist(main(0..1), (0..9).map { "15.1666" to "ad$it.ts" })
        val r = M3u8Cleaner.clean(text, "https://cdn.test/v/index.m3u8", listOf("15.1666"), heuristic = false)
        assertEquals(0, r.removed)
        assertTrue(r.text.contains("ad9.ts"))
    }

    @Test
    fun `master playlists route each variant back through the engine`() {
        val master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nhttps://other.test/hi.m3u8\n"
        assertTrue(M3u8Cleaner.isMaster(master))
        val out = M3u8Cleaner.rewriteMaster(master, "https://cdn.test/v/master.m3u8") { "http://engine/m3u8?url=$it" }
        assertTrue(out.contains("\nhttp://engine/m3u8?url=https://cdn.test/v/low/index.m3u8\n"), out)
        assertTrue(out.contains("\nhttp://engine/m3u8?url=https://other.test/hi.m3u8"), out)
    }
}
