package tvbox.engine.core.net

import kotlinx.coroutines.runBlocking
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import okio.ByteString.Companion.decodeBase64
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.config.ConfigDocument
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.config.ConfigParser
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.EngineSettings
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.store.EngineStore
import tvbox.engine.core.store.JsonFileStore
import tvbox.engine.core.store.MemoryStore
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CopyOnWriteArrayList

/** The config's `hosts`, `headers`, `doh` and `ads`, and the user's choice of DNS. */
class ConfigNetworkTest {
    /** Stands in for the system's DNS: knows [names] and nothing else, and notes what it was asked. */
    private class FakeDns(private val names: Map<String, String> = emptyMap()) : Dns {
        val asked = CopyOnWriteArrayList<String>()

        override fun lookup(hostname: String): List<InetAddress> {
            ConfigNetwork.literal(hostname)?.let { return listOf(it) }
            asked += hostname
            return listOf(InetAddress.getByName(names[hostname] ?: throw UnknownHostException(hostname)))
        }
    }

    /** The site every name is redirected to; answers with the path and notes what it was asked. */
    private val site = MockWebServer()

    /** A DNS-over-HTTPS server (RFC 8484, GET) that knows [dohRecords]. */
    private val doh = MockWebServer()
    private val dohRecords = HashMap<String, String>()
    private val dohAsked = CopyOnWriteArrayList<String>()

