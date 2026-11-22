package tvbox.engine.py

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Getting Python and packages: the CPython download and pip installs, both against a local server standing in for
 * python.org and PyPI. Nothing is fetched from the internet.
 */
class PythonManagerTest {
    @TempDir
    lateinit var dir: File

    private val server = MockWebServer()
    private val requests = CopyOnWriteArrayList<String>()

    @AfterEach
    fun cleanUp() = server.shutdown()

    private fun zip(vararg entries: Pair<String, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { z ->
            for ((name, bytes) in entries) {
                z.putNextEntry(ZipEntry(name))
                z.write(bytes)
                z.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun serve(routes: Map<String, ByteArray>) {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl!!.encodedPath
                requests += path
                val body = routes[path] ?: return MockResponse().setResponseCode(404)
                val type = if (path.startsWith("/simple/")) "text/html" else "application/octet-stream"
                return MockResponse().setHeader("Content-Type", type).setBody(Buffer().write(body))
            }
        }
        server.start()
    }

    private fun awaitTask(manager: PythonManager, timeoutMs: Long = 120_000): PythonTask {
        val until = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < until) {
            val task = manager.task!!
            if (task.state != "running") return task
            Thread.sleep(100)
        }
        throw AssertionError("task still running: ${manager.task}")
    }

    @Test
    fun `the CPython download comes from the configured address, is checked and unpacked into the engine's folder`() {
        val archive = zip("python.exe" to "not really python".toByteArray(), "python399._pth" to "python399.zip\n.\n".toByteArray())
        serve(mapOf("/mirror/9.9.9/python-9.9.9-embed-amd64.zip" to archive))
        val spec = EmbeddedPython("9.9.9", "amd64", archive.size.toLong(), sha256(archive))
        val manager = PythonManager(File(dir, "python"), OkHttpClient(), embedded = spec, env = emptyMap(), searchMachine = false)
        manager.updateSettings(PythonSettingsUpdate(downloadMirror = server.url("/mirror").toString()))

        // Offered, with its size, before anything is fetched.
        val offer = manager.status(PythonWorkerInfo(), emptyList()).download!!
        assertEquals(archive.size.toLong(), offer.sizeBytes)
        assertEquals(server.url("/mirror/9.9.9/python-9.9.9-embed-amd64.zip").toString(), offer.url)
        assertFalse(offer.installed)
        assertTrue(requests.isEmpty())

        manager.startDownload()
        val task = awaitTask(manager)
        assertEquals("done", task.state, task.message)
        assertEquals(listOf("/mirror/9.9.9/python-9.9.9-embed-amd64.zip"), requests)
        assertEquals("not really python", File(manager.runtimeDir, "python.exe").readText())
        assertTrue(File(manager.runtimeDir, "python399._pth").isFile)
        assertTrue(manager.status(PythonWorkerInfo(), emptyList()).download!!.installed)
        assertFalse(File(manager.home, "download.part").exists())
        // Not a real Python: found, probed, not used.
        assertNull(manager.current())

        manager.removeDownloaded()
        assertFalse(manager.runtimeDir.exists())
    }

    @Test
    fun `a download that does not match the published checksum is thrown away`() {
        val archive = zip("python.exe" to "tampered".toByteArray())
        serve(mapOf("/ftp/9.9.9/python-9.9.9-embed-amd64.zip" to archive))
        val spec = EmbeddedPython("9.9.9", "amd64", archive.size.toLong(), "0".repeat(64))
        val manager = PythonManager(File(dir, "python"), OkHttpClient(), embedded = spec, env = emptyMap(), searchMachine = false)
        manager.updateSettings(PythonSettingsUpdate(downloadMirror = server.url("/ftp/").toString()))
        manager.startDownload()
        val task = awaitTask(manager)
        assertEquals("failed", task.state)
        assertTrue("校验" in task.message, task.message)
        assertFalse(manager.runtimeDir.exists())
        assertFalse(File(manager.home, "download.part").exists())
    }

    @Test
    fun `nothing to download where there is no embeddable CPython`() {
        assertNull(EmbeddedPython.forThisMachine("mac os x", "aarch64"))
        assertNull(EmbeddedPython.forThisMachine("linux", "amd64"))
        assertEquals("amd64", EmbeddedPython.forThisMachine("windows 10", "amd64")!!.arch)
        assertEquals("arm64", EmbeddedPython.forThisMachine("windows 11", "aarch64")!!.arch)
        val manager = PythonManager(File(dir, "python"), OkHttpClient(), embedded = null, env = emptyMap(), searchMachine = false)
        assertNull(manager.status(PythonWorkerInfo(), emptyList()).download)
        assertTrue(runCatching { manager.startDownload() }.isFailure)
    }

