package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** The demo's live sources beyond the plain playlist of [DemoSite]: a list that a JS spider serves. */
object DemoLive {
    /** More entries for the demo config's `lives`. */
    fun lives(base: String): List<JsonObject> = listOf(
        // type 3 with a script: the engine asks its `live()` for the list (TVBox `JsSpider.liveContent`).
        buildJsonObject {
            put("name", "演示JS直播")
            put("type", 3)
            put("api", "$base/demo/live.js")
            put("ext", buildJsonObject { put("group", "JS 蜘蛛") })
            put("epg", "$base/demo/epg?ch={name}&date={date}")
        },
    )

    /**
     * A JS spider that serves a live list, written the plain way (a default export, where the demo site's spider is
     * the cat kind). The three channels name their address the three ways scripts do: as it is, through the
     * script's own proxy (`getProxy`), and with TVBox's `proxy://`. The last two only play when the request comes
     * back to this very script, whose `proxy()` sends the player on to the stream.
     */
    val spiderJs: String = """
        const STREAMS = { direct: '${DemoSite.TEST_STREAM}', bipbop: '${DemoSite.BIPBOP}', live: '${DemoSite.LIVE_TEST}' };
        let group = 'JS';
        export default {
          init(ext) { if (ext && ext.group) group = ext.group; },
          live(url) {
            return [
              group + ',#genre#',
              'JS 直连台,' + STREAMS.direct,
              'JS 代理台,' + getProxy(true) + '&ch=bipbop',
              'JS 协议台,proxy://do=js&ch=live',
            ].join('\n');
          },
          proxy(params) {
            const to = STREAMS[params.ch];
            return to ? [302, 'text/plain', '', { Location: to }] : [404, 'text/plain', 'no such channel'];
          },
        };
    """.trimIndent()
}

fun Route.demoLiveRoutes() {
    get("/demo/live.js") { call.respondText(DemoLive.spiderJs, ContentType.Text.JavaScript) }
}
