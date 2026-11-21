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
        assertEquals("https://epg.test/e.xml.gz,https://epg.test/other.xml", p.tvgUrl, "every guide the header names, in order")
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
              {"name":"蜘蛛直播","type":3,"api":"csp_Live","url":"yqk","ext":{"sp":"Huya"},"jar":"http://j.test/live.jar"},
              {"name":"没有蜘蛛","type":3,"url":"https://x.test/list"},
              {"name":"本机代理","type":0,"url":"http://127.0.0.1:9978/proxy?do=live&type=txt&ext=$hidden"},
              {"name":"蜘蛛代理","type":"0","url":"http://127.0.0.1:9978/proxy?do=live&url=https://x.test/huya.m3u"}
            ]""",
        )
        assertEquals(
            listOf("直播", "肥猫", "redirect", "蜘蛛直播", "没有蜘蛛", "本机代理", "蜘蛛代理"),
            specs.map { it.name },
            "channels written in the config come first",
        )
        assertEquals("测试台", specs[0].inline.single().channels.single().name)
        assertEquals("一号", specs[0].inline.single().channels.single().urls.single().label)
        assertEquals("okhttp/3.15", specs[1].headers["User-Agent"])
        assertEquals("http://h.test/live.txt", specs[2].url, "the playlist hidden in proxy://do=live")
        assertEquals(listOf("csp_Live", "yqk", """{"sp":"Huya"}""", "http://j.test/live.jar"), specs[3].let { listOf(it.api, it.url, it.ext, it.jar) })
        assertTrue(specs[3].supported, "a spider serves the list")
        assertTrue(specs[4].supported, "type 3 without a spider is a playlist, as in TVBox")
        assertEquals(listOf("https://x.test/list", ""), specs[4].let { listOf(it.url, it.api) })
        assertEquals("http://h.test/live.txt", specs[5].url, "TVBox's playlist proxy written as a url")
        assertEquals("http://127.0.0.1:9978/proxy?do=live&url=https://x.test/huya.m3u", specs[6].url, "a spider's proxy is asked as it is")
    }

    @Test
    fun `json playlists and m3u entries that name their user agent`() {
        val json = """[
          {"group":"央视","channels":[{"name":"CCTV1","logo":"https://l.test/1.png","urls":["http://a.test/1.m3u8${'$'}主线","http://b.test/1.m3u8"]}]},
          {"name":"卫视","channel":[{"name":"湖南卫视","url":"http://a.test/hn.m3u8#http://b.test/hn.m3u8"},{"name":"没地址"}]}
        ]"""
        assertTrue(LivePlaylistParser.looksLikePlaylist(json))
        val p = LivePlaylistParser.parse(json)
        assertEquals(listOf("央视", "卫视"), p.groups.map { it.name })
        assertEquals(listOf("主线", ""), p.groups[0].channels.single().urls.map { it.label })
        assertEquals("https://l.test/1.png", p.groups[0].channels.single().logo)
        assertEquals(2, p.groups[1].channels.single().urls.size)

        val m3u = "#EXTM3U\n#EXTINF:-1 http-user-agent=\"AptvPlayer-UA\" http-referrer=\"https://r.test/\" group-title=\"央视\",CCTV1\nhttp://a.test/1.m3u8"
        val url = LivePlaylistParser.parse(m3u).groups.single().channels.single().urls.single()
        assertEquals(mapOf("User-Agent" to "AptvPlayer-UA", "Referer" to "https://r.test/"), url.headers)
    }

    @Test
    fun `spider lives, the engine's own proxy, and the second guide when the first is empty`() = runBlocking {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/huya.m3u" -> MockResponse().setBody(
                    "#EXTM3U x-tvg-url=\"${server.url("/blocked.xml")},${server.url("/guide.xml")}\"\n" +
                        "#EXTINF:-1 group-title=\"一起看\",CCTV1\nhttp://127.0.0.1:9978/proxy?do=huya&id=1\n",
                )
                "/blocked.xml" -> MockResponse().setResponseCode(403)
                "/guide.xml" -> MockResponse().setBody(
                    """<tv><channel id="1"><display-name>CCTV1</display-name></channel>
                       <programme start="20261113080000 +0800" stop="20261113090000 +0800" channel="1"><title>朝闻天下</title></programme></tv>""",
                )
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
        try {
            // The engine listens on another port than TVBox's 9978; nothing answers on the proxy path here.
            val proxyBase = server.url("/proxy").toString() + "?"
            val asked = ArrayList<String>()
            val service = LiveService(SiteHttp(OkHttpClient()), proxyBase, spiderList = { spec ->
                asked += spec.api + " " + spec.url
                "一起看,#genre#\n房间一,http://s.test/1.flv"
            })
            service.onConfig(
                """[{"name":"蜘蛛","type":3,"api":"csp_Live","url":"yqk"},
                   {"name":"代理","type":0,"url":"http://127.0.0.1:9978/proxy?do=live&url=${server.url("/huya.m3u")}"}]""",
            )
            assertTrue(service.sources().all { it.supported })
            assertEquals("房间一", service.list(0).groups.single().channels.single().name)
            assertEquals(listOf("csp_Live yqk"), asked)

            val channel = service.list(1).groups.single().channels.single()
            assertEquals(proxyBase + "do=huya&id=1", channel.urls.single().url, "TVBox's proxy address means this engine's proxy")
            assertEquals(listOf("朝闻天下"), service.epg(1, "CCTV1", "2026-11-13").programs.map { it.title }, "the first guide is refused, the second answers")

            val without = LiveService(SiteHttp(OkHttpClient()), proxyBase)
            without.onConfig("""[{"name":"蜘蛛","type":3,"api":"csp_Live","url":"yqk"}]""")
            assertFalse(without.sources().single().supported, "no runtime to ask")
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `type 3 without an api is a playlist at its url, fetched with its user agent`() = runBlocking {
        val server = MockWebServer()
        val agents = ArrayList<String>()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/gather" -> {
                    agents += request.getHeader("User-Agent").orEmpty()
                    MockResponse().setBody("央视,#genre#\nCCTV1,http://a.test/1.m3u8\n代理台,proxy://do=live&id=7\n")
                }
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
        try {
            val proxyBase = "http://127.0.0.1:19978/proxy?"
            // No spider runtime at all: a list like this does not need one to load.
            val service = LiveService(SiteHttp(OkHttpClient()), proxyBase)
            service.onConfig("""[{"name":"Gather「果」","type":3,"url":"${server.url("/gather")}","ua":"okhttp/3.8.1","epg":"https://e.test/epg.xml.gz"}]""")
            val source = service.sources().single()
            assertTrue(source.supported, "TVBox reads it like type 0")
            assertEquals("", source.spider)
            assertTrue(source.hasEpg)
            val channels = service.list(0).groups.single().channels
            assertEquals(listOf("CCTV1", "代理台"), channels.map { it.name })
            assertEquals(proxyBase + "do=live&id=7", channels[1].urls.single().url, "proxy:// is this engine's proxy, where the config's jar answers")
            assertEquals(listOf("okhttp/3.8.1"), agents)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun `script lives are supported, Python ones not, and a spider's proxy addresses name the spider`() = runBlocking {
        val proxyBase = "http://127.0.0.1:19978/proxy?"
        val service = LiveService(SiteHttp(OkHttpClient()), proxyBase, spiderList = { spec ->
            if (spec.api.endsWith(".js")) {
                "组,#genre#\n甲,http://127.0.0.1:9978/proxy?do=js&ch=1\n乙,proxy://do=js&ch=2&siteKey=other\n丙,http://s.test/3.m3u8"
            } else {
                "组,#genre#\n丁,proxy://do=live&id=4"
            }
        })
        service.onConfig(
            """[{"name":"脚本 直播","type":3,"api":"http://j.test/live.js"},
               {"name":"jar","type":3,"api":"csp_Live"},
               {"name":"py","type":3,"api":"http://j.test/live.py"},
               {"name":"列表","type":0,"url":"http://l.test/tv.txt"}]""",
        )
        assertEquals(listOf("js", "jar", "py", ""), service.sources().map { it.spider })
        assertEquals(listOf(true, true, false, true), service.sources().map { it.supported }, "a script can be asked; Python has no runtime yet")
        assertEquals(
            listOf(
                // TVBox's proxy address means this engine's, and the request has to reach the spider that wrote it.
                proxyBase + "do=js&ch=1&siteKey=live_%E8%84%9A%E6%9C%AC+%E7%9B%B4%E6%92%AD",
                proxyBase + "do=js&ch=2&siteKey=other",
                "http://s.test/3.m3u8",
            ),
            service.list(0).groups.single().channels.map { it.urls.single().url },
        )
        assertEquals(proxyBase + "do=live&id=4&siteKey=live_jar", service.list(1).groups.single().channels.single().urls.single().url)
        val python = runCatching { service.list(2) }.exceptionOrNull()
        assertTrue(python is LiveException && python.code == "UNSUPPORTED", python.toString())
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
