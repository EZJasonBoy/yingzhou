package tvbox.engine.core.play

import com.google.gson.JsonParser
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.site.PlayerResult
import tvbox.engine.core.util.TextDecoding
import java.io.ByteArrayOutputStream
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.GZIPOutputStream

class SubtitlesTest {
    private fun parse(json: String) = Subtitles.parse(JsonParser.parseString(json).asJsonObject)

    @Test
    fun `subs is a list of name, lang, format and url, and the MIME type gives the format`() {
        val subs = parse(
            """{"subs":[
                {"name":"中文","lang":"zh","format":"application/x-subrip","url":"https://s.test/a"},
                {"name":"English","lang":"en","format":"text/x-ssa","url":"https://s.test/b?x=1"},
                {"name":"网页","format":"text/vtt","url":"https://s.test/c.vtt"}
            ]}""",
        )
        assertEquals(listOf("中文", "English", "网页"), subs.map { it.name })
        assertEquals(listOf("zh", "en", ""), subs.map { it.lang })
        assertEquals(listOf("srt", "ass", "vtt"), subs.map { it.format })
        assertEquals("https://s.test/b?x=1", subs[1].url)
    }

    @Test
    fun `subt is one address, and what follows # names the file`() {
        val subs = parse("""{"subt":"https://s.test/sub/123#%E5%8F%8C%E8%AF%AD.ass"}""")
        assertEquals(1, subs.size)
        assertEquals("双语", subs[0].name)
        assertEquals("ass", subs[0].format)
        assertEquals("https://s.test/sub/123", subs[0].url, "the fragment is not sent to the server")

        val plain = parse("""{"subt":"https://s.test/files/movie.chs.srt"}""").single()
        assertEquals("字幕", plain.name)
        assertEquals("srt", plain.format)
    }

    @Test
    fun `lyrics, duplicates and addresses that are not http are left out`() {
        val subs = parse(
            """{"subt":"https://s.test/a.srt","subs":[
                {"name":"歌词","format":"text/lrc","url":"https://s.test/song.lrc"},
                {"name":"lyric","url":"https://s.test/song2.lrc"},
                {"name":"同一个","url":"https://s.test/a.srt"},
                {"name":"本地","url":"file:///sdcard/a.srt"},
                {"name":"代理","url":"proxy://do=sub&id=1"}
            ]}""",
        )
        assertEquals(listOf("https://s.test/a.srt", "proxy://do=sub&id=1"), subs.map { it.url })
        assertEquals("字幕 1", subs[0].name, "unnamed ones are numbered when there are several")
    }

    @Test
    fun `subs written as JSON text or a single object are read too`() {
        assertEquals(1, parse("""{"subs":"[{\"name\":\"a\",\"url\":\"https://s.test/a.srt\"}]"}""").size)
        assertEquals(1, parse("""{"subs":{"name":"a","url":"https://s.test/a.srt"}}""").size)
        assertEquals(0, parse("""{"subs":null,"subt":""}""").size)
    }

    @Test
    fun `the play answer carries subtitles and danmaku along`() {
        val raw = PlayerResult.parse(
            """{"parse":0,"url":"https://v.test/1.mp4","header":{"Referer":"https://v.test/"},"subt":"https://s.test/1.srt","danmaku":"https://d.test/1.xml"}""",
            defaultUrl = "", flag = "f",
        )
        assertEquals(1, raw.subtitles.size)
        assertEquals("https://d.test/1.xml", raw.danmaku)
        val inline = PlayerResult.parse("""{"url":"https://v.test/1.mp4","danmaku":{"comments":[]}}""", defaultUrl = "", flag = "f")
        assertEquals("""{"comments":[]}""", inline.danmaku)
    }

    @Test
    fun `the player gets an engine address with the play headers and the format`() {
        val track = Subtitles.track(
            RawSubtitle("中文", "proxy://do=sub&id=1", "zh", "lrc"),
            base = "http://127.0.0.1:9978/subtitle?",
            headers = mapOf("Referer" to "https://v.test/"),
            proxyBase = "http://127.0.0.1:9978/proxy?",
        )
        assertTrue(track.url.startsWith("http://127.0.0.1:9978/subtitle?url=http%3A%2F%2F127.0.0.1%3A9978%2Fproxy%3Fdo%3Dsub%26id%3D1&h="), track.url)
        assertTrue(track.url.endsWith("&f=lrc"), track.url)
        assertEquals("srt", track.format, "lyrics are served as SRT")
        assertEquals("zh", track.lang)
    }

    // ---- encodings ----

