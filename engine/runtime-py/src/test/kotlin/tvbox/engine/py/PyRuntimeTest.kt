package tvbox.engine.py

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.net.ConfigNetwork
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.search.SearchEvent
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/**
 * Python spiders through the engine, with a real Python: the one in TVBOX_PYTHON or the first found on the machine.
 * Skipped when there is none (CI installs one with actions/setup-python). The spiders are this module's test
 * resources, served by a local server together with the config and a fake site API; nothing leaves the machine.
 */
class PyRuntimeTest {
    @TempDir
    lateinit var dir: File

    private val logs = CopyOnWriteArrayList<String>()
    private val server = MockWebServer()
    private val apiRequests = CopyOnWriteArrayList<RecordedRequest>()
    private var runtime: PyRuntime? = null

    @AfterEach
    fun cleanUp() {
        runtime?.close()
        server.shutdown()
    }

    /** A manager with the machine's Python, or the test is skipped. */
    private fun manager(searchMachine: Boolean = true, env: Map<String, String> = System.getenv()): PythonManager =
        PythonManager(File(dir, "python"), OkHttpClient(), log = { logs += it }, env = env, embedded = null, searchMachine = searchMachine)

    private fun withPython(): PythonManager = manager().also {
        it.relocate()
        assumeTrue(it.current() != null, "no Python 3.8+ found (set TVBOX_PYTHON): Python spider tests skipped")
    }

    private fun script(name: String) = PyRuntimeTest::class.java.getResourceAsStream("/py/$name")!!.readBytes().toString(Charsets.UTF_8)

