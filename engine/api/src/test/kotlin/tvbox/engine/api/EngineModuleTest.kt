package tvbox.engine.api

import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo

class EngineModuleTest {
    private fun engine() = Engine(
        EngineInfo("tvbox-engine", "test", platform = "test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/")),
    )

    @Test
    fun `info and proxy probe`() = testApplication {
        application { engineModule(engine()) }
        val info = EngineJson.parseToJsonElement(client.get("/api/v1/info").bodyAsText()).jsonObject
        assertEquals("tvbox-engine", info["name"]!!.jsonPrimitive.content)
        assertEquals("1", info["protocol"]!!.jsonPrimitive.content)
        assertEquals("ok", client.get("/proxy?do=ck").bodyAsText())
    }

    @Test
    fun `sites before any subscription is a conflict`() = testApplication {
        application { engineModule(engine()) }
        val res = client.get("/api/v1/sites")
        assertEquals(HttpStatusCode.Conflict, res.status)
        assertEquals("NO_CONFIG", EngineJson.parseToJsonElement(res.bodyAsText()).jsonObject["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
    }

    @Test
    fun `subscribe to a repository, activate, list sites`() {
        val upstream = MockWebServer().apply { start() }
        try {
            val configUrl = upstream.url("/b.json").toString()
            upstream.enqueue(MockResponse().setBody("""{"urls":[{"name":"B","url":"$configUrl"}]}"""))
            upstream.enqueue(MockResponse().setBody("""{"sites":[{"key":"a","name":"A","type":1,"api":"http://x"},{"key":"j","type":3,"api":"http://x/j.js"}]}"""))

            testApplication {
                application { engineModule(engine()) }
                val created = client.post("/api/v1/subscriptions") {
                    contentType(ContentType.Application.Json)
                    setBody("""{"url":"${upstream.url("/repo.json")}"}""")
                }
                assertEquals(HttpStatusCode.Created, created.status)
                val id = EngineJson.parseToJsonElement(created.bodyAsText()).jsonObject["id"]!!.jsonPrimitive.content

                val summary = EngineJson.parseToJsonElement(client.post("/api/v1/subscriptions/$id/activate").bodyAsText()).jsonObject
                assertEquals(configUrl, summary["url"]!!.jsonPrimitive.content)
                assertEquals("2", summary["sites"]!!.jsonPrimitive.content)
                assertEquals(1, summary["repos"]!!.jsonArray.size)

                val sites = EngineJson.parseToJsonElement(client.get("/api/v1/sites").bodyAsText()).jsonArray
                assertEquals(listOf("cms", "js"), sites.map { it.jsonObject["runtime"]!!.jsonPrimitive.content })
            }
        } finally {
            upstream.shutdown()
        }
    }
}
