package tvbox.engine.server

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.server.application.ApplicationCall
import io.ktor.server.response.header
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.method
import io.ktor.server.routing.route
import tvbox.engine.core.drive.DriveFiles
import tvbox.engine.core.drive.DriveKind
import tvbox.engine.core.drive.DriveRequest
import tvbox.engine.core.drive.DriveService
import java.io.File
import java.util.Base64

/**
 * The demo's drives: the same few short videos as a WebDAV server (`/demo/dav/`, user `demo`, password `demo`) and
 * as a folder on this machine. The videos are made by [DemoVideo] when the engine starts (no files in the
 * repository); each episode starts at another segment, so the picture says which one is playing.
 *
 * ```
 * 演示剧集/第1集.ts  第1集.srt  第2集.ts  第2集.zh.vtt  第10集.ts
 * 短片.ts
 * 说明.txt
 * ```
 */
class DemoDrive(work: File) {
    private val video = DemoVideo(segmentSeconds = 6, kbit = 300)

    /** Path inside the drive -> content; folders are implied by the paths. */
    val files: Map<String, ByteArray> = linkedMapOf(
        "/演示剧集/第1集.ts" to clip(0, 3),
        "/演示剧集/第1集.srt" to srt("第 1 集"),
        "/演示剧集/第2集.ts" to clip(3, 3),
        "/演示剧集/第2集.zh.vtt" to vtt("第 2 集"),
        "/演示剧集/第10集.ts" to clip(6, 3),
        "/短片.ts" to clip(9, 2),
        "/说明.txt" to "映舟演示网盘：几段几秒长的测试视频，画面上是分片序号和时间。\n".toByteArray(),
    )

    /** The demo folder on this machine, written afresh at every start. */
    val folder: File = File(work, "demo-drive").also { dir ->
        dir.deleteRecursively()
        for ((path, bytes) in files) File(dir, path.removePrefix("/")).apply { parentFile.mkdirs() }.writeBytes(bytes)
    }

    private val modified = System.currentTimeMillis()

    /** Adds the two demo drives unless they are there already (an engine started with `--demo --data`). */
    fun register(drives: DriveService, local: String) {
        val have = drives.list()
        if (have.none { it.kind == DriveKind.WEBDAV && it.url == "$local/demo/dav" }) {
            drives.add(DriveRequest(name = "演示 WebDAV", kind = DriveKind.WEBDAV, url = "$local/demo/dav", username = USER, password = PASSWORD), fromThisMachine = true)
        }
        if (have.none { it.kind == DriveKind.LOCAL && it.url == folder.canonicalPath }) {
            drives.add(DriveRequest(name = "演示本机文件夹", kind = DriveKind.LOCAL, url = folder.canonicalPath), fromThisMachine = true)
        }
    }

    private fun clip(first: Int, count: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(video.segmentBytes * count)
        for (i in first until first + count) out.write(video.segment(i))
        return out.toByteArray()
    }

    private fun srt(title: String) = ("1\n00:00:01,000 --> 00:00:05,000\n$title：演示字幕\n\n" +
        "2\n00:00:06,000 --> 00:00:12,000\n字幕来自视频旁边的 .srt 文件\n").toByteArray()

    private fun vtt(title: String) = ("WEBVTT\n\n00:00:01.000 --> 00:00:05.000\n$title：演示字幕\n\n" +
        "00:00:06.000 --> 00:00:12.000\n字幕来自视频旁边的 .vtt 文件\n").toByteArray()

    /** The entries right inside [folder]: name -> (is a folder, size). */
    fun children(folder: String): Map<String, Pair<Boolean, Long>> {
        val out = sortedMapOf<String, Pair<Boolean, Long>>()
        val prefix = if (folder == "/") "/" else "$folder/"
        for ((path, bytes) in files) {
            if (!path.startsWith(prefix)) continue
            val rest = path.removePrefix(prefix)
            val name = rest.substringBefore('/')
            out[name] = if ('/' in rest) (true to 0L) else (false to bytes.size.toLong())
        }
        return out
    }

    fun isFolder(path: String) = path == "/" || files.keys.any { it.startsWith("$path/") }

    companion object {
        const val USER = "demo"
        const val PASSWORD = "demo"
    }

