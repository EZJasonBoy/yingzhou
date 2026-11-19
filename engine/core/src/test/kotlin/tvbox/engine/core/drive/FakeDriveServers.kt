package tvbox.engine.core.drive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList

/** Content of a test file: the same bytes for the same name. */
fun testBytes(name: String, size: Int = 50_000) = ByteArray(size) { i -> (name.hashCode() * 31 + i * 7).toByte() }

/** Serves `bytes=a-b` / `bytes=a-` of [bytes] like a server that supports ranges. */
private fun ranged(request: RecordedRequest, bytes: ByteArray, type: String): MockResponse {
    val m = Regex("bytes=(\\d+)-(\\d*)").matchEntire(request.getHeader("Range").orEmpty())
        ?: return MockResponse().setHeader("Content-Type", type).setHeader("Accept-Ranges", "bytes").setBody(Buffer().write(bytes))
    val start = m.groupValues[1].toInt()
    val end = m.groupValues[2].toIntOrNull()?.coerceAtMost(bytes.size - 1) ?: (bytes.size - 1)
    if (start >= bytes.size) return MockResponse().setResponseCode(416).setHeader("Content-Range", "bytes */${bytes.size}")
    return MockResponse().setResponseCode(206).setHeader("Content-Type", type).setHeader("Accept-Ranges", "bytes")
        .setHeader("Content-Range", "bytes $start-$end/${bytes.size}").setBody(Buffer().write(bytes.copyOfRange(start, end + 1)))
}

/**
 * A small WebDAV server for the tests: PROPFIND (depth 1) and GET with ranges under [base], Basic authentication
 * when [user] is set. Folders are implied by the files' paths. Every request is recorded with its Authorization.
 */
class TestDav(private val base: String = "/dav", private val user: String? = null, private val password: String? = null) {
    val server = MockWebServer()
    val files = LinkedHashMap<String, ByteArray>()
    val requests = CopyOnWriteArrayList<Pair<String, String?>>()

    /** hrefs as whole urls instead of paths, as some servers write them. */
    var absoluteHrefs = false

    fun start(): TestDav {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += (request.method + " " + request.path) to request.getHeader("Authorization")
                if (user != null) {
                    val expected = "Basic " + Base64.getEncoder().encodeToString("$user:$password".toByteArray())
                    if (request.getHeader("Authorization") != expected) return MockResponse().setResponseCode(401).setHeader("WWW-Authenticate", "Basic realm=\"x\"")
                }
                val raw = request.requestUrl!!.encodedPath
                if (!raw.startsWith(base)) return MockResponse().setResponseCode(404)
                val path = "/" + DriveFiles.decodePath(raw.removePrefix(base)).trim('/')
                return when (request.method) {
                    "PROPFIND" -> propfind(path)
                    "GET", "HEAD" -> files[path]?.let { ranged(request, it, "application/octet-stream") } ?: MockResponse().setResponseCode(404)
                    else -> MockResponse().setResponseCode(405)
                }
            }
        }
        server.start()
        return this
    }

    val url: String get() = server.url(base).toString().trimEnd('/')

    private fun isFolder(path: String) = path == "/" || files.keys.any { it.startsWith("$path/") }

    private fun propfind(path: String): MockResponse {
        if (!isFolder(path)) return MockResponse().setResponseCode(404)
        val prefix = if (path == "/") "/" else "$path/"
        val children = sortedMapOf<String, Boolean>()
        for (p in files.keys) if (p.startsWith(prefix)) p.removePrefix(prefix).let { children[it.substringBefore('/')] = '/' in it }
        val origin = if (absoluteHrefs) server.url("/").toString().trimEnd('/') else ""
        val body = StringBuilder("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">")
        fun entry(p: String, dir: Boolean, size: Int) {
            body.append("<d:response><d:href>").append(origin + base + DriveFiles.encodePath(p) + if (dir && p != "/") "/" else "").append("</d:href>")
            body.append("<d:propstat><d:prop>")
            if (dir) body.append("<d:resourcetype><d:collection/></d:resourcetype>") else body.append("<d:resourcetype/><d:getcontentlength>$size</d:getcontentlength>")
            body.append("<d:getlastmodified>Mon, 12 Feb 2024 10:00:00 GMT</d:getlastmodified>")
            body.append("</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")
        }
        entry(path, true, 0)
        for ((name, dir) in children) entry(DriveFiles.join(path, "/$name"), dir, files[DriveFiles.join(path, "/$name")]?.size ?: 0)
        body.append("</d:multistatus>")
        return MockResponse().setResponseCode(207).setHeader("Content-Type", "application/xml; charset=utf-8").setBody(body.toString())
    }

    fun shutdown() = server.shutdown()
}

