package tvbox.engine.core.danmaku

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import tvbox.engine.core.net.SiteHttp
import java.io.ByteArrayOutputStream
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream

class DanmakuTest {
    private fun c(time: Long, mode: String, color: Int, size: Int, text: String) = DanmakuComment(time, mode, color, size, text)

    // ---- formats ----

    @Test
    fun `Bilibili XML, with entities, CDATA, odd attribute order and modes that cannot be shown`() {
        val xml = """<?xml version="1.0" encoding="UTF-8"?><i><chatid>1</chatid>
            <d p="12.5,1,25,16777215,1700000000,0,abc,1">普通 &amp; 滚动</d>
            <d p="3.0,5,36,16711680,1,0,x,2">顶部</d>
            <d id="3" p='1.25,4,18,65280,1,0,x,3'><![CDATA[底部 <b>]]></d>
            <d p="4,6,25,255">逆向</d>
            <d p="5,7,25,255">[0,0,"1-1",4.5,"高级"]</d>
            <d p="6,8,25,255">代码</d>
            <d p="7,1,25,255">   </d>
            <d p="x,1,25,255">坏的</d>
            <d p="8,1,25,255">&#x1F600;&#26159;</d>
        </i>"""
        assertEquals(
            listOf(
                c(1250, "bottom", 0x00FF00, 18, "底部 <b>"),
                c(3000, "top", 0xFF0000, 36, "顶部"),
                c(4000, "scroll", 0x0000FF, 25, "逆向"),
                c(8000, "scroll", 0x0000FF, 25, "😀是"),
                c(12500, "scroll", 0xFFFFFF, 25, "普通 & 滚动"),
            ),
            DanmakuParser.parse(xml),
        )
    }

    @Test
    fun `JSON from dandanplay services, Bilibili layouts in JSON, DPlayer arrays and plain objects`() {
        val dandan = """{"count":3,"comments":[{"cid":1,"p":"2.50,1,16777215,[x]u1","m":"弹幕一"},{"cid":2,"p":"1.00,5,255,u2","m":"顶"},{"p":"3,4,#00ff00,u3","m":"底"}]}"""
        assertEquals(
            listOf(c(1000, "top", 255, 25, "顶"), c(2500, "scroll", 0xFFFFFF, 25, "弹幕一"), c(3000, "bottom", 0x00FF00, 25, "底")),
            DanmakuParser.parse(dandan),
        )
        // Five fields or more: Bilibili's order (size before colour).
        assertEquals(listOf(c(1500, "top", 0xFF0000, 18, "x")), DanmakuParser.parse("""[{"p":"1.5,5,18,16711680,1700000000,0,u,1","m":"x"}]"""))
        // DPlayer: {code, data: [[time, type, color, author, text]]}
        assertEquals(
            listOf(c(500, "top", 0xFFFFFF, 25, "上"), c(2000, "scroll", 0xFF0000, 25, "飘")),
            DanmakuParser.parse("""{"code":0,"data":[[2.0,0,16711680,"a","飘"],[0.5,1,16777215,"b","上"]]}"""),
        )
        // ArtPlayer-like objects; Bilibili's own JSON gives milliseconds as "progress".
        assertEquals(
            listOf(c(1000, "bottom", 0x123456, 25, "对象"), c(4200, "top", 0xFFFFFF, 30, "毫秒")),
            DanmakuParser.parse("""[{"text":"对象","time":1,"color":"#123456","type":"bottom"},{"content":"毫秒","progress":4200,"mode":5,"fontsize":30}]"""),
        )
        assertEquals(emptyList<DanmakuComment>(), DanmakuParser.parse("""{"url":"https://x.test/1.xml"}"""))
        assertEquals(emptyList<DanmakuComment>(), DanmakuParser.parse("not danmaku"))
    }

