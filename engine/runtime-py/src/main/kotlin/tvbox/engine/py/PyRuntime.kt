package tvbox.engine.py

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.config.SiteRuntime
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.net.ConfigNetwork
import tvbox.engine.core.net.GithubProxy
import tvbox.engine.core.spider.ProxyResponse
import tvbox.engine.core.spider.Spider
import tvbox.engine.core.spider.SpiderLoadException
import tvbox.engine.core.spider.SpiderRuntime
import java.util.concurrent.ConcurrentHashMap

/**
 * Runs `.py` spiders (type-3 sites and `lives` entries whose api contains `.py`) in a Python worker process
 * ([PyWorker]), one per engine, as TVBox runs them all in one Python. The worker is started on first use, and again
 * after it crashed or was replaced; spiders load themselves into the new one when they are next used.
 *
 * - The Python comes from [manager]; until there is one, [available] is false and creating a spider fails with
 *   `PY_UNAVAILABLE`. A spider that imports a package that is not installed fails with `PY_MODULE_MISSING`, and the
 *   module is listed in the status so the settings can offer to install it.
 * - `/proxy?do=py`: the spider named by `siteKey` (what `getProxyUrl()` adds), else the one used last (TVBox).
 * - The worker gets the engine's network rules (config `hosts` / `headers`, the GitHub proxy, whether certificates
 *   are checked) and is told again whenever they change.
 */