    /** A wheel pip accepts: one module, ymdemo_pkg. */
    private fun wheel(): ByteArray = zip(
        "ymdemo_pkg/__init__.py" to "VALUE = 42\n".toByteArray(),
        "ymdemo_pkg-1.0.dist-info/METADATA" to "Metadata-Version: 2.1\nName: ymdemo-pkg\nVersion: 1.0\n".toByteArray(),
        "ymdemo_pkg-1.0.dist-info/WHEEL" to "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n".toByteArray(),
        "ymdemo_pkg-1.0.dist-info/RECORD" to "ymdemo_pkg/__init__.py,,\nymdemo_pkg-1.0.dist-info/METADATA,,\nymdemo_pkg-1.0.dist-info/WHEEL,,\nymdemo_pkg-1.0.dist-info/RECORD,,\n".toByteArray(),
    )

    private fun index(name: String, file: String, bytes: ByteArray) =
        "<!DOCTYPE html><html><body><a href=\"/files/$file#sha256=${sha256(bytes)}\">$file</a></body></html>".toByteArray()

    /** pip reads no config file of the user's (it could name another index). */
    private val pipEnv = mapOf("PIP_CONFIG_FILE" to if (System.getProperty("os.name").lowercase().startsWith("windows")) "nul" else "/dev/null")

    private fun managerWithPython(networkProxy: tvbox.engine.core.net.NetworkProxy? = null): PythonManager {
        val manager = PythonManager(File(dir, "python"), OkHttpClient(), embedded = null, pipEnv = pipEnv, networkProxy = networkProxy)
        manager.relocate()
        assumeTrue(manager.current() != null, "no Python 3.8+ found (set TVBOX_PYTHON): skipped")
        return manager
    }

    @Test
    fun `packages are installed with pip into the engine's folder, from the configured index`() {
        val manager = managerWithPython()
        assumeTrue(manager.current()!!.pip, "this Python has no pip")
        val whl = wheel()
        serve(mapOf("/simple/ymdemo-pkg/" to index("ymdemo-pkg", "ymdemo_pkg-1.0-py3-none-any.whl", whl), "/files/ymdemo_pkg-1.0-py3-none-any.whl" to whl))
        manager.updateSettings(PythonSettingsUpdate(indexUrl = server.url("/simple/").toString()))
        assertFalse(manager.importable("ymdemo_pkg"))

        manager.startInstall(listOf("ymdemo-pkg"))
        val task = awaitTask(manager)
        assertEquals("done", task.state, task.message + "\n" + task.log.joinToString("\n"))
        assertTrue(File(manager.packagesDir(manager.current()!!.tag), "ymdemo_pkg/__init__.py").isFile)
        assertTrue(manager.importable("ymdemo_pkg"))
        assertTrue("/files/ymdemo_pkg-1.0-py3-none-any.whl" in requests)
        assertTrue(task.log.any { it.startsWith("$ pip install ymdemo-pkg") })
    }

    @Test
    fun `the module proxy carries the pip subprocess index and wheel requests`() {
        val routing = tvbox.engine.core.net.NetworkProxy()
        val manager = managerWithPython(routing)
        assumeTrue(manager.current()!!.pip, "this Python has no pip")
        val wheelName = "ymdemo_pkg-1.0-py3-none-any.whl"
        val wheel = wheel()
        server.enqueue(MockResponse().setHeader("Content-Type", "text/html").setBody(Buffer().write(index("ymdemo-pkg", wheelName, wheel))))
        server.enqueue(MockResponse().setBody(Buffer().write(wheel)))
        server.start()
        routing.apply(tvbox.engine.core.model.EngineSettings(httpProxy = "127.0.0.1:${server.port}", proxyScopes = listOf("modules")))
        manager.updateSettings(PythonSettingsUpdate(indexUrl = "http://index.example.invalid/simple/"))
        manager.startInstall(listOf("ymdemo-pkg"))
        val result = awaitTask(manager)
        assertEquals("done", result.state, result.log.joinToString("\n"))
        assertTrue(server.takeRequest().requestLine.contains("http://index.example.invalid/simple/ymdemo-pkg/"))
        assertTrue(server.takeRequest().requestLine.contains("http://index.example.invalid/files/$wheelName"))
    }

