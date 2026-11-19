package tvbox.engine.api

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytesWriter
import io.ktor.server.response.respondRedirect
import io.ktor.server.routing.Route
import io.ktor.server.routing.RoutingCall
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.utils.io.ByteWriteChannel
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import tvbox.engine.core.Engine
import tvbox.engine.core.cache.StreamCache
import tvbox.engine.core.cache.StreamCache.Answer
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.EngineSettings
import tvbox.engine.core.model.ErrorBody
import tvbox.engine.core.model.StreamCacheInfo
import tvbox.engine.core.model.StreamCoverage
import java.io.File
import java.io.RandomAccessFile

/**
 * The stream cache over HTTP:
 *
 * - `/hls/<playlist>/<number>.<ext>`: the files the playlists of `/m3u8` name (segments, keys, initialisation
 *   maps), from the cache or, while they are fetched, as they arrive. Sends the player to the source when the
 *   engine cannot get a file.
 * - `/api/v1/stream-cache`: GET says how big it is, DELETE empties it.
 * - `/api/v1/stream-cache/coverage?key=`: which parts of a film are cached (`key` is `PlayInfo.cache`).
 */
fun Route.streamCacheRoutes(engine: Engine) {
    get("/hls/{playlist}/{file}") {
        val cache = engine.streamCache
        val number = call.parameters["file"]?.substringBefore('.')?.toIntOrNull()
        if (cache == null || number == null) {
            call.respond(HttpStatusCode.NotFound, ErrorBody(ApiError("NOT_FOUND", "no such file")))
            return@get
        }
        val range = byteRange(call.request.headers[HttpHeaders.Range])
        when (val answer = cache.open(call.parameters["playlist"].orEmpty(), number, call.request.headers[HttpHeaders.UserAgent])) {
            is Answer.Stored -> call.sendStored(answer.file, answer.type, range)
            is Answer.Arriving -> try {
                call.sendArriving(answer, range)
            } finally {
                answer.close()
            }
            is Answer.Redirect -> call.respondRedirect(answer.url, permanent = false)
            is Answer.Failed -> call.respond(HttpStatusCode.fromValue(answer.status), ErrorBody(ApiError("STREAM_CACHE", answer.message)))
        }
    }

    get("/api/v1/stream-cache") { call.respond(info(engine.streamCache)) }
    delete("/api/v1/stream-cache") {
        engine.streamCache?.clear()
        call.respond(info(engine.streamCache))
    }
    get("/api/v1/stream-cache/coverage") {
        val key = call.parameters["key"]?.takeIf { it.isNotBlank() } ?: throw BadRequestException("key is required")
        val coverage = engine.streamCache?.coverage(key)
        call.respond(if (coverage == null) StreamCoverage() else StreamCoverage(coverage.durationMs, coverage.ranges.map { listOf(it[0], it[1]) }))
    }
}

private fun info(cache: StreamCache?): StreamCacheInfo {
    if (cache == null) return StreamCacheInfo(available = false)
    val stats = cache.store.stats()
    return StreamCacheInfo(available = true, enabled = cache.enabled, bytes = stats.bytes, files = stats.files, streams = stats.streams, maxBytes = stats.maxBytes, path = cache.store.root.absolutePath)
}

/** The settings a client sent laid over the current ones: fields the client does not know (or left out) stay as they are. */
internal fun mergedSettings(current: EngineSettings, sent: JsonObject): EngineSettings =
    EngineJson.decodeFromJsonElement<EngineSettings>(JsonObject(EngineJson.encodeToJsonElement(current).jsonObject + sent))

/** `bytes=a-b` or `bytes=a-` as (first byte, last byte or -1); null for anything else. */
private fun byteRange(header: String?): Pair<Long, Long>? {
    val m = Regex("bytes=(\\d+)-(\\d*)").matchEntire(header?.trim() ?: return null) ?: return null
    return m.groupValues[1].toLong() to (m.groupValues[2].toLongOrNull() ?: -1)
}

private suspend fun RoutingCall.sendStored(file: File, type: String, range: Pair<Long, Long>?) {
    val size = file.length()
    val from = range?.first ?: 0
    val last = if (range == null || range.second < 0) size - 1 else minOf(range.second, size - 1)
    response.header(HttpHeaders.AcceptRanges, "bytes")
    if (range != null && from > last) {
        response.header(HttpHeaders.ContentRange, "bytes */$size")
        respond(HttpStatusCode.RequestedRangeNotSatisfiable)
        return
    }
    if (range != null) response.header(HttpHeaders.ContentRange, "bytes $from-$last/$size")
    respondBytesWriter(contentType(type), if (range != null) HttpStatusCode.PartialContent else HttpStatusCode.OK, last - from + 1) {
        withContext(Dispatchers.IO) {
            RandomAccessFile(file, "r").use { input ->
                input.seek(from)
                val buffer = ByteArray(64 * 1024)
                var left = last - from + 1
                while (left > 0) {
                    val n = input.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
                    if (n <= 0) break
                    send(buffer, n)
                    left -= n
                }
            }
        }
    }
}

/**
 * A file that is still being fetched: the answer starts at once and carries the bytes on as they come. Its length
 * is said when the source has said it; otherwise the answer is chunked. If the download fails half way the
 * connection is cut, which a player takes as a failed request and tries again.
 */
private suspend fun RoutingCall.sendArriving(answer: Answer.Arriving, range: Pair<Long, Long>?) {
    val size = answer.length
    if (range != null && size >= 0) {
        val from = range.first
        val last = if (range.second < 0) size - 1 else minOf(range.second, size - 1)
        if (from > last) {
            response.header(HttpHeaders.ContentRange, "bytes */$size")
            respond(HttpStatusCode.RequestedRangeNotSatisfiable)
            return
        }
        response.header(HttpHeaders.ContentRange, "bytes $from-$last/$size")
        respondBytesWriter(contentType(answer.type), HttpStatusCode.PartialContent, last - from + 1) {
            // Let go of the download when the body is out (a server may write it after this function has returned).
            try {
                answer.copyTo(from, last + 1) { bytes, n -> send(bytes, n) }
            } finally {
                answer.close()
            }
        }
        return
    }
    // A range of a file of unknown size cannot be answered as one; the player gets the whole file.
    respondBytesWriter(contentType(answer.type), HttpStatusCode.OK, size.takeIf { it >= 0 }) {
        try {
            answer.copyTo(0, -1) { bytes, n -> send(bytes, n) }
        } finally {
            answer.close()
        }
    }
}

private suspend fun ByteWriteChannel.send(bytes: ByteArray, n: Int) {
    writeFully(bytes, 0, n)
    flush()
}

private fun contentType(type: String): ContentType = runCatching { ContentType.parse(type) }.getOrDefault(ContentType.Application.OctetStream)
