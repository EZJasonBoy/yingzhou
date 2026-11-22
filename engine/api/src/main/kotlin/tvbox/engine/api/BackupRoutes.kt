package tvbox.engine.api

import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receiveText
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import tvbox.engine.api.access.AccessControl
import tvbox.engine.core.Engine
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.ErrorBody
import tvbox.engine.core.model.FavoriteEntry
import tvbox.engine.core.model.HistoryEntry
import tvbox.engine.core.model.Subscription
import tvbox.engine.core.store.Library

/** `GET /api/v1/backup`: what a user would miss on another device or a new engine, in one file. */
@Serializable
data class Backup(
    val format: String = BACKUP_FORMAT,
    val version: Int = BACKUP_VERSION,
    /** Epoch milliseconds. */
    val exportedAt: Long = 0,
    val from: BackupSource = BackupSource(),
    /** As stored, addresses in clear: the file is for putting them back. */
    val subscriptions: List<Subscription> = emptyList(),
    /** The engine's settings (`/api/v1/settings`). */
    val settings: JsonObject = JsonObject(emptyMap()),
    val history: List<HistoryEntry> = emptyList(),
    val favorites: List<FavoriteEntry> = emptyList(),
)

@Serializable
data class BackupSource(
    /** The engine it came from, as it calls itself on the LAN (else its platform). */
    val name: String = "",
)

/** What an import does, or would do (`dryRun=1`). */
@Serializable
data class BackupSummary(
    val subscriptions: BackupAddSkip = BackupAddSkip(),
    val history: BackupMerge = BackupMerge(),
    val favorites: BackupAddSkip = BackupAddSkip(),
    val settings: BackupSettingKeys = BackupSettingKeys(),
)

@Serializable
data class BackupAddSkip(val add: Int = 0, val skip: Int = 0)

@Serializable
data class BackupMerge(val add: Int = 0, val update: Int = 0, val keep: Int = 0)

/** The settings that change: those of the backup that differ from what the engine has. */
@Serializable
data class BackupSettingKeys(val keys: List<String> = emptyList())

const val BACKUP_FORMAT = "yingzhou-backup"
const val BACKUP_VERSION = 1

/** Which parts of a backup an import writes. Settings only when asked for: they are this engine's network setup. */
private data class Include(val subscriptions: Boolean = true, val history: Boolean = true, val favorites: Boolean = true, val settings: Boolean = false)

/** A request the engine turns down, with a sentence for the person importing. */
private class BackupRefused(val code: String, message: String) : Exception(message)

/**
 * Backups (docs/protocol.md, "备份"):
 *
 * - `GET /api/v1/backup`: subscriptions, the engine's settings, history and favorites as one JSON document;
 * - `POST /api/v1/backup?dryRun=1` with a backup: what importing it would add, update and leave alone, nothing written;
 * - `POST /api/v1/backup` with `{backup, include}`: the import, answered the same way.
 *
 * Importing never removes anything: a subscription already here (same address) is skipped, history keeps for each
 * video whichever was watched later, a favorite is added when missing, settings are written only when included.
 */
fun Route.backupRoutes(engine: Engine, access: AccessControl) {
    get("/api/v1/backup") {
        val name = runCatching { access.host?.status()?.name }.getOrNull()?.takeIf { it.isNotBlank() } ?: engine.info.platform
        call.respond(
            Backup(
                exportedAt = System.currentTimeMillis(),
                from = BackupSource(name),
                subscriptions = engine.subscriptions(),
                settings = EngineJson.encodeToJsonElement(engine.settings()).jsonObject,
                history = engine.library.history(Int.MAX_VALUE),
                favorites = engine.library.favorites(),
            ),
        )
    }

    post("/api/v1/backup") {
        val dryRun = call.parameters["dryRun"].let { it == "1" || it == "true" }
        try {
            val body = parseObject(call.receiveText())
            // The import names its parts; a dry run may send the backup alone.
            val wrapped = body["backup"] as? JsonObject
            if (!dryRun && wrapped == null) throw BackupRefused("BAD_REQUEST", "没有要导入的备份")
            val backup = readBackup(wrapped ?: body)
            val include = if (dryRun && wrapped == null) Include(settings = true) else readInclude(body["include"] as? JsonObject)
            call.respond(importBackup(engine, backup, include, write = !dryRun))
        } catch (e: BackupRefused) {
            call.respond(HttpStatusCode.BadRequest, ErrorBody(ApiError(e.code, e.message.orEmpty())))
        }
    }
}

