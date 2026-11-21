package tvbox.engine.core.vod

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.model.Episode
import tvbox.engine.core.site.PlayerResult

class VodParsingTest {

    @Test
    fun `episodes split on hash and first dollar`() {
        assertEquals(
            listOf(Episode("http://a/1.m3u8", "第1集"), Episode("http://a/2.m3u8?x=\$y", "第2集"), Episode("http://a/3.m3u8", "3")),
            TvboxResult.splitEpisodes("第1集\$http://a/1.m3u8#第2集\$http://a/2.m3u8?x=\$y##http://a/3.m3u8#"),
        )
    }

    @Test
    fun `blank lines are dropped`() {
        val lines = TvboxResult.splitLines("a$$$ $$\$c", "1\$u1$$\$x\$u2$$$")
        assertEquals(listOf("a"), lines.map { it.name })
    }

    @Test
    fun `json home accepts id and name aliases and object filters`() {
        val home = TvboxResult.parseHome(
            "s",
            """{"class":[{"id":1,"name":"电影"},{"type_id":"2"}],"filters":{"1":{"key":"area","name":"地区","value":[{"n":"全部","v":""}]}},"list":[{"vod_id":3,"vod_name":"x"},{"vod_name":"no id"}]}""",
        )
        assertEquals(listOf("1" to "电影"), home.classes.map { it.id to it.name })
        assertEquals("area", home.filters["1"]!!.single().key)
        // The card without an id is kept: it is opened by searching for its title.
        assertEquals(listOf("3" to "x", "" to "no id"), home.list.map { it.id to it.name })
    }

    @Test
    fun `cards without an id keep an empty one, cards without an id and a name are dropped`() {
        val page = TvboxResult.parseList(
            "s",
            """{"list":[{"vod_id":"msearch:片名","vod_name":"片名"},{"vod_id":"","vod_name":"空编号"},{"vod_id":null,"vod_name":"null 编号"},""" +
                """{"vod_pic":"http://p/1.png"},{"vod_id":" ","vod_name":""},{"vod_id":" 7 ","vod_name":"带空格"}]}""",
        )
        assertEquals(
            listOf("msearch:片名" to "片名", "" to "空编号", "" to "null 编号", " 7 " to "带空格"),
            page.list.map { it.id to it.name },
        )

        val xml = CmsXml.parseList("x", "<rss><list><video><name>无编号</name></video><video><pic>http://p/2.png</pic></video><video><id>9</id></video></list></rss>")
        assertEquals(listOf("" to "无编号", "9" to ""), xml.list.map { it.id to it.name })
    }

    @Test
    fun `xml site parses classes, paging and detail lines`() {
        val xml = """<?xml version="1.0" encoding="utf-8"?>
            <rss version="5.1">
              <list page="2" pagecount="9" pagesize="20" recordcount="170">
                <video><id>11</id><name><![CDATA[老爸当家]]></name><pic>http://p/11.jpg</pic><note><![CDATA[共40集]]></note>
                  <year>2020</year><des><![CDATA[简介]]></des>
                  <dl><dd flag="m3u8"><![CDATA[第1集${'$'}http://v/1.m3u8#第2集${'$'}http://v/2.m3u8]]></dd><dd flag="empty"></dd></dl>
                </video>
              </list>
              <class><ty id="1">电影</ty><ty id="2">剧集</ty></class>
            </rss>"""
        val home = CmsXml.parseHome("x", xml)
        assertEquals(listOf("电影", "剧集"), home.classes.map { it.name })

        val page = CmsXml.parseList("x", xml)
        assertEquals(2, page.page)
        assertEquals(9, page.pageCount)
        assertEquals(170, page.total)
        assertEquals("老爸当家", page.list.single().name)
        assertEquals("共40集", page.list.single().remarks)

        val detail = CmsXml.parseDetail("x", xml)
        assertEquals("简介", detail.content)
        assertEquals(listOf("m3u8"), detail.lines.map { it.name })
        assertEquals(2, detail.lines.single().episodes.size)
    }

    @Test
    fun `xml with a doctype is rejected`() {
        assertThrows(SiteResultException::class.java) {
            CmsXml.parseList("x", """<!DOCTYPE rss [<!ENTITY e SYSTEM "file:///etc/passwd">]><rss><list>&e;</list></rss>""")
        }
    }

    @Test
    fun `player result normalisation`() {
        val direct = PlayerResult.parse("""{"url":"https://cdn.test/a.m3u8","header":"{\"Referer\":\"r\"}"}""", "id", "f")
        assertEquals(0, direct.parse)
        assertEquals(mapOf("Referer" to "r"), direct.headers)

        val page = PlayerResult.parse("""{"url":"video://https://page.test/1"}""", "id", "f")
        assertEquals(1, page.parse)
        assertEquals("https://page.test/1", page.url)

        val quality = PlayerResult.parse("""{"url":"[\"标清\",\"https://a/1.m3u8\",\"高清\",\"https://a/2.m3u8\"]"}""", "id", "f")
        assertEquals("https://a/1.m3u8", quality.url)
        assertEquals(0, quality.parse)

        val explicit = PlayerResult.parse("""{"parse":1,"jx":"1","url":"https://page.test/2","playUrl":"json:http://jx/?url="}""", "id", "f")
        assertEquals(1, explicit.parse)
        assertEquals(1, explicit.jx)
        assertEquals("json:http://jx/?url=", explicit.playUrl)
    }

    @Test
    fun `video format heuristic`() {
        assertTrue(VideoFormat.isVideo("https://cdn.example.com/2024/a/index.m3u8"))
        assertTrue(VideoFormat.isVideo("https://cdn.example.com/video/movie.mp4?token=1"))
        assertFalse(VideoFormat.isVideo("https://www.example.com/play/123.html"))
        assertFalse(VideoFormat.isVideo("https://a.mp4"))
    }
}
