package tvbox.engine.core.play

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.play.HlsRewriter.Kind

class HlsRewriterTest {
    private val base = "http://127.0.0.1:9978/hls/abc/"

    private fun rewrite(text: String, url: String = "https://cdn.test/v/1/index.m3u8") = HlsRewriter.rewrite(text.trimIndent(), url)!!

    @Test
    fun `segments are numbered and named by the engine, other lines stay`() {
        val r = rewrite(
            """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:10
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:10.0,
            seg0.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:4.5,title
            https://other.test/x/seg1.ts?t=1
            #EXT-X-ENDLIST
            """,
        )
        assertEquals(
            """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:10
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:10.0,
            ${base}0.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:4.5,title
            ${base}1.ts
            #EXT-X-ENDLIST
            """.trimIndent(),
            r.render(base),
        )
        assertEquals(listOf("https://cdn.test/v/1/seg0.ts", "https://other.test/x/seg1.ts?t=1"), r.resources.map { it.url })
        assertEquals(listOf(0L, 10_000L), r.resources.map { it.startMs })
        assertEquals(listOf(10_000L, 4_500L), r.resources.map { it.durationMs })
        assertEquals(14_500L, r.durationMs)
        assertEquals(listOf(0, 1), r.segments)
    }

    @Test
    fun `a live playlist is left alone`() {
        assertNull(HlsRewriter.rewrite("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\na.ts\n#EXTINF:6,\nb.ts\n", "https://cdn.test/live.m3u8"))
    }

    @Test
    fun `keys and maps go through the engine too, each address once`() {
        val r = rewrite(
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="key1.bin",IV=0x00000000000000000000000000000001
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:4,
            a.m4s
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.test/k2?token=abc"
            #EXTINF:4,
            b.m4s
            #EXT-X-KEY:METHOD=AES-128,URI="key1.bin",IV=0x00000000000000000000000000000003
            #EXTINF:4,
            c.m4s
            #EXT-X-KEY:METHOD=NONE
            #EXTINF:4,
            d.m4s
            #EXT-X-ENDLIST
            """,
        )
        val text = r.render(base)
        assertEquals(listOf(Kind.KEY, Kind.MAP, Kind.SEGMENT, Kind.KEY, Kind.SEGMENT, Kind.SEGMENT, Kind.SEGMENT), r.resources.map { it.kind })
        assertTrue(text.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"${base}0.key\",IV=0x00000000000000000000000000000001\n"), text)
        assertTrue(text.contains("#EXT-X-MAP:URI=\"${base}1.mp4\"\n"), text)
        assertTrue(text.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"${base}3.key\"\n"), text)
        // The first key again, under the number it already has.
        assertTrue(text.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"${base}0.key\",IV=0x00000000000000000000000000000003\n"), text)
        assertTrue(text.contains("#EXT-X-KEY:METHOD=NONE\n"), text)
        assertEquals("https://cdn.test/v/1/key1.bin", r.resources[0].url)
        assertEquals("https://keys.test/k2?token=abc", r.resources[3].url)
        // Segments of a fragmented stream keep an extension players take for one.
        assertTrue(text.contains("\n${base}2.m4s\n") && text.contains("\n${base}6.m4s\n"), text)
    }

    @Test
    fun `byte ranges move into the resources and the tags go`() {
        val r = rewrite(
            """
            #EXTM3U
            #EXT-X-VERSION:4
            #EXT-X-MAP:URI="all.mp4",BYTERANGE="800@0"
            #EXTINF:6,
            #EXT-X-BYTERANGE:1000@800
            all.mp4
            #EXTINF:6,
            #EXT-X-BYTERANGE:500
            all.mp4
            #EXTINF:6,
            #EXT-X-BYTERANGE:700
            all.mp4
            #EXTINF:6,
            #EXT-X-BYTERANGE:300@9000
            other.mp4
            #EXT-X-ENDLIST
            """,
        )
        val text = r.render(base)
        assertFalse(text.contains("BYTERANGE"), text)
        assertTrue(text.contains("#EXT-X-MAP:URI=\"${base}0.mp4\"\n"), text)
        val ranges = r.resources.map { Triple(it.url.substringAfterLast('/'), it.start, it.length) }
        assertEquals(
            listOf(
                Triple("all.mp4", 0L, 800L),
                Triple("all.mp4", 800L, 1000L),
                // Without an offset a range carries on where the one before on the same file ended.
                Triple("all.mp4", 1800L, 500L),
                Triple("all.mp4", 2300L, 700L),
                Triple("other.mp4", 9000L, 300L),
            ),
            ranges,
        )
        // Ranges of one file are different things to cache.
        assertEquals(5, r.resources.map { it.name }.toSet().size)
    }

    @Test
    fun `cache names ignore host and token, unless the query is what tells segments apart`() {
        fun names(vararg segments: String, url: String = "https://cdn.test/v/index.m3u8") =
            rewrite("#EXTM3U\n" + segments.joinToString("") { "#EXTINF:5,\n$it\n" } + "#EXT-X-ENDLIST", url).resources.map { it.name }

        // Another visit: another CDN host, another token, the same files.
        assertEquals(names("https://a.cdn.test/v/1/s0.ts?sign=111", "https://a.cdn.test/v/1/s1.ts?sign=111"), names("https://b.cdn.test/v/1/s0.ts?sign=222", "https://b.cdn.test/v/1/s1.ts?sign=222"))
        assertNotEquals(names("s0.ts")[0], names("s1.ts")[0])
        // One script serving every segment: the query names them.
        val byQuery = names("https://cdn.test/get.php?seg=0", "https://cdn.test/get.php?seg=1")
        assertEquals(2, byQuery.toSet().size)
        assertEquals(byQuery, names("https://cdn.test/get.php?seg=0", "https://cdn.test/get.php?seg=1"))
    }

    @Test
    fun `segments with odd extensions are named as transport streams, known ones keep theirs`() {
        val r = rewrite("#EXTM3U\n#EXTINF:5,\nseg0.png\n#EXTINF:5,\nseg1\n#EXTINF:5,\nseg2.aac\n#EXTINF:5,\nseg3.TS?x=1\n#EXT-X-ENDLIST")
        assertEquals(listOf("ts", "ts", "aac", "ts"), r.resources.map { it.ext })
    }

    @Test
    fun `the fingerprint follows the list of files, not their tokens`() {
        fun fp(vararg segments: String) = rewrite("#EXTM3U\n" + segments.joinToString("") { "#EXTINF:5,\n$it\n" } + "#EXT-X-ENDLIST").fingerprint
        assertEquals(fp("a.ts?t=1", "b.ts?t=1"), fp("a.ts?t=2", "b.ts?t=2"))
        assertNotEquals(fp("a.ts", "b.ts"), fp("a.ts", "ad.ts", "b.ts"))
    }

    @Test
    fun `line endings and a byte order mark do not matter`() {
        val r = HlsRewriter.rewrite("﻿#EXTM3U\r\n#EXTINF:5,\r\na.ts\r\n#EXT-X-ENDLIST\r\n", "https://cdn.test/v/index.m3u8")!!
        assertEquals("#EXTM3U\n#EXTINF:5,\n${base}0.ts\n#EXT-X-ENDLIST\n", r.render(base))
    }
}