    @Test
    fun `GBK, Big5, UTF-16 and UTF-8 with or without a byte order mark all come out right`() {
        val text = "第 1 句：这个画面里的人在说话，我们都听见了"
        assertEquals(text, TextDecoding.decode(text.toByteArray(charset("GBK"))))
        assertEquals(text, TextDecoding.decode(text.toByteArray(charset("GB18030"))))
        val traditional = "第 1 句：這個畫面裡的人在說話，我們都聽見了"
        assertEquals(traditional, TextDecoding.decode(traditional.toByteArray(charset("Big5"))))
        assertEquals(text, TextDecoding.decode(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + text.toByteArray()))
        assertEquals(text, TextDecoding.decode(text.toByteArray()))
        val ascii = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        assertEquals(ascii, TextDecoding.decode(ascii.toByteArray(Charsets.UTF_16LE)), "UTF-16 without a byte order mark")
        assertEquals(text, TextDecoding.decode(byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + text.toByteArray(Charsets.UTF_16LE)))
        // A server that says the wrong charset is not believed over what the bytes are.
        assertEquals(text, TextDecoding.decode(text.toByteArray(charset("GBK")), declared = "utf-8"))
        assertEquals(text, TextDecoding.decode(text.toByteArray(), declared = "gbk"))
    }

    @Test
    fun `gzip, zlib and raw deflate are unpacked and plain text is left alone`() {
        val text = "<i><d p=\"1.0,1,25,16777215\">你好</d></i>"
        fun deflate(nowrap: Boolean) = ByteArrayOutputStream().also { out ->
            DeflaterOutputStream(out, Deflater(Deflater.DEFAULT_COMPRESSION, nowrap)).use { it.write(text.toByteArray()) }
        }.toByteArray()
        val gzip = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(text.toByteArray()) } }.toByteArray()
        assertEquals(text, TextDecoding.text(deflate(nowrap = true)))
        assertEquals(text, TextDecoding.text(deflate(nowrap = false)))
        assertEquals(text, TextDecoding.text(gzip))
        assertEquals(text, TextDecoding.text(text.toByteArray()))
    }

    // ---- formats ----

    @Test
    fun `SRT, ASS and WebVTT pass through as UTF-8 and dots in SRT times become commas`() {
        val srt = SubtitleConverter.convert("1\r\n00:00:01.500 --> 00:00:02.000\r\n你好\r\n".toByteArray(charset("GBK")))
        assertEquals("srt", srt.format)
        assertEquals("1\n00:00:01,500 --> 00:00:02,000\n你好\n", srt.text)
        assertTrue(srt.contentType.startsWith("application/x-subrip"))

        val ass = "﻿[Script Info]\nScriptType: v4.00+\n\n[V4+ Styles]\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,你好\n"
        val a = SubtitleConverter.convert(ass.toByteArray())
        assertEquals("ass", a.format)
        assertEquals(ass.removePrefix("﻿"), a.text)

        val vtt = SubtitleConverter.convert("WEBVTT\n\n00:01.000 --> 00:02.000\nhi\n".toByteArray())
        assertEquals("vtt", vtt.format)
        assertEquals("ssa", SubtitleConverter.convert("[Script Info]\n[V4 Styles]\n".toByteArray()).format)
    }

    @Test
    fun `TTML, LRC and Bilibili JSON subtitles become SRT`() {
        val ttml = """<?xml version="1.0"?><tt xmlns="http://www.w3.org/ns/ttml"><body><div>
            <p begin="00:00:01.000" end="00:00:02.500">第一句<br/>换行</p>
            <p begin="3s" dur="1.5s">第二句 &amp; 符号</p>
            <p begin="40000000t" end="50000000t"><span>第三句</span></p>
        </div></body></tt>"""
        assertEquals(
            "1\n00:00:01,000 --> 00:00:02,500\n第一句\n换行\n\n2\n00:00:03,000 --> 00:00:04,500\n第二句 & 符号\n\n3\n00:00:04,000 --> 00:00:05,000\n第三句\n\n",
            SubtitleConverter.convert(ttml.toByteArray()).text,
        )

        val lrc = "[ti:歌]\n[00:01.00]第一句\n[00:03.50][00:10.00]重复的一句\n[00:05.00]\n"
        assertEquals(
            "1\n00:00:01,000 --> 00:00:03,500\n第一句\n\n2\n00:00:03,500 --> 00:00:05,000\n重复的一句\n\n3\n00:00:10,000 --> 00:00:15,000\n重复的一句\n\n",
            SubtitleConverter.convert(lrc.toByteArray(), hint = "lrc").text,
        )

        val bcc = """{"font_size":0.4,"body":[{"from":0.5,"to":1.25,"location":2,"content":"哔哩字幕"},{"from":2,"to":3,"content":""}]}"""
        val converted = SubtitleConverter.convert(bcc.toByteArray())
        assertEquals("srt", converted.format)
        assertEquals("1\n00:00:00,500 --> 00:00:01,250\n哔哩字幕\n\n", converted.text)
    }

    @Test
    fun `text that says nothing about its format is passed on for the player to probe`() {
        val micro = "{1}{25}Hello\n{26}{50}World\n"
        val converted = SubtitleConverter.convert(micro.toByteArray())
        assertEquals(micro, converted.text)
    }
}
