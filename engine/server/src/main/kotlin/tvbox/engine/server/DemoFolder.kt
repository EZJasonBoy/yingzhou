package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * 演示文件夹 (`demo_folder`): a site whose cards are folders (`vod_tag: "folder"`), the way live-game and
 * drive spiders list platform → area → room. TVBox opens a folder card by asking for the category whose id is the
 * card's id, not its detail; the detail of a folder id is empty here, as it is on those sites.
 */
object DemoFolder {
    const val KEY = "demo_folder"

    private class Room(val id: String, val name: String, val poster: Int)

    /** Folder id → (name, what it holds). Rooms are the leaves. */
    private val platforms = listOf("p1" to "平台甲", "p2" to "平台乙")
    private val areas = mapOf("p1" to listOf("a1" to "分区一", "a2" to "分区二"), "p2" to listOf("a3" to "分区三"))
    private val rooms = mapOf(
        "a1" to listOf(Room("r1", "一号房间", 1), Room("r2", "二号房间", 2)),
        "a2" to listOf(Room("r3", "三号房间", 3)),
        "a3" to listOf(Room("r4", "四号房间", 4)),
    )
    private val allRooms = rooms.values.flatten()

    fun siteJson(base: String): JsonObject = buildJsonObject {
        put("key", KEY)
        put("name", "演示文件夹")
        put("type", 1)
        put("api", "$base/demo/folder/api.php/provide/vod/")
        put("searchable", 0)
        put("changeable", 0)
    }

    fun api(params: Map<String, String>, base: String): String {
        val t = params["t"]
        val ids = params["ids"]
        return when {
            ids != null -> page(ids.split(',').mapNotNull { id -> allRooms.firstOrNull { it.id == id } }.map { detail(it, base) })
            params["wd"] != null -> page(emptyList())
            t != null -> page(cards(t, base))
            else -> buildJsonObject {
                put("class", buildJsonArray { add(buildJsonObject { put("type_id", "live"); put("type_name", "直播") }) })
                put("list", JsonArray(cards("live", base)))
            }.toString()
        }
    }

    /** What the category [id] holds: the platforms under the class, the areas under a platform, the rooms under an area. */
    private fun cards(id: String, base: String): List<JsonObject> = when {
        id == "live" -> platforms.mapIndexed { i, (pid, name) -> folder(pid, name, "$base/demo/poster/${i + 5}.png") }
        areas.containsKey(id) -> areas.getValue(id).mapIndexed { i, (aid, name) -> folder(aid, name, "$base/demo/poster/${i + 7}.png") }
        rooms.containsKey(id) -> rooms.getValue(id).map { room ->
            buildJsonObject {
                put("vod_id", room.id)
                put("vod_name", room.name)
                put("vod_pic", "$base/demo/poster/${room.poster}.png")
                put("vod_remarks", "直播中")
            }
        }
        else -> emptyList()
    }

    private fun folder(id: String, name: String, pic: String) = buildJsonObject {
        put("vod_id", id)
        put("vod_name", name)
        put("vod_pic", pic)
        put("vod_tag", "folder")
        put("vod_remarks", "文件夹")
    }

    private fun detail(room: Room, base: String) = buildJsonObject {
        put("vod_id", room.id)
        put("vod_name", room.name)
        put("vod_pic", "$base/demo/poster/${room.poster}.png")
        put("vod_content", "演示文件夹里的房间，播放演示的公开测试流。")
        put("vod_play_from", "直播")
        put("vod_play_url", "直播\$${DemoSite.TEST_STREAM}")
    }

    private fun page(list: List<JsonObject>) = buildJsonObject {
        put("page", 1)
        put("pagecount", 1)
        put("limit", list.size.toString())
        put("total", list.size)
        put("list", JsonArray(list))
    }.toString()
}

fun Route.demoFolderRoutes() {
    get("/demo/folder/api.php/provide/vod/") {
        val base = "http://" + (call.request.headers[HttpHeaders.Host] ?: "127.0.0.1")
        val params = call.request.queryParameters.entries().associate { (k, v) -> k to v.firstOrNull().orEmpty() }
        call.respondText(DemoFolder.api(params, base), ContentType.Application.Json)
    }
}