/**
 * An AList v3 for the tests: `/api/auth/login`, `/api/fs/list`, `/api/fs/get`, `/d/` with signatures. [token] is
 * what `Authorization` must carry (null: guests are let in); [locked] folders want their password.
 */
class TestAList(
    private val token: String? = null,
    private val user: Pair<String, String>? = null,
    private val locked: Map<String, String> = emptyMap(),
) {
    val server = MockWebServer()
    val files = LinkedHashMap<String, ByteArray>()
    val requests = CopyOnWriteArrayList<Triple<String, String, String?>>()

    /** Tokens handed out by logging in; a test can revoke them. */
    val issued = CopyOnWriteArrayList<String>()
    @Volatile var revoked = false

    fun start(): TestAList {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = request.body.readUtf8()
                requests += Triple(request.path!!, body, request.getHeader("Authorization"))
                val path = request.requestUrl!!.encodedPath
                return when {
                    path == "/api/auth/login" -> login(Json.parseToJsonElement(body) as JsonObject)
                    path.startsWith("/api/fs/") -> fs(path, Json.parseToJsonElement(body) as JsonObject, request.getHeader("Authorization"))
                    path.startsWith("/d/") -> download(request)
                    else -> MockResponse().setResponseCode(404).setBody("404 page not found")
                }
            }
        }
        server.start()
        return this
    }

    val url: String get() = server.url("/").toString().trimEnd('/')

    private fun answer(code: Int, message: String, data: String = "null") =
        MockResponse().setHeader("Content-Type", "application/json").setBody("""{"code":$code,"message":"$message","data":$data}""")

    private fun login(o: JsonObject): MockResponse {
        val u = o["username"]!!.jsonPrimitive.content
        val p = o["password"]!!.jsonPrimitive.content
        if (user == null || user != (u to p)) return answer(400, "password is incorrect")
        val t = "login-token-" + (issued.size + 1)
        issued += t
        return answer(200, "success", """{"token":"$t"}""")
    }

    private fun authorised(header: String?): Boolean = when {
        token != null -> header == token
        user != null -> header != null && header in issued && !(revoked && header == issued.first())
        else -> true
    }

    private fun sign(path: String) = "sig-" + path.hashCode().toString(16)

    private fun fs(endpoint: String, o: JsonObject, auth: String?): MockResponse {
        if (!authorised(auth)) return answer(401, "token is invalidated")
        val path = o["path"]!!.jsonPrimitive.content
        val sent = o["password"]?.jsonPrimitive?.content.orEmpty()
        locked.entries.firstOrNull { path == it.key || path.startsWith(it.key + "/") }?.let { (_, pw) ->
            if (sent != pw) return answer(403, "password is incorrect or you have no permission")
        }
        if (endpoint == "/api/fs/get") {
            val bytes = files[path] ?: return answer(500, "failed get storage: object not found")
            return answer(200, "success", """{"name":"${DriveFiles.nameOf(path)}","size":${bytes.size},"is_dir":false,"sign":"${sign(path)}","raw_url":"http://cdn.invalid/x"}""")
        }
        val prefix = if (path == "/") "/" else "$path/"
        if (path != "/" && files.keys.none { it.startsWith(prefix) }) return answer(500, "failed get objs: object not found")
        val children = sortedMapOf<String, Boolean>()
        for (p in files.keys) if (p.startsWith(prefix)) p.removePrefix(prefix).let { children[it.substringBefore('/')] = '/' in it }
        val content = children.entries.joinToString(",") { (name, dir) ->
            val full = DriveFiles.join(path, "/$name")
            """{"name":"$name","size":${files[full]?.size ?: 0},"is_dir":$dir,"modified":"2024-05-01T12:34:56.789+08:00","sign":"${if (dir) "" else sign(full)}","thumb":"","type":${if (dir) 1 else 2}}"""
        }
        return answer(200, "success", """{"content":${if (children.isEmpty()) "null" else "[$content]"},"total":${children.size},"readme":"","write":false,"provider":"Local"}""")
    }

    private fun download(request: RecordedRequest): MockResponse {
        val path = DriveFiles.decodePath(request.requestUrl!!.encodedPath.removePrefix("/d"))
        val bytes = files[path] ?: return MockResponse().setResponseCode(404)
        if (request.requestUrl!!.queryParameter("sign") != sign(path)) return MockResponse().setResponseCode(401).setBody("""{"code":401,"message":"sign mismatch"}""")
        return ranged(request, bytes, "video/mp4")
    }

    fun shutdown() = server.shutdown()
}
