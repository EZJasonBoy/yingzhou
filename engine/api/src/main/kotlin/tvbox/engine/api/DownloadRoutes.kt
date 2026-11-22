package tvbox.engine.api

import io.ktor.http.CacheControl
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.cacheControl
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondOutputStream
import io.ktor.server.response.respondText
import io.ktor.server.response.respondTextWriter
import io.ktor.server.routing.Route
import io.ktor.server.routing.RoutingCall
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.download.DownloadManager
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.DownloadAddRequest
import tvbox.engine.core.model.DownloadExportRequest
import tvbox.engine.core.model.DownloadList
import tvbox.engine.core.model.DownloadSettingsInfo
import tvbox.engine.core.model.DownloadSettingsUpdate
import tvbox.engine.core.model.ErrorBody
import java.net.URLEncoder

/**
 * Downloads over HTTP:
 *
 * - `/api/v1/downloads`: the list (GET), adding episodes (POST), and per download pause / resume / delete / export;
 *   `/events` sends the list again whenever it changes (SSE); `/settings` is the folder and how many run at once.
 * - `/dl/<id>/index.m3u8`, `/dl/<id>/<number>.<ext>`, `/dl/<id>/<file>`: a finished download as a player gets it
 *   (`/play/resolve` hands these out). They are outside `/api/`, so a player on another device opens them with the
 *   signature the engine puts on them, like the stream cache's `/hls/` addresses.
 * - `/dl/<id>/export`: the download as one file, for saving on another device.
 */
fun Route.downloadRoutes(engine: Engine) {
    get("/dl/{id}/{file}") {
        val downloads = engine.downloads
        val id = call.parameters["id"].orEmpty()
        val name = call.parameters["file"].orEmpty()
        if (downloads == null) {
            call.respond(HttpStatusCode.NotFound, ErrorBody(ApiError("NOT_FOUND", "no such download")))
            return@get
        }
        when {
            name.endsWith(".m3u8") -> {
                val text = downloads.offlinePlaylist(id, call.origin() + "/dl/$id/", name)
                if (text == null) call.respond(HttpStatusCode.NotFound, ErrorBody(ApiError("NOT_FOUND", "no such download")))
                else call.respondText(text, ContentType("application", "vnd.apple.mpegurl"))
            }
            name == "export" || name.startsWith("export.") -> {
                val export = withContext(Dispatchers.IO) { downloads.exportOf(id) }
                call.response.header(HttpHeaders.ContentDisposition, attachment(export.fileName))
                val type = if (export.format == "ts") ContentType("video", "mp2t") else ContentType("video", export.format)
                call.respondOutputStream(type) { withContext(Dispatchers.IO) { export.write(this@respondOutputStream) } }
            }
            else -> {
                val found = withContext(Dispatchers.IO) { downloads.offlineFile(id, name) }
                if (found == null) call.respond(HttpStatusCode.NotFound, ErrorBody(ApiError("NOT_FOUND", "no such file in the download")))
                else call.sendStored(found.first, found.second, byteRange(call.request.headers[HttpHeaders.Range]))
            }
        }
    }

    route("/api/v1/downloads") {
        get { call.respond(DownloadList(available = engine.downloads != null, items = engine.downloads?.list().orEmpty())) }
        post {
            val req = call.receive<DownloadAddRequest>()
            call.respond(DownloadList(available = true, items = engine.required().add(req.items)))
        }
        // The whole list, now and whenever it changes (a few times a second at most while downloads run).
        get("/events") {
            val downloads = engine.required()
            call.response.cacheControl(CacheControl.NoCache(null))
            call.respondTextWriter(ContentType.Text.EventStream) {
                var seen = -1L
                while (true) {
                    val version = withTimeoutOrNull(PING_MS) { downloads.changes.first { it != seen } }
                    if (version == null) {
                        write(": ping\n\n")
                    } else {
                        seen = version
                        write("event: downloads\ndata: " + EngineJson.encodeToString(DownloadList.serializer(), DownloadList(true, downloads.list())) + "\n\n")
                    }
                    flush()
                    delay(EVENT_GAP_MS)
                }
            }
        }
        get("/settings") { call.respond(engine.downloads?.settings() ?: DownloadSettingsInfo(available = false)) }
        put("/settings") { call.respond(withContext(Dispatchers.IO) { engine.required().updateSettings(call.receive<DownloadSettingsUpdate>()) }) }
        post("/{id}/pause") { call.respond(engine.required().pause(call.id())) }
        post("/{id}/resume") { call.respond(engine.required().resume(call.id())) }
        delete("/{id}") {
            engine.required().delete(call.id())
            call.respond(HttpStatusCode.NoContent)
        }
        // Writes the download as one file on the engine's machine (into the folder given, or the default one).
        post("/{id}/export") {
            val req = runCatching { call.receive<DownloadExportRequest>() }.getOrDefault(DownloadExportRequest())
            val id = call.id()
            call.respond(withContext(Dispatchers.IO) { engine.required().export(id, req.path) })
        }
    }
}

private const val PING_MS = 15_000L
private const val EVENT_GAP_MS = 400L

private fun Engine.required(): DownloadManager = downloads ?: throw EngineException.Unsupported("这台引擎不能下载（版本太旧）")

private fun RoutingCall.id(): String = parameters["id"].orEmpty()

/** The engine as this caller reaches it, e.g. `http://192.168.1.5:9978` for a TV on the LAN. */
private fun RoutingCall.origin(): String = "http://" + (request.headers[HttpHeaders.Host] ?: "127.0.0.1:${request.local.localPort}")

/** A download's name may be Chinese: the plain `filename` is a safe ASCII stand-in, `filename*` the real one. */
private fun attachment(name: String): String {
    val ascii = name.map { if (it.code in 0x20..0x7e && it != '"' && it != '\\') it else '_' }.joinToString("")
    return "attachment; filename=\"$ascii\"; filename*=UTF-8''" + URLEncoder.encode(name, "UTF-8").replace("+", "%20")
}
