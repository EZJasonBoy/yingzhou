package tvbox.engine.api.access

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.ApplicationCallPipeline
import io.ktor.server.application.call
import io.ktor.server.application.isHandled
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.request.queryString
import io.ktor.server.request.receive
import io.ktor.server.response.ApplicationSendPipeline
import io.ktor.server.response.respond
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.util.AttributeKey
import kotlinx.serialization.Serializable
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.ErrorBody
import tvbox.engine.core.model.LiveList
import tvbox.engine.core.model.PlayInfo
import java.net.InetAddress

@Serializable
data class PairRequest(val code: String = "", val name: String = "")

@Serializable
data class PairResponse(val token: String, val deviceId: String, val name: String)

@Serializable
data class LanDevice(val id: String, val name: String, val createdAt: Long, val lastSeenAt: Long, val lastAddress: String)

@Serializable
data class LanUpdate(val enabled: Boolean)

/** `GET /api/v1/lan`: the LAN sharing switch and what goes with it. Only for callers on the engine's machine. */
@Serializable
data class LanStatus(
    /** False where the engine cannot share (the Android app). */
    val supported: Boolean,
    val enabled: Boolean,
    /** Started with `--lan`: always on, the switch does nothing. */
    val forced: Boolean,
    val listening: Boolean,
    val name: String = "",
    val port: Int = 0,
    val addresses: List<String> = emptyList(),
    val discoverable: Boolean = false,
    val error: String = "",
    /** The pairing code showing now (only while sharing is on), and until when it is good (epoch ms). */
    val code: String = "",
    val codeExpiresAt: Long = 0,
    /** Pairing is locked after too many wrong codes until then (epoch ms); 0 when it is not. */
    val lockedUntil: Long = 0,
    val devices: List<LanDevice> = emptyList(),
)

private val GrantKey = AttributeKey<AccessControl.Grant>("tvbox.access.grant")

/** Who the call acts for, once [installAccess] let it in; null on public routes. */
val ApplicationCall.accessGrant: AccessControl.Grant? get() = attributes.getOrNull(GrantKey)

/** The caller's address is this machine's (127.0.0.1, ::1). */
fun ApplicationCall.peerIsLoopback(): Boolean =
    runCatching { InetAddress.getByName(request.local.remoteAddress).isLoopbackAddress }.getOrDefault(false)

/**
 * A caller on this machine that also addressed the engine by a loopback name. The second half keeps out web pages
 * in a local browser that reach 127.0.0.1 under their own host name (DNS rebinding), as `/file/` does.
 */
