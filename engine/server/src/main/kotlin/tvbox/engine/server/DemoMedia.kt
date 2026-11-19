package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.response.header
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.ByteArrayOutputStream
import java.net.URLEncoder
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream

/**
 * Demo titles for subtitles, audio tracks and danmaku (`--demo`), all made up here, nothing fetched from elsewhere:
 *
 * - 《字幕演示》: three minutes of the made-up video ([DemoVideo]) with two audio renditions (`#EXT-X-MEDIA`, MPEG-1
 *   Layer II: 国语 mono, English stereo; both silent, since there is no encoder here), and three external subtitles
 *   from the spider: an SRT in GBK, a styled ASS, and an SRT the server only gives with the right `Referer`.
 * - 《弹幕演示》: the same video, and a `danmaku` address from the spider: 3000 comments in three minutes, Bilibili
 *   XML, raw deflate like Bilibili serves it.
 * - The config's `danmaku` API (`/demo/danmaku/api?name={name}&episode={episode}`) answers for every title with a
 *   few comments in the JSON form danmaku services use; the engine asks it only when the user switched that on.
 *
 * The CMS site lists the two titles too, but only the JS spider ([DemoSite.spiderJs]) adds subtitles and danmaku to
 * the play answer, through `/demo/extras`.
 */
object DemoMedia {
    const val SUBS_ITEM = 98
    const val DANMAKU_ITEM = 99

    /** id → (name, play url path, description). */
    val ITEMS: Map<Int, Triple<String, String, String>> = linkedMapOf(
        SUBS_ITEM to Triple(
            "字幕演示",
            "/demo/av/master.m3u8",
            "开发用：在「演示JS站」里打开，播放时带三条外挂字幕（GBK 编码的 SRT、带样式的 ASS、要请求头才给的 SRT）和两条音轨（国语、English，都是静音）。画面上是分片序号和时间。",
        ),
        DANMAKU_ITEM to Triple(
            "弹幕演示",
            "/demo/av/video.m3u8",
            "开发用：在「演示JS站」里打开，蜘蛛给出弹幕地址：三分钟 3000 条（B 站 XML，deflate 压缩）。",
        ),
    )

