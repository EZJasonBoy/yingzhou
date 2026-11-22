package tvbox.engine.server

import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respondBytesWriter
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.delay

/**
 * The demo's throttled line, 限速线路 on 《白昼迷踪 第二季》: the slow source's video ([DemoSlowSource]) as HLS
 * under `/demo/throttled`, every segment sent at [THROTTLED_RATE] bytes a second. That is well under the 2 Mbit/s
 * the video needs, so the line probe reports the line `slow` and a player keeps waiting on it. It has no knobs and
 * keeps no record, so it does not disturb the slow source's measurements.
 */
fun Route.demoThrottledRoutes(slow: DemoSlowSource) {
    get("/demo/throttled/master.m3u8") {
        call.respondText(
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2100000,RESOLUTION=${DemoVideo.WIDTH}x${DemoVideo.HEIGHT}\nindex.m3u8\n",
            DemoSlowSource.M3U8,
        )
    }
    get("/demo/throttled/index.m3u8") { call.respondText(slow.playlist({ "seg/$it.ts" }), DemoSlowSource.M3U8) }
    get("/demo/throttled/seg/{name}") {
        val index = call.parameters["name"]?.removeSuffix(".ts")?.toIntOrNull()?.takeIf { it in 0 until slow.segments }
            ?: return@get call.respondText("no such segment", status = HttpStatusCode.NotFound)
        val data = slow.segment(index)
        call.respondBytesWriter(DemoSlowSource.TS, HttpStatusCode.OK, data.size.toLong()) {
            val started = System.nanoTime()
            var at = 0
            while (at < data.size) {
                val n = minOf(THROTTLED_CHUNK, data.size - at)
                writeFully(data.copyOfRange(at, at + n), 0, n)
                flush()
                at += n
                // On a schedule from the start, so that coarse timers do not add up to a slower rate.
                val wait = (started + at * 1_000_000_000L / THROTTLED_RATE - System.nanoTime()) / 1_000_000
                if (wait > 0) delay(wait)
            }
        }
    }
}

/** Bytes a second of the throttled line: under half of what its video needs. */
const val THROTTLED_RATE = 100_000L
private const val THROTTLED_CHUNK = 8 * 1024
