package tvbox.engine.api

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.FavoriteEntry
import tvbox.engine.core.model.HistoryEntry
import tvbox.engine.core.net.SiteHttp

/**
 * Backups: exported from one engine, looked at and imported into another that already has some of it. Nothing is
 * loaded from the subscriptions (adding one does not fetch it), so no network is involved.
 */
class BackupRoutesTest {
    private fun engine() = Engine(
        EngineInfo("tvbox-engine", "test", platform = "jvm-test", capabilities = Capabilities(false, false, false, false)),
        ConfigLoader(OkHttpClient(), ConfigLocator("http://127.0.0.1:80/file/")),
        SiteHttp(OkHttpClient()),
        proxyBase = "http://127.0.0.1:80/proxy?",
    )

    private fun history(vodId: String, at: Long, position: Long, name: String = "片$vodId") =
        HistoryEntry(site = "cms", vodId = vodId, name = name, episodeIndex = 1, positionMs = position, durationMs = 2_700_000, updatedAt = at)

    private fun json(text: String): JsonObject = EngineJson.parseToJsonElement(text).jsonObject

    private suspend fun HttpClient.postJson(path: String, body: String): HttpResponse = post(path) {
        contentType(ContentType.Application.Json)
        setBody(body)
    }

    private fun JsonObject.counts(part: String): Map<String, Int> = this[part]!!.jsonObject.mapValues { it.value.jsonPrimitive.int }