    @Test
    fun `ASS made by danmaku converters`() {
        val ass = """[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Danmaku,Microsoft YaHei,50,&H33FFFFFF,&H33FFFFFF,&H33000000,&H33000000,0,0,0,0,100,100,0.00,0.00,1,2,0,7,0,0,0,0

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 2,0:00:01.50,0:00:09.50,Danmaku,,0000,0000,0000,,{\move(1920,50,-200,50)}滚动的, 有逗号
Dialogue: 2,0:00:02.00,0:00:06.00,Danmaku,,0000,0000,0000,,{\an8\pos(960,50)\c&H0000FF&}顶部红色
Dialogue: 2,0:00:03.00,0:00:07.00,Danmaku,,0000,0000,0000,,{\an2\pos(960,1050)\fs75}底部大字
"""
        assertEquals(
            listOf(c(1500, "scroll", 0xFFFFFF, 25, "滚动的, 有逗号"), c(2000, "top", 0xFF0000, 25, "顶部红色"), c(3000, "bottom", 0xFFFFFF, 37, "底部大字")),
            DanmakuParser.parse(ass),
        )
    }

    @Test
    fun `episode numbers from the names sites give`() {
        assertEquals(12, DanmakuService.episodeNumber("第12集"))
        assertEquals(3, DanmakuService.episodeNumber("第 3 话"))
        assertEquals(5, DanmakuService.episodeNumber("S01E05"))
        assertEquals(7, DanmakuService.episodeNumber("EP07"))
        assertEquals(8, DanmakuService.episodeNumber("08"))
        assertEquals(null, DanmakuService.episodeNumber("正片"))
    }

    // ---- sources ----

    private fun deflated(text: String) = ByteArrayOutputStream().also { out ->
        DeflaterOutputStream(out, Deflater(Deflater.DEFAULT_COMPRESSION, true)).use { it.write(text.toByteArray()) }
    }.toByteArray()

    private val xml = """<i><d p="1,1,25,16777215">站点弹幕</d><d p="2,1,25,16777215">第二条</d></i>"""

