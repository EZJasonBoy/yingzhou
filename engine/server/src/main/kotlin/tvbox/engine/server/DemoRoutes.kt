package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
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
class DemoSite(private val base: String) {
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

    val configJson: String = buildJsonObject {
        put("wallpaper", "")
        put("sites", buildJsonArray {
            add(buildJsonObject {
                put("key", "demo")
                put("name", "演示站")
                put("type", 1)
                put("api", "$base/demo/api.php/provide/vod/")
                put("searchable", 1)
            })
        })
        put("parses", buildJsonArray {
            add(buildJsonObject {
                put("name", "演示解析")
                put("type", 1)
                put("url", "$base/demo/jx?url=")
            })
        })
    }.toString()

    fun api(params: Map<String, String>): String {
        val ids = params["ids"]
        val wd = params["wd"]
        val t = params["t"]
        val pg = params["pg"]?.toIntOrNull()?.coerceAtLeast(1) ?: 1
        return when {
            ids != null -> page(ids.split(',').mapNotNull { id -> items.firstOrNull { it.id.toString() == id } }, 1, detail = true)
            wd != null -> page(items.filter { wd in it.name }, pg, detail = false)
            t != null -> page(items.filter { it.classId == t }, pg, detail = false)
            else -> buildJsonObject {
                put("class", buildJsonArray {
                    classes.forEach { (id, name) -> add(buildJsonObject { put("type_id", id); put("type_name", name) }) }
                })
                put("filters", buildJsonObject {
                    classes.forEach { (id, _) -> put(id, yearFilter()) }
                })
                put("list", JsonArray(items.takeLast(18).reversed().map { card(it, detail = false) }))
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

    private fun page(list: List<Item>, pg: Int, detail: Boolean): String {
        val size = 20
        val pageCount = maxOf(1, (list.size + size - 1) / size)
        return buildJsonObject {
            put("page", pg)
            put("pagecount", pageCount)
            put("limit", size.toString())
            put("total", list.size)
            put("list", JsonArray(list.drop((pg - 1) * size).take(size).map { card(it, detail) }))
        }.toString()
    }

    private fun card(item: Item, detail: Boolean): JsonObject = buildJsonObject {
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
        g.drawString((item?.year ?: 2025).toString(), 24, h - 30)
        g.dispose()
        ByteArrayOutputStream().also { ImageIO.write(img, "png", it) }.toByteArray()
    }

    companion object {
        private const val LINE_SEP = "\$\$\$"

        /** Public HLS test stream (Big Buck Bunny, CC BY 3.0), widely used for player development. */
        const val TEST_STREAM = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
    }
}

fun Route.demoRoutes(site: DemoSite) {
    get("/demo/config.json") { call.respondText(site.configJson, ContentType.Application.Json) }
    get("/demo/api.php/provide/vod/") {
        val params = call.request.queryParameters.entries().associate { (k, v) -> k to v.firstOrNull().orEmpty() }
        call.respondText(site.api(params), ContentType.Application.Json)
    }
    get("/demo/jx") { call.respondText(site.parse(call.request.queryParameters["url"].orEmpty()), ContentType.Application.Json) }
    get("/demo/poster/{id}.png") {
        val id = call.parameters["id"]?.toIntOrNull() ?: 0
        call.respondBytes(site.poster(id), ContentType.Image.PNG)
    }
}
