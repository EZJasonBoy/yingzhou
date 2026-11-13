package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondRedirect
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.awt.Color
import java.awt.Font
import java.awt.GradientPaint
import java.awt.RenderingHints
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import javax.imageio.ImageIO

/**
 * A fake MacCMS JSON site for development (`--demo`): categories, paging, search, details, generated posters,
 * one directly playable line and one line that goes through a JSON parser. Nothing here touches third-party sites
 * except the public HLS test stream used as the video.
 */
class DemoSite {
    private val classes = listOf("1" to "电影", "2" to "剧集", "3" to "动漫", "4" to "纪录片")
    private val first = listOf("星河", "长夜", "山海", "迷城", "归途", "风起", "浮光", "暗涌", "逆流", "长安", "雾港", "白昼")
    private val second = listOf("之约", "纪事", "往事", "来信", "奇谈", "迷踪", "长歌", "未眠", "边境", "回声")

    private data class Item(val id: Int, val classId: String, val name: String, val year: Int, val episodes: Int)

    private val items: List<Item> = (1..96).map { i ->
        val classId = classes[i % classes.size].first
        val name = first[i % first.size] + second[(i * 7) % second.size] + if (i > 60) " 第二季" else ""
        val episodes = if (classId == "1") 1 else 6 + (i % 20)
        Item(i, classId, name, 2014 + i % 12, episodes)
    }
    private val posterCache = ConcurrentHashMap<Int, ByteArray>()

    /** Urls use the host the request came in on, so an emulator or a phone on the LAN gets reachable links. */
    fun configJson(base: String): String = buildJsonObject {
        put("wallpaper", "")
        // The global spider jar also carries the "Json聚合" parser (com.github.catvod.parser.MixDemo).
        put("spider", "$base/demo/spider.jar")
        put("sites", buildJsonArray {
            add(buildJsonObject {
                put("key", "demo")
                put("name", "演示站")
                put("type", 1)
                put("api", "$base/demo/api.php/provide/vod/")
                put("searchable", 1)
            })
            add(buildJsonObject {
                put("key", "demo_js")
                put("name", "演示JS站")
                put("type", 3)
                put("api", "$base/demo/spider.js")
                put("searchable", 1)
                put("ext", buildJsonObject { put("api", "$base/demo/api.php/provide/vod/") })
            })
            // Runs where jar spiders can run (the Android app's embedded engine).
            add(buildJsonObject {
                put("key", "demo_jar")
                put("name", "演示JAR站")
                put("type", 3)
                put("api", "csp_DemoJar")
                put("jar", "$base/demo/spider.jar")
                put("searchable", 1)
                put("ext", buildJsonObject { put("api", "$base/demo/api.php/provide/vod/") })
            })
            // Plays through a web page that has to be sniffed (playUrl = a type-0 parser).
            add(buildJsonObject {
                put("key", "demo_sniff")
                put("name", "演示嗅探站")
                put("type", 1)
                put("api", "$base/demo/api.php/provide/vod/")
                put("searchable", 0)
                put("playUrl", "$base/demo/sniff?url=")
            })
        })
        put("parses", buildJsonArray {
            // First = default parser, as in TVBox; engines without jar spiders skip it.
            add(buildJsonObject {
                put("name", "演示聚合")
                put("type", 3)
                put("url", "Demo")
            })
            add(buildJsonObject {
                put("name", "演示解析")
                put("type", 1)
                put("url", "$base/demo/jx?url=")
            })
            add(buildJsonObject {
                put("name", "演示嗅探")
                put("type", 0)
                put("url", "$base/demo/sniff?url=")
            })
        })
        // Ad rule for /demo/ads/index.m3u8: drop discontinuity blocks lasting 15.1666 s.
        put("lives", buildJsonArray {
            add(buildJsonObject {
                put("name", "演示直播")
                put("type", 0)
                put("url", "$base/demo/live.m3u")
                put("epg", "$base/demo/epg?ch={name}&date={date}")
            })
        })
        put("rules", buildJsonArray {
            add(buildJsonObject {
                put("name", "演示去广告")
                put("hosts", buildJsonArray { add(JsonPrimitive("/demo/ads/")) })
                put("regex", buildJsonArray { add(JsonPrimitive("15.1666")) })
            })
        })
    }.toString()