    @Test
    fun `a package that is not there fails the task with pip's words, and names that are options are refused`() {
        val manager = managerWithPython()
        assumeTrue(manager.current()!!.pip, "this Python has no pip")
        serve(emptyMap())
        manager.updateSettings(PythonSettingsUpdate(indexUrl = server.url("/simple/").toString()))
        manager.startInstall(listOf("ymdemo-absent"))
        val task = awaitTask(manager)
        assertEquals("failed", task.state)
        assertTrue("ymdemo-absent" in task.message, task.message)
        assertTrue(task.log.size > 1)

        for (bad in listOf("--index-url=http://evil.test/", "-r requirements.txt", "../x", "a b", "file:///c:/x.whl")) {
            assertTrue(runCatching { manager.startInstall(listOf(bad)) }.exceptionOrNull() is IllegalArgumentException, bad)
        }
    }

    @Test
    fun `a Python without pip (the embeddable CPython) gets pip from the index first`() {
        val manager = managerWithPython()
        val py = manager.current()!!
        // The pip wheel CPython bundles for ensurepip stands in for the one on PyPI.
        val bundled = File(File(py.path).parentFile, "Lib/ensurepip/_bundled").listFiles { f -> f.name.startsWith("pip-") && f.name.endsWith(".whl") }
            ?.firstOrNull()
        assumeTrue(bundled != null, "no bundled pip wheel next to ${py.path}")
        val pip = bundled!!.readBytes()
        val whl = wheel()
        serve(
            mapOf(
                "/simple/pip/" to index("pip", bundled.name, pip).let { String(it).replace("/files/", "/pipfiles/").toByteArray() },
                "/pipfiles/${bundled.name}" to pip,
                "/simple/ymdemo-pkg/" to index("ymdemo-pkg", "ymdemo_pkg-1.0-py3-none-any.whl", whl),
                "/files/ymdemo_pkg-1.0-py3-none-any.whl" to whl,
            ),
        )
        manager.updateSettings(PythonSettingsUpdate(indexUrl = server.url("/simple/").toString()))
        manager.install(py.copy(pip = false), listOf("ymdemo-pkg"))
        assertTrue("/pipfiles/${bundled.name}" in requests)
        assertTrue(File(manager.home, "pip/${bundled.name}").isFile)
        assertTrue(manager.importable("ymdemo_pkg"))
    }

    @Test
    fun `the newest pip wheel this Python can run is picked from an index page`() {
        val page = """
            <a href="../../packages/pip-9.0.1-py2.py3-none-any.whl#sha256=aa">pip-9.0.1-py2.py3-none-any.whl</a>
            <a href="../../packages/pip-24.0-py3-none-any.whl#sha256=bb" data-requires-python="&gt;=3.7">pip-24.0-py3-none-any.whl</a>
            <a href="../../packages/pip-25.0-py3-none-any.whl#sha256=cc" data-requires-python="&gt;=3.8" data-yanked="">pip-25.0-py3-none-any.whl</a>
            <a href="../../packages/pip-26.2-py3-none-any.whl#sha256=dd" data-requires-python="&gt;=3.9">pip-26.2-py3-none-any.whl</a>
            <a href="../../packages/pip-26.2.tar.gz#sha256=ee">pip-26.2.tar.gz</a>
        """
        assertEquals("pip-26.2-py3-none-any.whl", PipIndex.latestWheel(page, "pip", listOf(3, 14, 0))!!.file)
        assertEquals("dd", PipIndex.latestWheel(page, "pip", listOf(3, 14, 0))!!.sha256)
        // 3.8: 26.2 needs 3.9, 25.0 is yanked.
        assertEquals("pip-24.0-py3-none-any.whl", PipIndex.latestWheel(page, "pip", listOf(3, 8, 10))!!.file)
    }

    @Test
    fun `module names map to the packages that provide them`() {
        assertEquals("pycryptodome", PythonPackages.forModule("Crypto"))
        assertEquals("beautifulsoup4", PythonPackages.forModule("bs4"))
        assertEquals("websocket-client", PythonPackages.forModule("websocket"))
        assertEquals("somethingelse", PythonPackages.forModule("somethingelse"))
        assertTrue(PythonPackages.valid("pywasm==0.4.8"))
        assertTrue(PythonPackages.valid("requests[socks]"))
        assertFalse(PythonPackages.valid("--upgrade"))
    }
}