class PyRuntime(
    val manager: PythonManager,
    private val scripts: PyScripts,
    /** The engine's spider proxy, e.g. `http://127.0.0.1:9978/proxy`. */
    private val proxyUrl: String,
    private val network: ConfigNetwork? = null,
    private val githubProxy: GithubProxy? = null,
    private val strictTls: Boolean = false,
    private val log: (String) -> Unit = {},
    /** Started (true) and ended (false) worker processes, for whoever kills children on exit. */
    private val onProcess: (ProcessHandle, Boolean) -> Unit = { _, _ -> },
) : SpiderRuntime {
    override val kind = "py"

    override val available: Boolean get() = manager.current() != null

    private val spiders = ConcurrentHashMap<String, PySpider>()
    @Volatile private var recent: PySpider? = null
    @Volatile private var sites: List<SiteBean> = emptyList()

    private val workerLock = Mutex()
    @Volatile private var worker: PyWorker? = null
    @Volatile private var starts = 0
    private val recentStarts = ArrayDeque<Long>()
    @Volatile private var lastNet: String = ""

    private val missing = ConcurrentHashMap<String, PythonMissing>()

    init {
        // Another Python, or new packages: the next call starts a fresh worker. What spiders found missing is
        // forgotten; a spider that still lacks it says so again when next used.
        manager.onChanged = {
            missing.clear()
            recycle("python changed")
        }
    }

    override fun supports(site: SiteBean) = site.runtime == SiteRuntime.PY

    override suspend fun create(site: SiteBean, ext: String): Spider {
        manager.current() ?: throw SpiderLoadException(NO_PYTHON, code = "PY_UNAVAILABLE")
        val script = scripts.fetch(site.api)
        // TVBox hands Python spiders the site's ext as written (not what an http ext points to), or `?extend=`.
        val spiderExt = site.ext.ifEmpty { PyScripts.extendOf(site.api) }
        val spider = PySpider(this, site, script.path, spiderExt)
        spider.ready()
        spiders[site.key] = spider
        recent = spider
        return spider
    }

    override fun onConfig(config: TvboxConfig) {
        sites = config.sites
        spiders.clear()
        recent = null
    }

    override suspend fun proxy(params: Map<String, String>): ProxyResponse? {
        if (params["do"] != "py") return null
        val spider = params["siteKey"]?.let { spiders[it] } ?: recent ?: return null
        return spider.proxy(params)
    }

    fun status(): PythonStatus {
        val w = worker
        val info = PythonWorkerInfo(running = w?.alive == true, pid = if (w?.alive == true) w.pid else 0, starts = starts, spiders = spiders.size)
        return manager.status(info, missing.values.sortedByDescending { it.at })
    }

    // ---- for PySpider ----

    internal fun proxyBase(): String = proxyUrl

    internal fun used(spider: PySpider) {
        recent = spider
    }

    internal fun forget(spider: PySpider) {
        spiders.remove(spider.key, spider)
        if (recent === spider) recent = null
    }

    internal fun noteMissing(module: String, site: String) {
        missing[module] = PythonMissing(module, PythonPackages.forModule(module), site, System.currentTimeMillis())
    }

    /** The running worker, started when there is none; the network rules it has are brought up to date. */
    internal suspend fun worker(): PyWorker {
        val w = worker?.takeIf { it.alive && it.stuckCalls < MAX_STUCK } ?: workerLock.withLock {
            val current = worker
            if (current != null && current.alive && current.stuckCalls < MAX_STUCK) return@withLock current
            if (current != null && current.alive) {
                log("py: replacing the worker, ${current.stuckCalls} calls hang in it")
                current.kill()
            }
            start().also { worker = it }
        }
        val net = netSpec()
        if (net.toString() != lastNet) {
            w.request("net", mapOf("net" to net), 10_000)
            lastNet = net.toString()
        }
        return w
    }

    private suspend fun start(): PyWorker {
        val py = manager.current() ?: throw SpiderLoadException(NO_PYTHON, code = "PY_UNAVAILABLE")
        synchronized(recentStarts) {
            val now = System.currentTimeMillis()
            while (recentStarts.isNotEmpty() && now - recentStarts.first() > 60_000) recentStarts.removeFirst()
            if (recentStarts.size >= 5) throw SpiderLoadException("Python 进程一分钟内退出了 ${recentStarts.size} 次，稍后再试（详见引擎日志）", code = "PY_CRASHED")
            recentStarts.addLast(now)
        }
        val bridge = manager.bridgeDir()
        val command = listOf(
            py.path, "-E", "-X", "utf8", "-u", java.io.File(bridge, "worker.py").path,
            "--home", manager.workerHome.path, "--packages", manager.packagesDir(py.tag).path,
        )
        val w = PyWorker(command, manager.workerHome, log, onProcess)
        try {
            w.start()
            val net = netSpec()
            w.request("setup", mapOf("proxy" to JsonPrimitive(proxyUrl), "net" to net), 30_000)
            lastNet = net.toString()
        } catch (e: PyWorkerGone) {
            w.kill()
            throw SpiderLoadException("Python 进程启动失败：${e.message}" + (if (e.output.isBlank()) "" else "\n" + e.output.takeLast(600)), e, "PY_CRASHED")
        } catch (e: PyError) {
            w.kill()
            throw SpiderLoadException("Python 进程启动失败：${e.message}", e, "PY_CRASHED")
        }
        starts++
        log("py: worker ${w.pid} started with ${py.path} ${py.versionText}")
        return w
    }

    /** Stops the worker for good (tests; the engine's own exit kills it anyway). */
    fun close() = recycle("closing")

    /** Stops the worker; the next call starts a new one (and spiders load again). */
    fun recycle(why: String) {
        val w = worker ?: return
        worker = null
        if (w.alive) log("py: stopping the worker ($why)")
        w.kill()
    }

    /** The network rules for the worker (see base/_host.py). */
    private fun netSpec(): JsonObject = buildJsonObject {
        put("hosts", buildJsonObject { network?.hostRules()?.forEach { (k, v) -> put(k, v) } })
        put("headers", buildJsonObject {
            network?.headerRules()?.forEach { (host, headers) -> put(host, buildJsonObject { headers.forEach { (k, v) -> put(k, v) } }) }
        })
        put("github", buildJsonObject {
            put("enabled", githubProxy?.enabled == true)
            put("prefix", githubProxy?.prefix.orEmpty())
        })
        put("strictTls", strictTls)
    }

    /**
     * Where a dependency (`getDependence()`) is: TVBox looks for a site of the config whose `api` is the name and
     * takes its `ext` as the script's address; otherwise `<name>.py` next to the spider.
     */
    internal suspend fun dependency(name: String, spiderApi: String): Map<String, JsonElement> {
        val bySite = sites.firstOrNull { it.api == name && it.ext.startsWith("http") }?.ext
        val address = bySite ?: runCatching {
            java.net.URI(spiderApi.substringBefore('?')).resolve(if (name.endsWith(".py")) name else "$name.py").toString()
        }.getOrNull() ?: throw SpiderLoadException("找不到依赖 $name")
        val file = scripts.fetch(address)
        return mapOf("name" to JsonPrimitive(name), "path" to JsonPrimitive(file.path), "ext" to JsonPrimitive(PyScripts.extendOf(address)))
    }

    companion object {
        /** Calls left hanging in Python before the worker is replaced. */
        private const val MAX_STUCK = 8

        const val NO_PYTHON = "需要 Python 3.8 或更新的版本才能打开这个站点：在「设置」页的「Python 蜘蛛」里下载 Python 运行时，或指定 python 的位置"
    }
}