    fun api(params: Map<String, String>, base: String): String {
        val ids = params["ids"]
        val wd = params["wd"]
        val t = params["t"]
        val pg = params["pg"]?.toIntOrNull()?.coerceAtLeast(1) ?: 1
        return when {
            ids != null -> page(ids.split(",").mapNotNull { id -> items.firstOrNull { it.id.toString() == id } }, 1, detail = true, base)
            wd != null -> page(items.filter { wd in it.name }, pg, detail = false, base)
            t != null -> page(items.filter { it.classId == t }, pg, detail = false, base)
            else -> buildJsonObject {
                put("class", buildJsonArray {
                    classes.forEach { (id, name) -> add(buildJsonObject { put("type_id", id); put("type_name", name) }) }
                })
                put("filters", buildJsonObject {
                    classes.forEach { (id, _) -> put(id, yearFilter()) }
                })
                put("list", JsonArray(items.takeLast(18).reversed().map { card(it, detail = false, base) }))
            }.toString()
        }
    }

    private fun yearFilter(): JsonArray = buildJsonArray {
        add(buildJsonObject {
            put("key", "year")
            put("name", "年份")
            put("value", buildJsonArray {
                add(buildJsonObject { put("n", "全部"); put("v", "") })
                (2025 downTo 2014 step 3).forEach { y -> add(buildJsonObject { put("n", "$y"); put("v", "$y") }) }
            })
        })
    }

    private fun page(list: List<Item>, pg: Int, detail: Boolean, base: String): String {
        val size = 20
        val pageCount = maxOf(1, (list.size + size - 1) / size)
        return buildJsonObject {
            put("page", pg)
            put("pagecount", pageCount)
            put("limit", size.toString())
            put("total", list.size)
            put("list", JsonArray(list.drop((pg - 1) * size).take(size).map { card(it, detail, base) }))
        }.toString()
    }

    private fun card(item: Item, detail: Boolean, base: String): JsonObject = buildJsonObject {
        put("vod_id", item.id.toString())
        put("vod_name", item.name)
        put("vod_pic", "$base/demo/poster/${item.id}.png")
        put("vod_remarks", if (item.episodes == 1) "HD" else "更新至${item.episodes}集")
        put("type_name", classes.first { it.first == item.classId }.second)
        put("vod_year", item.year.toString())
        if (detail) {
            put("vod_area", "演示地区")
            put("vod_actor", "演员甲,演员乙,演员丙")
            put("vod_director", "导演丁")
            put("vod_content", "这是开发用的演示数据。《${item.name}》讲述了一个关于远方与回声的故事，共 ${item.episodes} 集。")
            val eps = (1..item.episodes).map { if (item.episodes == 1) "正片" else "第${it}集" }
            put("vod_play_from", "演示直链" + LINE_SEP + "需解析线路")
            put(
                "vod_play_url",
                eps.joinToString("#") { "$it\$$TEST_STREAM" } + LINE_SEP +
                    eps.mapIndexed { i, n -> "$n\$$base/demo/page/${item.id}/${i + 1}" }.joinToString("#"),
            )
        }
    }

    fun parse(url: String): String = buildJsonObject {
        // Any demo page "resolves" to the test stream.
        put("url", if (url.contains("/demo/page/")) TEST_STREAM else "")
    }.toString()

