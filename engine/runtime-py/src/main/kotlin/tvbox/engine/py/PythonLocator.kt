package tvbox.engine.py

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.util.concurrent.TimeUnit

/** A Python that answered the probe. */
data class PythonInstall(
    /** What the worker is started with. */
    val path: String,
    val version: List<Int>,
    /** custom | env | system | downloaded */
    val source: String,
    val pip: Boolean,
    /** Interpreter and platform (`cp314-win_amd64`): packages for one do not load in another. */
    val tag: String,
    /** The embeddable CPython (a `._pth` file next to it): no pip, no site-packages. */
    val embedded: Boolean,
    /** Module -> where it was found (null: not found), for the modules asked about. */
    val modules: Map<String, String?> = emptyMap(),
) {
    val versionText: String get() = version.joinToString(".")
    val recentEnough: Boolean get() = version.size >= 2 && (version[0] > 3 || (version[0] == 3 && version[1] >= 8))
}

/**
 * Finds a Python to run spiders with, in this order:
 *
 * 1. the path the user set;
 * 2. `TVBOX_PYTHON` (for tests and unusual setups);
 * 3. a Python on this machine: on Windows the `py` launcher (`py -3`), `python3`, `python` on the PATH, then the
 *    usual install folders (python.org installs per user and are often not on the PATH); on macOS `python3` on the
 *    PATH and in Homebrew's and python.org's folders (apps started from the Finder get a short PATH), and Apple's
 *    `/usr/bin/python3` only when the developer tools are there (otherwise running it asks to install them);
 * 4. the CPython the engine downloaded (Windows).
 *
 * Each candidate is asked for its version with probe.py; the first that is 3.8 or newer wins.
 */
