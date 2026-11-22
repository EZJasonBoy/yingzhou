package tvbox.engine.py

import com.google.gson.Gson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import tvbox.engine.core.net.NetworkProxy
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipInputStream

/**
 * Which Python the engine uses, and what it installs for it. Everything lives under [home]
 * (`<data>/python`; with `--demo` and no `--data` a temporary folder):
 *
 * ```
 * settings.json        the user's choices (PythonSettings)
 * bridge/<hash>/       worker.py, probe.py and the `base` package, written out of the engine's jar
 * runtime/             the CPython the engine downloaded (Windows, only when the user asked for it)
 * packages/<tag>/      packages installed with pip --target, one folder per interpreter (cp314-win_amd64, ...)
 * pip/                 a pip wheel, for a Python without pip (the embeddable CPython)
 * pip-cache/           pip's download cache
 * spiders/             the spider scripts (see PyScripts)
 * home/                the worker's working folder; getCache / setCache keep their file there
 * ```
 *
 * Nothing is ever installed into the Python itself. Nothing is downloaded unless the user asks: the CPython download
 * and package installation start only from the 「Python 蜘蛛」 settings.
 */
class PythonManager(
    val home: File,
    private val client: OkHttpClient,
    private val log: (String) -> Unit = {},
    env: Map<String, String> = System.getenv(),
    /** The CPython to offer for download on this machine; null where there is none (anything but Windows). */
    private val embedded: EmbeddedPython? = EmbeddedPython.forThisMachine(),
    /** Extra environment for pip (tests point PIP_CONFIG_FILE at nothing). */
    private val pipEnv: Map<String, String> = emptyMap(),
    /** False: do not look for a Python on the machine, only the user's, TVBOX_PYTHON and the downloaded one (tests). */
    searchMachine: Boolean = true,
    private val networkProxy: NetworkProxy? = null,
) {
    private val gson = Gson()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val settingsFile = File(home, "settings.json")
    val runtimeDir = File(home, "runtime")
    val workerHome = File(home, "home")
    val spidersDir = File(home, "spiders")

    @Volatile var settings: PythonSettings = loadSettings()
        private set

    private val locator = PythonLocator(probeScript = { File(bridgeDir(), "probe.py") }, env = env, log = log, searchMachine = searchMachine)

    @Volatile private var located: PythonLocator.Result? = null
    private val firstLocate = CountDownLatch(1)
    private val locateLock = Any()

    @Volatile var task: PythonTask? = null
        private set

    /** Called when what the worker runs on changed: another Python, new packages. */
    @Volatile var onChanged: () -> Unit = {}

    init {
        home.mkdirs()
        // The first look happens in the background, so the engine starts at once; [current] waits for it a little.
        scope.launch { relocate() }
    }

    // ---- which Python ----

    /** The Python in use; null when there is none (yet). Waits up to 5 s for the first look after the engine starts. */
    fun current(): PythonInstall? {
        if (located == null) firstLocate.await(5, TimeUnit.SECONDS)
        return located?.found
    }

    /** Looks for a Python again (settings changed, something was installed). */
    fun relocate(): PythonLocator.Result = synchronized(locateLock) {
        val before = located?.found
        val result = try {
            locator.locate(settings.path, runtimeDir, { packagesDir(it) }, PythonPackages.COMMON.map { it.second })
        } catch (e: Exception) {
            PythonLocator.Result(null, "找 Python 时出错：${e.message}", emptyList())
        }
        located = result
        firstLocate.countDown()
        if (before?.path != result.found?.path || before?.tag != result.found?.tag) {
            log(result.found?.let { "python: using ${it.path} ${it.versionText} (${it.source})" } ?: "python: none (${result.problem})")
            onChanged()
        }
        result
    }

    /** Whether the Python in use can import [module] (from its own packages or the engine's). */
    fun importable(module: String): Boolean {
        val py = current() ?: return false
        return locator.probe(listOf(py.path), py.source, listOf(packagesDir(py.tag)), listOf(module))?.modules?.get(module) != null
    }

    /** Where packages for the Python with [tag] go. */
    fun packagesDir(tag: String): File = File(home, "packages/" + tag.replace(Regex("[^A-Za-z0-9._-]"), "_"))

    fun updateSettings(update: PythonSettingsUpdate): PythonSettings {
        val next = settings.copy(
            path = update.path?.trim() ?: settings.path,
            indexUrl = update.indexUrl?.trim() ?: settings.indexUrl,
            downloadMirror = update.downloadMirror?.trim() ?: settings.downloadMirror,
        )
        if (next.indexUrl.isNotEmpty() && !next.indexUrl.matches(Regex("^https?://\\S+$"))) throw IllegalArgumentException("PyPI 镜像要是 http(s) 地址")
        if (next.downloadMirror.isNotEmpty() && !next.downloadMirror.matches(Regex("^https?://\\S+$"))) throw IllegalArgumentException("下载镜像要是 http(s) 地址")
        settings = next
        runCatching { settingsFile.writeText(gson.toJson(next)) }
        if (update.path != null) relocate()
        return next
    }

    private fun loadSettings(): PythonSettings {
        val o = runCatching { com.google.gson.JsonParser.parseString(settingsFile.readText()).asJsonObject }.getOrNull() ?: return PythonSettings()
        fun s(key: String) = o.get(key)?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
        return PythonSettings(s("path"), s("indexUrl"), s("downloadMirror"))
    }

    // ---- the bridge scripts ----

    @Volatile private var bridge: File? = null

    /** worker.py, probe.py and `base/`, written out once per engine version. */
    fun bridgeDir(): File = bridge ?: synchronized(this) {
        bridge ?: run {
            val files = BRIDGE_FILES.associateWith { name ->
                PythonManager::class.java.getResourceAsStream("/tvbox/py/$name")?.use { it.readBytes() }
                    ?: throw IllegalStateException("missing resource tvbox/py/$name")
            }
            val digest = MessageDigest.getInstance("SHA-1")
            files.forEach { (name, bytes) -> digest.update(name.toByteArray()); digest.update(bytes) }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }.take(12)
            val root = File(home, "bridge")
            val dir = File(root, hash)
            if (!File(dir, ".complete").exists()) {
                files.forEach { (name, bytes) -> File(dir, name).apply { parentFile.mkdirs() }.writeBytes(bytes) }
                File(dir, ".complete").writeText(hash)
            }
            // Older versions' copies; one still in use by a running worker stays until the next start.
            root.listFiles()?.filter { it.isDirectory && it.name != hash }?.forEach { runCatching { it.deleteRecursively() } }
            dir.also { bridge = it }
        }
    }

    // ---- status ----

    fun status(worker: PythonWorkerInfo, missing: List<PythonMissing>): PythonStatus {
        val result = located ?: relocate()
        val py = result.found
        val packagesDir = py?.let { packagesDir(it.tag) }
        val packages = PythonPackages.COMMON.map { (name, module) ->
            val where = py?.modules?.get(module)
            PythonPackage(
                name = name,
                module = module,
                installed = where != null,
                where = when {
                    where == null -> ""
                    packagesDir != null && File(where).absolutePath.startsWith(packagesDir.absolutePath) -> "engine"
                    else -> "python"
                },
            )
        }
        val stillMissing = missing.filter { m -> py?.modules?.get(m.module) == null }
        return PythonStatus(
            supported = true,
            available = py != null,
            python = py?.let { PythonFound(it.path, it.versionText, it.source, it.pip) },
            problem = result.problem,
            settings = settings,
            packagesDir = packagesDir?.path.orEmpty(),
            packages = packages,
            missing = stillMissing,
            download = embedded?.let {
                PythonDownload(it.version, it.url(downloadBase()), it.size, it.sha256, runtimeDir.path, File(runtimeDir, "python.exe").isFile)
            },
            task = task,
            worker = worker,
        )
    }

    private fun downloadBase(): String = settings.downloadMirror.ifEmpty { EmbeddedPython.OFFICIAL }.trimEnd('/') + "/"

    // ---- downloading CPython (Windows) ----

    /** Starts downloading the embeddable CPython; the status shows how far it is. */
    fun startDownload(): PythonTask {
        val spec = embedded ?: throw IllegalArgumentException("这台机器上不能下载 Python 运行时：只有 Windows 有官方的免安装版。请自己安装 Python 3.8 或更新的版本")
        return startTask("download", "正在下载 Python ${spec.version}") { download(spec) }
    }

    private fun download(spec: EmbeddedPython) {
        val url = spec.url(downloadBase())
        val part = File(home, "download.part")
        val digest = MessageDigest.getInstance("SHA-256")
        log("python: downloading $url")
        client.newCall(Request.Builder().url(url).build()).execute().use { res ->
            if (!res.isSuccessful) throw IOException("下载失败：HTTP ${res.code}（$url）")
            val body = res.body ?: throw IOException("下载失败：没有内容")
            val total = body.contentLength().takeIf { it > 0 } ?: spec.size
            var done = 0L
            var shown = 0L
            body.byteStream().use { input ->
                part.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        digest.update(buf, 0, n)
                        done += n
                        if (done > spec.size * 2) throw IOException("下载的文件比预期大得多，已停止")
                        if (done - shown > 256 * 1024) {
                            shown = done
                            progress(done.toDouble() / total, "正在下载 Python ${spec.version}：${done / 1024 / 1024} / ${total / 1024 / 1024} MB")
                        }
                    }
                }
            }
        }
        val hash = digest.digest().joinToString("") { "%02x".format(it) }
        if (part.length() != spec.size || !hash.equals(spec.sha256, ignoreCase = true)) {
            part.delete()
            throw IOException("下载的文件校验不通过（大小 ${part.length()}，SHA-256 $hash），没有安装")
        }
        progress(1.0, "正在解压")
        val fresh = File(home, "runtime.new").apply { deleteRecursively() }
        unzip(part, fresh)
        part.delete()
        if (!File(fresh, "python.exe").isFile) throw IOException("压缩包里没有 python.exe")
        if (runtimeDir.exists() && !runtimeDir.deleteRecursively()) throw IOException("旧的运行时删不掉（还在使用？）：$runtimeDir")
        if (!fresh.renameTo(runtimeDir)) throw IOException("无法放到 $runtimeDir")
        relocate()
    }

    /** Removes the downloaded CPython (and the packages installed for it). */
    fun removeDownloaded() {
        val py = current()
        if (task?.state == "running") throw IllegalStateException("正在下载或安装，稍后再试")
        // A worker running on it has to stop before its files can go.
        if (py?.source == "downloaded") onChanged()
        if (runtimeDir.exists() && !runtimeDir.deleteRecursively()) throw IOException("删不掉 $runtimeDir（还在使用？）")
        if (py?.source == "downloaded") packagesDir(py.tag).deleteRecursively()
        relocate()
    }

    private fun unzip(zip: File, into: File) {
        into.mkdirs()
        val root = into.canonicalPath + File.separator
        ZipInputStream(zip.inputStream().buffered()).use { zin ->
            while (true) {
                val entry = zin.nextEntry ?: break
                val target = File(into, entry.name)
                if (!target.canonicalPath.startsWith(root)) throw IOException("压缩包里有越界的路径：${entry.name}")
                if (entry.isDirectory) target.mkdirs() else target.apply { parentFile.mkdirs() }.outputStream().use { zin.copyTo(it) }
            }
        }
    }

    // ---- packages ----

    /** Installs [requested] (empty: the common packages) into the engine's folder for the Python in use. */
    fun startInstall(requested: List<String>): PythonTask {
        val py = current() ?: throw IllegalStateException("还没有可用的 Python")
        val packages = requested.map { it.trim() }.filter { it.isNotEmpty() }.ifEmpty { PythonPackages.COMMON.map { it.first } }
        packages.firstOrNull { !PythonPackages.valid(it) }?.let { throw IllegalArgumentException("不是有效的包名：$it") }
        return startTask("install", "正在安装 ${packages.joinToString("、")}") { install(py, packages) }
    }

    internal fun install(py: PythonInstall, packages: List<String>) {
        val target = packagesDir(py.tag).apply { mkdirs() }
        val pip = if (py.pip) listOf(py.path, "-E", "-m", "pip") else listOf(py.path, "-E", File(pipWheel(py), "pip").path)
        val failed = ArrayList<String>()
        if (pipInstall(pip, target, packages) != 0) {
            if (packages.size == 1) {
                failed += packages
            } else {
                // One package without a wheel for this Python must not keep the others out.
                packages.forEach { if (pipInstall(pip, target, listOf(it)) != 0) failed += it }
            }
        }
        relocate()
        onChanged()
        if (failed.isNotEmpty()) {
            val ok = packages - failed.toSet()
            throw IOException((if (ok.isEmpty()) "" else "已安装 ${ok.joinToString("、")}；") + "没装上：${failed.joinToString("、")}（详见下面的输出）")
        }
    }

    /** Runs pip; its output goes into the task's log. */
    private fun pipInstall(pip: List<String>, target: File, packages: List<String>): Int {
        val args = ArrayList(pip)
        args += listOf(
            "install", "--target", target.path, "--upgrade", "--only-binary=:all:", "--no-input",
            "--disable-pip-version-check", "--no-warn-script-location", "--cache-dir", File(home, "pip-cache").path,
        )
        settings.indexUrl.takeIf { it.isNotEmpty() }?.let { index ->
            args += listOf("--index-url", index)
            // pip refuses plain http unless the host is named as trusted; the user chose this mirror.
            if (index.startsWith("http://")) runCatching { java.net.URI(index).host }.getOrNull()?.let { args += listOf("--trusted-host", it) }
        }
        args += "--"
        args += packages
        appendLog("$ pip install ${packages.joinToString(" ")}")
        val pb = ProcessBuilder(args).redirectErrorStream(true).directory(home)
        pb.environment()["PIP_NO_INPUT"] = "1"
        pb.environment().putAll(pipEnv)
        networkProxy?.endpoint(NetworkProxy.MODULES)?.takeIf { it.isNotEmpty() }?.let { endpoint ->
            val env = pb.environment()
            for (key in listOf("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY")) env[key] = "http://$endpoint"
            val bypass = listOfNotNull(env["no_proxy"] ?: env["NO_PROXY"], "localhost,.localhost,.local,.lan,127.0.0.0/8,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16").joinToString(",")
            env["no_proxy"] = bypass
            env["NO_PROXY"] = bypass
        }
        val p = pb.start()
        p.outputStream.close()
        p.inputStream.bufferedReader(Charsets.UTF_8).useLines { lines -> lines.forEach { appendLog(it) } }
        if (!p.waitFor(15, TimeUnit.MINUTES)) {
            p.destroyForcibly()
            appendLog("pip 超过 15 分钟没有结束，已停止")
            return -1
        }
        return p.exitValue()
    }

    /** A pip wheel to run pip from (`python pip.whl/pip install ...`), fetched from the index once. */
    private fun pipWheel(py: PythonInstall): File {
        val dir = File(home, "pip").apply { mkdirs() }
        dir.listFiles { f -> f.name.startsWith("pip-") && f.name.endsWith(".whl") }?.maxByOrNull { it.lastModified() }?.let { return it }
        val index = settings.indexUrl.ifEmpty { "https://pypi.org/simple/" }.trimEnd('/') + "/pip/"
        appendLog("下载 pip：$index")
        val page = client.newCall(Request.Builder().url(index).header("Accept", "text/html").build()).execute().use { res ->
            if (!res.isSuccessful) throw IOException("取不到 pip 的下载列表：HTTP ${res.code}")
            res.body?.string().orEmpty()
        }
        val wheel = PipIndex.latestWheel(page, "pip", py.version) ?: throw IOException("下载列表里没有适合 Python ${py.versionText} 的 pip")
        val url = java.net.URI(index).resolve(wheel.href.substringBefore('#')).toString()
        val file = File(dir, wheel.file)
        val bytes = client.newCall(Request.Builder().url(url).build()).execute().use { res ->
            if (!res.isSuccessful) throw IOException("pip 下载失败：HTTP ${res.code}")
            res.body?.bytes() ?: ByteArray(0)
        }
        wheel.sha256?.let { expected ->
            val actual = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            if (!actual.equals(expected, ignoreCase = true)) throw IOException("pip 校验不通过")
        }
        file.writeBytes(bytes)
        return file
    }

    // ---- tasks ----

    private val logLines = ArrayDeque<String>()

    private fun appendLog(line: String) {
        val text = line.trimEnd().take(500)
        if (text.isEmpty()) return
        synchronized(logLines) {
            logLines.addLast(text)
            while (logLines.size > LOG_LINES) logLines.removeFirst()
        }
        task = task?.copy(log = synchronized(logLines) { logLines.toList() })
    }

    private fun progress(value: Double, message: String) {
        task = task?.copy(progress = value.coerceIn(0.0, 1.0), message = message)
    }

    private fun startTask(kind: String, message: String, body: () -> Unit): PythonTask = synchronized(this) {
        if (task?.state == "running") throw IllegalStateException("${if (task?.kind == "download") "正在下载" else "正在安装"}，等它结束再试")
        synchronized(logLines) { logLines.clear() }
        val started = PythonTask(kind, "running", message, -1.0, emptyList(), System.currentTimeMillis())
        task = started
        scope.launch {
            task = try {
                body()
                val done = if (kind == "download") "Python 已下载" else "安装完成"
                task!!.copy(state = "done", message = done, progress = 1.0, finishedAt = System.currentTimeMillis())
            } catch (e: Exception) {
                log("python $kind failed: $e")
                task!!.copy(state = "failed", message = e.message ?: e.toString(), finishedAt = System.currentTimeMillis())
            }
        }
        started
    }

    companion object {
        private const val LOG_LINES = 200

        private val BRIDGE_FILES = listOf(
            "worker.py", "probe.py",
            "base/__init__.py", "base/_host.py", "base/spider.py", "base/localProxy.py", "base/htmlParser.py",
        )
    }
}