    private fun <T> withServer(respond: (RecordedRequest) -> MockResponse, block: suspend (MockWebServer, DanmakuService) -> T): T {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = respond(request)
        }
        server.start()
        try {
            return runBlocking { block(server, DanmakuService(SiteHttp(OkHttpClient()), "http://127.0.0.1:9978/proxy?")) }
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `the site's address comes first, Bilibili's raw deflate is undone, and the answer is kept`() {
        var fetched = 0
        withServer({ r ->
            when (r.requestUrl!!.encodedPath) {
                "/comment.xml" -> {
                    fetched++
                    MockResponse().setHeader("Content-Encoding", "deflate").setBody(Buffer().write(deflated(xml)))
                }
                else -> MockResponse().setResponseCode(404)
            }
        }) { server, service ->
            service.remember("s", "l", "e1", server.url("/comment.xml").toString())
            val list = service.episode("s", "l", "e1", "片", "第1集", configApi = null, customApi = null)
            assertEquals("site", list.source)
            assertEquals(listOf("站点弹幕", "第二条"), list.items.map { it.text })
            assertEquals(2, list.count)
            service.episode("s", "l", "e1", "片", "第1集", configApi = null, customApi = null)
            assertEquals(1, fetched, "kept per episode")
            service.episode("s", "l", "e1", "片", "第1集", configApi = null, customApi = null, refresh = true)
            assertEquals(2, fetched)

            // Inline danmaku from a spider.
            service.remember("s", "l", "e2", xml)
            assertEquals("inline", service.describe(xml))
            assertEquals(2, service.episode("s", "l", "e2", "片", "第2集", null, null).count)
            // Another episode with nothing anywhere: no source, nothing asked.
            assertEquals(DanmakuList(), service.episode("s", "l", "e3", "片", "第3集", null, null))
        }
    }

    @Test
    fun `an API with placeholders answers an address, or the danmaku themselves`() {
        val asked = ArrayList<String>()
        withServer({ r ->
            asked += r.requestUrl.toString()
            when (java.net.URLDecoder.decode(r.requestUrl!!.encodedPath, "UTF-8")) {
                "/api" -> MockResponse().setBody("""{"code":0,"url":"${r.requestUrl!!.newBuilder("/files/${r.requestUrl!!.queryParameter("ep")}.xml")}"}""")
                "/inline" -> MockResponse().setBody("""{"comments":[{"p":"1,1,16777215,u","m":"直接给的"}]}""")
                "/files/第2集.xml" -> MockResponse().setBody(xml)
                else -> MockResponse().setResponseCode(404)
            }
        }) { server, service ->
            val api = server.url("/api").toString() + "?name={name}&ep={episode}"
            val list = service.episode("s", "l", "e", "星河 & 往事", "第2集", configApi = api, customApi = null)
            assertEquals("config", list.source)
            assertEquals(2, list.count)
            assertEquals("星河 & 往事", okhttp3.HttpUrl.Companion.run { asked.first().toHttpUrl() }.queryParameter("name"), "the title is encoded")
            val direct = service.episode("s", "l", "e", "片", "第1集", configApi = null, customApi = server.url("/inline").toString() + "?n={name}")
            assertEquals("custom", direct.source)
            assertEquals("直接给的", direct.items.single().text)
        }
    }

    @Test
    fun `an API ending in danmaku gets a form, and a failing site falls back to the APIs`() {
        withServer({ r ->
            when (r.requestUrl!!.encodedPath) {
                "/x/danmaku" -> {
                    val form = r.body.readUtf8()
                    assertTrue(form.contains("name=%E7%89%87") && form.contains("episode="), form)
                    MockResponse().setBody("""[{"url":"${r.requestUrl!!.newBuilder("/d.xml")}"}]""")
                }
                "/d.xml" -> MockResponse().setBody(xml)
                else -> MockResponse().setResponseCode(500)
            }
        }) { server, service ->
            service.remember("s", "l", "e", server.url("/broken.xml").toString())
            val list = service.episode("s", "l", "e", "片", "第1集", configApi = server.url("/x/danmaku").toString(), customApi = null)
            assertEquals("config", list.source)
            assertEquals(2, list.count)
        }
    }

    @Test
    fun `a dandanplay-compatible base searches episodes by title and number and fetches comments by id`() {
        val asked = ArrayList<String>()
        withServer({ r ->
            asked += r.requestUrl!!.encodedPath + "?" + (r.requestUrl!!.encodedQuery ?: "")
            when (r.requestUrl!!.encodedPath) {
                "/token/api/v2/search/episodes" -> MockResponse().setBody(
                    """{"success":true,"animes":[
                        {"animeId":1,"animeTitle":"星河往事 第二季","type":"tvseries","episodes":[{"episodeId":101,"episodeTitle":"第1话"}]},
                        {"animeId":2,"animeTitle":"星河往事","type":"tvseries","episodes":[{"episodeId":201,"episodeTitle":"第1话 开始"},{"episodeId":203,"episodeTitle":"第3话 归来","episodeNumber":"3"}]}
                    ]}""",
                )
                "/token/api/v2/comment/203" -> MockResponse().setBody("""{"count":1,"comments":[{"cid":9,"p":"10.00,1,16777215,[d]1","m":"第三集的弹幕"}]}""")
                else -> MockResponse().setResponseCode(404)
            }
        }) { server, service ->
            val list = service.episode("s", "l", "e", "星河往事", "第3集", configApi = null, customApi = server.url("/token/").toString())
            assertEquals("custom", list.source)
            assertEquals("第三集的弹幕", list.items.single().text)
            assertTrue(list.from.endsWith("/token/api/v2/comment/203?format=json"), list.from)
            assertTrue(asked.first().contains("anime=%E6%98%9F%E6%B2%B3%E5%BE%80%E4%BA%8B&episode=3"), asked.toString())
        }
    }

    @Test
    fun `when every source fails the reasons are given, and an answer without danmaku is no error`() {
        withServer({ r ->
            when (r.requestUrl!!.encodedPath) {
                "/empty" -> MockResponse().setBody("""{"comments":[]}""")
                else -> MockResponse().setResponseCode(503)
            }
        }) { server, service ->
            val e = assertThrows<DanmakuException> {
                runBlocking { service.episode("s", "l", "e", "片", "第1集", configApi = server.url("/down").toString() + "?n={name}", customApi = null) }
            }
            assertTrue(e.message!!.contains("订阅的弹幕接口"), e.message)
            val none = service.episode("s", "l", "e", "片", "第1集", configApi = server.url("/empty").toString() + "?n={name}", customApi = null)
            assertEquals(0, none.count)
            assertEquals("config", none.source)
        }
    }
}
