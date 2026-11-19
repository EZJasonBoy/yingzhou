package tvbox.engine.core.live

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.model.CatchupTemplate
import tvbox.engine.core.net.SiteHttp
import java.text.SimpleDateFormat
import java.util.Locale

class CatchupTest {
    private fun china(t: String) = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).apply { timeZone = Epg.ZONE }.parse(t)!!.time

    // 08:00–09:00 China time, asked for at noon.
    private val start = china("2026-11-13 08:00")
    private val end = china("2026-11-13 09:00")
    private val now = china("2026-11-13 12:00")
    private val s = start / 1000
    private val e = end / 1000
    private val n = now / 1000

    private fun one(rule: CatchupTemplate?, url: String) = Catchup.build(rule, url, start, end, now).single()

    @Test
    fun `placeholders of TVBox and of M3U playlists`() {
        val source = "http://a.test/p?" +
            "a={utc}&b={utcend}&c=\${start}&d=\${end}&e={lutc}&f=\${now}&g=\${timestamp}&h=\${duration}&i={duration}&j={duration:60}" +
            "&k={offset:60}&l={Y}{m}{d}{H}{M}{S}&m={utc:YmdHMS}&o=\${end:Ymd-H-M}&p=\${(b)yyyyMMddHHmmss}&q=\${(e)timestamp}" +
            "&r={utc:yyyy-MM-dd'T'HH:mm}&s={utc:}&t={nonsense}"
        assertEquals(
            "http://a.test/p?a=$s&b=$e&c=$s&d=$e&e=$n&f=$n&g=$n&h=3600&i=3600&j=60&k=240&l=20261113080000&m=20261113080000" +
                "&o=20261113-09-00&p=20261113080000&q=$e&r=2026-11-13T08:00&s=$s&t={nonsense}",
            one(CatchupTemplate(type = "default", source = source), "http://live.test/1.m3u8"),
        )
    }

    @Test
    fun `default, append and TVBox's replace`() {
        val playseek = "?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}"
        assertEquals("http://h.test/1.m3u8?playseek=20261113080000-20261113090000", one(CatchupTemplate(type = "append", source = playseek), "http://h.test/1.m3u8"))
        assertEquals(
            "http://h.test/1.m3u8?token=x&playseek=20261113080000-20261113090000",
            one(CatchupTemplate(type = "append", source = playseek), "http://h.test/1.m3u8?token=x"),
            "a source starting a query continues the address's own",
        )
        assertEquals(
            "http://h.test/TVOD/88888888/1/index.m3u8?playseek=20261113080000-20261113090000",
            one(CatchupTemplate(source = playseek, replace = "/PLTV/,/TVOD/"), "http://h.test/PLTV/88888888/1/index.m3u8"),
            "TVBox writes no type for append",
        )
        assertEquals("http://other.test/$s.m3u8", one(CatchupTemplate(type = "default", source = "http://other.test/{utc}.m3u8"), "http://h.test/1.m3u8"))
        assertEquals("http://other.test/$s.m3u8", one(CatchupTemplate(type = "vod", source = "http://other.test/{utc}.m3u8"), "http://h.test/1.m3u8"))
    }

    @Test
    fun `shift, flussonic and xtream codes build the address from the live one`() {
        assertEquals("http://h.test/1.m3u8?utc=$s&lutc=$n", one(CatchupTemplate(type = "shift"), "http://h.test/1.m3u8"))
        assertEquals("http://h.test/1.m3u8?k=v&utc=$s&lutc=$n", one(CatchupTemplate(type = "shift"), "http://h.test/1.m3u8?k=v"))

        val fs = CatchupTemplate(type = "flussonic")
        assertEquals(
            listOf("http://list.tv:8888/325/index-$s-3600.m3u8?token=secret", "http://list.tv:8888/325/timeshift_rel-14400.m3u8?token=secret"),
            Catchup.build(fs, "http://list.tv:8888/325/index.m3u8?token=secret", start, end, now),
        )
        assertEquals(
            listOf("http://list.tv:8888/325/mono-$s-3600.m3u8?token=secret", "http://list.tv:8888/325/mono-timeshift_rel-14400.m3u8?token=secret"),
            Catchup.build(CatchupTemplate(type = "fs"), "http://list.tv:8888/325/mono.m3u8?token=secret", start, end, now),
        )
        assertEquals(
            listOf("http://ch01.spr24.net/151/archive-$s-3600.ts?token=my_token", "http://ch01.spr24.net/151/timeshift_abs-$s.ts?token=my_token"),
            Catchup.build(fs, "http://ch01.spr24.net/151/mpegts?token=my_token", start, end, now),
        )
        assertEquals(
            listOf("http://list.tv:8888/325/index-$s-3600.m3u8?token=my_token", "http://list.tv:8888/325/timeshift_rel-14400.m3u8?token=my_token"),
            Catchup.build(fs, "http://list.tv:8888/325/live?token=my_token", start, end, now),
        )

        val xc = CatchupTemplate(type = "xc")
        assertEquals("http://list.tv:8080/timeshift/my@account.xc/my_password/60/2026-11-13:08-00/1477.ts", one(xc, "http://list.tv:8080/my@account.xc/my_password/1477"))
        assertEquals(
            "http://list.tv:8080/timeshift/my@account.xc/my_password/60/2026-11-13:08-00/1477.m3u8",
            one(xc, "http://list.tv:8080/live/my@account.xc/my_password/1477.m3u8"),
        )
        assertEquals(0, Catchup.days(xc, "http://list.tv/not/an/xtream/address/at/all"), "an address the mode cannot read has no catch-up")
    }

    @Test
    fun `channels without a rule, regex, a programme still on air, and the correction`() {
        assertEquals("http://h.test/TVOD/8888/1/index.m3u8?playseek=20261113080000-20261113090000", one(null, "http://h.test/PLTV/8888/1/index.m3u8"))
        assertEquals(Catchup.DEFAULT_DAYS, Catchup.days(null, "http://h.test/PLTV/8888/1/index.m3u8"))
        assertEquals(0, Catchup.days(null, "http://h.test/live/1.m3u8"), "nothing says this channel has catch-up")
        assertEquals(0, Catchup.days(CatchupTemplate(type = "append", source = "?a={utc}", regex = "/PLTV/"), "http://h.test/live/1.m3u8"))
        assertEquals(3, Catchup.days(CatchupTemplate(type = "append", source = "?a={utc}", regex = "/live/", days = 3), "http://h.test/live/1.m3u8"))

        val onAir = Catchup.build(CatchupTemplate(type = "default", source = "http://a.test/{utc}/{duration}"), "x", start, now + 3_600_000, now).single()
        assertEquals("http://a.test/$s/14400", onAir, "played up to now")

        val corrected = Catchup.build(CatchupTemplate(type = "default", source = "http://a.test/{utc}", correctionSeconds = -3600), "x", start, end, now).single()
        assertEquals("http://a.test/${s - 3600}", corrected)
    }

    @Test
    fun `m3u attributes, header defaults, json lists and the lives entry's catchup`() = runBlocking {
        val m3u = """
            #EXTM3U x-tvg-url="http://e.test/e.xml" catchup="append" catchup-source="?playseek=${'$'}{(b)yyyyMMddHHmmss}-${'$'}{(e)yyyyMMddHHmmss}" catchup-days="5"
            #EXTINF:-1 group-title="央视",CCTV1
            http://a.test/cctv1.m3u8
            #EXTINF:-1 group-title="央视" catchup="default" catchup-source="http://b.test/{utc}.m3u8" catchup-days="2" catchup-correction="1",CCTV2
            http://a.test/cctv2.m3u8
            #EXTINF:-1 group-title="央视" timeshift="4",CCTV3
            http://a.test/cctv3.m3u8
        """.trimIndent()
        val channels = LivePlaylistParser.parse(m3u).groups.single().channels
        assertEquals(CatchupTemplate(type = "append", source = "?playseek=\${(b)yyyyMMddHHmmss}-\${(e)yyyyMMddHHmmss}", days = 5), channels[0].urls.single().catchup)
        assertEquals(CatchupTemplate(type = "default", source = "http://b.test/{utc}.m3u8", days = 2, correctionSeconds = 3600), channels[1].urls.single().catchup)
        assertEquals("shift", channels[2].urls.single().catchup!!.type, "SIPTV's timeshift is shift mode")

        val json = """[{"group":"组","channels":[{"name":"台","urls":["http://a.test/1.m3u8"],"catchup":{"type":"append","source":"?s={utc}","days":"2"}}]}]"""
        assertEquals(CatchupTemplate(type = "append", source = "?s={utc}", days = 2), LivePlaylistParser.parse(json).groups.single().channels.single().urls.single().catchup)

        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/tv.m3u" -> MockResponse().setBody(m3u)
                "/tv.txt" -> MockResponse().setBody("组,#genre#\n甲,http://a.test/1.m3u8#http://b.test/1.m3u8\n乙,http://a.test/2.m3u8\n")
                "/epg" -> MockResponse().setBody("""{"epg_data":[{"start":"08:00","end":"09:00","title":"${request.requestUrl!!.queryParameter("date")}"}]}""")
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
        try {
            val service = LiveService(SiteHttp(OkHttpClient()), "http://127.0.0.1:19982/proxy?")
            service.onConfig(
                """[{"name":"m3u","type":0,"url":"${server.url("/tv.m3u")}"},
                   {"name":"txt","type":0,"url":"${server.url("/tv.txt")}","epg":"${server.url("/epg")}?ch={name}&date={date}",
                    "catchup":{"type":"append","source":"?b={utc}&e={utcend}","regex":"a.test"}}]""",
            )
            assertEquals(listOf(5, 2, 4), service.list(0).groups.single().channels.map { it.catchupDays }, "header days, own days, SIPTV timeshift days")
            val txt = service.list(1).groups.single().channels
            assertEquals(listOf(7, 7), txt.map { it.catchupDays }, "the entry's rule, for the lines its regex lets through")

            val now = System.currentTimeMillis()
            val from = now - 3 * 3_600_000L
            val to = now - 2 * 3_600_000L
            val picked = service.catchup(1, "组", "甲", 1, from, to)
            assertEquals(0, picked.line, "the second line's address does not match the regex: the first is the one with catch-up")
            assertEquals("http://a.test/1.m3u8?b=${from / 1000}&e=${to / 1000}", picked.url)
            assertTrue(picked.alternates.isEmpty())

            val fail = runCatching { service.catchup(1, null, "甲", 0, now + 60_000, now + 120_000) }.exceptionOrNull()
            assertTrue(fail is LiveException && fail.code == "BAD_REQUEST", "a programme that has not started")

            // The guide of an earlier day is asked for with that day.
            assertEquals(listOf("2026-11-10"), service.epg(1, "甲", "2026-11-10").programs.map { it.title })
        } finally {
            server.shutdown()
        }
    }
}
