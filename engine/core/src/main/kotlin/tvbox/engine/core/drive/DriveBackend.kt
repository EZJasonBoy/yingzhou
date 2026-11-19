package tvbox.engine.core.drive

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Response
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** One kind of drive: lists folders, says where players fetch a file, and reads files for the engine's own route. */
internal interface DriveBackend {
    /** The entries of the folder [path] (normalised, inside the drive), in no particular order. */
    suspend fun list(path: String): List<DriveItem>

    /** An address a player can fetch [item] at by itself, or null when only the engine can (it needs credentials). */
    fun direct(item: DriveItem): DirectLink?

    /** The bytes of the file [path] for the engine's `/drive/` route; [range] is the player's `Range` header. */
    suspend fun open(path: String, range: String?, head: Boolean): DriveStream
}

/** A listed entry plus what the server needs to hand it out (an AList signature). */
internal data class DriveItem(val entry: DriveEntry, val sign: String = "")

internal data class DirectLink(val url: String, val headers: Map<String, String> = emptyMap())

/**
 * A file, or a part of it, on its way to a player. [status] 200, 206 or 416; [length] is the length of [body] (null:
 * not known). Closing it releases whatever holds the bytes (a file, a connection).
 */
class DriveStream(
    val status: Int,
    val contentType: String,
    val length: Long?,
    /** Content-Range, Accept-Ranges, Last-Modified, ETag, as they apply. */
    val headers: Map<String, String>,
    val body: InputStream?,
    private val release: () -> Unit = {},
) : Closeable {
    override fun close() {
        runCatching { body?.close() }
        runCatching { release() }
    }
}

/** A single `bytes=` range of a file of known size: what to send, or that nothing fits. Multiple ranges are not served. */
internal sealed class ByteRange {
    object Whole : ByteRange()
    object Unsatisfiable : ByteRange()
    data class Part(val start: Long, val end: Long) : ByteRange()

    companion object {
        fun parse(header: String?, size: Long): ByteRange {
            val spec = header?.trim()?.takeIf { it.startsWith("bytes=", ignoreCase = true) }?.substring(6)?.trim() ?: return Whole
            if (',' in spec) return Whole
            val dash = spec.indexOf('-')
            if (dash < 0) return Whole
            val a = spec.substring(0, dash).trim()
            val b = spec.substring(dash + 1).trim()
            if (a.isEmpty()) {
                val n = b.toLongOrNull() ?: return Whole
                if (n <= 0 || size == 0L) return Unsatisfiable
                return Part(maxOf(0, size - n), size - 1)
            }
            val start = a.toLongOrNull() ?: return Whole
            if (start >= size) return Unsatisfiable
            val end = if (b.isEmpty()) size - 1 else (b.toLongOrNull() ?: return Whole).coerceAtMost(size - 1)
            if (end < start) return Unsatisfiable
            return Part(start, end)
        }
    }
}

internal object DriveHttp {
    suspend fun execute(call: Call): Response = withContext(Dispatchers.IO) {
        try {
            call.execute()
        } catch (e: IOException) {
            throw DriveException.unreachable("连接不上服务器：${e.message ?: e.javaClass.simpleName}")
        }
    }

    suspend fun text(response: Response): String = withContext(Dispatchers.IO) { response.body?.string().orEmpty() }

    /** What a server's answer to a file request becomes for the player; the response is closed with the stream. */
    fun relay(response: Response, name: String, head: Boolean): DriveStream {
        val code = response.code
        if (code !in 200..299 && code != 416) {
            response.close()
            throw when (code) {
                401, 403 -> DriveException.auth("服务器拒绝了这个文件（HTTP $code）")
                404 -> DriveException.notFound("文件不存在：$name")
                else -> DriveException.unreachable("服务器回答 HTTP $code")
            }
        }
        val upstreamType = response.header("Content-Type").orEmpty()
        // Many servers say octet-stream for everything; players do better with the real type.
        val type = if (upstreamType.isBlank() || upstreamType.startsWith("application/octet-stream")) DriveFiles.contentType(name) else upstreamType
        val headers = LinkedHashMap<String, String>()
        for (h in listOf("Content-Range", "Accept-Ranges", "Last-Modified", "ETag")) response.header(h)?.let { headers[h] = it }
        val length = response.header("Content-Length")?.toLongOrNull()
        val body = if (head || code == 416) null else response.body?.byteStream()
        if (body == null) response.close()
        return DriveStream(code, type, if (code == 416) 0 else length, headers, body) { response.close() }
    }

    fun httpDate(ms: Long): String = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT") }.format(Date(ms))

    /** Loopback names a player on another device cannot reach; no DNS lookup. */
    fun isLoopback(url: String): Boolean {
        val host = url.toHttpHost() ?: return false
        return host == "localhost" || host.startsWith("127.") || host == "::1" || host == "[::1]" || host.endsWith(".localhost")
    }

    private fun String.toHttpHost(): String? {
        val rest = substringAfter("://", "").takeIf { it.isNotEmpty() } ?: return null
        val authority = rest.substringBefore('/').substringBefore('?').substringAfterLast('@')
        val host = if (authority.startsWith("[")) authority.substringBefore(']') + "]" else authority.substringBefore(':')
        return host.lowercase(Locale.ROOT)
    }
}
