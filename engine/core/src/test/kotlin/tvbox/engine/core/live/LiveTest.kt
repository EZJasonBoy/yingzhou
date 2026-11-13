package tvbox.engine.core.live

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.util.Base64Compat
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream

class LiveTest {
    @Test
    fun `txt playlists have groups, several urls per channel and line labels`() {
        val text = """
            央视频道,#genre#
            CCTV-1 综合,http://a.test/1.m3u8#http://b.test/1.m3u8${'$'}备用线路
            CCTV-1 综合,http://c.test/1.m3u8
            CCTV-2,rtmp://r.test/2
            卫视频道,#genre#
            湖南卫视,http://a.test/hn.m3u8
            坏行没有地址
            空地址,ftp://x
        """.trimIndent()
        val p = LivePlaylistParser.parse(text, mapOf("User-Agent" to "ua"))
        assertEquals(listOf("央视频道", "卫视频道"), p.groups.map { it.name })
        val cctv1 = p.groups[0].channels[0]
        assertEquals("CCTV-1 综合", cctv1.name)
        assertEquals(listOf("http://a.test/1.m3u8", "http://b.test/1.m3u8", "http://c.test/1.m3u8"), cctv1.urls.map { it.url })
        assertEquals("备用线路", cctv1.urls[1].label)
        assertEquals("ua", cctv1.urls[0].headers["User-Agent"])
        assertEquals(listOf("湖南卫视"), p.groups[1].channels.map { it.name }, "lines without a playable url are skipped")
    }

    @Test
    fun `m3u playlists read group, logo, vlc options and the guide url`() {
        val text = """
            #EXTM3U x-tvg-url="https://epg.test/e.xml.gz,https://epg.test/other.xml"
            #EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV1" tvg-logo="https://logo.test/cctv1.png" group-title="央视",CCTV-1 综合
            #EXTVLCOPT:http-user-agent=Mozilla/5.0
            #EXTVLCOPT:http-referrer=https://ref.test/
            http://a.test/cctv1.m3u8
            #EXTINF:-1 group-title="央视",CCTV-1 综合
            http://b.test/cctv1.m3u8
            #EXTINF:-1,无分组频道
            http://a.test/x.m3u8
        """.trimIndent()
        val p = LivePlaylistParser.parse(text)
        assertEquals("https://epg.test/e.xml.gz", p.tvgUrl)
        assertEquals(listOf("央视", "未分组"), p.groups.map { it.name })
        val c = p.groups[0].channels.single()
        assertEquals("https://logo.test/cctv1.png", c.logo)
        assertEquals(2, c.urls.size)
        assertEquals("Mozilla/5.0", c.urls[0].headers["User-Agent"])
        assertEquals("https://ref.test/", c.urls[0].headers["Referer"])
        assertTrue(c.urls[1].headers.isEmpty(), "options belong to the entry they follow")
    }

    @Test
    fun `lives config entries in their different shapes`() {
        val hidden = Base64Compat.encode("http://h.test/live.txt".toByteArray(), urlSafe = true)
        val specs = LiveSourceSpec.parseAll(
            """[
              {"name":"肥猫","type":0,"url":"http://f.test/tv.txt","epg":"https://epg.test/?ch={name}&date={date}","logo":"https://epg.test/logo/{name}.png","ua":"okhttp/3.15"},
              {"group":"redirect","channels":[{"name":"live","urls":["proxy://do=live&type=txt&ext=$hidden"]}]},
              {"group":"内置","channels":[{"name":"测试台","urls":["http://i.test/1.m3u8${'$'}一号"]}]},
              {"name":"蜘蛛直播","type":3,"api":"csp_Live","ext":""}
            ]""",
        )
        assertEquals(listOf("直播", "肥猫", "redirect", "蜘蛛直播"), specs.map { it.name }, "channels written in the config come first")
        assertEquals("测试台", specs[0].inline.single().channels.single().name)
        assertEquals("一号", specs[0].inline.single().channels.single().urls.single().label)
        assertEquals("okhttp/3.15", specs[1].headers["User-Agent"])
        assertEquals("http://h.test/live.txt", specs[2].url, "the playlist hidden in proxy://do=live")
        assertFalse(specs[3].supported)
    }

