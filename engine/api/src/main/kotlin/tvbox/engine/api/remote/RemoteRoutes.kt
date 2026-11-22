package tvbox.engine.api.remote

import io.ktor.http.CacheControl
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.install
import io.ktor.server.application.pluginOrNull
import io.ktor.server.response.cacheControl
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondRedirect
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import io.ktor.server.websocket.DefaultWebSocketServerSession
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.pingPeriod
import io.ktor.server.websocket.timeout
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.access.accessGrant
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.ErrorBody
import java.util.concurrent.ConcurrentHashMap
import kotlin.time.Duration.Companion.seconds

/**
 * The remote control over HTTP (docs/protocol.md, "遥控"):
 *
 * - `GET /api/v1/remote/screens`: the screens that can be driven now;
 * - `WS /api/v1/remote/screen`: a client registers as a screen;
 * - `WS /api/v1/remote/control?screen=<id>`: a remote drives one;
 * - `/remote/`: the web remote, a static page (it pairs itself through `POST /api/v1/pair`).
 *
 * Who gets in is the access plugin's business, as for every route; the page alone is public. A connection whose
 * device is revoked, or that outlives LAN sharing, is cut within [RECHECK].
 */
fun Application.installRemote(hub: RemoteHub, access: AccessControl) {
    if (pluginOrNull(WebSockets) == null) {
        install(WebSockets) {
            // Pings from the engine: a screen or a phone that vanished (Wi-Fi gone, lid closed) is noticed and removed.
            pingPeriod = 15.seconds
            timeout = 20.seconds
            maxFrameSize = RemoteHub.MAX_SCREEN_MESSAGE * 4L
        }
    }
    routing { remoteRoutes(hub, access) }
}

private val RECHECK = 3.seconds
private val HELLO_TIMEOUT = 10.seconds

private fun Route.remoteRoutes(hub: RemoteHub, access: AccessControl) {
    get("/api/v1/remote/screens") { call.respond(hub.screens()) }

    // With the subprotocol (browsers, which also carry their token in it) and without (scripts, older clients).
    for (protocol in listOf(RemoteHub.PROTOCOL, null)) {
        webSocket("/api/v1/remote/screen", protocol) {
            val subject = call.accessGrant?.subject ?: return@webSocket close(CloseReason(RemoteHub.NOT_ALLOWED.toShort(), "not allowed"))
            serve(access, subject, RemoteHub.MAX_SCREEN_MESSAGE) { peer ->
                val hello = withTimeoutOrNull(HELLO_TIMEOUT) { incoming.nextText(RemoteHub.MAX_SCREEN_MESSAGE) }
                    ?: throw RemoteHub.Refused(RemoteHub.BAD_MESSAGE, "expected hello")
                val screen = hub.screenConnected(hello, subject, peer)
                Attached(screen::receive, screen::closed)
            }
        }
        webSocket("/api/v1/remote/control", protocol) {
            val subject = call.accessGrant?.subject ?: return@webSocket close(CloseReason(RemoteHub.NOT_ALLOWED.toShort(), "not allowed"))
            val screenId = call.request.queryParameters["screen"].orEmpty()
            val name = if (subject == AccessControl.LOCAL) "本机" else access.devices().firstOrNull { it.id == subject }?.name ?: "手机"
            serve(access, subject, RemoteHub.MAX_CONTROLLER_MESSAGE) { peer ->
                val controller = hub.controllerConnected(screenId, subject, name, peer)
                Attached(controller::receive, controller::closed)
            }
        }
    }

    get("/remote") { call.respondRedirect("/remote/", permanent = false) }
    get("/remote/{file?}") { call.respondRemoteFile(call.parameters["file"].orEmpty().ifEmpty { "index.html" }) }
    // The console's pages (订阅与站点, 数据, 日志与崩溃, 设置), each loaded when it is first opened.
    get("/remote/pages/{file}") { call.respondRemoteFile("pages/" + call.parameters["file"].orEmpty()) }
}

/** One of the web remote's files by its name in [RemotePage]'s list; anything else is 404. */
private suspend fun ApplicationCall.respondRemoteFile(name: String) {
    val file = RemotePage.file(name)
    if (file == null) {
        respond(HttpStatusCode.NotFound, ErrorBody(ApiError("NOT_FOUND", "没有这个文件")))
        return
    }
    // The page shows names that come from third-party sites; nothing but its own script may run in it.
    response.header("Content-Security-Policy", RemotePage.CSP)
    response.header("X-Content-Type-Options", "nosniff")
    response.header("Referrer-Policy", "no-referrer")
    response.cacheControl(CacheControl.NoCache(null))
    respondBytes(file.bytes, file.type)
}