/** The embeddable CPython offered for download: a fixed version with python.org's published size and SHA-256. */
data class EmbeddedPython(val version: String, val arch: String, val size: Long, val sha256: String) {
    fun url(base: String): String = "${base.trimEnd('/')}/$version/python-$version-embed-$arch.zip"

    companion object {
        const val OFFICIAL = "https://www.python.org/ftp/python/"

        /**
         * CPython 3.14.10 (python.org, Windows embeddable package; sizes and SHA-256 from its release page). Pinned
         * on purpose: the hash is what makes a mirror safe to use. New enough that the packages spiders use have
         * wheels for it.
         */
        private val AMD64 = EmbeddedPython("3.14.10", "amd64", 12_619_664, "90905e64a840557d8c1bc4f5b74db3d7ee85e3ffb217611cac1c7813acea4159")
        private val ARM64 = EmbeddedPython("3.14.10", "arm64", 11_934_283, "bbe116bb1248820359cbf25127ac5c7794ea161869d83686cfbc9a45203ff836")

        fun forThisMachine(
            os: String = System.getProperty("os.name").lowercase(),
            arch: String = System.getProperty("os.arch").lowercase(),
        ): EmbeddedPython? = when {
            !os.startsWith("windows") -> null
            arch == "aarch64" || arch == "arm64" -> ARM64
            arch == "amd64" || arch == "x86_64" -> AMD64
            else -> null
        }
    }
}