    fun poster(id: Int): ByteArray = posterCache.getOrPut(id) {
        val item = items.firstOrNull { it.id == id }
        val w = 300
        val h = 420
        val img = BufferedImage(w, h, BufferedImage.TYPE_INT_RGB)
        val g = img.createGraphics()
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON)
        val hue = (id * 47 % 360) / 360f
        g.paint = GradientPaint(0f, 0f, Color.getHSBColor(hue, 0.55f, 0.55f), w.toFloat(), h.toFloat(), Color.getHSBColor((hue + 0.15f) % 1f, 0.6f, 0.18f))
        g.fillRect(0, 0, w, h)
        g.color = Color(255, 255, 255, 40)
        g.fillOval(-80, h - 220, 300, 300)
        g.color = Color.WHITE
        g.font = Font(Font.SANS_SERIF, Font.BOLD, 30)
        val name = item?.name ?: "演示"
        name.chunked(6).forEachIndexed { i, line -> g.drawString(line, 24, 70 + i * 40) }
        g.font = Font(Font.SANS_SERIF, Font.PLAIN, 18)
        g.color = Color(255, 255, 255, 180)
        g.drawString((item?.year ?: 2025).toString(), 24, 70 + 40 * (name.chunked(6).size - 1) + 34)
        g.dispose()
        ByteArrayOutputStream().also { ImageIO.write(img, "png", it) }.toByteArray()
    }

    /** A cat-style JS spider wrapping the demo CMS api, to exercise the JS runtime end to end. */
    val spiderJs: String = """
        let api = '';
        async function init(cfg) { api = cfg.ext.api; }
        async function home(filter) {
          const d = JSON.parse((await req(api, {})).content);
          d.list = d.list.map(v => Object.assign({}, v, { vod_remarks: 'JS · ' + (v.vod_remarks || '') }));
          return JSON.stringify(d);
        }
        async function category(tid, pg, filter, extend) {
          return (await req(api + '?ac=detail&t=' + tid + '&pg=' + pg, {})).content;
        }
        async function detail(id) { return (await req(api + '?ac=detail&ids=' + id, {})).content; }
        async function search(wd, quick) { return (await req(api + '?ac=detail&wd=' + encodeURIComponent(wd), {})).content; }
        async function play(flag, id) { return JSON.stringify({ parse: id.indexOf('/demo/page/') >= 0 ? 1 : 0, url: id }); }
        export function __jsEvalReturn() { return { init, home, category, detail, search, play }; }
    """.trimIndent()

    companion object {
        private const val LINE_SEP = "\$\$\$"

        /** Public HLS test stream (Big Buck Bunny, CC BY 3.0), widely used for player development. */
        const val TEST_STREAM = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

        /** Public test streams: Apple's HLS example and Unified Streaming's live demo channel. */
        const val BIPBOP = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"
        const val LIVE_TEST = "https://demo.unified-streaming.com/k8s/live/stable/scte35.isml/.m3u8"

        private val PROGRAMS = listOf("早间新闻", "纪录片时间", "午间剧场", "动画乐园", "体育快报", "晚间新闻", "黄金剧场", "深夜电影")

        /** A made-up schedule in the `epg_data` format: one programme every 90 minutes. */
        fun epg(channel: String, date: String): String = buildJsonObject {
            put("date", date)
            put("channel_name", channel)
            put("epg_data", buildJsonArray {
                val offset = channel.hashCode().mod(PROGRAMS.size)
                for (i in 0 until 16) {
                    val start = i * 90
                    val end = start + 90
                    add(buildJsonObject {
                        put("start", "%02d:%02d".format(start / 60 % 24, start % 60))
                        put("end", "%02d:%02d".format(end / 60 % 24, end % 60))
                        put("title", PROGRAMS[(i + offset) % PROGRAMS.size])
                    })
                }
            })
        }.toString()
    }
}

