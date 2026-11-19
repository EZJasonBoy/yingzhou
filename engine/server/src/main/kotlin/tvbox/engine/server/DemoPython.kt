package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The demo's Python spiders (`src/main/resources/demo/py`), served at `/demo/py/<name>.py`:
 *
 * - 演示Python站 (`demo_vod.py`): browse, search, two lines per title (direct, and through the spider's localProxy);
 * - 演示Python依赖站 (`demo_pkg.py`): imports lxml, to show what happens when a package is missing;
 * - 演示Python直播 (`demo_live.py`): a live list with a direct channel, one through getProxyUrl and one through proxy://.
 *
 * The streams are the demo's public test streams, handed over in `ext` so that the scripts carry no addresses.
 */
object DemoPython {
    fun sites(base: String): List<JsonObject> = listOf(
        buildJsonObject {
            put("key", "demo_py")
            put("name", "演示Python站")
            put("type", 3)
            put("api", "$base/demo/py/demo_vod.py")
            put("searchable", 1)
            put("ext", buildJsonObject {
                put("poster", "$base/demo/poster/")
                put("stream", DemoSite.TEST_STREAM)
            })
        },
        buildJsonObject {
            put("key", "demo_py_pkg")
            put("name", "演示Python依赖站")
            put("type", 3)
            put("api", "$base/demo/py/demo_pkg.py")
            put("searchable", 0)
            put("ext", buildJsonObject {
                put("poster", "$base/demo/poster/")
                put("stream", DemoSite.TEST_STREAM)
            })
        },
    )

    fun lives(base: String): List<JsonObject> = listOf(
        buildJsonObject {
            put("name", "演示Python直播")
            put("type", 3)
            put("api", "$base/demo/py/demo_live.py")
            put("ext", buildJsonObject {
                put("group", "Python 蜘蛛")
                put("direct", DemoSite.TEST_STREAM)
                put("bipbop", DemoSite.BIPBOP)
                put("live", DemoSite.LIVE_TEST)
            })
            put("epg", "$base/demo/epg?ch={name}&date={date}")
        },
    )
}

fun Route.demoPythonRoutes() {
    get("/demo/py/{name}") {
        val name = call.parameters["name"].orEmpty()
        val text = if (name.matches(Regex("[a-z_]+\\.py"))) DemoPython::class.java.getResourceAsStream("/demo/py/$name")?.use { String(it.readBytes(), Charsets.UTF_8) } else null
        if (text == null) call.respondText("not found", status = HttpStatusCode.NotFound) else call.respondText(text, ContentType("text", "x-python"))
    }
}