    const val SEGMENTS = 30
    private val video = DemoVideo()
    private val recent = object : LinkedHashMap<Int, ByteArray>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, ByteArray>?) = size > 6
    }

    /** Video segment [i]: the slow source's picture, made once for the last few asked for. */
    fun videoSegment(i: Int): ByteArray = synchronized(recent) { recent.getOrPut(i) { video.segment(i) } }

    /** The play answer the JS spider hands on for one of [ITEMS]' addresses (`/demo/extras?url=`). */
    fun extras(url: String, base: String): String = buildJsonObject {
        put("parse", 0)
        put("url", url)
        if (url.endsWith("/demo/av/master.m3u8")) {
            // The private subtitle wants this; the player is told to send it too.
            put("header", buildJsonObject { put("Referer", "$base/demo/") })
            put("subs", buildJsonArray {
                add(buildJsonObject {
                    put("name", "简体中文（GBK）")
                    put("lang", "zh")
                    put("format", "application/x-subrip")
                    put("url", "$base/demo/subs/gbk.srt")
                })
                add(buildJsonObject {
                    put("name", "双语特效（ASS）")
                    put("lang", "zh-en")
                    put("format", "text/x-ssa")
                    put("url", "$base/demo/subs/styled.ass")
                })
                add(buildJsonObject {
                    put("name", "English (needs Referer)")
                    put("lang", "en")
                    put("format", "application/x-subrip")
                    put("url", "$base/demo/subs/private.srt")
                })
            })
        } else {
            put("danmaku", "$base/demo/danmaku/dense.xml")
        }
    }.toString()

    // ---- video and audio ----

    fun master(): String = buildString {
        appendLine("#EXTM3U")
        appendLine("#EXT-X-VERSION:3")
        appendLine("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"国语\",LANGUAGE=\"zh\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio/zh.m3u8\"")
        appendLine("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=NO,AUTOSELECT=YES,URI=\"audio/en.m3u8\"")
        appendLine("#EXT-X-STREAM-INF:BANDWIDTH=2300000,RESOLUTION=${DemoVideo.WIDTH}x${DemoVideo.HEIGHT},AUDIO=\"aud\"")
        appendLine("video.m3u8")
    }

    fun playlist(prefix: String): String = buildString {
        appendLine("#EXTM3U")
        appendLine("#EXT-X-VERSION:3")
        appendLine("#EXT-X-TARGETDURATION:${video.segmentSeconds}")
        appendLine("#EXT-X-MEDIA-SEQUENCE:0")
        appendLine("#EXT-X-PLAYLIST-TYPE:VOD")
        for (i in 0 until SEGMENTS) appendLine("#EXTINF:${video.segmentSeconds}.000,").appendLine("$prefix$i.ts")
        appendLine("#EXT-X-ENDLIST")
    }

    /**
     * Segment [index] of an audio rendition: MPEG-1 Layer II at 48 kHz, every frame silent (no bits allocated to any
     * sub-band, so the frame is its header and zeros), in a transport stream of its own, timed like the video.
     */
    fun audioSegment(lang: String, index: Int): ByteArray {
        val stereo = lang == "en"
        // Header: MPEG-1 Layer II, no CRC; 64 kbit/s mono or 128 kbit/s stereo; 48 kHz.
        val frame = ByteArray(if (stereo) 384 else 192)
        frame[0] = 0xFF.toByte()
        frame[1] = 0xFD.toByte()
        frame[2] = (if (stereo) 0x84 else 0x44).toByte()
        frame[3] = (if (stereo) 0x00 else 0xC0).toByte()
        val out = ByteArrayOutputStream()
        out.write(psi(0, index and 15, PAT))
        out.write(psi(PMT_PID, index and 15, pmt(lang)))
        val framesPerSegment = video.segmentSeconds * 48_000 / 1152
        // Continuity counters carry on from the segment before: every segment has the same number of packets.
        val packetsPerPes = 1 + (14 + FRAMES_PER_PES * frame.size - 176 + 183) / 184
        var cc = (index * (framesPerSegment / FRAMES_PER_PES) * packetsPerPes) and 15
        var f = 0
        while (f < framesPerSegment) {
            val n = minOf(FRAMES_PER_PES, framesPerSegment - f)
            val pts = PTS_START + index.toLong() * video.segmentSeconds * 90_000 + f.toLong() * 1152 * 90_000 / 48_000
            val payload = ByteArray(n * frame.size)
            for (k in 0 until n) System.arraycopy(frame, 0, payload, k * frame.size, frame.size)
            cc = writePes(out, pes(pts, payload), pts, cc)
            f += n
        }
        return out.toByteArray()
    }

    private fun pes(pts: Long, payload: ByteArray): ByteArray {
        val out = ByteArray(14 + payload.size)
        out[2] = 1
        out[3] = 0xC0.toByte() // audio stream 0
        val length = 8 + payload.size
        out[4] = (length shr 8).toByte()
        out[5] = length.toByte()
        out[6] = 0x80.toByte()
        out[7] = 0x80.toByte() // PTS only
        out[8] = 5
        out[9] = (0x21 or ((pts shr 29).toInt() and 0x0E)).toByte()
        out[10] = (pts shr 22).toByte()
        out[11] = (((pts shr 14).toInt() and 0xFE) or 1).toByte()
        out[12] = (pts shr 7).toByte()
        out[13] = (((pts shl 1).toInt() and 0xFE) or 1).toByte()
        System.arraycopy(payload, 0, out, 14, payload.size)
        return out
    }

    /** One PES as transport stream packets on the audio PID, a PCR in the first; returns the continuity counter. */
    private fun writePes(out: ByteArrayOutputStream, pes: ByteArray, pts: Long, counterIn: Int): Int {
        var counter = counterIn
        var at = 0
        var first = true
        while (at < pes.size) {
            val packet = ByteArray(TS_PACKET) { 0xFF.toByte() }
            packet[0] = 0x47
            packet[1] = ((if (first) 0x40 else 0) or (AUDIO_PID shr 8)).toByte()
            packet[2] = AUDIO_PID.toByte()
            val adaptation = if (first) 8 else 0
            var room = TS_PACKET - 4 - adaptation
            val left = pes.size - at
            val stuffing = if (left < room) room - left else 0
            room -= stuffing
            val fieldLength = adaptation + stuffing
            packet[3] = ((if (fieldLength > 0) 0x30 else 0x10) or (counter and 15)).toByte()
            counter = (counter + 1) and 15
            var p = 4
            if (fieldLength > 0) {
                packet[p++] = (fieldLength - 1).toByte()
                if (fieldLength > 1) {
                    packet[p++] = (if (first) 0x10 else 0x00).toByte()
                    if (first) {
                        val pcr = pts - 9_000
                        packet[p++] = (pcr shr 25).toByte()
                        packet[p++] = (pcr shr 17).toByte()
                        packet[p++] = (pcr shr 9).toByte()
                        packet[p++] = (pcr shr 1).toByte()
                        packet[p++] = (((pcr and 1).toInt() shl 7) or 0x7E).toByte()
                        packet[p++] = 0
                    }
                    // The rest of the adaptation field is stuffing (0xFF, already there).
                    p = 4 + fieldLength
                }
            }
            System.arraycopy(pes, at, packet, p, room)
            at += room
            out.write(packet)
            first = false
        }
        return counter
    }

    private fun psi(pid: Int, counter: Int, section: ByteArray): ByteArray {
        val packet = ByteArray(TS_PACKET) { 0xFF.toByte() }
        packet[0] = 0x47
        packet[1] = (0x40 or (pid shr 8)).toByte()
        packet[2] = pid.toByte()
        packet[3] = (0x10 or (counter and 15)).toByte()
        packet[4] = 0
        System.arraycopy(section, 0, packet, 5, section.size)
        return packet
    }

    private fun pmt(lang: String): ByteArray {
        val code = (if (lang == "en") "eng" else "chi").toByteArray()
        return section(
            0x02, 1,
            byteArrayOf(
                (0xE0 or (AUDIO_PID shr 8)).toByte(), AUDIO_PID.toByte(), // PCR_PID
                0xF0.toByte(), 0, // program_info_length
                0x03, (0xE0 or (AUDIO_PID shr 8)).toByte(), AUDIO_PID.toByte(), 0xF0.toByte(), 6, // MPEG-1 audio
                0x0A, 4, code[0], code[1], code[2], 0, // ISO 639 language
            ),
        )
    }

    private fun section(tableId: Int, id: Int, body: ByteArray): ByteArray {
        val length = 5 + body.size + 4
        val out = ByteArray(3 + length)
        out[0] = tableId.toByte()
        out[1] = (0xB0 or (length shr 8)).toByte()
        out[2] = length.toByte()
        out[3] = (id shr 8).toByte()
        out[4] = id.toByte()
        out[5] = 0xC1.toByte()
        System.arraycopy(body, 0, out, 8, body.size)
        var crc = -1
        for (i in 0 until out.size - 4) {
            crc = crc xor (out[i].toInt() shl 24)
            repeat(8) { crc = if (crc < 0) (crc shl 1) xor 0x04C11DB7 else crc shl 1 }
        }
        for (i in 0 until 4) out[out.size - 4 + i] = (crc ushr (24 - 8 * i)).toByte()
        return out
    }

    private val PAT = section(0x00, 1, byteArrayOf(0, 1, (0xE0 or (PMT_PID shr 8)).toByte(), PMT_PID.toByte()))

    // ---- subtitles ----

    private fun time(ms: Long, sep: Char = ','): String =
        String.format(java.util.Locale.ROOT, "%02d:%02d:%02d%c%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, sep, ms % 1000)

    /** A line every three seconds that says which segment the picture is in; GBK, CRLF, no byte order mark. */
    fun gbkSrt(): ByteArray = buildString {
        for (i in 0 until 60) {
            val start = i * 3_000L
            append(i + 1).append("\r\n")
            append(time(start)).append(" --> ").append(time(start + 2_500)).append("\r\n")
            append("第 ${i + 1} 句：画面在第 ${start / 6000} 个分片（GBK 编码）").append("\r\n\r\n")
        }
    }.toByteArray(charset("GBK"))

    fun privateSrt(): ByteArray = buildString {
        for (i in 0 until 60) {
            val start = i * 3_000L + 1_000
            append(i + 1).append('\n').append(time(start)).append(" --> ").append(time(start + 1_800)).append('\n')
            append("Line ${i + 1}: this file needs the Referer header").append("\n\n")
        }
    }.toByteArray()

    fun styledAss(): ByteArray = buildString {
        append('﻿')
        appendLine("[Script Info]")
        appendLine("Title: 映舟字幕演示")
        appendLine("ScriptType: v4.00+")
        appendLine("PlayResX: 1280")
        appendLine("PlayResY: 720")
        appendLine()
        appendLine("[V4+ Styles]")
        appendLine("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")
        appendLine("Style: Default,Microsoft YaHei,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,30,1")
        appendLine("Style: English,Arial,34,&H0000E5FF,&H000000FF,&H00000000,&H64000000,0,1,0,0,100,100,0,0,1,2,1,2,20,20,30,1")
        appendLine("Style: Sign,Microsoft YaHei,40,&H0080FF80,&H000000FF,&H00203020,&H64000000,1,0,0,0,100,100,0,0,1,3,0,8,20,20,40,1")
        appendLine()
        appendLine("[Events]")
        appendLine("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")
        for (i in 0 until 45) {
            val start = i * 4_000L
            val end = start + 3_500
            fun t(ms: Long) = String.format(java.util.Locale.ROOT, "%d:%02d:%02d.%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000 / 10)
            appendLine("Dialogue: 0,${t(start)},${t(end)},Default,,0,0,0,,第 ${i + 1} 句双语字幕\\N{\\rEnglish}Line ${i + 1} in English")
            if (i % 3 == 0) appendLine("Dialogue: 1,${t(start)},${t(end)},Sign,,0,0,0,,{\\fad(300,300)}【画面上方的提示 ${i / 3 + 1}】")
        }
    }.toByteArray()

    // ---- danmaku ----

    private val PHRASES = listOf(
        "前方高能", "哈哈哈哈", "这里好看", "打卡", "第一次看", "名场面", "awsl", "666", "泪目", "终于等到了",
        "这配乐绝了", "又来看了", "弹幕护体", "画质好清楚", "空降成功", "笑死", "太真实了", "就这？", "我来了", "好家伙",
    )

    /** [count] comments over [seconds] seconds, always the same: mostly scrolling, some at the top and bottom. */
    fun denseXml(count: Int = 3000, seconds: Int = 180): String {
        val random = java.util.Random(20261119L)
        val colors = listOf(0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFE0302, 0xFFFF00, 0x00CD00, 0x4266BE, 0xCC0273, 0x89D5FF)
        val items = (0 until count).map { i ->
            val time = random.nextDouble() * seconds
            val roll = random.nextInt(100)
            val mode = when {
                roll < 85 -> 1
                roll < 93 -> 5
                else -> 4
            }
            val size = when (random.nextInt(10)) {
                0 -> 18
                1 -> 36
                else -> 25
            }
            val color = colors[random.nextInt(colors.size)]
            val text = PHRASES[random.nextInt(PHRASES.size)] + if (i % 7 == 0) " #$i" else ""
            Triple(time, "${"%.3f".format(java.util.Locale.ROOT, time)},$mode,$size,$color,${1_700_000_000 + i},0,u$i,$i", text)
        }.sortedBy { it.first }
        return buildString {
            append("<?xml version=\"1.0\" encoding=\"UTF-8\"?><i><chatserver>chat.bilibili.com</chatserver><chatid>0</chatid><maxlimit>$count</maxlimit>")
            for ((_, p, text) in items) append("<d p=\"").append(p).append("\">").append(text.replace("&", "&amp;").replace("<", "&lt;")).append("</d>")
            append("</i>")
        }
    }

    /** [denseXml] as raw deflate, made once. */
    val denseDeflated: ByteArray by lazy {
        val out = ByteArrayOutputStream()
        DeflaterOutputStream(out, Deflater(Deflater.DEFAULT_COMPRESSION, true)).use { it.write(denseXml().toByteArray()) }
        out.toByteArray()
    }

    /** What the config's danmaku API returns for a title: a few comments that name it, as JSON (`p` = time,mode,color,uid). */
    fun apiComments(name: String, episode: String): String = buildJsonObject {
        val count = 80
        put("count", count)
        put("comments", buildJsonArray {
            for (i in 0 until count) {
                val time = 1.0 + i * 2.2
                val mode = if (i % 10 == 9) 5 else 1
                add(buildJsonObject {
                    put("cid", i)
                    put("p", "${"%.2f".format(java.util.Locale.ROOT, time)},$mode,${if (i % 4 == 0) 0x89D5FF else 0xFFFFFF},demo$i")
                    put("m", "订阅弹幕接口：《$name》$episode 第 ${i + 1} 条")
                })
            }
        })
    }.toString()

    private const val TS_PACKET = 188
    private const val PMT_PID = 0x1000
    private const val AUDIO_PID = 0x101
    private const val PTS_START = 180_000L
    private const val FRAMES_PER_PES = 10
}

fun Route.demoMediaRoutes() {
    fun ApplicationCall.base(): String = "http://" + (request.headers[HttpHeaders.Host] ?: "127.0.0.1")
    val hls = ContentType("application", "vnd.apple.mpegurl")
    val ts = ContentType("video", "mp2t")

    get("/demo/extras") {
        val url = call.request.queryParameters["url"].orEmpty()
        call.respondText(DemoMedia.extras(url, call.base()), ContentType.Application.Json)
    }
    get("/demo/av/master.m3u8") { call.respondText(DemoMedia.master(), hls) }
    get("/demo/av/video.m3u8") { call.respondText(DemoMedia.playlist("v/"), hls) }
    get("/demo/av/v/{n}.ts") {
        val n = call.parameters["n"]?.toIntOrNull()?.takeIf { it in 0 until DemoMedia.SEGMENTS } ?: return@get call.respondText("no such segment", status = HttpStatusCode.NotFound)
        call.respondBytes(DemoMedia.videoSegment(n), ts)
    }
    get("/demo/av/audio/{lang}.m3u8") {
        val lang = call.parameters["lang"]?.takeIf { it == "zh" || it == "en" } ?: return@get call.respondText("no such track", status = HttpStatusCode.NotFound)
        call.respondText(DemoMedia.playlist("$lang/"), hls)
    }
    get("/demo/av/audio/{lang}/{n}.ts") {
        val lang = call.parameters["lang"]?.takeIf { it == "zh" || it == "en" } ?: return@get call.respondText("no such track", status = HttpStatusCode.NotFound)
        val n = call.parameters["n"]?.toIntOrNull()?.takeIf { it in 0 until DemoMedia.SEGMENTS } ?: return@get call.respondText("no such segment", status = HttpStatusCode.NotFound)
        call.respondBytes(DemoMedia.audioSegment(lang, n), ts)
    }
    // No charset: the engine has to find out that this one is GBK.
    get("/demo/subs/gbk.srt") { call.respondBytes(DemoMedia.gbkSrt(), ContentType.Text.Plain) }
    get("/demo/subs/styled.ass") { call.respondBytes(DemoMedia.styledAss(), ContentType.Text.Plain) }
    get("/demo/subs/private.srt") {
        if (call.request.headers[HttpHeaders.Referrer]?.contains("/demo/") != true) {
            call.respondText("this subtitle needs a Referer", status = HttpStatusCode.Forbidden)
        } else {
            call.respondBytes(DemoMedia.privateSrt(), ContentType.Text.Plain)
        }
    }
    // Like comment.bilibili.com: raw deflate, said in Content-Encoding, which most HTTP clients do not undo.
    get("/demo/danmaku/dense.xml") {
        call.response.header(HttpHeaders.ContentEncoding, "deflate")
        call.respondBytes(DemoMedia.denseDeflated, ContentType.Text.Xml)
    }
    get("/demo/danmaku/api") {
        val name = call.request.queryParameters["name"].orEmpty()
        val episode = call.request.queryParameters["episode"].orEmpty()
        if (name.isEmpty()) return@get call.respondText("{}", ContentType.Application.Json)
        val url = "${call.base()}/demo/danmaku/comments.json?name=${URLEncoder.encode(name, "UTF-8")}&episode=${URLEncoder.encode(episode, "UTF-8")}"
        call.respondText(buildJsonObject { put("url", url) }.toString(), ContentType.Application.Json)
    }
    get("/demo/danmaku/comments.json") {
        call.respondText(DemoMedia.apiComments(call.request.queryParameters["name"].orEmpty(), call.request.queryParameters["episode"].orEmpty()), ContentType.Application.Json)
    }
}
