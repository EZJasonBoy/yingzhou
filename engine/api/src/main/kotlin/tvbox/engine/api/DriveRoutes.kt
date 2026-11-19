package tvbox.engine.api

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.receive
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytesWriter
import io.ktor.server.routing.Route
import io.ktor.server.routing.RoutingCall
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.head
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import io.ktor.utils.io.writeFully
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import tvbox.engine.api.access.isLocal
import tvbox.engine.core.EngineException
import tvbox.engine.core.drive.DriveException
import tvbox.engine.core.drive.DriveRequest
import tvbox.engine.core.drive.DriveService
import tvbox.engine.core.drive.DriveUnlockRequest
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.ErrorBody
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.model.VodDetail

/**
 * Drives over HTTP (docs/protocol.md, "网盘"):
 *
 * - `/api/v1/drives`: the user's drives (never with a password or token), adding, changing, removing, testing;
 *   `/{id}/list?path=` a folder, `/{id}/unlock` an AList folder's password, `/{id}/detail?path=` a folder as a
 *   video, `/{id}/play?path=` a file as a [PlayInfo].
 * - `/drive/<id>/<path>`: a file of a drive, streamed by the engine with `Range` for players that cannot fetch it
 *   themselves. Like every engine address handed to a player it is signed for devices on the LAN (AccessPlugin).
 *
 * Folders of the engine's machine can be added or pointed elsewhere only from that machine.
 */
fun Route.driveRoutes(drives: DriveService) {
    route("/drive/{id}/{path...}") {
        get { call.sendDriveFile(drives, head = false) }
        head { call.sendDriveFile(drives, head = true) }
    }

    route("/api/v1/drives") {
        get { call.respond(drives.list()) }
        post { call.drive { call.respond(HttpStatusCode.Created, drives.add(call.receive<DriveRequest>(), call.isLocal())) } }
        post("/test") { call.drive { call.respond(drives.test(call.receive<DriveRequest>(), call.isLocal())) } }
        route("/{id}") {
            get { call.drive { call.respond(drives.get(call.driveId())) } }
            put { call.drive { call.respond(drives.update(call.driveId(), call.receive<DriveRequest>(), call.isLocal())) } }
            delete {
                call.drive {
                    drives.remove(call.driveId())
                    call.respond(HttpStatusCode.NoContent)
                }
            }
            get("/list") { call.drive { call.respond(drives.listFolder(call.driveId(), call.parameters["path"] ?: "/")) } }
            post("/unlock") {
                call.drive {
                    val req = call.receive<DriveUnlockRequest>()
                    call.respond(drives.unlock(call.driveId(), req.path, req.password))
                }
            }
            get("/detail") { call.drive { call.respond(drives.detail(call.driveId(), call.parameters["path"] ?: "/")) } }
            get("/play") {
                call.drive {
                    val path = call.parameters["path"]?.takeIf { it.isNotBlank() } ?: throw DriveException.bad("缺少参数 path")
                    call.respond(forClient(drives.play(call.driveId(), path, remote = !call.isLocal()), call))
                }
            }
        }
    }
}

/** `/play/resolve` for a `drive:` site (null for other sites), with the subtitles' addresses as the caller reaches the engine. */
internal suspend fun RoutingCall.drivePlay(drives: DriveService?, request: PlayRequest): PlayInfo? {
    if (drives == null || DriveService.driveOf(request.site) == null) return null
    return engineErrors { drives.resolveSite(request.site, request.episodeId, remote = !isLocal()) }
}

/** `/sites/{site}/detail` for a `drive:` site; null for other sites. */
internal suspend fun RoutingCall.driveDetail(drives: DriveService?): VodDetail? {
    val site = parameters["site"].orEmpty()
    if (drives == null || DriveService.driveOf(site) == null) return null
    return engineErrors { drives.detailSite(site, parameters["id"]?.takeIf { it.isNotBlank() } ?: "/") }
}

/** Drive failures as the errors the site routes answer with. */
private suspend fun <T> engineErrors(block: suspend () -> T): T = try {
    block()
} catch (e: DriveException) {
    throw when (e.status) {
        404 -> EngineException.NotFound(e.message.orEmpty())
        400 -> EngineException.BadRequest(e.message.orEmpty())
        else -> EngineException.SiteFailed(e.code, e.message.orEmpty())
    }
}

private fun RoutingCall.driveId(): String = parameters["id"].orEmpty()

private suspend fun ApplicationCall.drive(block: suspend () -> Unit) {
    try {
        block()
    } catch (e: DriveException) {
        respond(HttpStatusCode.fromValue(e.status), ErrorBody(ApiError(e.code, e.message.orEmpty())))
    }
}

/** Engine addresses in the answer as the caller reaches the engine (another device: by the address it used). */
private fun forClient(info: PlayInfo, call: ApplicationCall): PlayInfo {
    val loopback = "http://127.0.0.1:${call.request.local.localPort}/"
    val self = "http://" + (call.request.headers[HttpHeaders.Host] ?: "127.0.0.1:${call.request.local.localPort}") + "/"
    if (self == loopback) return info
    fun fix(url: String) = if (url.startsWith(loopback)) self + url.removePrefix(loopback) else url
    return info.copy(url = fix(info.url), subtitles = info.subtitles.map { it.copy(url = fix(it.url)) })
}

private suspend fun RoutingCall.sendDriveFile(drives: DriveService, head: Boolean) {
    val id = parameters["id"].orEmpty()
    val path = "/" + parameters.getAll("path").orEmpty().joinToString("/")
    val stream = try {
        drives.open(id, path, request.headers[HttpHeaders.Range], head)
    } catch (e: DriveException) {
        respond(HttpStatusCode.fromValue(e.status), ErrorBody(ApiError(e.code, e.message.orEmpty())))
        return
    }
    for ((name, value) in stream.headers) response.header(name, value)
    val status = HttpStatusCode.fromValue(stream.status)
    val type = runCatching { ContentType.parse(stream.contentType) }.getOrDefault(ContentType.Application.OctetStream)
    val body = stream.body
    if (body == null) {
        stream.close()
        respond(object : OutgoingContent.NoContent() {
            override val status = status
            override val contentType = type
            override val contentLength = stream.length
        })
        return
    }
    // The stream is closed by the body writer: a server may write the body after this function has returned.
    respondBytesWriter(type, status, stream.length) {
        try {
            withContext(Dispatchers.IO) {
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = body.read(buffer)
                    if (n < 0) break
                    if (n > 0) writeFully(buffer, 0, n)
                }
            }
        } finally {
            stream.close()
        }
    }
}
