package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.net.URLEncoder
import java.util.ArrayDeque
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

/**
 * 演示豆瓣 (`demo_douban`): a recommendation site like the Douban spider most real configs put first. Its cards
 * have the id `msearch:<title>` (one has an empty id) and nothing to open here: TVBox finds them by searching for
 * the title on the other sites, and the titles are 演示站's. Not searched (`searchable: 0`) and not switched to
 * (`changeable: 0`).
 *
 * Its posters are served only with Douban's Referer, the way Douban's image hosts refuse other pages: the cards ask
 * for it with `@Referer=` after the address (one card with `@Headers=` and a JSON object instead). Without it,
 * `/demo/douban/poster/<n>.png` answers 418. What came in is kept at `/demo/douban/log` (DELETE clears it).
 */
class DemoDouban(private val site: DemoSite) {
    private val classes = listOf("movie" to "热门电影", "tv" to "热门剧集")

    /** 演示站's videos (by id) recommended under each class. */
    private val recommended = mapOf("movie" to listOf(4, 8, 12, 16), "tv" to listOf(1, 5, 9, 13))

    private data class Hit(val n: Int, val referer: String, val status: Int, val time: Long)

    private val hits = ArrayDeque<Hit>()
    private val withReferer = AtomicInteger()
    private val withoutReferer = AtomicInteger()

    fun siteJson(base: String): JsonObject = buildJsonObject {
        put("key", KEY)
        put("name", "演示豆瓣")
        put("type", 1)
        put("api", "$base/demo/douban/api.php/provide/vod/")
        put("searchable", 0)
        put("changeable", 0)
    }

    fun api(params: Map<String, String>, base: String): String {
        val t = params["t"]
        return when {
            // Nothing opens here, and nothing is found here.
            params["ids"] != null || params["wd"] != null -> """{"list":[]}"""
            t != null -> buildJsonObject {
                val list = cards(t, base)
                put("page", 1)
                put("pagecount", 1)
                put("limit", list.size.toString())
                put("total", list.size)
                put("list", JsonArray(list))
            }.toString()
            else -> buildJsonObject {
                put("class", buildJsonArray {
                    classes.forEach { (id, name) -> add(buildJsonObject { put("type_id", id); put("type_name", name) }) }
                })
                put("list", JsonArray(classes.flatMap { (id, _) -> cards(id, base) }))
            }.toString()
        }
    }

    /**
     * The cards of class [classId]: `msearch:` ids; the movies also have [EMPTY_ID_VIDEO] with an empty id, and their
     * second card names its Referer with `@Headers=`.
     */
    private fun cards(classId: String, base: String): List<JsonObject> {
        val ids = recommended[classId] ?: return emptyList()
        val withEmpty = if (classId == "movie") ids + EMPTY_ID_VIDEO else ids
        return withEmpty.mapIndexed { i, n ->
            val title = site.title(n)
            buildJsonObject {
                put("vod_id", if (n == EMPTY_ID_VIDEO) "" else "msearch:$title")
                put("vod_name", title)
                put("vod_pic", posterUrl(base, n, headers = classId == "movie" && i == 1))
                put("vod_remarks", String.format(Locale.ROOT, "豆瓣 %.1f", 6.0 + (n * 37 % 40) / 10.0))
            }
        }
    }

    private fun posterUrl(base: String, n: Int, headers: Boolean): String {
        val url = "$base/demo/douban/poster/$n.png"
        return if (headers) url + "@Headers=" + URLEncoder.encode("""{"Referer":"$REFERER"}""", "UTF-8") else "$url@Referer=$REFERER"
    }

    fun poster(n: Int): ByteArray = site.poster(n, "豆瓣")

    /** Remembers a poster request; true when it carried Douban's Referer. */
    fun hit(n: Int, referer: String): Boolean {
        val ok = referer == REFERER
        (if (referer.isEmpty()) withoutReferer else withReferer).incrementAndGet()
        synchronized(hits) {
            hits.addLast(Hit(n, referer, if (ok) 200 else 418, System.currentTimeMillis()))
            while (hits.size > MAX_HITS) hits.removeFirst()
        }
        return ok
    }

    /** `{withReferer, withoutReferer, hits: [{n, referer, status, time}]}`: counts since the start (or the last clear), the latest hits. */
    fun logJson(): String = buildJsonObject {
        put("withReferer", withReferer.get())
        put("withoutReferer", withoutReferer.get())
        put("hits", buildJsonArray {
            synchronized(hits) { hits.toList() }.forEach {
                add(buildJsonObject { put("n", it.n); put("referer", it.referer); put("status", it.status); put("time", it.time) })
            }
        })
    }.toString()

    fun clearLog() {
        synchronized(hits) { hits.clear() }
        withReferer.set(0)
        withoutReferer.set(0)
    }

    companion object {
        const val KEY = "demo_douban"
        const val REFERER = "https://movie.douban.com/"

        /** 《山海奇谈》 is recommended with an empty id. */
        const val EMPTY_ID_VIDEO = 2
        private const val MAX_HITS = 200
    }
}

fun Route.demoDoubanRoutes(douban: DemoDouban) {
    fun io.ktor.server.application.ApplicationCall.base(): String =
        "http://" + (request.headers[HttpHeaders.Host] ?: "127.0.0.1")

    get("/demo/douban/api.php/provide/vod/") {
        val params = call.request.queryParameters.entries().associate { (k, v) -> k to v.firstOrNull().orEmpty() }
        call.respondText(douban.api(params, call.base()), ContentType.Application.Json)
    }
    get("/demo/douban/poster/{n}.png") {
        val n = call.parameters["n"]?.toIntOrNull() ?: 0
        if (douban.hit(n, call.request.headers[HttpHeaders.Referrer].orEmpty())) {
            call.respondBytes(douban.poster(n), ContentType.Image.PNG)
        } else {
            call.respondText("这张封面要带 Referer: ${DemoDouban.REFERER}", status = HttpStatusCode(418, "I'm a teapot"))
        }
    }
    get("/demo/douban/log") { call.respondText(douban.logJson(), ContentType.Application.Json) }
    delete("/demo/douban/log") {
        douban.clearLog()
        call.respond(HttpStatusCode.NoContent)
    }
}