    @BeforeEach
    fun start() {
        site.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when {
                request.path == "/hop" -> MockResponse().setResponseCode(302).setHeader("Location", "http://second.test:${site.port}/landed")
                request.path!!.startsWith("/config/") -> MockResponse().setBody(configs[request.path!!.removePrefix("/config/")] ?: "")
                request.path!!.startsWith("/cms") -> MockResponse().setBody("""{"class":[{"type_id":"1","type_name":"电影"}],"list":[]}""")
                else -> MockResponse().setBody("served " + request.path)
            }
        }
        site.start()
        doh.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = dnsAnswer(request)
        }
        doh.start()
    }

    @AfterEach
    fun stop() {
        site.shutdown()
        runCatching { doh.shutdown() }
    }

    private val configs = HashMap<String, String>()

    private fun dnsAnswer(request: RecordedRequest): MockResponse {
        val query = request.requestUrl!!.queryParameter("dns")!!.decodeBase64()!!.toByteArray()
        // Header (12 bytes), then the question: labels, a zero, type and class.
        var at = 12
        val labels = ArrayList<String>()
        while (query[at].toInt() != 0) {
            val length = query[at].toInt()
            labels += String(query, at + 1, length)
            at += length + 1
        }
        val type = ((query[at + 1].toInt() and 0xff) shl 8) or (query[at + 2].toInt() and 0xff)
        val name = labels.joinToString(".")
        val address = dohRecords[name]?.takeIf { type == 1 }
        if (type == 1) dohAsked += name
        val answer = Buffer()
            .write(query, 0, 2).writeShort(0x8180).writeShort(1).writeShort(if (address == null) 0 else 1).writeShort(0).writeShort(0)
            .write(query, 12, at + 5 - 12)
        if (address != null) {
            answer.writeShort(0xC00C).writeShort(1).writeShort(1).writeInt(60).writeShort(4).write(InetAddress.getByName(address).address)
        }
        return MockResponse().setHeader("Content-Type", "application/dns-message").setBody(answer)
    }

    private fun dohUrl() = doh.url("/dns-query").toString()

    private fun client(network: ConfigNetwork) = network.install(OkHttpClient.Builder()).build()

    private fun get(client: OkHttpClient, host: String, path: String = "/x", headers: Map<String, String> = emptyMap()): String {
        val request = Request.Builder().url("http://$host:${site.port}$path").apply { headers.forEach { (k, v) -> header(k, v) } }.build()
        return client.newCall(request).execute().use { it.body!!.string() }
    }

    private fun config(text: String): TvboxConfig = (ConfigParser.parse(text) as ConfigDocument.Single).config

    @Test
    fun `a name in hosts is resolved as its target, another name or an address`() {
        val system = FakeDns(mapOf("real.test" to "127.0.0.1"))
        val network = ConfigNetwork(system)
        val client = client(network)
        assertThrows(IOException::class.java) { get(client, "alias.test") }

        network.onConfig(
            config("""{"sites":[],"hosts":["alias.test=real.test"," Direct.Test = 127.0.0.1 ","cache.*.cdn.test=127.0.0.1","v6.test=[::1]","bad.test=http://x/","127.0.0.1=10.9.9.9","localhost=10.9.9.9","same.test=same.test","noequals"]}"""),
        )
        assertEquals("served /x", get(client, "alias.test"), "another name, resolved by the system")
        assertEquals("alias.test:${site.port}", site.takeRequest().getHeader("Host"), "the request itself still names the host asked for")
        assertEquals("served /y", get(client, "direct.test", "/y"), "an address is the answer itself")
        assertEquals("served /z", get(client, "cache.ott.cdn.test", "/z"), "a star stands for anything")
        assertEquals(listOf("alias.test", "real.test"), system.asked, "one step; an address target asks nobody")

        // Entries that cannot be meant are left out; addresses and localhost are never redirected.
        assertEquals(
            mapOf("alias.test" to "real.test", "direct.test" to "127.0.0.1", "cache.*.cdn.test" to "127.0.0.1", "v6.test" to "::1"),
            network.info().hosts,
        )
        assertEquals("served /l", get(client, "127.0.0.1", "/l"))
        assertEquals("MAP alias.test real.test, MAP direct.test 127.0.0.1, MAP cache.*.cdn.test 127.0.0.1, MAP v6.test [::1]", network.hostResolverRules())

        // The next config has no hosts: the name is unknown again, without a new client.
        network.onConfig(config("""{"sites":[]}"""))
        assertThrows(IOException::class.java) { get(client, "direct.test") }
        assertEquals("", network.hostResolverRules())
    }

    @Test
    fun `headers are added to requests for their host only, also after a redirect`() {
        val network = ConfigNetwork(FakeDns(mapOf("first.test" to "127.0.0.1", "second.test" to "127.0.0.1", "other.test" to "127.0.0.1")))
        val client = client(network)
        network.onConfig(
            config(
                """{"sites":[],"headers":[
                    {"host":"second.test","header":{"User-Agent":"okHttp/Mod-1.5.0.0","X-Token":"t1"}},
                    {"host":"*.img.test","header":{"Referer":"https://img.test/"}},
                    {"host":"broken.test","header":{"Bad Name":"x","X-Ok":"y"}},
                    {"host":"none.test"}
                ]}""",
            ),
        )

        get(client, "other.test", headers = mapOf("User-Agent" to "mine"))
        site.takeRequest().let {
            assertEquals("mine", it.getHeader("User-Agent"))
            assertNull(it.getHeader("X-Token"), "another host gets nothing")
        }
        get(client, "second.test", headers = mapOf("User-Agent" to "mine"))
        site.takeRequest().let {
            assertEquals("okHttp/Mod-1.5.0.0", it.getHeader("User-Agent"), "the config's header replaces the request's")
            assertEquals("t1", it.getHeader("X-Token"))
        }
        // first.test answers with a redirect to second.test: only the second request carries them.
        assertEquals("served /landed", get(client, "first.test", "/hop"))
        assertNull(site.takeRequest().getHeader("X-Token"))
        assertEquals("t1", site.takeRequest().getHeader("X-Token"))

        // What a player is told to send to a media host.
        assertEquals(mapOf("Referer" to "https://img.test/"), network.headersFor("https://a.img.test/p.jpg"))
        assertEquals(mapOf("X-Ok" to "y"), network.headersFor("http://broken.test/"), "a header no request can carry is dropped")
        assertEquals(emptyMap<String, String>(), network.headersFor("http://none.test/"))
        assertEquals(
            mapOf("Cookie" to "c=1", "User-Agent" to "okHttp/Mod-1.5.0.0", "X-Token" to "t1"),
            network.playerHeaders("http://second.test/live.m3u8", mapOf("user-agent" to "spider", "Cookie" to "c=1")),
        )
        assertEquals(listOf("second.test", "*.img.test", "broken.test"), network.info().headerHosts)

        network.onConfig(null)
        get(client, "second.test")
        assertNull(site.takeRequest().getHeader("X-Token"), "gone with the config")
        assertFalse(network.hasHeaders)
    }

    /** Not kept in the pool: the next request for the host has to look the name up again. */
    private val once = mapOf("Connection" to "close")

    @Test
    fun `DoH answers only when it is switched on, and the system answers when it cannot`() {
        val system = FakeDns(mapOf("system.test" to "127.0.0.1", "later.test" to "127.0.0.1"))
        val messages = ArrayList<String>()
        val network = ConfigNetwork(system, log = { messages += it })
        val client = client(network)
        dohRecords["site.test"] = "127.0.0.1"

        // Off (the default): nothing goes to the DoH server, whatever the config offers.
        network.onConfig(config("""{"sites":[],"doh":[{"name":"演示","url":"${dohUrl()}","ips":["127.0.0.1","not-an-ip"]},{"name":"x","url":"ftp://nope"}]}"""))
        assertThrows(IOException::class.java) { get(client, "site.test") }
        assertEquals(0, doh.requestCount)
        assertEquals("", network.info().doh)
        val offered = network.dohOptions()
        assertEquals(ConfigNetwork.BUILTIN_DOH.map { it.url } + dohUrl(), offered.map { it.url }, "built-in ones, then the config's")
        assertEquals(listOf("127.0.0.1"), offered.last().ips)
        assertEquals("config", offered.last().source)

        // On: the same client now resolves through it.
        assertEquals(dohUrl(), network.setDoh(" ${dohUrl()} "))
        assertEquals("served /x", get(client, "site.test", headers = once))
        assertEquals(listOf("site.test"), dohAsked)
        assertEquals("ok", network.info().dohStatus)
        // Answers are remembered for a while; names of the local network and addresses are not sent out.
        assertEquals("served /x", get(client, "site.test", headers = once))
        assertThrows(IOException::class.java) { get(client, "printer.lan") }
        assertThrows(IOException::class.java) { get(client, "nas") }
        get(client, "127.0.0.1")
        assertEquals(listOf("site.test"), dohAsked)

        // A name the server does not know is asked of the system.
        assertEquals("served /x", get(client, "system.test"))
        assertEquals(listOf("site.test", "system.test"), dohAsked)
        assertTrue("system.test" in system.asked)
        assertEquals("ok", network.info().dohStatus, "an unknown name is an answer, not a failure")

        // hosts first, then DoH for the target.
        dohRecords["target.test"] = "127.0.0.1"
        network.onConfig(config("""{"sites":[],"hosts":["moved.test=target.test"]}"""))
        assertEquals("served /x", get(client, "moved.test"))
        assertEquals("target.test", dohAsked.last())
        assertEquals("saved", network.dohOptions().last().source, "still the user's choice when the config no longer lists it")

        // The server goes away: the system answers, and the server is left alone for a while.
        doh.shutdown()
        assertEquals("served /x", get(client, "later.test"))
        assertTrue(network.info().dohStatus.startsWith("failed: "), network.info().dohStatus)
        assertTrue(messages.last().contains("using the system's DNS"), messages.toString())

        // Off again.
        assertEquals("", network.setDoh(""))
        assertThrows(IOException::class.java) { get(client, "site.test") }
        assertEquals("", network.info().dohStatus)
        assertEquals("", ConfigNetwork.normalizeDoh("dns.example"), "not an address")
    }

    @Test
    fun `ads are the urls that contain one of the config's ad hosts`() {
        val network = ConfigNetwork(FakeDns())
        assertFalse(network.isAd("https://static-mozai.4gtv.tv/a.js"))
        network.onConfig(config("""{"sites":[],"ads":["Static-Mozai.4gtv.tv"," ","cnzz.com"]}"""))
        assertTrue(network.isAd("https://static-mozai.4gtv.tv/a.js"))
        assertTrue(network.isAd("https://S23.CNZZ.com/stat.php"))
        assertFalse(network.isAd("https://4gtv.tv/video.m3u8"))
        assertEquals(listOf("static-mozai.4gtv.tv", "cnzz.com"), network.info().ads)
    }

    private fun engine(network: ConfigNetwork, store: EngineStore = MemoryStore()): Engine {
        val client = client(network)
        return Engine(
            EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
            ConfigLoader(client, ConfigLocator("http://127.0.0.1:9978/file/")),
            SiteHttp(client),
            proxyBase = "http://127.0.0.1:9978/proxy?",
            store = store,
            network = network,
        )
    }

    @Test
    fun `the engine applies the active config, and the next config replaces it`() = runBlocking {
        val network = ConfigNetwork(FakeDns())
        val engine = engine(network)
        val api = "http://cms.test:${site.port}/cms"
        configs["with"] = """{
            "sites":[{"key":"a","type":1,"api":"$api"}],
            "hosts":["cms.test=127.0.0.1"],
            "headers":[{"host":"cms.test","header":{"X-Site":"1"}},{"host":"media.test","header":{"User-Agent":"tv/1"}}],
            "ads":["ads.test"],
            "lives":[{"group":"台","channels":[{"name":"一台","urls":["http://media.test/1.m3u8","http://other.test/1.m3u8"]}]}]
        }"""
        configs["without"] = """{"sites":[{"key":"a","type":1,"api":"$api"}]}"""
        val with = engine.addSubscription(site.url("/config/with").toString(), null).id
        val without = engine.addSubscription(site.url("/config/without").toString(), null).id

        engine.activate(with)
        assertEquals(listOf("电影"), engine.home("a").classes.map { it.name }, "the site's name only exists in the config's hosts")
        site.takeRequest() // the config itself
        assertEquals("1", site.takeRequest().getHeader("X-Site"))
        assertEquals(mapOf("cms.test" to "127.0.0.1"), engine.network().hosts)
        assertEquals(listOf("ads.test"), engine.network().ads)

        // What the player is told to send: the config's headers for the media host, direct or through /m3u8.
        val direct = engine.resolvePlay(PlayRequest("a", "线路", "http://media.test/v.mp4"))
        assertEquals(mapOf("User-Agent" to "tv/1"), direct.headers)
        val hls = engine.resolvePlay(PlayRequest("a", "线路", "http://media.test/v.m3u8"))
        assertTrue(hls.url.startsWith("http://127.0.0.1:9978/m3u8?url="), hls.url)
        assertEquals(mapOf("User-Agent" to "tv/1"), hls.headers)
        assertEquals(emptyMap<String, String>(), engine.resolvePlay(PlayRequest("a", "线路", "http://elsewhere.test/v.mp4")).headers)
        val lines = engine.liveList(0).groups.single().channels.single().urls
        assertEquals(listOf(mapOf("User-Agent" to "tv/1"), emptyMap()), lines.map { it.headers })

        // Another config becomes active: its rules, not the previous one's.
        engine.activate(without)
        val failure = assertThrows(EngineException::class.java) { runBlocking { engine.home("a") } }
        assertEquals("SITE_UNREACHABLE", failure.code)
        assertEquals(emptyMap<String, String>(), engine.network().hosts)
        assertEquals(emptyMap<String, String>(), engine.resolvePlay(PlayRequest("a", "线路", "http://media.test/v.mp4")).headers)

        // Back, then the subscription is removed: nothing of it stays.
        engine.activate(with)
        assertEquals(1, engine.network().hosts.size)
        engine.removeSubscription(with)
        assertEquals(emptyMap<String, String>(), engine.network().hosts)
    }

    @Test
    fun `the DoH choice is a setting that is kept, and off by default`(@TempDir dir: File) = runBlocking {
        dohRecords["cms.test"] = "127.0.0.1"
        configs["plain"] = """{"sites":[{"key":"a","type":1,"api":"http://cms.test:${site.port}/cms"}],"doh":[{"name":"演示","url":"${dohUrl()}"}]}"""
        val first = engine(ConfigNetwork(FakeDns()), JsonFileStore(dir))
        val id = first.addSubscription(site.url("/config/plain").toString(), null).id
        first.activate(id)
        assertEquals("", first.settings().doh)
        assertThrows(EngineException::class.java) { runBlocking { first.home("a") } }
        assertEquals(0, doh.requestCount, "a config that offers a server does not turn it on")

        // The user picks the server the config offers: used at once, the config is not loaded again.
        assertEquals(dohUrl(), first.updateSettings(EngineSettings(doh = dohUrl())).doh)
        assertEquals(1, first.home("a").classes.size)
        assertEquals("ok", first.network().dohStatus)
        assertEquals("", first.updateSettings(EngineSettings(doh = "nonsense")).doh, "only an address can be chosen")
        first.updateSettings(EngineSettings(doh = dohUrl()))

        // After a restart the choice is back before anything is fetched.
        val network = ConfigNetwork(FakeDns())
        val second = engine(network, JsonFileStore(dir))
        assertEquals(dohUrl(), second.settings().doh)
        assertEquals(dohUrl(), network.info().doh)
        second.restore()!!.getOrThrow()
        assertEquals(1, second.home("a").classes.size)
    }

    @Test
    fun `the config's headers list is read`() {
        val parsed = config("""{"sites":[],"headers":[{"host":"a.test","header":{"User-Agent":"x"}}]}""")
        assertTrue(parsed.headersJson.contains("a.test"))
        assertEquals("", config("""{"sites":[],"headers":"oops"}""").headersJson)
    }
}