    /** The WebDAV server: PROPFIND (depth 0 or 1), GET and HEAD with `Range`, Basic authentication. Read only. */
    internal suspend fun dav(call: ApplicationCall, path: String) {
        val expected = "Basic " + Base64.getEncoder().encodeToString("$USER:$PASSWORD".toByteArray())
        if (call.request.headers[HttpHeaders.Authorization] != expected) {
            call.response.header(HttpHeaders.WWWAuthenticate, "Basic realm=\"demo\"")
            call.respondText("", status = HttpStatusCode.Unauthorized)
            return
        }
        when (call.request.local.method.value) {
            "PROPFIND" -> propfind(call, path)
            "GET", "HEAD" -> get(call, path, head = call.request.local.method == HttpMethod.Head)
            "OPTIONS" -> {
                call.response.header("DAV", "1")
                call.response.header(HttpHeaders.Allow, "OPTIONS, GET, HEAD, PROPFIND")
                call.respondText("")
            }
            else -> call.respondText("", status = HttpStatusCode.MethodNotAllowed)
        }
    }

    private suspend fun propfind(call: ApplicationCall, path: String) {
        val bytes = files[path]
        if (bytes == null && !isFolder(path)) {
            call.respondText("", status = HttpStatusCode.NotFound)
            return
        }
        val date = java.text.SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", java.util.Locale.US)
            .apply { timeZone = java.util.TimeZone.getTimeZone("GMT") }.format(java.util.Date(modified))
        fun response(p: String, dir: Boolean, size: Long) = buildString {
            val href = "/demo/dav" + DriveFiles.encodePath(p) + if (dir && p != "/") "/" else ""
            append("<D:response><D:href>").append(href).append("</D:href><D:propstat><D:prop>")
            append("<D:displayname>").append(if (p == "/") "dav" else DriveFiles.nameOf(p)).append("</D:displayname>")
            if (dir) append("<D:resourcetype><D:collection/></D:resourcetype>") else append("<D:resourcetype/><D:getcontentlength>$size</D:getcontentlength>")
            append("<D:getlastmodified>").append(date).append("</D:getlastmodified>")
            append("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>")
        }
        val body = StringBuilder("<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">")
        if (bytes != null) {
            body.append(response(path, false, bytes.size.toLong()))
        } else {
            body.append(response(path, true, 0))
            if (call.request.headers["Depth"] != "0") {
                for ((name, info) in children(path)) body.append(response(DriveFiles.join(path, "/$name"), info.first, info.second))
            }
        }
        body.append("</D:multistatus>")
        call.respondText(body.toString(), ContentType.parse("application/xml; charset=utf-8"), HttpStatusCode.MultiStatus)
    }

    private suspend fun get(call: ApplicationCall, path: String, head: Boolean) {
        val bytes = files[path]
        if (bytes == null) {
            call.respondText("", status = HttpStatusCode.NotFound)
            return
        }
        val size = bytes.size.toLong()
        val type = ContentType.parse(DriveFiles.contentType(path))
        call.response.header(HttpHeaders.AcceptRanges, "bytes")
        val m = Regex("bytes=(\\d*)-(\\d*)").matchEntire(call.request.headers[HttpHeaders.Range]?.trim().orEmpty())
        if (m == null) {
            if (head) headOnly(call, HttpStatusCode.OK, type, size) else call.respondBytes(bytes, type, HttpStatusCode.OK)
            return
        }
        val (a, b) = m.destructured
        val start = if (a.isEmpty()) maxOf(0, size - (b.toLongOrNull() ?: 0)) else a.toLong()
        val end = if (a.isEmpty() || b.isEmpty()) size - 1 else minOf(b.toLong(), size - 1)
        if (start >= size || end < start) {
            call.response.header(HttpHeaders.ContentRange, "bytes */$size")
            call.respondText("", status = HttpStatusCode.RequestedRangeNotSatisfiable)
            return
        }
        call.response.header(HttpHeaders.ContentRange, "bytes $start-$end/$size")
        if (head) {
            headOnly(call, HttpStatusCode.PartialContent, type, end - start + 1)
        } else {
            call.respondBytes(bytes.copyOfRange(start.toInt(), end.toInt() + 1), type, HttpStatusCode.PartialContent)
        }
    }

    private suspend fun headOnly(call: ApplicationCall, status: HttpStatusCode, type: ContentType, length: Long) {
        call.respond(object : OutgoingContent.NoContent() {
            override val status = status
            override val contentType = type
            override val contentLength = length
        })
    }
}

/** `/demo/dav/...`: the demo WebDAV server. */
fun Route.demoDriveRoutes(demo: DemoDrive) {
    route("/demo/dav/{path...}") {
        for (m in listOf(HttpMethod("PROPFIND"), HttpMethod.Get, HttpMethod.Head, HttpMethod.Options)) {
            method(m) {
                handle {
                    val segments = call.parameters.getAll("path").orEmpty().filter { it.isNotEmpty() }
                    if (segments.any { it == "." || it == ".." }) {
                        call.respondText("", status = HttpStatusCode.BadRequest)
                        return@handle
                    }
                    demo.dav(call, "/" + segments.joinToString("/"))
                }
            }
        }
    }
}