    @Test
    fun `epg names, json days crossing midnight and xmltv`() {
        assertEquals("CCTV1", Epg.normalize("CCTV-1 综合"))
        assertEquals("CCTV5+", Epg.normalize("CCTV-5+ 体育赛事"))
        assertEquals("CCTV13", Epg.normalize("CCTV13新闻 HD"))
        assertEquals("湖南卫视", Epg.normalize("湖南卫视 高清"))
        assertEquals("https://e.test/?ch=CCTV1&date=2026-11-13", Epg.requestUrl("https://e.test/?ch={name}&date={date}", "CCTV1", "2026-11-13"))
        assertEquals("https://e.test/api?ch=%E6%B9%96%E5%8D%97%E5%8D%AB%E8%A7%86&date=2026-11-13", Epg.requestUrl("https://e.test/api", "湖南卫视", "2026-11-13"))

        val day = Epg.parseJson("""{"epg_data":[{"start":"00:00","end":"06:30","title":"夜间节目"},{"start":"23:30","end":"00:30","title":"跨夜"}]}""", "2026-11-13")
        val midnight = Epg.dayFormat().parse("2026-11-13")!!.time
        assertEquals(midnight, day[0].start)
        assertEquals(midnight + 24 * 3600_000L + 30 * 60_000L, day[1].end, "an end before the start is the next day")

        val xml = """<?xml version="1.0" encoding="UTF-8"?><tv>
            <channel id="cctv1"><display-name lang="zh">CCTV-1 综合</display-name><display-name>CCTV1</display-name></channel>
            <programme start="20261113080000 +0800" stop="20261113090000 +0800" channel="cctv1"><title lang="zh">朝闻天下 &amp; 早间</title></programme>
            <programme start="20261114080000 +0800" stop="20261114090000 +0800" channel="cctv1"><title>明天的节目</title></programme>
            </tv>"""
        val gz = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(xml.toByteArray()) } }.toByteArray()
        val guide = Epg.parseXmltv(gz)
        val today = Epg.forDay(guide["CCTV1"]!!, "2026-11-13")
        assertEquals(listOf("朝闻天下 & 早间"), today.map { it.title })
        assertEquals(midnight + 8 * 3600_000L, today[0].start)
    }

    @Test
    fun `the service loads playlists and guides through http`() = runBlocking {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.requestUrl!!
                return when (url.encodedPath) {
                    "/tv.txt" -> MockResponse().setBody("央视,#genre#\nCCTV-1 综合,proxy://do=live&id=1\n")
                    "/epg" -> if (url.queryParameter("ch") == "CCTV1") {
                        MockResponse().setBody("""{"epg_data":[{"start":"08:00","end":"09:00","title":"朝闻天下"}]}""")
                    } else {
                        MockResponse().setBody("""{"epg_data":[]}""")
                    }
                    "/wrapped.txt" -> MockResponse().setBody(Buffer().writeUtf8("abcdEFGH**" + Base64Compat.encode("组,#genre#\n台,http://w.test/1.m3u8".toByteArray())))
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        try {
            val service = LiveService(SiteHttp(OkHttpClient()), "http://127.0.0.1:9978/proxy?")
            service.onConfig(
                """[{"name":"A","type":0,"url":"${server.url("/tv.txt")}","epg":"${server.url("/epg")}?ch={name}&date={date}","logo":"https://l.test/{name}.png"},
                   {"name":"B","type":0,"url":"${server.url("/wrapped.txt")}"}]""",
            )
            assertEquals(listOf("A", "B"), service.sources().map { it.name })
            val list = service.list(0)
            val channel = list.groups.single().channels.single()
            assertEquals("http://127.0.0.1:9978/proxy?do=live&id=1", channel.urls.single().url, "proxy:// points at the engine")
            assertEquals("https://l.test/CCTV1.png", channel.logo)
            assertEquals(listOf("朝闻天下"), service.epg(0, "CCTV-1 综合", "2026-11-13").programs.map { it.title })
            assertEquals("台", service.list(1).groups.single().channels.single().name, "a playlist wrapped like a config")
        } finally {
            server.shutdown()
        }
    }
}
