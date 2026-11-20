package tvbox.engine.api.remote

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** One screen in `GET /api/v1/remote/screens`. */
@Serializable
data class RemoteScreenInfo(
    val id: String,
    val name: String,
    /** `windows`, `macos`, `linux`, `android`… as the screen says. */
    val platform: String = "",
    /** The screen's layout: `desktop`, `tv`, `phone` or `tablet`. */
    val form: String = "",
    val version: String = "",
    /** What it shows now, in a few words: the `title` of its last state. */
    val title: String = "",
    val controllers: Int = 0,
    val connectedAt: Long = 0,
)

/**
 * The LAN remote control's meeting point (docs/protocol.md, "遥控").
 *
 * A client that lets itself be driven registers as a *screen* and keeps a connection open; a phone opens a
 * *controller* connection to one screen. The hub passes the screen's state to its controllers (the latest at once,
 * then every change) and the controllers' commands to the screen, with the screen's answers back. It does not look
 * into either: what a state holds and which commands exist is between the client and the remote (and may grow
 * without a new engine).
 *
 * Who may connect is decided before the hub is reached (the access plugin: this machine, or a paired device while
 * sharing is on). Screens are only those that connected themselves, so a client that has not switched 「允许手机遥控」
 * on is not here, and cannot be driven. One hub is shared by every listener of the engine: the screen usually
 * comes in over 127.0.0.1 and the phone over a LAN address. Thread-safe; nothing here blocks.
 */
class RemoteHub(private val clock: () -> Long = System::currentTimeMillis) {
    /** The other end of a connection. Neither call may block; [close] also delivers what was sent before it. */
    interface Peer {
        fun send(text: String)

        fun close(code: Int, reason: String)
    }

    /** A connection the hub does not take: closed with [code] (a WebSocket close code) and [reason]. */
    class Refused(val code: Int, val reason: String) : Exception(reason)

    private val lock = Any()
    private val screens = LinkedHashMap<String, Screen>()
    private var sessions = 0L

    fun screens(): List<RemoteScreenInfo> = synchronized(lock) { screens.values.map { it.info() } }

    /**
     * A screen said hello: `{"type":"hello","id","name","platform","form","version"}`. [subject] is who it acts for
     * (see `AccessControl.Grant`). A screen that was here under the same id is replaced: a client that reconnects
     * before the engine noticed its old connection is gone.
     */
    fun screenConnected(hello: String, subject: String, peer: Peer): Screen {
        val msg = parse(hello)?.takeIf { it.string("type") == "hello" } ?: throw Refused(BAD_MESSAGE, "expected hello")
        val id = msg.string("id").orEmpty()
        if (!ID.matches(id)) throw Refused(BAD_MESSAGE, "bad screen id")
        val screen = Screen(
            id = id,
            name = clean(msg.string("name"), 40).ifEmpty { "映舟" },
            platform = clean(msg.string("platform"), 20),
            form = clean(msg.string("form"), 20),
            version = clean(msg.string("version"), 20),
            subject = subject,
            peer = peer,
        )
        synchronized(lock) {
            val old = screens[id]
            if (old == null && screens.size >= MAX_SCREENS) throw Refused(TOO_MANY, "too many screens")
            old?.drop(REPLACED, "replaced by a newer connection")
            screens[id] = screen
            peer.send(buildJsonObject { put("type", "welcome"); put("id", id); put("controllers", 0) }.toString())
        }
        return screen
    }

    /** A controller for the screen [screenId]; [name] is what the screen may show for it (the paired device's name). */
    fun controllerConnected(screenId: String, subject: String, name: String, peer: Peer): Controller = synchronized(lock) {
        val screen = screens[screenId] ?: throw Refused(NO_SCREEN, "no such screen")
        if (screen.controllers.size >= MAX_CONTROLLERS) throw Refused(TOO_MANY, "too many controllers")
        val controller = Controller("c${++sessions}", screen, subject, clean(name, 40), peer)
        screen.controllers[controller.session] = controller
        peer.send(buildJsonObject { put("type", "screen"); put("screen", screen.describe()) }.toString())
        screen.state?.let { peer.send(stateMessage(it)) }
        screen.tellControllers()
        controller
    }