/** What a connection turned into once the hub took it: where its messages go, and what to do when it ends. */
private class Attached(val receive: (String) -> Unit, val closed: () -> Unit)

/**
 * Runs one connection: [attach] hands it to the hub (or throws [RemoteHub.Refused]), then messages go to the hub and
 * what the hub sends goes out, until either side ends it or [subject] may not be here any more.
 */
private suspend fun DefaultWebSocketServerSession.serve(
    access: AccessControl,
    subject: String,
    maxMessage: Int,
    attach: suspend (RemoteHub.Peer) -> Attached,
) {
    val peer = SocketPeer()
    val reader = launch {
        var attached: Attached? = null
        try {
            attached = attach(peer)
            while (isActive) {
                val text = incoming.nextText(maxMessage) ?: break
                attached.receive(text)
            }
        } catch (e: RemoteHub.Refused) {
            peer.close(e.code, e.reason)
        } finally {
            attached?.closed?.invoke()
            peer.close(CloseReason.Codes.NORMAL.code.toInt(), "")
        }
    }
    val guard = launch {
        while (isActive) {
            delay(RECHECK)
            if (!access.stillAllowed(subject)) peer.close(RemoteHub.NOT_ALLOWED, "not allowed any more")
        }
    }
    try {
        for (text in peer.out) send(Frame.Text(text))
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        // The other end went away while something was on its way to it.
    } finally {
        guard.cancel()
        reader.cancel()
    }
    close(peer.reason ?: CloseReason(CloseReason.Codes.NORMAL, ""))
}

/** The next text message; null when the connection ended. One that is too long ends it. */
private suspend fun ReceiveChannel<Frame>.nextText(max: Int): String? {
    while (true) {
        val frame = receiveCatching().getOrNull() ?: return null
        if (frame !is Frame.Text) continue
        val text = frame.readText()
        if (text.length > max) throw RemoteHub.Refused(CloseReason.Codes.TOO_BIG.code.toInt(), "message too long")
        return text
    }
}

/** A queue in front of the socket, so the hub never waits for a slow phone: when it is full the oldest goes. */
private class SocketPeer : RemoteHub.Peer {
    val out = Channel<String>(capacity = 256, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    @Volatile var reason: CloseReason? = null
        private set

    override fun send(text: String) {
        out.trySend(text)
    }

    @Synchronized
    override fun close(code: Int, reason: String) {
        if (this.reason == null) this.reason = CloseReason(code.toShort(), reason)
        out.close()
    }
}

/** Whether who a connection acts for may still be here: this machine always, a device while paired and sharing is on. */
private fun AccessControl.stillAllowed(subject: String): Boolean =
    subject == AccessControl.LOCAL || (sharing && devices().any { it.id == subject })

/**
 * The web remote's files, read once from the engine's resources (`resources/remote/`): a fixed list, no paths. The
 * console's pages sit in `pages/` and are named here with that prefix; nothing else under it is served.
 */
internal object RemotePage {
    class File(val bytes: ByteArray, val type: ContentType)

    const val CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' ws: wss:; " +
        "manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    private val script = ContentType("text", "javascript").withParameter("charset", "utf-8")

    /** The modules `remote.js` loads for the console's pages (`import('./pages/<name>.js')`). */
    val pages = listOf("sources", "data", "logs", "settings")

    private val types = mapOf(
        "index.html" to ContentType.Text.Html.withParameter("charset", "utf-8"),
        "remote.css" to ContentType.Text.CSS.withParameter("charset", "utf-8"),
        "remote.js" to script,
        "icon.svg" to ContentType.Image.SVG,
        "manifest.webmanifest" to ContentType("application", "manifest+json"),
    ) + pages.associate { "pages/$it.js" to script }
    private val cache = ConcurrentHashMap<String, File>()

    /** Development: `-Dtvbox.remote.dir=<folder>` serves the files from there, read again each time. */
    private val devDir = System.getProperty("tvbox.remote.dir")?.takeIf { it.isNotBlank() }?.let { java.io.File(it) }

    fun file(name: String): File? {
        val type = types[name] ?: return null
        if (devDir != null) return java.io.File(devDir, name).takeIf { it.isFile }?.let { File(it.readBytes(), type) }
        cache[name]?.let { return it }
        val bytes = RemotePage::class.java.classLoader.getResourceAsStream("remote/$name")?.use { it.readBytes() } ?: return null
        return File(bytes, type).also { cache[name] = it }
    }
}
