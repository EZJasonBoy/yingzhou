package tvbox.engine.server

import io.ktor.server.routing.Route
import io.ktor.server.routing.get

/**
 * Episodes of 《慢速源演示》 for trying out downloads: the first two minutes of the slow source's film, small enough to
 * download in a demo, and a live playlist that a download must refuse. Same source, same knobs and request log as
 * the rest of `/demo/slow` ([DemoSlowSource]): `refuse=` switches the segments off, `cutAfter=` breaks them off.
 *
 * - `short/index.m3u8`: [SHORT_SEGMENTS] segments; `short/aes.m3u8`: the same, AES-128 encrypted with a key to fetch;
 * - `short.mpg`: those segments as one file (a direct link, which downloads with byte ranges);
 * - `live.m3u8`: a sliding window of five segments that moves with the clock and never ends.
 */
fun Route.demoDownloadRoutes(slow: DemoSlowSource) {
    val video = slow.video

    fun playlist(extra: String, line: (Int) -> String): String = buildString {
        appendLine("#EXTM3U")
        appendLine("#EXT-X-VERSION:4")
        appendLine("#EXT-X-TARGETDURATION:${video.segmentSeconds}")
        appendLine("#EXT-X-MEDIA-SEQUENCE:0")
        appendLine("#EXT-X-PLAYLIST-TYPE:VOD")
        if (extra.isNotEmpty()) appendLine(extra)
        for (i in 0 until SHORT_SEGMENTS) {
            appendLine("#EXTINF:${video.segmentSeconds}.000,")
            appendLine(line(i))
        }
        appendLine("#EXT-X-ENDLIST")
    }

    suspend fun io.ktor.server.application.ApplicationCall.text(body: String) {
        val bytes = body.toByteArray()
        slow.serve(this, "playlist", -1, DemoSlowSource.M3U8, bytes.size.toLong()) { from, to -> bytes.copyOfRange(from.toInt(), to.toInt()) }
    }

    get("/demo/slow/short/index.m3u8") { call.text(playlist("") { "../seg/$it.ts" }) }
    get("/demo/slow/short/aes.m3u8") { call.text(playlist("#EXT-X-KEY:METHOD=AES-128,URI=\"../aes/key.bin\"") { "../aes/seg/$it.ts" }) }
    get("/demo/slow/short.mpg") {
        val whole = SHORT_SEGMENTS.toLong() * video.segmentBytes
        val start = Regex("bytes=(\\d+)-").find(call.request.headers[io.ktor.http.HttpHeaders.Range].orEmpty())?.groupValues?.get(1)?.toLongOrNull() ?: 0
        slow.serve(call, "segment", (start / video.segmentBytes).toInt(), DemoSlowSource.TS, whole, slow::slice)
    }
    get("/demo/slow/live.m3u8") {
        val sequence = (System.currentTimeMillis() / (video.segmentSeconds * 1000L)) % (slow.segments - 5)
        call.text(buildString {
            appendLine("#EXTM3U")
            appendLine("#EXT-X-VERSION:3")
            appendLine("#EXT-X-TARGETDURATION:${video.segmentSeconds}")
            appendLine("#EXT-X-MEDIA-SEQUENCE:$sequence")
            for (i in sequence until sequence + 5) appendLine("#EXTINF:${video.segmentSeconds}.000,").appendLine("seg/$i.ts")
        })
    }
}

/** Two minutes of the slow film. */
const val SHORT_SEGMENTS = 20
