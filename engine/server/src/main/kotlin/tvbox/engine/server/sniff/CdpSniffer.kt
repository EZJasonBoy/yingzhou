package tvbox.engine.server.sniff

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import tvbox.engine.core.model.SniffRequest
import tvbox.engine.core.play.SniffResult
import tvbox.engine.core.play.Sniffer
import java.io.File
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Sniffs pages in a headless Edge/Chrome driven over the DevTools protocol: each sniff opens a tab, loads the page
 * with the site's headers, and returns the first request the sniff rules accept, with the Referer/User-Agent/Cookie
 * the page used. The browser starts on first use, with its own profile, and quits after [idleMillis] without sniffs.
 */
class CdpSniffer(
    private val browser: File,
    private val profileDir: File,
    private val http: OkHttpClient,
    private val idleMillis: Long = 5 * 60_000,
    private val log: (String) -> Unit = { System.err.println(it) },
) : Sniffer {
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val busy = AtomicInteger()
    @Volatile private var session: CdpSession? = null
    private var idleJob: Job? = null

    override suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult? {
        val s = mutex.withLock {
            idleJob?.cancel()
            busy.incrementAndGet()
            session?.takeIf { it.isAlive } ?: withContext(Dispatchers.IO) { start() }.also { session = it }
        }
        try {
            return s.sniff(request, isMedia)
        } finally {
            if (busy.decrementAndGet() == 0) scheduleIdleClose()
        }
    }

    private fun scheduleIdleClose() {
        scope.launch {
            mutex.withLock {
                idleJob?.cancel()
                idleJob = scope.launch {
                    delay(idleMillis)
                    mutex.withLock {
                        if (busy.get() == 0) {
                            session?.close()
                            session = null
                        }
                    }
                }
            }
        }
    }

    fun close() {
        session?.close()
        session = null
    }

    private suspend fun start(): CdpSession {
        profileDir.mkdirs()
        val portFile = File(profileDir, "DevToolsActivePort")
        closeLeftover(portFile)
        portFile.delete()
        val process = ProcessBuilder(
            browser.absolutePath,
            "--headless=new",
            "--remote-debugging-port=0",
            "--user-data-dir=${profileDir.absolutePath}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-sync",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-gpu",
            "--mute-audio",
            "--autoplay-policy=no-user-gesture-required",
            // Keep cross-site iframes (players inside parser pages) in the page's own target, so one session sees
            // every request.
            "--disable-site-isolation-trials",
            "--disable-features=IsolateOrigins,site-per-process,Translate,MediaRouter",
            "about:blank",
        ).redirectOutput(ProcessBuilder.Redirect.DISCARD).redirectError(ProcessBuilder.Redirect.DISCARD).start()
        val launcher = process.toHandle()
        ChildProcesses.register(launcher)
        var browserProcess: ProcessHandle? = null
        try {
            // Edge's msedge.exe may hand off to a separate browser process and exit with 0; the port file still
            // shows up, so only an early failure exit code is fatal.
            val deadline = System.currentTimeMillis() + 20_000
            var lines: List<String> = emptyList()
            while (System.currentTimeMillis() < deadline) {
                lines = runCatching { portFile.readLines() }.getOrDefault(emptyList())
                if (lines.size >= 2) break
                if (!process.isAlive && process.exitValue() != 0) throw IOException("${browser.name} exited with ${process.exitValue()}")
                Thread.sleep(100)
            }
            if (lines.size < 2) throw IOException("${browser.name} did not open its DevTools port")
            val session = CdpSession(launcher, "ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}", http)
            // The process that actually serves DevTools, so it can be shut down with the engine.
            browserProcess = session.browserProcess()
            browserProcess?.let(ChildProcesses::register)
            log("sniffer: ${browser.name} started" + (browserProcess?.let { " (pid ${it.pid()})" } ?: ""))
            return session
        } catch (e: Exception) {
            ChildProcesses.kill(launcher)
            browserProcess?.let(ChildProcesses::kill)
            throw e
        }
    }

    /** A browser left running on this profile by an engine that was killed: ask it to quit. */
    private fun closeLeftover(portFile: File) {
        val lines = runCatching { portFile.readLines() }.getOrNull() ?: return
        if (lines.size < 2) return
        val closed = CompletableFuture<Unit>()
        val ws = http.newWebSocket(
            Request.Builder().url("ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}").build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send("""{"id":1,"method":"Browser.close"}""")
                    log("sniffer: closing a browser left over from a previous run")
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    closed.complete(Unit)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    closed.complete(Unit)
                }
            },
        )
        runCatching { closed.get(3, TimeUnit.SECONDS) }
        ws.cancel()
    }

    companion object {
        /** Edge or Chrome/Chromium, or `TVBOX_BROWSER`. Null when none is installed. */
        fun findBrowser(): File? {
            System.getenv("TVBOX_BROWSER")?.let(::File)?.takeIf { it.canExecute() }?.let { return it }
            val os = System.getProperty("os.name").lowercase()
            val candidates = when {
                os.contains("win") -> {
                    val roots = listOfNotNull(System.getenv("ProgramFiles(x86)"), System.getenv("ProgramFiles"), System.getenv("LOCALAPPDATA"))
                    roots.flatMap { root ->
                        listOf(
                            "Microsoft\\Edge\\Application\\msedge.exe",
                            "Google\\Chrome\\Application\\chrome.exe",
                            "Chromium\\Application\\chrome.exe",
                        ).map { File(root, it) }
                    }
                }
                os.contains("mac") -> listOf(
                    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
                    "/Applications/Chromium.app/Contents/MacOS/Chromium",
                ).map(::File)
                else -> {
                    val names = listOf("chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "microsoft-edge")
                    val path = System.getenv("PATH").orEmpty().split(File.pathSeparatorChar)
                    names.flatMap { n -> path.map { File(it, n) } }
                }
            }
            return candidates.firstOrNull { it.isFile && it.canExecute() }
        }
    }
}