fun ApplicationCall.isLocal(): Boolean {
    val header = request.headers[HttpHeaders.Host]
    val host = when {
        header == null -> request.local.serverHost
        header.startsWith("[") -> header.substringBefore(']') + "]"
        else -> header.substringBefore(':')
    }.lowercase()
    return peerIsLoopback() && (host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1")
}

/**
 * Puts [access] in front of every route of the application, and adds `/api/v1/pair` and `/api/v1/lan`.
 *
 * In order: public routes (`GET /api/v1/info`, `POST /api/v1/pair`, [AccessControl.publicPrefixes]) → callers on
 * this machine → a valid `tvsig` on a GET outside `/api/` → (sharing off: 403) → a paired device's bearer token →
 * 401. Anything not let in is refused; routes added later are covered without doing anything.
 *
 * Engine addresses in what the engine sends back (play answers, live lists, HLS playlists) are signed for the caller,
 * so players reach them without our header.
 */
fun Application.installAccess(access: AccessControl) {
    intercept(ApplicationCallPipeline.Plugins) {
        if (call.isHandled) return@intercept
        val path = call.request.path()
        val method = call.request.httpMethod
        val local = call.isLocal()
        if (isPublic(path, method, access)) {
            if (local) call.attributes.put(GrantKey, AccessControl.Grant(AccessControl.LOCAL))
            return@intercept
        }
        if (local) {
            call.attributes.put(GrantKey, AccessControl.Grant(AccessControl.LOCAL))
            return@intercept
        }
        val query = call.request.queryString()
        if ((method == HttpMethod.Get || method == HttpMethod.Head) && query.contains(AccessControl.PARAM)) {
            access.checkSignature(path, query, call.peerIsLoopback())?.let {
                call.attributes.put(GrantKey, it)
                return@intercept
            }
        }
        if (!access.sharing) {
            call.respond(HttpStatusCode.Forbidden, ErrorBody(ApiError("LAN_SHARING_OFF", "局域网共享没有开启")))
            finish()
            return@intercept
        }
        val bearer = call.request.headers[HttpHeaders.Authorization]?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }?.substring(7)?.trim()
        val device = bearer?.let { access.deviceForToken(it) }
        if (device == null) {
            call.response.headers.append(HttpHeaders.WWWAuthenticate, "Bearer")
            val message = if (bearer == null) "需要先与这台引擎配对" else "令牌无效或已被撤销，请重新配对"
            call.respond(HttpStatusCode.Unauthorized, ErrorBody(ApiError("UNAUTHORIZED", message)))
            finish()
            return@intercept
        }
        access.seen(device, call.request.local.remoteAddress)
        call.attributes.put(GrantKey, AccessControl.Grant(device.id))
    }

    sendPipeline.intercept(ApplicationSendPipeline.Before) { message ->
        val grant = call.accessGrant ?: return@intercept
        when (message) {
            is PlayInfo -> proceedWith(UrlSigner(call, access, grant, AccessControl.PLAY_TTL_MS).play(message))
            is LiveList -> proceedWith(UrlSigner(call, access, grant, AccessControl.LIVE_TTL_MS).live(message))
            is tvbox.engine.core.model.LiveCatchup -> proceedWith(UrlSigner(call, access, grant, AccessControl.PLAY_TTL_MS).catchup(message))
            is TextContent -> if (message.contentType.contentSubtype.contains("mpegurl", ignoreCase = true)) {
                proceedWith(TextContent(UrlSigner(call, access, grant, AccessControl.PLAY_TTL_MS).hls(message.text), message.contentType, message.status))
            }
        }
    }

    routing {
        post("/api/v1/pair") {
            val req = runCatching { call.receive<PairRequest>() }.getOrDefault(PairRequest())
            when (val r = access.pair(req.code, req.name, call.request.local.remoteAddress)) {
                is AccessControl.PairResult.Paired -> call.respond(PairResponse(r.token, r.device.id, r.device.name))
                AccessControl.PairResult.CodeRequired ->
                    call.respond(HttpStatusCode.BadRequest, ErrorBody(ApiError("PAIR_CODE_REQUIRED", "请输入引擎上显示的配对码")))
                is AccessControl.PairResult.Wrong ->
                    call.respond(HttpStatusCode.Forbidden, ErrorBody(ApiError("PAIR_CODE_WRONG", "配对码不对或已过期，还能再试 ${r.triesLeft} 次")))
                is AccessControl.PairResult.Locked -> {
                    val seconds = (r.retryAfterMs + 999) / 1000
                    call.response.headers.append(HttpHeaders.RetryAfter, seconds.toString())
                    call.respond(HttpStatusCode.TooManyRequests, ErrorBody(ApiError("PAIR_LOCKED", "错误次数太多，请 $seconds 秒后再试；引擎上会换一个新的配对码")))
                }
                AccessControl.PairResult.Off ->
                    call.respond(HttpStatusCode.Forbidden, ErrorBody(ApiError("LAN_SHARING_OFF", "局域网共享没有开启")))
            }
        }

        // Only the app on the engine's own machine manages sharing. Checked here again, whatever path matched.
        route("/api/v1/lan") {
            get {
                if (!call.requireLocal()) return@get
                call.respond(access.lanStatus())
            }
            put {
                if (!call.requireLocal()) return@put
                val req = call.receive<LanUpdate>()
                access.setSharing(req.enabled)
                access.host?.apply(access.sharing)
                call.respond(access.lanStatus())
            }
            post("/code") {
                if (!call.requireLocal()) return@post
                if (access.sharing) access.newCode()
                call.respond(access.lanStatus())
            }
            delete("/devices/{id}") {
                if (!call.requireLocal()) return@delete
                if (access.revoke(call.parameters["id"].orEmpty())) {
                    call.respond(HttpStatusCode.NoContent)
                } else {
                    call.respond(HttpStatusCode.NotFound, ErrorBody(ApiError("NOT_FOUND", "没有这台设备")))
                }
            }
        }
    }
}

private suspend fun ApplicationCall.requireLocal(): Boolean {
    if (isLocal()) return true
    respond(HttpStatusCode.Forbidden, ErrorBody(ApiError("LOCAL_ONLY", "只能在引擎所在的设备上操作")))
    return false
}