fun Route.demoRoutes(site: DemoSite) {
    // Links point back at whatever host:port the caller used (127.0.0.1, 10.0.2.2 from an emulator, a LAN ip...).
    fun io.ktor.server.application.ApplicationCall.base(): String =
        "http://" + (request.headers[io.ktor.http.HttpHeaders.Host] ?: "127.0.0.1")

    get("/demo/config.json") { call.respondText(site.configJson(call.base()), ContentType.Application.Json) }
    get("/demo/spider.js") { call.respondText(site.spiderJs, ContentType.Text.JavaScript) }
    get("/demo/spider.jar") {
        val jar = DemoSite::class.java.getResourceAsStream("/demo/spider.jar")?.use { it.readBytes() }
        if (jar == null) call.respondText("demo jar not built (engine/server/demo-jar/build.sh)", status = io.ktor.http.HttpStatusCode.NotFound)
        else call.respondBytes(jar, ContentType.Application.OctetStream)
    }
    get("/demo/api.php/provide/vod/") {
        val params = call.request.queryParameters.entries().associate { (k, v) -> k to v.firstOrNull().orEmpty() }
        call.respondText(site.api(params, call.base()), ContentType.Application.Json)
    }
    get("/demo/jx") { call.respondText(site.parse(call.request.queryParameters["url"].orEmpty()), ContentType.Application.Json) }
    // A "parser page" whose player requests the stream from script, like hls.js does: only a browser finds it.
    get("/demo/sniff") {
        val id = call.request.queryParameters["url"].orEmpty().hashCode().toUInt().toString(16)
        call.respondText(
            """<!doctype html><html><head><meta charset="utf-8"><title>sniff demo</title></head><body>
            |<video id="v" muted autoplay></video>
            |<script>setTimeout(function () { fetch("/demo/stream/$id.m3u8").catch(function () {}); }, 300);</script>
            |</body></html>""".trimMargin(),
            ContentType.Text.Html,
        )
    }
    get("/demo/stream/{name}") { call.respondRedirect(DemoSite.TEST_STREAM, permanent = false) }
    // A playlist with an ad spliced in (3 segments, 15.1666 s in all), for checking the engine's ad cleaning.
    // Live demo: an M3U with a real live stream, two test streams, and a channel whose first line is dead.
    get("/demo/live.m3u") {
        val base = call.base()
        val text = buildString {
            appendLine("#EXTM3U")
            appendLine("#EXTINF:-1 tvg-logo=\"$base/demo/poster/1.png\" group-title=\"演示频道\",演示直播台")
            appendLine(DemoSite.LIVE_TEST)
            appendLine("#EXTINF:-1 tvg-logo=\"$base/demo/poster/2.png\" group-title=\"演示频道\",CCTV-1 综合")
            appendLine(DemoSite.TEST_STREAM)
            appendLine("#EXTINF:-1 tvg-logo=\"$base/demo/poster/3.png\" group-title=\"演示频道\",苹果示例台")
            appendLine(DemoSite.BIPBOP)
            appendLine("#EXTINF:-1 tvg-logo=\"$base/demo/poster/4.png\" group-title=\"测试\",备用线路演示")
            appendLine("http://127.0.0.1:1/dead.m3u8")
            appendLine("#EXTINF:-1 group-title=\"测试\",备用线路演示")
            appendLine(DemoSite.TEST_STREAM)
        }
        call.respondText(text, ContentType("audio", "x-mpegurl"))
    }
    get("/demo/epg") {
        call.respondText(DemoSite.epg(call.request.queryParameters["ch"].orEmpty(), call.request.queryParameters["date"].orEmpty()), ContentType.Application.Json)
    }
    get("/demo/ads/index.m3u8") {
        val text = buildString {
            appendLine("#EXTM3U")
            appendLine("#EXT-X-VERSION:3")
            appendLine("#EXT-X-TARGETDURATION:10")
            for (i in 0 until 10) appendLine("#EXTINF:10.000000,").appendLine("seg%04d.ts".format(i))
            appendLine("#EXT-X-DISCONTINUITY")
            appendLine("#EXTINF:3.000000,").appendLine("/demo/ads/ad/a1.ts")
            appendLine("#EXTINF:4.166666,").appendLine("/demo/ads/ad/a2.ts")
            appendLine("#EXTINF:8.000000,").appendLine("/demo/ads/ad/a3.ts")
            appendLine("#EXT-X-DISCONTINUITY")
            for (i in 10 until 20) appendLine("#EXTINF:10.000000,").appendLine("seg%04d.ts".format(i))
            appendLine("#EXT-X-ENDLIST")
        }
        call.respondText(text, ContentType("application", "vnd.apple.mpegurl"))
    }
    get("/demo/poster/{id}.png") {
        val id = call.parameters["id"]?.toIntOrNull() ?: 0
        call.respondBytes(site.poster(id), ContentType.Image.PNG)
    }
}