private fun parseObject(text: String): JsonObject =
    runCatching { EngineJson.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: throw BackupRefused("BAD_BACKUP", "这不是映舟的备份文件")

/** Checks what kind of file it is before reading its parts, so the answer says what is wrong in plain words. */
private fun readBackup(obj: JsonObject): Backup {
    val format = (obj["format"] as? JsonPrimitive)?.takeIf { it.isString }?.content
    if (format != BACKUP_FORMAT) throw BackupRefused("BAD_BACKUP", "这不是映舟的备份文件")
    val version = (obj["version"] as? JsonPrimitive)?.intOrNull ?: 0
    if (version > BACKUP_VERSION) throw BackupRefused("BACKUP_TOO_NEW", "这个备份来自更新版本的映舟，先把这里的映舟更新到最新再导入")
    if (version < 1) throw BackupRefused("BAD_BACKUP", "这不是映舟的备份文件")
    return try {
        EngineJson.decodeFromJsonElement<Backup>(obj)
    } catch (e: Exception) {
        throw BackupRefused("BAD_BACKUP", "备份文件不完整或已经损坏")
    }
}

private fun readInclude(obj: JsonObject?): Include {
    if (obj == null) return Include()
    fun flag(name: String, default: Boolean) = (obj[name] as? JsonPrimitive)?.booleanOrNull ?: default
    val defaults = Include()
    return Include(
        subscriptions = flag("subscriptions", defaults.subscriptions),
        history = flag("history", defaults.history),
        favorites = flag("favorites", defaults.favorites),
        settings = flag("settings", defaults.settings),
    )
}

/** Writes the parts of [backup] that [include] names (with [write]; otherwise only counts) and says what it did. */
private suspend fun importBackup(engine: Engine, backup: Backup, include: Include, write: Boolean): BackupSummary {
    var subscriptions = BackupAddSkip()
    if (include.subscriptions) {
        val known = engine.subscriptions().map { it.url.trim() }.toMutableSet()
        var add = 0
        var skip = 0
        for (s in backup.subscriptions) {
            val url = s.url.trim()
            if (url.isEmpty() || url in known) {
                skip++
                continue
            }
            known += url
            if (write) engine.addSubscription(url, s.name.takeIf { it != s.url })
            add++
        }
        subscriptions = BackupAddSkip(add, skip)
    }
    val history = if (include.history) engine.library.mergeHistory(backup.history, write).let { BackupMerge(it.add, it.update, it.keep) } else BackupMerge()
    val favorites = if (include.favorites) engine.library.mergeFavorites(backup.favorites, write).let { favoritesSummary(it) } else BackupAddSkip()
    var settings = BackupSettingKeys()
    if (include.settings && backup.settings.isNotEmpty()) {
        val current = engine.settings()
        val merged = mergedSettings(current, backup.settings)
        val before = EngineJson.encodeToJsonElement(current).jsonObject
        val after = EngineJson.encodeToJsonElement(merged).jsonObject
        val changed = after.keys.filter { after[it] != before[it] }
        if (write && changed.isNotEmpty()) engine.updateSettings(merged)
        settings = BackupSettingKeys(changed)
    }
    return BackupSummary(subscriptions, history, favorites, settings)
}

private fun favoritesSummary(merge: Library.Merge) = BackupAddSkip(add = merge.add, skip = merge.keep)