class PythonLocator(
    private val probeScript: () -> File,
    private val env: Map<String, String> = System.getenv(),
    private val osName: String = System.getProperty("os.name").lowercase(),
    private val log: (String) -> Unit = {},
    /** False: only the user's path, TVBOX_PYTHON and the downloaded CPython count (tests). */
    private val searchMachine: Boolean = true,
) {
    data class Candidate(val command: List<String>, val source: String)

    data class Result(val found: PythonInstall?, val problem: String, val rejected: List<String>)

    private val windows get() = osName.startsWith("windows")
    private val mac get() = osName.startsWith("mac")

    fun locate(custom: String, downloaded: File?, packages: (String) -> File?, modules: List<String>): Result {
        val rejected = ArrayList<String>()
        var problem = ""
        val seen = HashSet<String>()
        for (c in candidates(custom, downloaded)) {
            val key = c.command.joinToString(" ") { runCatching { File(it).canonicalPath }.getOrDefault(it) }
            if (!seen.add(key)) continue
            val probed = probe(c.command, c.source, emptyList(), emptyList())
            if (probed == null) {
                if (c.source == "custom") problem = "设置的 Python 运行不了：${c.command.first()}"
                continue
            }
            if (!probed.recentEnough) {
                rejected += "${probed.path}（${probed.versionText}，需要 3.8 或更新）"
                if (c.source == "custom") problem = "设置的 Python 是 ${probed.versionText}，需要 3.8 或更新"
                continue
            }
            // Asked again with the engine's package folder for this interpreter, now that its tag is known.
            val full = if (modules.isEmpty()) probed else probe(listOf(probed.path), c.source, listOfNotNull(packages(probed.tag)), modules) ?: probed
            return Result(full, problem, rejected)
        }
        if (problem.isEmpty()) {
            problem = if (rejected.isEmpty()) "没有找到 Python 3.8 或更新的版本" else "找到的 Python 都太旧：" + rejected.joinToString("；")
        }
        return Result(null, problem, rejected)
    }

    fun candidates(custom: String, downloaded: File?): List<Candidate> {
        val out = ArrayList<Candidate>()
        if (custom.isNotBlank()) out += Candidate(listOf(executableIn(File(custom.trim().removeSurrounding("\"")))), "custom")
        env["TVBOX_PYTHON"]?.takeIf { it.isNotBlank() }?.let { out += Candidate(listOf(executableIn(File(it.trim()))), "env") }
        if (!searchMachine) {
            // Nothing found on the machine.
        } else if (windows) {
            // The Microsoft Store's "python.exe" in WindowsApps is usually only a placeholder that offers to install
            // Python (it answers the probe with an error); a real Store Python is an alias there as well. Last.
            fun store(p: String) = p.contains("\\WindowsApps\\", ignoreCase = true)
            onPath("py").filterNot(::store).forEach { out += Candidate(listOf(it, "-3"), "system") }
            (onPath("python3") + onPath("python")).filterNot(::store).forEach { out += Candidate(listOf(it), "system") }
            val roots = listOfNotNull(
                env["LOCALAPPDATA"]?.let { File(it, "Programs/Python") },
                env["ProgramFiles"]?.let { File(it) },
                env["ProgramFiles(x86)"]?.let { File(it) },
                File("C:/"),
            )
            for (root in roots) {
                root.listFiles { f -> f.isDirectory && f.name.matches(Regex("(?i)python3\\d+(-32|-arm64)?")) }.orEmpty()
                    .sortedByDescending { it.name.filter(Char::isDigit).toIntOrNull() ?: 0 }
                    .map { File(it, "python.exe") }.filter { it.isFile }
                    .forEach { out += Candidate(listOf(it.path), "system") }
            }
            (onPath("python3") + onPath("python")).filter(::store).forEach { out += Candidate(listOf(it), "system") }
        } else {
            (onPath("python3") + onPath("python")).forEach { out += Candidate(listOf(it), "system") }
            val usual = if (mac) {
                listOf("/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3")
            } else {
                listOf("/usr/bin/python3", "/usr/local/bin/python3")
            }
            usual.map(::File).filter { it.canExecute() }.forEach { out += Candidate(listOf(it.path), "system") }
            if (mac && appleDeveloperTools()) out += Candidate(listOf("/usr/bin/python3"), "system")
        }
        if (downloaded != null) {
            val exe = File(downloaded, if (windows) "python.exe" else "bin/python3")
            if (exe.isFile) out += Candidate(listOf(exe.path), "downloaded")
        }
        return out
    }

    /** A folder stands for the python in it. */
    private fun executableIn(file: File): String {
        if (!file.isDirectory) return file.path
        val names = if (windows) listOf("python.exe", "Scripts/python.exe") else listOf("bin/python3", "python3", "bin/python")
        return names.map { File(file, it) }.firstOrNull { it.isFile }?.path ?: file.path
    }

    /** Every [name] on the PATH, in PATH order, as absolute paths (so nothing in the current folder is picked up). */
    fun onPath(name: String): List<String> {
        val path = env["PATH"] ?: env["Path"] ?: env.entries.firstOrNull { it.key.equals("PATH", ignoreCase = true) }?.value ?: return emptyList()
        val file = if (windows) "$name.exe" else name
        return path.split(File.pathSeparatorChar)
            .filter { it.isNotBlank() }
            .map { File(it.trim().removeSurrounding("\""), file) }
            .filter { it.isFile || (windows && it.exists()) }
            .map { it.absolutePath }
            .distinct()
    }

    private fun appleDeveloperTools(): Boolean =
        File("/Library/Developer/CommandLineTools/usr/bin/python3").exists() ||
            runCatching {
                val p = ProcessBuilder("/usr/bin/xcode-select", "-p").redirectErrorStream(true).start()
                p.inputStream.readBytes()
                p.waitFor(5, TimeUnit.SECONDS) && p.exitValue() == 0
            }.getOrDefault(false)

    /** Runs probe.py; null when the command does not run or does not answer like a Python. */
    fun probe(command: List<String>, source: String, packages: List<File>, modules: List<String>, timeoutMs: Long = 15_000): PythonInstall? {
        val args = ArrayList(command)
        args += listOf("-E", "-X", "utf8", probeScript().path)
        packages.forEach { args += listOf("--packages", it.path) }
        args += modules
        val text = try {
            val p = ProcessBuilder(args).start()
            p.outputStream.close()
            val out = java.io.ByteArrayOutputStream()
            val readers = listOf(
                Thread { runCatching { p.inputStream.copyTo(out) } },
                Thread { runCatching { p.errorStream.readBytes() } },
            ).onEach { it.isDaemon = true; it.start() }
            if (!p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                p.destroyForcibly()
                return null
            }
            readers.forEach { it.join(2000) }
            if (p.exitValue() != 0) return null
            synchronized(out) { out.toString(Charsets.UTF_8.name()) }
        } catch (e: Exception) {
            return null
        }
        val json = text.lineSequence().map { it.trim() }.lastOrNull { it.startsWith("{") }
            ?.let { runCatching { JsonParser.parseString(it).asJsonObject }.getOrNull() } ?: return null
        val version = json.getAsJsonArray("version")?.mapNotNull { runCatching { it.asInt }.getOrNull() } ?: return null
        val executable = json.str("executable")
        // `py -3` and shims hand over to the real interpreter: run that one from now on.
        val path = if (executable.isNotEmpty() && File(executable).isFile) executable else command.first()
        val found = json.getAsJsonObject("modules")?.entrySet()?.associate { (k, v) -> k to (if (v.isJsonNull) null else v.asString) }.orEmpty()
        return PythonInstall(
            path = path,
            version = version,
            source = source,
            pip = json.get("pip")?.asBoolean == true,
            tag = json.str("tag").ifEmpty { "py" + version.take(2).joinToString("") },
            embedded = json.get("embedded")?.asBoolean == true,
            modules = found,
        )
    }

    private fun JsonObject.str(key: String): String = get(key)?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
}
