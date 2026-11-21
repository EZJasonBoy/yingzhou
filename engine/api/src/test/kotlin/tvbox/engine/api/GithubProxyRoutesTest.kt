package tvbox.engine.api

import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.GithubProxy
import tvbox.engine.core.net.SiteHttp
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList

/** `/github-proxy`: the proxies offered and measuring them, against a fake network (nothing leaves the machine). */
class GithubProxyRoutesTest {
    private val asked = CopyOnWriteArrayList<String>()

    /** GitHub and `mirror.test` have the file; everything else is unreachable. */
    private val net = Interceptor { chain ->
        val url = chain.request().url.toString()
        asked += url
        if (url != GithubProxy.PROBE_URL && !url.startsWith("https://mirror.test/")) throw IOException("unreachable")
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body("* text=auto\n".toResponseBody()).build()
    }

    private fun engine(): Engine {
        val client = OkHttpClient.Builder().addInterceptor(GithubProxy()).addInterceptor(net).build()
        return Engine(
            EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
            ConfigLoader(client, ConfigLocator("http://127.0.0.1:9978/file/")),
            SiteHttp(client),
            proxyBase = "http://127.0.0.1:9978/proxy?",
        )
    }

    @Test
    fun `lists the presets and measures the ones asked for, or all of them`() = testApplication {
        application { engineModule(engine()) }

        val info = EngineJson.parseToJsonElement(client.get("/api/v1/github-proxy").bodyAsText()).jsonObject
        val presets = info["presets"]!!.jsonArray.map { it.jsonObject["prefix"]!!.jsonPrimitive.content }
        assertEquals(GithubProxy.PRESETS.map { it.prefix }, presets)
        assertEquals(GithubProxy.PROBE_URL, info["probeUrl"]!!.jsonPrimitive.content)

        val one = EngineJson.parseToJsonElement(client.post("/api/v1/github-proxy/probe") {
            contentType(ContentType.Application.Json)
            setBody("""{"prefixes":["mirror.test","https://gone.test/"]}""")
        }.bodyAsText()).jsonObject
        val results = one["results"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("", "https://mirror.test/", "https://gone.test/"), results.map { it["prefix"]!!.jsonPrimitive.content })
        assertEquals(listOf("true", "true", "false"), results.map { it["ok"]!!.jsonPrimitive.content })
        assertTrue(results[2]["error"]!!.jsonPrimitive.content.isNotEmpty())

        // No body: every preset, after GitHub itself.
        asked.clear()
        val all = EngineJson.parseToJsonElement(client.post("/api/v1/github-proxy/probe").bodyAsText()).jsonObject
        assertEquals(GithubProxy.PRESETS.size + 1, all["results"]!!.jsonArray.size)
        assertEquals((listOf("") + presets).map { it + GithubProxy.PROBE_URL }.toSet(), asked.toSet())
    }
}