    private fun JsonObject.keys(): List<String> = this["settings"]!!.jsonObject["keys"]!!.jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun `export from one engine, see what an import would do, import into another that has some of it already`() {
        // ---- the engine the backup comes from ----
        val from = engine()
        from.library.mergeHistory(listOf(history("1", at = 2_000, position = 61_000), history("2", at = 3_000, position = 120_000), history("3", at = 1_000, position = 900_000)))
        from.library.putFavorite(FavoriteEntry(site = "cms", vodId = "1", name = "片1"))
        from.library.putFavorite(FavoriteEntry(site = "cms", vodId = "2", name = "片2", remarks = "HD"))
        lateinit var backup: String
        testApplication {
            application { engineModule(from) }
            client.postJson("/api/v1/subscriptions", """{"url":"https://sub.example.com/private/a.json","name":"家里的"}""")
            client.postJson("/api/v1/subscriptions", """{"url":"https://sub.example.com/b.json"}""")
            client.put("/api/v1/settings") {
                contentType(ContentType.Application.Json)
                setBody("""{"githubProxy":true,"streamCacheMaxMB":4096}""")
            }
            val res = client.get("/api/v1/backup")
            assertEquals(HttpStatusCode.OK, res.status)
            backup = res.bodyAsText()
        }
        val b = json(backup)
        assertEquals("yingzhou-backup", b["format"]!!.jsonPrimitive.content)
        assertEquals(1, b["version"]!!.jsonPrimitive.int)
        assertTrue(b["exportedAt"]!!.jsonPrimitive.long > 0)
        assertEquals("jvm-test", b["from"]!!.jsonObject["name"]!!.jsonPrimitive.content, "no LAN name: the platform")
        val subs = b["subscriptions"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("https://sub.example.com/private/a.json", "https://sub.example.com/b.json"), subs.map { it["url"]!!.jsonPrimitive.content }, "addresses in clear")
        assertEquals("家里的", subs[0]["name"]!!.jsonPrimitive.content)
        assertTrue(b["settings"]!!.jsonObject["githubProxy"]!!.jsonPrimitive.boolean)
        assertEquals(3, b["history"]!!.jsonArray.size)
        assertEquals(2, b["favorites"]!!.jsonArray.size)

        // ---- the engine it goes to: one subscription, two of the videos (one watched later here), one favorite ----
        val to = engine()
        to.library.mergeHistory(listOf(history("2", at = 5_000, position = 30_000), history("3", at = 500, position = 10_000)))
        to.library.putFavorite(FavoriteEntry(site = "cms", vodId = "2", name = "片2"))
        testApplication {
            application { engineModule(to) }
            client.postJson("/api/v1/subscriptions", """{"url":"https://sub.example.com/b.json","name":"B"}""")
            val settingsBefore = client.get("/api/v1/settings").bodyAsText()

            // What it would do: nothing is written.
            val dry = client.postJson("/api/v1/backup?dryRun=1", backup)
            assertEquals(HttpStatusCode.OK, dry.status, dry.bodyAsText())
            val plan = json(dry.bodyAsText())
            assertEquals(mapOf("add" to 1, "skip" to 1), plan.counts("subscriptions"))
            assertEquals(mapOf("add" to 1, "update" to 1, "keep" to 1), plan.counts("history"), "1 is new, 3 was watched later there, 2 later here")
            assertEquals(mapOf("add" to 1, "skip" to 1), plan.counts("favorites"))
            assertEquals(setOf("githubProxy", "streamCacheMaxMB"), plan.keys().toSet())
            assertEquals(1, json("""{"s":${client.get("/api/v1/subscriptions").bodyAsText()}}""")["s"]!!.jsonArray.size)
            assertEquals(2, to.library.history().size)
            assertEquals(1, to.library.favorites().size)
            assertEquals(settingsBefore, client.get("/api/v1/settings").bodyAsText())

            // The import, without the settings: the same as the plan said.
            val applied = client.postJson("/api/v1/backup", """{"backup":$backup,"include":{"subscriptions":true,"history":true,"favorites":true,"settings":false}}""")
            assertEquals(HttpStatusCode.OK, applied.status, applied.bodyAsText())
            val done = json(applied.bodyAsText())
            assertEquals(plan.counts("subscriptions"), done.counts("subscriptions"))
            assertEquals(plan.counts("history"), done.counts("history"))
            assertEquals(plan.counts("favorites"), done.counts("favorites"))
            assertEquals(emptyList<String>(), done.keys())
            val nowSubs = EngineJson.parseToJsonElement(client.get("/api/v1/subscriptions").bodyAsText()).jsonArray.map { it.jsonObject }
            assertEquals(listOf("https://sub.example.com/b.json", "https://sub.example.com/private/a.json"), nowSubs.map { it["url"]!!.jsonPrimitive.content })
            assertEquals(listOf("B", "家里的"), nowSubs.map { it["name"]!!.jsonPrimitive.content }, "the one here keeps its own name")
            assertEquals(61_000, to.library.historyFor("cms", "1")!!.positionMs)
            assertEquals(2_000, to.library.historyFor("cms", "1")!!.updatedAt, "when it was watched, not when it was imported")
            assertEquals(900_000, to.library.historyFor("cms", "3")!!.positionMs, "watched later there")
            assertEquals(30_000, to.library.historyFor("cms", "2")!!.positionMs, "watched later here")
            assertEquals(listOf("1", "2"), to.library.favorites().map { it.vodId }.sorted())
            assertEquals("片2", to.library.favoriteFor("cms", "2")!!.name)
            assertEquals(settingsBefore, client.get("/api/v1/settings").bodyAsText(), "settings only when included")

            // The settings alone.
            val settingsOnly = json(
                client.postJson("/api/v1/backup", """{"backup":$backup,"include":{"subscriptions":false,"history":false,"favorites":false,"settings":true}}""").bodyAsText(),
            )
            assertEquals(setOf("githubProxy", "streamCacheMaxMB"), settingsOnly.keys().toSet())
            assertEquals(mapOf("add" to 0, "skip" to 0), settingsOnly.counts("subscriptions"))
            val settings = json(client.get("/api/v1/settings").bodyAsText())
            assertTrue(settings["githubProxy"]!!.jsonPrimitive.boolean)
            assertEquals(4096, settings["streamCacheMaxMB"]!!.jsonPrimitive.int)

            // Once in, the same file changes nothing more.
            val again = json(client.postJson("/api/v1/backup?dryRun=1", backup).bodyAsText())
            assertEquals(mapOf("add" to 0, "skip" to 2), again.counts("subscriptions"))
            assertEquals(mapOf("add" to 0, "update" to 0, "keep" to 3), again.counts("history"))
            assertEquals(mapOf("add" to 0, "skip" to 2), again.counts("favorites"))
            assertEquals(emptyList<String>(), again.keys())
        }
    }

