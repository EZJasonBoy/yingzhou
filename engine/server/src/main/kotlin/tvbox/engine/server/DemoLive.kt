package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.server.response.respondRedirect
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

/** The demo's catch-up channel: an M3U entry whose past is played from [demoLiveRoutes]' `/demo/catchup.m3u8`. */
fun demoCatchupEntry(base: String): String =
    "#EXTINF:-1 tvg-logo=\"$base/demo/poster/5.png\" group-title=\"演示频道\" catchup=\"default\" catchup-days=\"3\" " +
        "catchup-source=\"$base/demo/catchup.m3u8?start=\${(b)yyyyMMddHHmmss}&end=\${(e)yyyyMMddHHmmss}&utc={utc}\",回看演示台\n" +
        DemoSite.LIVE_TEST + "\n"

fun Route.demoLiveRoutes() {
    get("/demo/live.js") { call.respondText(DemoLive.spiderJs, ContentType.Text.JavaScript) }
    // Any past range of 回看演示台 "plays" as the VOD test stream; a request whose placeholders were not filled in
    // (or that is not in the past) is refused, so a wrong address shows up as a channel that does not play.
    get("/demo/catchup.m3u8") {
        val q = call.request.queryParameters
        val format = java.text.SimpleDateFormat("yyyyMMddHHmmss", java.util.Locale.ROOT).apply { timeZone = java.util.TimeZone.getTimeZone("Asia/Shanghai") }
        val start = runCatching { format.parse(q["start"].orEmpty())!!.time }.getOrNull()
        val end = runCatching { format.parse(q["end"].orEmpty())!!.time }.getOrNull()
        val utc = q["utc"]?.toLongOrNull()
        if (start == null || end == null || end <= start || utc != start / 1000 || start > System.currentTimeMillis()) {
            call.respondText("bad catch-up range", status = io.ktor.http.HttpStatusCode.BadRequest)
        } else {
            call.respondRedirect(DemoSite.TEST_STREAM, permanent = false)
        }
    }
}