/** One browser process and its DevTools connection. */
internal class CdpSession(launcher: ProcessHandle, wsUrl: String, http: OkHttpClient) {
    @Volatile private var process: ProcessHandle = launcher
    private val nextId = AtomicInteger()
    private val pending = ConcurrentHashMap<Int, CompletableDeferred<JsonObject>>()
    private val listeners = CopyOnWriteArrayList<(JsonObject) -> Unit>()
    @Volatile private var closed = false
    private val socket: WebSocket
    private var userAgent: String? = null

    val isAlive: Boolean get() = !closed && process.isAlive

    /** The browser process behind DevTools (the launcher may have exited); also what [isAlive] watches from now on. */
    suspend fun browserProcess(): ProcessHandle? {
        val pid = runCatching {
            call("SystemInfo.getProcessInfo")["processInfo"]?.jsonArray
                ?.firstOrNull { (it as? JsonObject)?.string("type") == "browser" }
                ?.let { ((it as JsonObject)["id"] as? JsonPrimitive)?.content?.toLongOrNull() }
        }.getOrNull() ?: return null
        return ProcessHandle.of(pid).orElse(null)?.also { process = it }
    }

    init {
        val opened = CompletableFuture<Unit>()
        socket = http.newBuilder().readTimeout(0, TimeUnit.MILLISECONDS).build()
            .newWebSocket(Request.Builder().url(wsUrl).build(), object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened.complete(Unit)
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    val msg = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return
                    val id = (msg["id"] as? JsonPrimitive)?.intOrNull
                    if (id != null) {
                        pending.remove(id)?.complete(msg)
                    } else {
                        listeners.forEach { runCatching { it(msg) } }
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    opened.completeExceptionally(t)
                    shutDown()
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    shutDown()
                }
            })
        opened.get(10, TimeUnit.SECONDS)
    }

    private fun shutDown() {
        closed = true
        pending.values.forEach { it.completeExceptionally(IOException("DevTools connection closed")) }
        pending.clear()
    }

    suspend fun call(method: String, params: JsonObject = JsonObject(emptyMap()), sessionId: String? = null): JsonObject {
        if (closed) throw IOException("DevTools connection closed")
        val id = nextId.incrementAndGet()
        val reply = CompletableDeferred<JsonObject>()
        pending[id] = reply
        val message = buildJsonObject {
            put("id", id)
            put("method", method)
            put("params", params)
            if (sessionId != null) put("sessionId", sessionId)
        }
        if (!socket.send(message.toString())) {
            pending.remove(id)
            throw IOException("DevTools connection closed")
        }
        val msg = try {
            withTimeout(10_000) { reply.await() }
        } finally {
            pending.remove(id)
        }
        (msg["error"] as? JsonObject)?.let { throw IOException("$method: ${it["message"]?.jsonPrimitive?.content}") }
        return msg["result"] as? JsonObject ?: JsonObject(emptyMap())
    }

    suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult? {
        val ua = request.headers.header("User-Agent") ?: defaultUserAgent()
        val targetId = call("Target.createTarget", obj("url" to JsonPrimitive("about:blank"))).string("targetId")
            ?: throw IOException("could not open a tab")
        try {
            val sessionId = call("Target.attachToTarget", obj("targetId" to JsonPrimitive(targetId), "flatten" to JsonPrimitive(true)))
                .string("sessionId") ?: throw IOException("could not attach to the tab")
            val found = CompletableDeferred<Pair<String, JsonObject>>()
            val loaded = CompletableDeferred<Unit>()
            val listener: (JsonObject) -> Unit = listener@{ msg ->
                if ((msg["sessionId"] as? JsonPrimitive)?.content != sessionId) return@listener
                if ((msg["method"] as? JsonPrimitive)?.content == "Page.loadEventFired") loaded.complete(Unit)
                val params = msg["params"] as? JsonObject ?: return@listener
                when ((msg["method"] as? JsonPrimitive)?.content) {
                    "Network.requestWillBeSent" -> {
                        val req = params["request"] as? JsonObject ?: return@listener
                        val url = req.string("url") ?: return@listener
                        if (isMedia(url)) found.complete(url to (req["headers"] as? JsonObject ?: JsonObject(emptyMap())))
                    }
                    "Network.responseReceived" -> {
                        val resp = params["response"] as? JsonObject ?: return@listener
                        val url = resp.string("url") ?: return@listener
                        val mime = resp.string("mimeType").orEmpty().lowercase()
                        if (url.startsWith("http") && mime in PLAYLIST_TYPES) {
                            found.complete(url to (resp["requestHeaders"] as? JsonObject ?: JsonObject(emptyMap())))
                        }
                    }
                }
            }
            listeners += listener
            try {
                call("Network.enable", sessionId = sessionId)
                call("Network.setUserAgentOverride", obj("userAgent" to JsonPrimitive(ua)), sessionId)
                val extra = request.headers.filterKeys { !it.equals("User-Agent", true) && !it.equals("Referer", true) }
                if (extra.isNotEmpty()) {
                    call("Network.setExtraHTTPHeaders", obj("headers" to JsonObject(extra.mapValues { JsonPrimitive(it.value) })), sessionId)
                }
                val navigate = buildMap<String, JsonElement> {
                    put("url", JsonPrimitive(request.pageUrl))
                    request.headers.header("Referer")?.let { put("referrer", JsonPrimitive(it)) }
                }
                if (request.scripts.isNotEmpty()) call("Page.enable", sessionId = sessionId)
                call("Page.navigate", JsonObject(navigate), sessionId)
                val (url, sentHeaders) = coroutineScope {
                    // The config's click scripts, once the page has loaded and again a little later for slow players.
                    val clicks = if (request.scripts.isEmpty()) null else launch {
                        loaded.await()
                        repeat(2) {
                            for (script in request.scripts) {
                                runCatching {
                                    call("Runtime.evaluate", obj("expression" to JsonPrimitive("(function(){try{$script\n}catch(e){}})()")), sessionId)
                                }
                            }
                            delay(1500)
                        }
                    }
                    try {
                        withTimeoutOrNull(request.timeoutMs) { found.await() }
                    } finally {
                        clicks?.cancel()
                    }
                } ?: return null
                val headers = LinkedHashMap<String, String>()
                for ((k, v) in sentHeaders) {
                    if (k.lowercase() in KEPT_HEADERS) headers[canonical(k)] = (v as? JsonPrimitive)?.content ?: continue
                }
                headers.putIfAbsent("User-Agent", ua)
                val cookies = runCatching {
                    call("Network.getCookies", obj("urls" to JsonArray(listOf(JsonPrimitive(url)))), sessionId)["cookies"]?.jsonArray
                }.getOrNull()
                val cookie = cookies?.mapNotNull { c ->
                    val o = c as? JsonObject ?: return@mapNotNull null
                    "${o.string("name")}=${o.string("value")}"
                }?.joinToString("; ")
                if (!cookie.isNullOrEmpty()) headers["Cookie"] = cookie
                return SniffResult(url, headers)
            } finally {
                listeners -= listener
            }
        } finally {
            runCatching { call("Target.closeTarget", obj("targetId" to JsonPrimitive(targetId))) }
        }
    }

    /** The browser's own user agent without "Headless", which some sites refuse. */
    private suspend fun defaultUserAgent(): String = userAgent ?: (
        call("Browser.getVersion").string("userAgent")?.replace("HeadlessChrome", "Chrome") ?: FALLBACK_UA
        ).also { userAgent = it }

    fun close() {
        if (process.isAlive) {
            runCatching { socket.send(buildJsonObject { put("id", 0); put("method", "Browser.close") }.toString()) }
            runCatching { process.onExit().get(2, TimeUnit.SECONDS) }
        }
        closed = true
        socket.cancel()
        ChildProcesses.kill(process)
    }

    private companion object {
        val PLAYLIST_TYPES = setOf("application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl", "application/dash+xml")
        val KEPT_HEADERS = setOf("referer", "user-agent", "origin")
        const val FALLBACK_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

        fun obj(vararg pairs: Pair<String, JsonElement>) = JsonObject(mapOf(*pairs))
        fun JsonObject.string(key: String) = (this[key] as? JsonPrimitive)?.content
        fun Map<String, String>.header(name: String) = entries.firstOrNull { it.key.equals(name, true) }?.value
        fun canonical(name: String) = name.split('-').joinToString("-") { part -> part.replaceFirstChar { it.uppercase() } }
    }
}

/** Child processes (the sniffing browser) to kill when the engine exits, including through `--exit-with-stdin`. */
object ChildProcesses {
    private val processes = CopyOnWriteArrayList<ProcessHandle>()

    fun register(p: ProcessHandle) {
        processes += p
    }

    fun kill(p: ProcessHandle) {
        processes -= p
        runCatching { p.descendants().forEach { it.destroyForcibly() } }
        p.destroyForcibly()
    }

    fun killAll() {
        processes.toList().forEach(::kill)
    }
}