/** Reading a PEP 503 "simple" index page. */
object PipIndex {
    data class Wheel(val file: String, val href: String, val version: List<Int>, val sha256: String?)

    private val ANCHOR = Regex("<a\\s+([^>]*)>([^<]*)</a>", RegexOption.IGNORE_CASE)
    private val HREF = Regex("href=\"([^\"]+)\"", RegexOption.IGNORE_CASE)

    private val REQUIRES = Regex("data-requires-python=\"([^\"]*)\"", RegexOption.IGNORE_CASE)

    /**
     * The newest final release of [project] as a pure-Python wheel (`<project>-<version>-py3-none-any.whl`), not
     * yanked, whose `>=` requirement on Python (the only kind pip's own releases state) [python] meets.
     */
    fun latestWheel(page: String, project: String, python: List<Int>): Wheel? = ANCHOR.findAll(page).mapNotNull { m ->
        val attrs = m.groupValues[1]
        if (attrs.contains("data-yanked", ignoreCase = true)) return@mapNotNull null
        val requires = REQUIRES.find(attrs)?.groupValues?.get(1)?.replace("&gt;", ">")?.replace("&lt;", "<").orEmpty()
        val minimum = Regex(">=\\s*([0-9.]+)").find(requires)?.groupValues?.get(1)?.split('.')?.mapNotNull { it.toIntOrNull() }
        if (minimum != null && compare(python, minimum) < 0) return@mapNotNull null
        val href = HREF.find(attrs)?.groupValues?.get(1)?.replace("&amp;", "&") ?: return@mapNotNull null
        val file = m.groupValues[2].trim().ifEmpty { href.substringBefore('#').substringAfterLast('/') }
        val match = Regex("^${Regex.escape(project)}-([0-9][0-9.]*)-(py3|py2\\.py3)-none-any\\.whl$", RegexOption.IGNORE_CASE).find(file) ?: return@mapNotNull null
        val version = match.groupValues[1].trimEnd('.').split('.').mapNotNull { it.toIntOrNull() }
        Wheel(file, href, version, href.substringAfter("#sha256=", "").ifEmpty { null })
    }.maxWithOrNull { a, b -> compare(a.version, b.version) }

    private fun compare(a: List<Int>, b: List<Int>): Int =
        (0 until maxOf(a.size, b.size)).asSequence()
            .map { (a.getOrNull(it) ?: 0).compareTo(b.getOrNull(it) ?: 0) }
            .firstOrNull { it != 0 } ?: 0
}
