package tvbox.engine.py

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.BufferedWriter
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** The Python side answered with an error (see worker.py `_describe`). */
class PyError(val type: String, override val message: String, val module: String, val trace: String) : Exception("$type: $message")

/** The worker process ended (crashed, was killed, never started). [output] is the last of what it wrote to stderr. */
class PyWorkerGone(message: String, val output: String) : IOException(message)

/**
 * One Python worker process (worker.py) and the line protocol to it. Requests carry an id; answers come back in any
 * order and complete the request with that id. Started by [PyRuntime], which starts a new one when this one is gone.
 *
 * The process goes away with the engine three ways: the engine kills it ([kill], a shutdown hook, the server's
 * ChildProcesses); and the worker exits by itself when its stdin closes, which is also what happens when the engine
 * dies without cleaning up.
 */
class PyWorker(
    private val command: List<String>,
    private val workDir: File,
    private val log: (String) -> Unit,
    private val onProcess: (ProcessHandle, Boolean) -> Unit = { _, _ -> },
) {
    private lateinit var process: Process
    private lateinit var writer: BufferedWriter
    private val pending = ConcurrentHashMap<Long, CompletableDeferred<JsonObject>>()
    private val ids = AtomicLong(1)
    private val hello = CompletableDeferred<JsonObject>()
    private val tail = ArrayDeque<String>()
    private val hook = Thread { kill() }

    /** Requests given up on (timed out, cancelled) whose answer has not come yet: Python threads still busy with them. */
    private val stuck = AtomicInteger(0)
    private val abandoned = ConcurrentHashMap.newKeySet<Long>()

    @Volatile var alive = false
        private set

    val pid: Long get() = if (::process.isInitialized) process.pid() else 0
    val stuckCalls: Int get() = stuck.get()
    val startedAt = System.currentTimeMillis()

    /** Starts the process and waits for its first line. */
    suspend fun start(timeoutMs: Long = 30_000) {
        workDir.mkdirs()
        val pb = ProcessBuilder(command).directory(workDir)
        // -E makes Python ignore these anyway; a stale PYTHONHOME would break the embeddable CPython.
        pb.environment().remove("PYTHONHOME")
        pb.environment().remove("PYTHONPATH")
        process = try {
            pb.start()
        } catch (e: IOException) {
            throw PyWorkerGone("Python 启动不了：${e.message}", "")
        }
        alive = true
        onProcess(process.toHandle(), true)
        runCatching { Runtime.getRuntime().addShutdownHook(hook) }
        writer = process.outputStream.bufferedWriter(Charsets.UTF_8)
        Thread({ readAnswers() }, "py-worker-out-${process.pid()}").apply { isDaemon = true }.start()
        Thread({ readErrors() }, "py-worker-err-${process.pid()}").apply { isDaemon = true }.start()
        try {
            withTimeout(timeoutMs) { hello.await() }
        } catch (e: TimeoutCancellationException) {
            kill()
            throw PyWorkerGone("Python 进程 ${timeoutMs / 1000} 秒内没有就绪", output())
        }
    }

    /** Sends [op] with [fields] and waits for the answer's `result`. Throws [PyError] for errors from Python. */
    suspend fun request(op: String, fields: Map<String, JsonElement> = emptyMap(), timeoutMs: Long = 60_000): JsonElement {
        if (!alive) throw PyWorkerGone("Python 进程已经退出", output())
        val id = ids.getAndIncrement()
        val answer = CompletableDeferred<JsonObject>()
        pending[id] = answer
        val message = buildJsonObject {
            put("id", JsonPrimitive(id))
            put("op", JsonPrimitive(op))
            fields.forEach { (k, v) -> put(k, v) }
        }
        try {
            send(message.toString())
            val res = withTimeout(timeoutMs) { answer.await() }
            if (res["ok"]?.jsonPrimitive?.contentOrNull == "true") return res["result"] ?: JsonNull
            val e = res["error"] as? JsonObject
            throw PyError(
                type = e.str("type").ifEmpty { "Error" },
                message = e.str("message"),
                module = e.str("module"),
                trace = e.str("trace"),
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            // The Python thread is still on it; remember that, so a worker full of hung calls gets replaced.
            if (pending.remove(id) != null && alive) {
                abandoned += id
                stuck.incrementAndGet()
            }
            throw e
        } finally {
            pending.remove(id)
        }
    }

    /** Sends without waiting for the answer (destroy). */
    fun post(op: String, fields: Map<String, JsonElement> = emptyMap()) {
        if (!alive) return
        val id = ids.getAndIncrement()
        abandoned += id
        val message = buildJsonObject {
            put("id", JsonPrimitive(id))
            put("op", JsonPrimitive(op))
            fields.forEach { (k, v) -> put(k, v) }
        }
        runCatching { send(message.toString()) }
    }

    private fun send(line: String) {
        try {
            synchronized(writer) {
                writer.write(line)
                writer.write("\n")
                writer.flush()
            }
        } catch (e: IOException) {
            gone("Python 进程已经退出")
            throw PyWorkerGone("Python 进程已经退出", output())
        }
    }

    private fun readAnswers() {
        try {
            process.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isBlank()) continue
                    val obj = runCatching { json.parseToJsonElement(line).jsonObject }.getOrNull()
                    if (obj == null) {
                        log("py: unexpected output: ${line.take(200)}")
                        continue
                    }
                    val id = obj["id"]?.jsonPrimitive?.longOrNull ?: continue
                    if (id == 0L) {
                        hello.complete(obj)
                        continue
                    }
                    val waiting = pending.remove(id)
                    if (waiting != null) {
                        waiting.complete(obj)
                    } else if (abandoned.remove(id)) {
                        if (stuck.get() > 0) stuck.decrementAndGet()
                    }
                }
            }
        } catch (e: IOException) {
            // The process went away.
        }
        gone("Python 进程退出了" + exitText())
    }

    private fun readErrors() {
        try {
            process.errorStream.bufferedReader(Charsets.UTF_8).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    synchronized(tail) {
                        tail.addLast(line.take(1000))
                        while (tail.size > TAIL_LINES) tail.removeFirst()
                    }
                    log("py: " + line.take(1000))
                }
            }
        } catch (e: IOException) {
            // The process went away.
        }
    }

    private fun exitText(): String {
        val code = runCatching { if (process.waitFor(2, TimeUnit.SECONDS)) process.exitValue() else null }.getOrNull()
        return if (code == null) "" else "（退出码 $code）"
    }

    private fun gone(why: String) {
        if (!alive && pending.isEmpty() && hello.isCompleted) return
        alive = false
        val failure = PyWorkerGone(why, output())
        hello.completeExceptionally(failure)
        pending.values.forEach { it.completeExceptionally(failure) }
        pending.clear()
        if (::process.isInitialized) onProcess(process.toHandle(), false)
        runCatching { Runtime.getRuntime().removeShutdownHook(hook) }
    }

    /** Closes the pipe to the worker, as an engine that dies does (tests: the worker must leave by itself). */
    internal fun closeInput() {
        runCatching { writer.close() }
    }

    /** The last lines the process wrote to stderr. */
    fun output(): String = synchronized(tail) { tail.toList() }.takeLast(12).joinToString("\n")

    fun kill() {
        if (!::process.isInitialized) return
        runCatching { writer.close() }
        runCatching { process.descendants().forEach { it.destroyForcibly() } }
        process.destroyForcibly()
        gone("Python 进程已停止")
    }

    companion object {
        private const val TAIL_LINES = 40
        private val json = Json { ignoreUnknownKeys = true }

        private fun JsonObject?.str(key: String): String = (this?.get(key) as? JsonPrimitive)?.contentOrNull.orEmpty()
    }
}
