package tvbox.next.tvbox_client.engine

import android.app.Activity
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import okhttp3.OkHttpClient
import okhttp3.Request
import tvbox.engine.core.download.DownloadManager
import tvbox.engine.core.model.DownloadExportResult
import java.io.BufferedOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.net.URLDecoder
import java.util.concurrent.TimeUnit

/**
 * Exports of downloads on Android, where there is no folder a user would type in: Android 10 and later put them into
 * the system's Downloads (`Download/映舟/`, through MediaStore, no permission needed), older versions into the app's
 * own `Download` folder on the shared storage (visible in file managers and over USB). Either way the answer carries
 * a `content://` address that the share sheet can hand to other apps.
 */
object AndroidExports {
    const val FOLDER = "映舟"

    /** What the engine's [DownloadManager] calls for an export without a path. */
    fun publish(context: Context, export: DownloadManager.Export): DownloadExportResult {
        val saved = save(context, export.fileName, mimeOf(export.format)) { out -> export.write(out) }
        return DownloadExportResult(saved.path, saved.bytes, export.format, uri = saved.uri.toString())
    }

    /**
     * Fetches the export of a download from an engine on another device ([url], `.../dl/<id>/export`, with [token] if
     * it wants one) straight into the system's Downloads. Blocking. Returns the place, the size and the address.
     */
    fun saveFromEngine(context: Context, url: String, token: String?): Saved {
        val http = OkHttpClient.Builder().readTimeout(5, TimeUnit.MINUTES).build()
        val request = Request.Builder().url(url).apply { if (!token.isNullOrEmpty()) header("Authorization", "Bearer $token") }.build()
        http.newCall(request).execute().use { response ->
            val body = response.body ?: throw IOException("引擎没有返回内容")
            if (response.code != 200) {
                val text = runCatching { body.string() }.getOrDefault("")
                val message = Regex("\"message\"\\s*:\\s*\"([^\"]*)\"").find(text)?.groupValues?.get(1)
                throw IOException(message ?: "HTTP ${response.code}")
            }
            val name = fileName(response.header("Content-Disposition"), url)
            val mime = body.contentType()?.let { "${it.type}/${it.subtype}" } ?: mimeOf(name.substringAfterLast('.', ""))
            return save(context, name, mime) { out -> body.byteStream().use { it.copyTo(out, 256 * 1024) } }
        }
    }

    class Saved(val path: String, val bytes: Long, val uri: Uri)

    private fun save(context: Context, fileName: String, mime: String, write: (OutputStream) -> Long): Saved {
        if (Build.VERSION.SDK_INT >= 29) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + FOLDER)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw IOException("系统不让写入「下载」文件夹")
            try {
                val stream = resolver.openOutputStream(uri) ?: throw IOException("系统不让写入「下载」文件夹")
                val bytes = BufferedOutputStream(stream, 256 * 1024).use { write(it) }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                // The system may have given it another name (one of that name is there already).
                val shown = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0) else null
                } ?: fileName
                return Saved("${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/$shown", bytes, uri)
            } catch (x: Throwable) {
                runCatching { resolver.delete(uri, null, null) }
                throw x
            }
        }
        val dir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: File(context.filesDir, "exports")
        dir.mkdirs()
        val file = unused(dir, fileName)
        val part = File(file.path + ".part")
        val bytes = try {
            BufferedOutputStream(part.outputStream(), 256 * 1024).use { write(it) }
        } catch (x: Throwable) {
            part.delete()
            throw x
        }
        if (!part.renameTo(file)) {
            part.delete()
            throw IOException("写不进 ${file.absolutePath}")
        }
        return Saved(file.absolutePath, bytes, FileProvider.getUriForFile(context, context.packageName + ".exports", file))
    }

    /** Opens the share sheet for an exported file. Only `content://` addresses (ours or MediaStore's) are shared. */
    fun share(activity: Activity, uri: String, title: String) {
        val u = Uri.parse(uri)
        if (u.scheme != "content") throw IllegalArgumentException("not a content address")
        val mime = activity.contentResolver.getType(u) ?: "video/*"
        val send = Intent(Intent.ACTION_SEND)
            .setType(mime)
            .putExtra(Intent.EXTRA_STREAM, u)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        // The grant reaches the app picked in the chooser only through ClipData on newer versions.
        send.clipData = ClipData.newRawUri(title, u)
        activity.startActivity(Intent.createChooser(send, title))
    }

    fun mimeOf(format: String): String = when (format.lowercase()) {
        "ts" -> "video/mp2t"
        "mp4", "m4v" -> "video/mp4"
        "mkv" -> "video/x-matroska"
        "flv" -> "video/x-flv"
        "webm" -> "video/webm"
        "avi" -> "video/x-msvideo"
        "mov" -> "video/quicktime"
        else -> "application/octet-stream"
    }

    /** `filename*=UTF-8''<name>` (the real name) or `filename="..."`, made safe for a file system. */
    private fun fileName(disposition: String?, url: String): String {
        val header = disposition.orEmpty()
        val star = Regex("filename\\*=UTF-8''([^;]+)", RegexOption.IGNORE_CASE).find(header)?.groupValues?.get(1)
        val plain = Regex("filename=\"([^\"]*)\"").find(header)?.groupValues?.get(1)
        val name = star?.let { runCatching { URLDecoder.decode(it.trim().replace("+", "%2B"), "UTF-8") }.getOrNull() }
            ?: plain ?: ("video-" + url.substringBeforeLast("/export").substringAfterLast('/') + ".ts")
        return name.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_").ifBlank { "video.ts" }
    }

    private fun unused(dir: File, name: String): File {
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var file = File(dir, name)
        var i = 2
        while (file.exists()) file = File(dir, "$base ($i)$ext").also { i++ }
        return file
    }
}
