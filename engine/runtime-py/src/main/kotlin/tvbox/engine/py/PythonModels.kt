package tvbox.engine.py

import kotlinx.serialization.Serializable

/** `GET /api/v1/python`: what the 「Python 蜘蛛」 settings show. */
@Serializable
data class PythonStatus(
    /** This engine can run Python spiders at all (false: the Android app). */
    val supported: Boolean = true,
    /** A Python 3.8+ was found: Python sites can be opened. */
    val available: Boolean = false,
    val python: PythonFound? = null,
    /** Why no Python is in use, or what is wrong with the one the user set; empty when all is well. */
    val problem: String = "",
    /** The user's settings. */
    val settings: PythonSettings = PythonSettings(),
    /** Where the engine installs packages for the Python in use; empty when there is none. */
    val packagesDir: String = "",
    /** The packages TVBox ships for Python spiders, and whether the Python in use can import each. */
    val packages: List<PythonPackage> = emptyList(),
    /** Modules spiders asked for and did not find, most recent first. */
    val missing: List<PythonMissing> = emptyList(),
    /** The CPython the engine can download (Windows only); null when there is none for this machine. */
    val download: PythonDownload? = null,
    /** The download or package installation running now, or the last one. */
    val task: PythonTask? = null,
    val worker: PythonWorkerInfo = PythonWorkerInfo(),
)

@Serializable
data class PythonFound(
    val path: String,
    val version: String,
    /** custom (set by the user), env (TVBOX_PYTHON), system (found on the machine), downloaded (by the engine). */
    val source: String,
    /** Whether it has pip; without it the engine fetches pip itself to install packages. */
    val pip: Boolean,
)

@Serializable
data class PythonSettings(
    /** The python executable (or its folder) to use; empty = find one. */
    val path: String = "",
    /** A PyPI mirror (simple index) for installing packages; empty = pip's own setting (pypi.org). */
    val indexUrl: String = "",
    /** Where to download CPython from instead of https://www.python.org/ftp/python/ (same layout). */
    val downloadMirror: String = "",
)

@Serializable
data class PythonPackage(
    /** What pip installs (`beautifulsoup4`). */
    val name: String,
    /** What spiders import (`bs4`). */
    val module: String,
    val installed: Boolean,
    /** engine (in the engine's folder) or python (the Python's own); empty when not installed. */
    val where: String = "",
)

@Serializable
data class PythonMissing(
    val module: String,
    /** The package that provides it, as far as the engine knows. */
    val packageName: String,
    /** The site that asked for it. */
    val site: String,
    val at: Long,
)

@Serializable
data class PythonDownload(
    val version: String,
    val url: String,
    val sizeBytes: Long,
    val sha256: String,
    /** Where it goes. */
    val dir: String,
    /** Already downloaded. */
    val installed: Boolean,
)

@Serializable
data class PythonTask(
    /** download | install */
    val kind: String,
    /** running | done | failed */
    val state: String,
    val message: String = "",
    /** 0..1; -1 when unknown. */
    val progress: Double = -1.0,
    /** The last lines of pip's output. */
    val log: List<String> = emptyList(),
    val startedAt: Long = 0,
    val finishedAt: Long = 0,
)

@Serializable
data class PythonWorkerInfo(
    val running: Boolean = false,
    val pid: Long = 0,
    /** How many times the worker process was started. */
    val starts: Int = 0,
    val spiders: Int = 0,
)

/** `PUT /api/v1/python`: fields left out stay as they are. */
@Serializable
data class PythonSettingsUpdate(
    val path: String? = null,
    val indexUrl: String? = null,
    val downloadMirror: String? = null,
)

/** `POST /api/v1/python/packages`: empty = the common packages. */
@Serializable
data class PythonInstallRequest(val packages: List<String> = emptyList())

/** Packages Python spiders import, and the modules they provide. */
object PythonPackages {
    /** What TVBox's Python build bundles (Chaquopy `pip { install ... }` in TVBoxOS and Box). */
    val COMMON: List<Pair<String, String>> = listOf(
        "requests" to "requests",
        "lxml" to "lxml",
        "pycryptodome" to "Crypto",
        "beautifulsoup4" to "bs4",
        "pyquery" to "pyquery",
        "ujson" to "ujson",
        "jsonpath" to "jsonpath",
        "cachetools" to "cachetools",
    )

    /** Module -> package, for modules whose package has another name. */
    private val BY_MODULE: Map<String, String> = COMMON.associate { (pkg, module) -> module to pkg } + mapOf(
        "Cryptodome" to "pycryptodomex",
        "websocket" to "websocket-client",
        "yaml" to "PyYAML",
        "execjs" to "PyExecJS",
        "PIL" to "Pillow",
        "dateutil" to "python-dateutil",
        "Levenshtein" to "python-Levenshtein",
        "cv2" to "opencv-python-headless",
        "sklearn" to "scikit-learn",
        "google" to "protobuf",
        "jwt" to "PyJWT",
        "OpenSSL" to "pyOpenSSL",
        "magic" to "python-magic",
        "socks" to "PySocks",
        "zhconv" to "zhconv",
        "pywasm" to "pywasm",
    )

    fun forModule(module: String): String = BY_MODULE[module] ?: module

    /** A requirement pip may be given: a name, maybe with extras and one version condition. No options, no paths. */
    private val REQUIREMENT = Regex("^[A-Za-z0-9][A-Za-z0-9._-]*(\\[[A-Za-z0-9,._-]+])?((==|>=|<=|~=|!=|<|>)[A-Za-z0-9.*+!_-]+)?$")

    fun valid(requirement: String): Boolean = REQUIREMENT.matches(requirement)
}