    @Test
    fun `an import with nothing said about what to include leaves the settings alone`() = testApplication {
        val engine = engine()
        application { engineModule(engine) }
        val backup = buildJsonObject {
            put("format", "yingzhou-backup"); put("version", 1)
            put("settings", buildJsonObject { put("githubProxy", true) })
            put("history", JsonArray(listOf(EngineJson.encodeToJsonElement(HistoryEntry.serializer(), history("9", at = 10, position = 5_000)))))
        }
        val done = json(client.postJson("/api/v1/backup", """{"backup":$backup}""").bodyAsText())
        assertEquals(mapOf("add" to 1, "update" to 0, "keep" to 0), done.counts("history"))
        assertEquals(emptyList<String>(), done.keys())
        assertFalse(engine.settings().githubProxy)
    }

    @Test
    fun `what is not a backup of this kind is refused in plain words`() = testApplication {
        val engine = engine()
        application { engineModule(engine) }
        fun error(body: String) = json(body)["error"]!!.jsonObject.let { it["code"]!!.jsonPrimitive.content to it["message"]!!.jsonPrimitive.content }

        for ((body, expected) in listOf(
            "not json" to ("BAD_BACKUP" to "这不是映舟的备份文件"),
            "[1,2]" to ("BAD_BACKUP" to "这不是映舟的备份文件"),
            """{"format":"tvbox","version":1}""" to ("BAD_BACKUP" to "这不是映舟的备份文件"),
            """{"version":1,"history":[]}""" to ("BAD_BACKUP" to "这不是映舟的备份文件"),
            """{"format":"yingzhou-backup"}""" to ("BAD_BACKUP" to "这不是映舟的备份文件"),
            """{"format":"yingzhou-backup","version":2}""" to ("BACKUP_TOO_NEW" to "这个备份来自更新版本的映舟，先把这里的映舟更新到最新再导入"),
            """{"format":"yingzhou-backup","version":1,"history":[{"site":"cms"}]}""" to ("BAD_BACKUP" to "备份文件不完整或已经损坏"),
            """{"format":"yingzhou-backup","version":1,"favorites":"lots"}""" to ("BAD_BACKUP" to "备份文件不完整或已经损坏"),
        )) {
            val dry = client.postJson("/api/v1/backup?dryRun=1", body)
            assertEquals(HttpStatusCode.BadRequest, dry.status, body)
            assertEquals(expected, error(dry.bodyAsText()), body)
            val wrapped = client.postJson("/api/v1/backup", if (body.startsWith("{") || body.startsWith("[")) """{"backup":$body}""" else body)
            assertEquals(HttpStatusCode.BadRequest, wrapped.status, body)
        }
        // An import names the backup it imports.
        val bare = client.postJson("/api/v1/backup", """{"format":"yingzhou-backup","version":1}""")
        assertEquals(HttpStatusCode.BadRequest, bare.status)
        assertEquals("BAD_REQUEST" to "没有要导入的备份", error(bare.bodyAsText()))
        assertTrue(engine.library.history().isEmpty())
        // A backup with nothing in it is fine and does nothing.
        val empty = client.postJson("/api/v1/backup?dryRun=1", """{"format":"yingzhou-backup","version":1}""")
        assertEquals(HttpStatusCode.OK, empty.status)
        assertEquals(mapOf("add" to 0, "update" to 0, "keep" to 0), json(empty.bodyAsText()).counts("history"))
        assertEquals(JsonPrimitive(0), json(empty.bodyAsText())["subscriptions"]!!.jsonObject["add"])
    }
}