    inner class Screen internal constructor(
        val id: String,
        val name: String,
        val platform: String,
        val form: String,
        val version: String,
        val subject: String,
        private val peer: Peer,
    ) {
        val connectedAt = clock()
        internal var state: JsonElement? = null
        internal val controllers = LinkedHashMap<String, Controller>()

        internal fun info() = RemoteScreenInfo(
            id, name, platform, form, version,
            title = clean((state as? JsonObject)?.string("title"), 120),
            controllers = controllers.size,
            connectedAt = connectedAt,
        )

        internal fun describe() = buildJsonObject {
            put("id", id); put("name", name); put("platform", platform); put("form", form); put("version", version)
        }

        /** A message from the screen: its state, the answer to a command, or a ping. Anything else is dropped. */
        fun receive(text: String) {
            val msg = parse(text) ?: return
            when (msg.string("type")) {
                "state" -> {
                    val next = msg["state"] as? JsonObject ?: return
                    synchronized(lock) {
                        if (screens[id] !== this) return
                        state = next
                        val out = stateMessage(next)
                        controllers.values.forEach { it.peer.send(out) }
                    }
                }
                "result" -> {
                    val to = msg.string("to") ?: return
                    val out = buildJsonObject {
                        put("type", "result")
                        put("id", msg["id"] ?: JsonNull)
                        put("ok", (msg["ok"] as? JsonPrimitive)?.content == "true")
                        put("message", clean(msg.string("message"), 200))
                    }.toString()
                    synchronized(lock) { controllers[to]?.peer?.send(out) }
                }
                "ping" -> peer.send(PONG)
            }
        }

        /** The screen's connection ended: it is off the list and its controllers are told and let go. */
        fun closed() = synchronized(lock) {
            if (screens[id] === this) screens.remove(id)
            drop(GONE, "the screen is gone")
        }

        internal fun drop(code: Int, reason: String) {
            controllers.values.forEach {
                it.peer.send(GONE_MESSAGE)
                it.peer.close(GONE, "the screen is gone")
            }
            controllers.clear()
            peer.close(code, reason)
        }

        internal fun command(from: Controller, msg: JsonObject) {
            val name = msg.string("name")?.takeIf { it.isNotEmpty() && it.length <= 40 } ?: return
            peer.send(
                buildJsonObject {
                    put("type", "command")
                    put("from", from.session)
                    put("id", msg["id"] as? JsonPrimitive ?: JsonNull)
                    put("name", name)
                    put("args", msg["args"] as? JsonObject ?: JsonObject(emptyMap()))
                }.toString(),
            )
        }

        internal fun tellControllers() {
            peer.send(
                buildJsonObject {
                    put("type", "controllers")
                    put("count", controllers.size)
                    put("names", buildJsonArray { controllers.values.forEach { add(JsonPrimitive(it.name)) } })
                }.toString(),
            )
        }
    }

    inner class Controller internal constructor(
        val session: String,
        val screen: Screen,
        val subject: String,
        val name: String,
        internal val peer: Peer,
    ) {
        /** A message from the controller: a command for the screen, or a ping. */
        fun receive(text: String) {
            val msg = parse(text) ?: return
            when (msg.string("type")) {
                "command" -> synchronized(lock) { if (screen.controllers[session] === this) screen.command(this, msg) }
                "ping" -> peer.send(PONG)
            }
        }

        fun closed() = synchronized(lock) {
            if (screen.controllers.remove(session) != null) screen.tellControllers()
        }
    }

    companion object {
        /** The WebSocket subprotocol of both routes. */
        const val PROTOCOL = "yingzhou.remote.v1"

        /** A paired token may come as a second subprotocol, `yingzhou.token.<token>` (browsers cannot set headers). */
        const val TOKEN_PROTOCOL = "yingzhou.token."

        // Close codes (4000–4999 are the application's).
        const val BAD_MESSAGE = 4400
        const val NOT_ALLOWED = 4401
        const val NO_SCREEN = 4404
        const val REPLACED = 4409
        const val GONE = 4410
        const val TOO_MANY = 4429

        const val MAX_SCREENS = 32
        const val MAX_CONTROLLERS = 8

        /** The longest message taken from a screen (a state with a long episode list) and from a controller. */
        const val MAX_SCREEN_MESSAGE = 512 * 1024
        const val MAX_CONTROLLER_MESSAGE = 32 * 1024

        private val ID = Regex("[A-Za-z0-9._-]{1,64}")
        private const val PONG = """{"type":"pong"}"""
        private const val GONE_MESSAGE = """{"type":"gone"}"""
        private val json = Json { ignoreUnknownKeys = true }

        private fun parse(text: String): JsonObject? = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull()

        private fun JsonObject.string(name: String): String? = (this[name] as? JsonPrimitive)?.takeIf { it.isString }?.content

        private fun clean(text: String?, max: Int): String = text.orEmpty().filter { !it.isISOControl() }.trim().take(max)

        private fun stateMessage(state: JsonElement): String = buildJsonObject { put("type", "state"); put("state", state) }.toString()
    }
}
