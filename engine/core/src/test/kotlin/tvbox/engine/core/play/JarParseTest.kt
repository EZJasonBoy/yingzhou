package tvbox.engine.core.play

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import tvbox.engine.core.config.ParseBean
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.model.SniffRequest
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.site.RawPlay
import tvbox.engine.core.spider.JarRepository
import tvbox.engine.core.util.Base64Compat

class JarParseTest {
    private lateinit var server: MockWebServer

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = when (request.requestUrl!!.encodedPath) {
                "/jx" -> MockResponse().setBody("""{"url":"https://cdn.test/json/abcdefgh/index.m3u8"}""")
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
    }

    @AfterEach
    fun stop() = server.shutdown()

    private class FakeJar(private val answer: String?) : JarParsers {
        var mixArgs: List<Any?> = emptyList()
        override suspend fun jsonExt(key: String, jxs: LinkedHashMap<String, String>, url: String) = answer
        override suspend fun jsonExtMix(flag: String, key: String, name: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): String? {
            mixArgs = listOf(flag, key, name, jxs.keys.toList(), jxs["JSON"]?.get("type"), url)
            return answer
        }
    }

    private fun config(vararg parses: ParseBean) = TvboxConfig(parses = parses.toList())
    private val raw = RawPlay(url = "https://site.test/v/1", parse = 1, flag = "qq")

    @Test
    fun `the first parser is the default and a Mix parser gets TVBox's arguments`() = runBlocking {
        val jar = FakeJar("""{"url":"https://cdn.test/mix/abcdefgh/index.mp4","header":{"Referer":"r"},"jxFrom":"线路2"}""")
        val resolver = PlayResolver(SiteHttp(OkHttpClient()), "http://127.0.0.1:9978/proxy?", jarParsers = jar)
        val cfg = config(ParseBean("聚合", "Demo", 3), ParseBean("JSON", server.url("/jx?url=").toString(), 1))
        val info = resolver.resolve(raw, cfg)
        assertEquals("https://cdn.test/mix/abcdefgh/index.mp4", info.url)
        assertEquals("r", info.headers["Referer"])
        assertEquals("聚合 · 线路2", info.parsedBy)
        assertEquals(listOf("qq111", "Demo", "聚合", listOf("聚合", "JSON"), "1", "https://site.test/v/1"), jar.mixArgs)
    }

    @Test
    fun `a jar parser asking for a sniff goes to the sniffer`() = runBlocking {
        val jar = FakeJar("""{"url":"https://jx.test/page?v=1","parse":1,"ua":"UA"}""")
        val sniffer = object : Sniffer {
            override suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult? {
                assertEquals("UA", request.headers["User-Agent"])
                return SniffResult("https://cdn.test/sniffed/abcdefgh/a.mp4")
            }
        }
        val resolver = PlayResolver(SiteHttp(OkHttpClient()), "", sniffer = sniffer, jarParsers = jar)
        assertEquals("https://cdn.test/sniffed/abcdefgh/a.mp4", resolver.resolve(raw, config(ParseBean("聚合", "Demo", 3))).url)
    }

    @Test
    fun `a failing default parser falls back to the JSON parsers`() = runBlocking {
        val resolver = PlayResolver(SiteHttp(OkHttpClient()), "", jarParsers = FakeJar(null))
        val cfg = config(ParseBean("聚合", "Demo", 3), ParseBean("JSON", server.url("/jx?url=").toString(), 1))
        val info = resolver.resolve(raw, cfg)
        assertEquals("JSON", info.parsedBy)
        // Without the jar runtime the Mix parser is skipped altogether.
        assertEquals("JSON", PlayResolver(SiteHttp(OkHttpClient()), "").resolve(raw, cfg).parsedBy)
    }

    @Test
    fun `hls goes through the engine playlist endpoint with its headers`() = runBlocking {
        val resolver = PlayResolver(SiteHttp(OkHttpClient()), "http://127.0.0.1:9978/proxy?", playlistBase = "http://127.0.0.1:9978/m3u8?")
        val info = resolver.resolve(RawPlay(url = "https://cdn.test/a/index.m3u8", headers = mapOf("Referer" to "r")), config())
        assertTrue(info.url.startsWith("http://127.0.0.1:9978/m3u8?url=https%3A%2F%2Fcdn.test%2Fa%2Findex.m3u8&h="), info.url)
        val h = String(Base64Compat.decode(info.url.substringAfter("&h=")))
        assertEquals("""{"Referer":"r"}""", h)
        assertEquals("r", info.headers["Referer"], "the player still sends them to segment hosts")
        // Spider proxy urls are left alone.
        val proxied = resolver.resolve(RawPlay(url = "http://127.0.0.1:9978/proxy?do=x&u=a.m3u8"), config())
        assertEquals("http://127.0.0.1:9978/proxy?do=x&u=a.m3u8", proxied.url)
    }

    @Test
    fun `mixUrl carries a parser's ext as cat_ext`() {
        val p = ParseBean("J", "https://jx.test/api?key=1&url=", 1, """{"flag":["qq"]}""")
        val mixed = PlayResolver.mixUrl(p)
        assertTrue(mixed.startsWith("https://jx.test/api?cat_ext="), mixed)
        assertTrue(mixed.endsWith("&key=1&url="), mixed)
        assertEquals("""{"flag":["qq"]}""", String(Base64Compat.decode(mixed.substringAfter("cat_ext=").substringBefore('&'))))
    }

    @Test
    fun `jars disguised as images are unwrapped`() {
        val jar = byteArrayOf(0x50, 0x4b, 3, 4, 1, 2, 3)
        val png = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0, 0, 0, 0)
        assertEquals(jar.toList(), JarRepository.unwrap(png + jar, isImage = false, url = "x.png").toList(), "image with the jar appended")
        val marked = png + "abcdEFGH**".toByteArray() + Base64Compat.encode(jar).toByteArray()
        assertEquals(jar.toList(), JarRepository.unwrap(marked, isImage = true, url = "x.png").toList(), "img+ base64 after the marker")
        assertEquals(jar.toList(), JarRepository.unwrap(jar, isImage = false, url = "x.jar").toList())
    }

    @Test
    fun `a jar address that serves a web page is reported as such`() {
        val page = "﻿\n<!DOCTYPE html><html><body>404 Not Found</body></html>".toByteArray()
        val e = org.junit.jupiter.api.Assertions.assertThrows(IllegalStateException::class.java) {
            JarRepository.unwrap(page, isImage = false, url = "https://gone.test/83.jar")
        }
        assertEquals("https://gone.test/83.jar answered with a web page, not a jar", e.message)
        val text = org.junit.jupiter.api.Assertions.assertThrows(IllegalStateException::class.java) {
            JarRepository.unwrap("""{"code":403,"msg":"forbidden"}""".toByteArray(), isImage = false, url = "j.php")
        }
        assertTrue(text.message!!.contains("""text ("{"code":403"""), text.message)
        // Binary that is neither zip nor dex is left to the dex converter to report.
        val binary = byteArrayOf(1, 2, 3, 0, 0, 7, 8)
        assertEquals(binary.toList(), JarRepository.unwrap(binary, isImage = false, url = "x.bin").toList())
    }
}