/** The status for the local app; while sharing is on there is always a code to show. */
fun AccessControl.lanStatus(): LanStatus {
    val host = host?.status()
    val code = if (sharing) codeOrNew() else null
    return LanStatus(
        supported = supported && host != null,
        enabled = sharing,
        forced = forced,
        listening = host?.listening ?: false,
        name = host?.name.orEmpty(),
        port = host?.port ?: 0,
        addresses = host?.addresses.orEmpty(),
        discoverable = host?.discoverable ?: false,
        error = host?.error.orEmpty(),
        code = code?.code.orEmpty(),
        codeExpiresAt = code?.expiresAt ?: 0,
        lockedUntil = lockedUntil(),
        devices = devices().map { LanDevice(it.id, it.name, it.createdAt, it.lastSeenAt, it.lastAddress) },
    )
}

private fun isPublic(path: String, method: HttpMethod, access: AccessControl): Boolean {
    if (path == "/api/v1/info" && (method == HttpMethod.Get || method == HttpMethod.Head)) return true
    if (path == "/api/v1/pair" && method == HttpMethod.Post) return true
    val prefixes = access.publicPrefixes
    return prefixes.isNotEmpty() && prefixes.any { path.startsWith(it) } && Canonical.mediaPath(path)
}

/**
 * Signs the engine's own addresses in an answer for [grant]: those on 127.0.0.1 / localhost at the engine's port,
 * and those on the host name the caller used (what `forClient` rewrites them to for LAN clients). Addresses inherit
 * the expiry of the signed request they came from.
 */
private class UrlSigner(call: ApplicationCall, private val access: AccessControl, private val grant: AccessControl.Grant, ttl: Long) {
    private val port = call.request.local.localPort
    private val loopbacks = listOf("http://127.0.0.1:$port/", "http://localhost:$port/")
    private val self = call.request.headers[HttpHeaders.Host]?.let { "http://$it/" }
    private val expiresAt = grant.expiresAt ?: (System.currentTimeMillis() + ttl)

    private fun own(url: String): Boolean = loopbacks.any { url.startsWith(it) } || (self != null && url.startsWith(self))

    fun sign(url: String): String {
        if (!own(url)) return url
        val path = url.substringAfter("://").let { "/" + it.substringAfter('/', "") }.substringBefore('?')
        if (!Canonical.mediaPath(path)) return url
        return access.sign(url, grant.subject, expiresAt)
    }

    fun play(info: PlayInfo): PlayInfo = info.copy(url = sign(info.url), sniff = info.sniff?.let { it.copy(pageUrl = sign(it.pageUrl)) })

    fun live(list: LiveList): LiveList = list.copy(
        groups = list.groups.map { g -> g.copy(channels = g.channels.map { c -> c.copy(urls = c.urls.map { it.copy(url = sign(it.url)) }) }) },
    )

    fun catchup(c: tvbox.engine.core.model.LiveCatchup): tvbox.engine.core.model.LiveCatchup =
        c.copy(url = sign(c.url), alternates = c.alternates.map { it.copy(url = sign(it.url)) })

    /**
     * In playlists the host name of the request comes from a player, and may be a CDN's (players send the stream's
     * headers to every address): there only the engine's playlist and proxy endpoints count as its own.
     */
    fun hls(text: String): String = text.lineSequence().joinToString("\n") { line ->
        if (line.startsWith("#")) {
            URI_ATTR.replace(line) { m -> "URI=\"" + hlsUrl(m.groupValues[1]) + "\"" }
        } else {
            hlsUrl(line)
        }
    }

    private fun hlsUrl(url: String): String {
        val trimmed = url.trim()
        if (loopbacks.any { trimmed.startsWith(it) }) return sign(trimmed)
        // hls/: the segments, keys and maps of a stream the engine caches (StreamCacheRoutes).
        if (self != null && (trimmed.startsWith(self + "m3u8?") || trimmed.startsWith(self + "proxy?") || trimmed.startsWith(self + "hls/"))) return sign(trimmed)
        // dl/: the files of a finished download (DownloadRoutes).
        if (self != null && trimmed.startsWith(self + "dl/")) return sign(trimmed)
        return url
    }

    companion object {
        private val URI_ATTR = Regex("URI=\"([^\"]*)\"")
    }
}

@Suppress("unused")
private val HLS = ContentType("application", "vnd.apple.mpegurl")
