package tvbox.engine.core.spider

import okhttp3.OkHttpClient
import okhttp3.Request
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.util.Base64Compat
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Downloads and caches spider jars, following TVBox `JarLoader.parseJar` / `ApiConfig.loadJar`:
 *
 * - `url;md5;<md5 or url of md5>`: the cached jar is reused only while its md5 matches;
 * - without md5 the cache is reused for a week;
 * - `img+url`: the jar is base64 inside an image, after an 8-character marker and `**`;
 * - `clan://` / `file://` go through the engine's file mapping.
 */
class JarRepository(
    private val http: OkHttpClient,
    private val locator: ConfigLocator,
    private val dir: File,
) {
    fun fetch(spec: String): File {
        val (source, md5Spec) = spec.split(";md5;", limit = 2).let { it[0].trim() to it.getOrNull(1)?.trim().orEmpty() }
        val isImage = source.startsWith("img+")
        val url = source.removePrefix("img+").let {
            if (it.startsWith("clan://") || it.startsWith("file://")) locator.clanToAddress(it.replace("file://", "clan://localhost/")) else it
        }
        val expectedMd5 = if (md5Spec.startsWith("http")) runCatching { text(md5Spec).trim() }.getOrDefault("") else md5Spec
        val file = File(dir, md5(source) + ".jar")

        val cacheValid = file.length() > 0 && when {
            expectedMd5.isNotEmpty() -> fileMd5(file).equals(expectedMd5, ignoreCase = true)
            else -> System.currentTimeMillis() - file.lastModified() < TimeUnit.DAYS.toMillis(7)
        }
        if (cacheValid) return file

        val bytes = try {
            download(url, isImage)
        } catch (e: Exception) {
            // Offline or the host is down: an older copy is better than nothing.
            if (file.length() > 0) return file
            throw e
        }
        dir.mkdirs()
        // Android 14+ refuses to load writable dex files, so write elsewhere and publish read-only.
        val tmp = File(dir, file.name + ".tmp")
        tmp.writeBytes(bytes)
        file.setWritable(true)
        file.delete()
        if (!tmp.renameTo(file)) throw IllegalStateException("cannot store jar ${file.path}")
        return file
    }

    private fun download(url: String, isImage: Boolean): ByteArray {
        http.newCall(Request.Builder().url(url).build()).execute().use { res ->
            if (!res.isSuccessful) throw IllegalStateException("HTTP ${res.code} for $url")
            val body = res.body ?: throw IllegalStateException("empty jar body from $url")
            if (!isImage) return body.bytes()
            val text = body.string()
            val marker = IMAGE_MARKER.find(text) ?: throw IllegalStateException("no jar inside image $url")
            return Base64Compat.decode(text.substring(text.indexOf(marker.value) + 10))
        }
    }

    private fun text(url: String): String = http.newCall(Request.Builder().url(url).build()).execute().use { it.body?.string().orEmpty() }

    private companion object {
        val IMAGE_MARKER = Regex("[A-Za-z0-9]{8}\\*\\*")

        fun md5(s: String): String = hex(MessageDigest.getInstance("MD5").digest(s.toByteArray()))

        fun fileMd5(f: File): String = f.inputStream().use { input ->
            val md = MessageDigest.getInstance("MD5")
            val buf = ByteArray(16 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
            hex(md.digest())
        }

        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    }
}
