package tvbox.engine.core.drive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.ConcurrentHashMap

/**
 * AList v3 and its fork OpenList (same API): `POST /api/fs/list` for folders, files played from `/d/<path>?sign=`.
 * Box (takagen99, AGPL-3.0) reads AList the same way; the version-2 API (`/api/public/path`) it also speaks is gone
 * from every AList still maintained and is not supported here.
 *
 * Accounts: a token from AList's settings goes in `Authorization` as it is; a user name and password log in through
 * `/api/auth/login` (the token is kept in [session] until AList refuses it); neither means the guest account. Folder
 * passwords (AList "meta" passwords) are sent with every request for that folder and the ones below it.
 */
internal class AListBackend(
    private val config: DriveConfig,
    private val http: OkHttpClient,
    private val session: AListSession,
    /** The password for a folder, overriding the saved ones (a password being tried out); null: the saved ones. */
    private val passwordOverride: Pair<String, String>? = null,
) : DriveBackend {
    private val base = config.url.trimEnd('/')
    private val root = DriveFiles.normalize(config.root)

    private fun serverPath(path: String) = DriveFiles.join(root, path)

    /** The password for [path]: the one being tried, else the saved one of the folder or its nearest parent. */
    private fun password(path: String): String {
        passwordOverride?.let { (folder, pw) -> if (path == folder || path.startsWith(if (folder == "/") "/" else "$folder/")) return pw }
        var p = path
        while (true) {
            config.folderPasswords[p]?.let { return it }
            if (p == "/") return ""
            p = DriveFiles.parent(p)
        }
    }

    override suspend fun list(path: String): List<DriveItem> {
        val sent = password(path)
        val data = api(
            "/api/fs/list",
            buildJsonObject {
                put("path", serverPath(path))
                put("password", sent)
                put("page", 1)
                put("per_page", 0)
                put("refresh", false)
            },
            path,
            sent.isNotEmpty(),
        )
        val content = (data as? JsonObject)?.get("content") as? JsonArray ?: return emptyList()
        return content.mapNotNull { element ->
            val o = element as? JsonObject ?: return@mapNotNull null
            val name = o.string("name").takeIf { it.isNotEmpty() && '/' !in it && it != "." && it != ".." } ?: return@mapNotNull null
            val dir = (o["is_dir"] as? JsonPrimitive)?.booleanOrNull ?: false
            DriveItem(
                DriveEntry(
                    name = name,
                    path = DriveFiles.join(path, "/$name"),
                    dir = dir,
                    size = (o["size"] as? JsonPrimitive)?.longOrNull ?: 0,
                    modified = DriveFiles.parseIso(o.string("modified")),
                    type = DriveFiles.type(name, dir),
                ),
                sign = o.string("sign"),
            )
        }
    }

    /** `/d/` is AList's download route: it sends the player on to the storage (or serves the file itself). */
    override fun direct(item: DriveItem): DirectLink = DirectLink(downloadUrl(item.entry.path, item.sign))

    private fun downloadUrl(path: String, sign: String) =
        base + "/d" + DriveFiles.encodePath(serverPath(path)) + (if (sign.isNotEmpty()) "?sign=" + DriveFiles.encodeSegment(sign) else "")

    override suspend fun open(path: String, range: String?, head: Boolean): DriveStream {
        val sign = session.sign(config.id, path) ?: run {
            val sent = password(path)
            val data = api("/api/fs/get", buildJsonObject { put("path", serverPath(path)); put("password", sent) }, DriveFiles.parent(path), sent.isNotEmpty())
            val o = data as? JsonObject ?: throw DriveException.notFound("文件不存在：$path")
            if ((o["is_dir"] as? JsonPrimitive)?.booleanOrNull == true) throw DriveException.bad("这是一个文件夹：$path")
            o.string("sign").also { session.keepSign(config.id, path, it) }
        }
        val request = Request.Builder().url(downloadUrl(path, sign)).apply {
            if (head) head() else get()
            range?.let { header("Range", it) }
        }.build()
        return DriveHttp.relay(DriveHttp.execute(http.newCall(request)), DriveFiles.nameOf(path), head)
    }

    /** Lists the drive's first folder: whether the address, the account and the folder are right. */
    suspend fun check(): Int = list("/").size

    /**
     * A call of AList's API; its `data`. AList answers HTTP 200 with its own `code` in the body. [folder] and
     * [passwordSent] say which folder a password complaint is about and whether a password was tried.
     */
    private suspend fun api(endpoint: String, body: JsonObject, folder: String, passwordSent: Boolean, retried: Boolean = false): JsonElement? {
        val token = session.token(config) ?: login()
        val request = Request.Builder()
            .url(base + endpoint)
            .post(body.toString().toRequestBody(JSON))
            .header("Accept", "application/json, text/plain, */*")
            .apply { if (token.isNotEmpty()) header("Authorization", token) }
            .build()
        val (status, text) = DriveHttp.execute(http.newCall(request)).use { it.code to DriveHttp.text(it) }
        val answer = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            ?: throw DriveException.unreachable(if (status == 404) "这个地址不是 AList / OpenList（HTTP 404）" else "AList 的回答看不懂（HTTP $status）")
        val code = (answer["code"] as? JsonPrimitive)?.intOrNull ?: status
        val message = answer.string("message")
        if (code == 200) return answer["data"]
        return when {
            code == 401 && config.token.isEmpty() && config.username.isNotEmpty() && !retried -> {
                // The login expired: once more with a new one.
                session.forget(config.id)
                api(endpoint, body, folder, passwordSent, retried = true)
            }
            code == 401 -> throw DriveException.auth(if (config.token.isNotEmpty()) "AList 不接受这个令牌：$message" else "AList 要求登录：$message")
            code == 403 && message.contains("password", ignoreCase = true) -> throw DriveException.password(folder, passwordSent)
            code == 403 -> throw DriveException.auth("AList 拒绝访问：$message")
            message.contains("not found", ignoreCase = true) -> throw DriveException.notFound("不存在：$folder")
            else -> throw DriveException.unreachable("AList：$message（$code）")
        }
    }

    /** Logs in with the drive's user name and password; "" (the guest account) when it has none. */
    private suspend fun login(): String {
        if (config.username.isEmpty()) return ""
        val body = buildJsonObject {
            put("username", config.username)
            put("password", config.password)
        }
        val request = Request.Builder().url("$base/api/auth/login").post(body.toString().toRequestBody(JSON)).build()
        val text = DriveHttp.execute(http.newCall(request)).use { DriveHttp.text(it) }
        val answer = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            ?: throw DriveException.unreachable("这个地址不是 AList / OpenList")
        val token = ((answer["data"] as? JsonObject)?.get("token") as? JsonPrimitive)?.contentOrNull
        if ((answer["code"] as? JsonPrimitive)?.intOrNull != 200 || token.isNullOrEmpty()) {
            throw DriveException.auth("AList 登录失败：${answer.string("message")}")
        }
        session.keepToken(config.id, token)
        return token
    }

    private fun JsonObject.string(key: String): String = (this[key] as? JsonPrimitive)?.contentOrNull.orEmpty()

    companion object {
        private val JSON = "application/json;charset=UTF-8".toMediaType()
    }
}

/** What the engine remembers about AList servers between calls: login tokens and file signatures. */
internal class AListSession {
    private val tokens = ConcurrentHashMap<String, String>()
    private val signs = ConcurrentHashMap<String, Pair<String, Long>>()

    /** The configured token, or the one from the last login; null: log in (when there is an account). */
    fun token(config: DriveConfig): String? = config.token.ifEmpty { null } ?: tokens[config.id] ?: if (config.username.isEmpty()) "" else null

    fun keepToken(drive: String, token: String) {
        tokens[drive] = token
    }

    /** The drive's account or address changed, or AList refused the token. */
    fun forget(drive: String) {
        tokens.remove(drive)
        signs.keys.removeAll { it.startsWith("$drive\n") }
    }

    /** A file's signature, kept for a while: players ask for many ranges of one file. */
    fun sign(drive: String, path: String): String? =
        signs["$drive\n$path"]?.takeIf { System.currentTimeMillis() - it.second < SIGN_TTL_MS }?.first

    fun keepSign(drive: String, path: String, sign: String) {
        if (signs.size > 2000) signs.clear()
        signs["$drive\n$path"] = sign to System.currentTimeMillis()
    }

    companion object {
        private const val SIGN_TTL_MS = 10 * 60_000L
    }
}
