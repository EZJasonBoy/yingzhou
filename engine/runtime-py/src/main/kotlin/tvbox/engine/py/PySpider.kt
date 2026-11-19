package tvbox.engine.py

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.spider.ProxyResponse
import tvbox.engine.core.spider.Spider
import tvbox.engine.core.spider.SpiderLoadException
import tvbox.engine.core.util.Base64Compat
import java.io.ByteArrayInputStream

/** A failure inside a spider method (not while loading): the site's problem more often than not. */
class PySpiderException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * One Python spider, living in the runtime's worker. It loads itself into the worker on first use and again when the
 * worker was replaced (crash, new packages), so callers never see a worker restart except as a slower call.
 */
class PySpider internal constructor(
    private val runtime: PyRuntime,
    private val site: SiteBean,
    private val path: String,
    private val ext: String,
) : Spider {
    val key: String get() = site.key
    private val lock = Mutex()
    @Volatile private var loadedIn: PyWorker? = null

    /** The worker, with this spider loaded and initialised in it. */
    internal suspend fun ready(): PyWorker {
        val w = runtime.worker()
        if (loadedIn === w) return w
        return lock.withLock {
            if (loadedIn === w) return@withLock w
            load(w)
            loadedIn = w
            w
        }
    }

    private suspend fun load(w: PyWorker) {
        val answer = guard(loading = true) { w.request("load", mapOf("key" to JsonPrimitive(key), "path" to JsonPrimitive(path)), LOAD_MS) }
        val deps = (answer as? JsonObject)?.get("deps")?.let { runCatching { it.jsonArray }.getOrNull() }
            ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        val depSpecs = deps.map { JsonObject(runtime.dependency(it, site.api)) }
        guard(loading = true) {
            w.request("init", mapOf("key" to JsonPrimitive(key), "ext" to JsonPrimitive(ext), "deps" to JsonArray(depSpecs)), LOAD_MS)
        }
    }

    override suspend fun init(ext: String) {
        ready()
    }

    override suspend fun home(filter: Boolean) = call("homeContent", JsonPrimitive(filter))
    override suspend fun homeVod() = call("homeVideoContent")
    override suspend fun category(tid: String, pg: String, filter: Boolean, extend: Map<String, String>) =
        call("categoryContent", JsonPrimitive(tid), JsonPrimitive(pg), JsonPrimitive(filter), JsonObject(extend.mapValues { JsonPrimitive(it.value) }))
    override suspend fun detail(id: String) = call("detailContent", JsonArray(listOf(JsonPrimitive(id))))
    override suspend fun search(key: String, quick: Boolean, pg: String) = call("searchContent", JsonPrimitive(key), JsonPrimitive(quick), JsonPrimitive(pg))

    override suspend fun play(flag: String, id: String, vipFlags: List<String>): String? =
        call("playerContent", JsonPrimitive(flag), JsonPrimitive(id), JsonArray(vipFlags.map { JsonPrimitive(it) }))
            ?.replace(TVBOX_PROXY, runtime.proxyBase())

    /** TVBox `liveContent(url)`; the address of a `lives` entry without `url` is the script's own. */
    override suspend fun live(url: String): String? = call("liveContent", JsonPrimitive(url.ifEmpty { site.api }))

    override suspend fun proxy(params: Map<String, String>): ProxyResponse? {
        runtime.used(this)
        val w = ready()
        val answer = guard(loading = false) {
            w.request("proxy", mapOf("key" to JsonPrimitive(key), "params" to JsonObject(params.mapValues { JsonPrimitive(it.value) })), CALL_MS)
        }
        val o = answer as? JsonObject ?: return null
        val body = o["body"]?.jsonPrimitive?.contentOrNull?.let { Base64Compat.decode(it) } ?: ByteArray(0)
        val headers = (o["headers"] as? JsonObject)?.mapValues { (_, v) -> (v as? JsonPrimitive)?.contentOrNull.orEmpty() }.orEmpty()
        return ProxyResponse(
            status = o["status"]?.jsonPrimitive?.intOrNull ?: 200,
            contentType = o["type"]?.jsonPrimitive?.contentOrNull ?: "application/octet-stream",
            body = ByteArrayInputStream(body),
            headers = headers,
        )
    }

    override fun destroy() {
        runtime.forget(this)
        val w = loadedIn ?: return
        loadedIn = null
        w.post("destroy", mapOf("key" to JsonPrimitive(key)))
    }

    private suspend fun call(method: String, vararg args: JsonElement): String? {
        runtime.used(this)
        val w = ready()
        val answer = guard(loading = false) {
            w.request("call", mapOf("key" to JsonPrimitive(key), "method" to JsonPrimitive(method), "args" to JsonArray(args.toList())), CALL_MS)
        }
        return if (answer is JsonNull) null else (answer as? JsonPrimitive)?.contentOrNull ?: answer.toString()
    }

    /** Errors from Python, as the engine reports them. */
    private suspend fun <T> guard(loading: Boolean, block: suspend () -> T): T = try {
        block()
    } catch (e: PyError) {
        if (e.module.isNotEmpty()) {
            runtime.noteMissing(e.module, site.name)
            val pkg = PythonPackages.forModule(e.module)
            val named = if (pkg == e.module) "「$pkg」" else "「$pkg」（模块 ${e.module}）"
            throw SpiderLoadException("${site.name}：缺少 Python 包$named。在「源」页的「Python 蜘蛛」里安装后再试", e, "PY_MODULE_MISSING")
        }
        if (loading) throw SpiderLoadException("${site.name}: ${e.type}: ${e.message}", e)
        throw PySpiderException("${site.name}: ${e.type}: ${e.message}", e)
    } catch (e: PyWorkerGone) {
        loadedIn = null
        throw SpiderLoadException("${site.name}: ${e.message}" + (if (e.output.isBlank()) "" else "：" + e.output.lines().lastOrNull { it.isNotBlank() }.orEmpty()), e, "PY_CRASHED")
    }

    companion object {
        private const val LOAD_MS = 60_000L
        private const val CALL_MS = 60_000L

        /** TVBox's Python rewrote this placeholder to its own proxy in play answers; spiders also write 9978 itself. */
        private val TVBOX_PROXY = Regex("http://127\\.0\\.0\\.1:(UndCover|9978)/proxy")
    }
}