    /** Serves [config] at /tv.json (`{base}` = this server, `{port}` = its port), the test spiders at /py/, and /api. */
    private fun serve(config: String): String {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl!!.encodedPath
                return when {
                    path == "/tv.json" -> MockResponse().setBody(config.replace("{base}", server.url("/").toString().trimEnd('/')).replace("{port}", server.port.toString()))
                    path.startsWith("/py/") -> MockResponse().setBody(script(path.removePrefix("/py/")))
                    path == "/api" -> {
                        apiRequests += request
                        MockResponse().setBody("""{"list":[{"vod_id":"v1","vod_name":"来自接口"}]}""")
                    }
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        return server.url("/tv.json").toString()
    }

    private fun engine(manager: PythonManager, network: ConfigNetwork = ConfigNetwork(), routing: tvbox.engine.core.net.NetworkProxy = tvbox.engine.core.net.NetworkProxy()): Engine {
        val client = OkHttpClient.Builder().let { network.install(it) }.build()
        val locator = ConfigLocator("http://127.0.0.1:80/file/")
        val rt = PyRuntime(manager, PyScripts(client, locator, File(dir, "spiders")), "http://127.0.0.1:80/proxy", network = network, log = { logs += it }, networkProxy = routing)
        runtime = rt
        return Engine(
            EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
            ConfigLoader(client, locator),
            SiteHttp(client),
            proxyBase = "http://127.0.0.1:80/proxy?",
            runtimes = listOf(rt),
            network = network,
            networkProxy = routing,
        )
    }

    private suspend fun Engine.load(url: String) = activate(addSubscription(url, null).id)

    private fun query(url: String): Map<String, String> = url.substringAfter('?').split('&').associate {
        it.substringBefore('=') to java.net.URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
    }

    private suspend fun failure(block: suspend () -> Unit): EngineException {
        try {
            block()
        } catch (e: EngineException) {
            return e
        }
        throw AssertionError("expected an EngineException")
    }

    @Test
    fun `a python site browses, searches, plays and proxies, and its requests follow the config's hosts and headers`() = runBlocking {
        val manager = withPython()
        val url = serve(
            """{"hosts":["pyhost.test=127.0.0.1"],"headers":[{"host":"pyhost.test","header":{"X-Yingzhou":"py"}}],
            "sites":[{"key":"pyvod","name":"Py点播","type":3,"api":"{base}/py/vod.py","ext":{"api":"http://pyhost.test:{port}/api"}}]}""",
        )
        val engine = engine(manager)
        engine.load(url)
        assertTrue(engine.info.capabilities.py)
        assertEquals("py", engine.sites().single().runtime)

        val home = engine.home("pyvod")
        assertEquals(listOf("来自接口"), home.list.map { it.name })
        assertEquals("电影", home.classes.single().name)
        // The name only resolves through the config's hosts; the header only the config adds.
        assertEquals("py", apiRequests.single().getHeader("X-Yingzhou"))
        assertEquals("pyhost.test:${server.port}", apiRequests.single().getHeader("Host"))

        assertEquals("c1-2-2024", engine.category("pyvod", "1", 2, mapOf("year" to "2024")).list.single().id)
        val detail = engine.detail("pyvod", "v1")
        assertEquals(listOf("直连", "代理"), detail.lines.map { it.name })
        assertEquals("星河 搜索结果", engine.search("pyvod", "星河", 1).list.single().name)
        val events = engine.searchAll("星河").toList()
        assertTrue(events.any { it is SearchEvent.Results && it.event.site == "pyvod" && it.event.items.isNotEmpty() })

        val direct = engine.resolvePlay(PlayRequest("pyvod", "直连", "e1"))
        assertEquals("http://media.test/e1.mp4", direct.url)
        assertEquals("http://media.test/", direct.headers["Referer"])

        val proxied = engine.resolvePlay(PlayRequest("pyvod", "代理", "e2"))
        assertTrue(proxied.url.startsWith("http://127.0.0.1:80/proxy?do=py&siteKey=pyvod&id=e2"), proxied.url)
        val response = engine.proxy(query(proxied.url))
        assertNotNull(response)
        assertEquals(200, response!!.status)
        assertEquals("video/mp2t", response.contentType)
        assertEquals("vod", response.headers["X-Spider"])
        assertEquals("proxied e2 by pyvod", response.body!!.readBytes().toString(Charsets.UTF_8))

        // What the spider prints goes into the engine's log.
        assertTrue(logs.any { "hello from python, ext keys: api" in it }, logs.joinToString("\n"))
        assertTrue(runtime!!.status().worker.running)
    }

    @Test
    fun `playback proxy reaches the running Python worker without changing its catalogue requests`() = runBlocking {
        val manager = withPython()
        val url = serve("""{"sites":[{"key":"py","name":"test","type":3,"api":"{base}/py/vod.py","ext":{"api":"{base}/api","resolve":"http://resolver.example.invalid/video"}}]}""")
        val engine = engine(manager)
        engine.load(url)
        assertEquals("来自接口", engine.home("py").list.single().name)
        MockWebServer().use { forwarder ->
            forwarder.enqueue(MockResponse().setBody("http://media.test/v.mp4"))
            forwarder.start()
            engine.updateSettings(tvbox.engine.core.model.EngineSettings(httpProxy = "127.0.0.1:${forwarder.port}", proxyScopes = listOf("playback")))
            assertEquals("http://media.test/v.mp4", engine.resolvePlay(PlayRequest("py", "直连", "1")).url)
            assertTrue(forwarder.takeRequest().requestLine.contains("http://resolver.example.invalid/video"))
            assertEquals("来自接口", engine.home("py").list.single().name)
            assertEquals(1, forwarder.requestCount)
        }
    }

    @Test
    fun `a python live source lists its channels, and their proxy addresses come back to its spider`() = runBlocking {
        val manager = withPython()
        val url = serve("""{"sites":[],"lives":[{"name":"Py直播","type":3,"api":"{base}/py/live.py","ext":"x"}]}""")
        val engine = engine(manager)
        engine.load(url)
        val source = engine.liveSources().single()
        assertTrue(source.supported)
        assertEquals("py", source.spider)

        val channels = engine.liveList(source.index).groups.flatMap { it.channels }
        assertEquals(listOf("直连台", "代理台", "协议台"), channels.map { it.name })
        assertEquals("http://media.test/direct.m3u8", channels[0].urls.single().url)
        for ((channel, ch) in listOf(channels[1] to "a", channels[2] to "b")) {
            val address = channel.urls.single().url
            assertTrue(address.startsWith("http://127.0.0.1:80/proxy?do=py") && "siteKey=live_" in address, address)
            val response = engine.proxy(query(address))!!
            assertEquals(302, response.status)
            assertEquals("http://media.test/$ch.m3u8", response.headers["Location"])
        }
    }

    @Test
    fun `a crash, a hang or an error in one call does not take the spider down`() = runBlocking {
        val manager = withPython()
        val url = serve("""{"sites":[{"key":"bad","name":"坏站","type":3,"api":"{base}/py/trouble.py","timeout":1}]}""")
        val engine = engine(manager)
        engine.load(url)
        assertEquals("still here", engine.detail("bad", "1").name)

        // homeContent kills the Python process: that call fails, the next one gets a new process.
        val crash = failure { engine.home("bad") }
        assertEquals("PY_CRASHED", crash.code, crash.message)
        assertEquals("still here", engine.detail("bad", "2", refresh = true).name)
        assertEquals(2, runtime!!.status().worker.starts)

        // categoryContent hangs: the call times out, the spider keeps answering.
        val started = System.currentTimeMillis()
        val hang = failure { engine.category("bad", "1", 1, emptyMap()) }
        assertEquals("SITE_TIMEOUT", hang.code, hang.message)
        assertTrue(System.currentTimeMillis() - started < 10_000)
        assertEquals("still here", engine.detail("bad", "3").name)

        // An exception in the spider is the site's error, with Python's message.
        val error = failure { engine.search("bad", "x", 1) }
        assertEquals("SITE_ERROR", error.code)
        assertTrue("KeyError" in error.message!! && "the site changed its page" in error.message!!, error.message)
    }

    @Test
    fun `a missing package is named in the error and listed for the settings`() = runBlocking {
        val manager = withPython()
        val url = serve("""{"sites":[{"key":"needs","name":"要包的站","type":3,"api":"{base}/py/missing.py"}]}""")
        val engine = engine(manager)
        engine.load(url)
        val e = failure { engine.home("needs") }
        assertEquals("PY_MODULE_MISSING", e.code)
        assertTrue("yingzhou_no_such_package" in e.message!!, e.message)
        val missing = runtime!!.status().missing.single()
        assertEquals("yingzhou_no_such_package", missing.module)
        assertEquals("要包的站", missing.site)

        // After an installation (the manager reports a change) the list starts over; the site reports it again.
        manager.onChanged()
        assertTrue(runtime!!.status().missing.isEmpty())
        assertEquals("PY_MODULE_MISSING", failure { engine.home("needs") }.code)
        assertEquals(1, runtime!!.status().missing.size)
    }

    @Test
    fun `dependencies are fetched from next to the spider and handed to init`() = runBlocking {
        val manager = withPython()
        val url = serve("""{"sites":[{"key":"deps","name":"依赖","type":3,"api":"{base}/py/withdeps.py"}]}""")
        val engine = engine(manager)
        engine.load(url)
        assertEquals("helper says hi, extend=", engine.home("deps").classes.single().name)
    }

    @Test
    fun `without a Python the sites are listed but say what they need, and searches leave them out`() = runBlocking {
        val manager = manager(searchMachine = false, env = emptyMap())
        val url = serve(
            """{"sites":[{"key":"pyvod","name":"Py点播","type":3,"api":"{base}/py/vod.py"}],
            "lives":[{"name":"Py直播","type":3,"api":"{base}/py/live.py"}]}""",
        )
        val engine = engine(manager)
        engine.load(url)
        assertFalse(engine.info.capabilities.py)
        assertEquals("py", engine.sites().single().runtime)
        val e = failure { engine.home("pyvod") }
        assertEquals("PY_UNAVAILABLE", e.code)
        assertTrue("Python" in e.message!!)
        val events = engine.searchAll("星河").toList()
        assertTrue(events.none { it is SearchEvent.Site && it.event.site == "pyvod" }, events.toString())
        assertFalse(engine.liveSources().single().supported)
        assertFalse(runtime!!.status().available)
    }

    @Test
    fun `spiders that use requests get the config's hosts and headers too`() = runBlocking {
        val manager = withPython()
        assumeTrue(manager.importable("requests"), "requests is not installed for this Python")
        val url = serve(
            """{"hosts":["pyhost.test=127.0.0.1"],"headers":[{"host":"pyhost.test","header":{"X-Yingzhou":"py"}}],
            "sites":[{"key":"req","name":"requests站","type":3,"api":"{base}/py/withrequests.py","ext":{"api":"http://pyhost.test:{port}/api"}}]}""",
        )
        val engine = engine(manager)
        engine.load(url)
        assertEquals(listOf("来自接口"), engine.home("req").list.map { it.name })
        val request = apiRequests.single()
        assertEquals("py", request.getHeader("X-Yingzhou"))
        assertEquals("requests", request.getHeader("X-Spider"))
    }

    @Test
    fun `the worker exits when the engine closes its stdin, and is killed with the runtime`() = runBlocking {
        val manager = withPython()
        val url = serve("""{"sites":[{"key":"deps","name":"依赖","type":3,"api":"{base}/py/withdeps.py"}]}""")
        val engine = engine(manager)
        engine.load(url)
        engine.home("deps")
        val pid = runtime!!.status().worker.pid
        assertTrue(pid > 0)
        runtime!!.close()
        assertTrue(ProcessHandle.of(pid).map { it.onExit().get(5, TimeUnit.SECONDS) }.map { !it.isAlive }.orElse(true))

        // The engine dying without cleaning up closes the pipe: the worker leaves by itself.
        val bridge = manager.bridgeDir()
        val py = manager.current()!!
        val worker = PyWorker(listOf(py.path, "-E", "-X", "utf8", "-u", File(bridge, "worker.py").path, "--home", manager.workerHome.path), manager.workerHome, { logs += it })
        worker.start()
        val handle = ProcessHandle.of(worker.pid).get()
        worker.closeInput()
        assertFalse(handle.onExit().get(10, TimeUnit.SECONDS).isAlive)
    }
}
