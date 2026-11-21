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

        // The md5 in the config is of the download, which may be an image wrapping the jar.
        val md5File = File(dir, file.name + ".md5")
        val cacheValid = file.length() > 0 && when {
            expectedMd5.isNotEmpty() -> (md5File.takeIf { it.isFile }?.readText()?.trim() ?: fileMd5(file)).equals(expectedMd5, ignoreCase = true)
            else -> System.currentTimeMillis() - file.lastModified() < TimeUnit.DAYS.toMillis(7)
        }
        if (cacheValid) return file

        val raw = try {
            download(url)
        } catch (e: Exception) {
            // Offline or the host is down: an older copy is better than nothing.
            if (file.length() > 0) return file
            throw e
        }
        val bytes = try {
            unwrap(raw, isImage, url)
        } catch (e: IllegalStateException) {
            // The address now serves something else (a web page, an error message): an older copy is better.
            if (file.length() > 0) return file
            throw e
        }
        dir.mkdirs()
        md5File.writeText(hex(MessageDigest.getInstance("MD5").digest(raw)))
        // Android 14+ refuses to load writable dex files, so write elsewhere and publish read-only.
        val tmp = File(dir, file.name + ".tmp")
        tmp.writeBytes(bytes)
        file.setWritable(true)
        file.delete()
        if (!tmp.renameTo(file)) throw IllegalStateException("cannot store jar ${file.path}")
        return file
    }

    private fun download(url: String): ByteArray {
        http.newCall(Request.Builder().url(url).build()).execute().use { res ->
            if (!res.isSuccessful) throw IllegalStateException("HTTP ${res.code} for $url")
            return res.body?.bytes() ?: throw IllegalStateException("empty jar body from $url")
        }
    }

    private fun text(url: String): String = http.newCall(Request.Builder().url(url).build()).execute().use { it.body?.string().orEmpty() }

    internal companion object {
        val IMAGE_MARKER = Regex("[A-Za-z0-9]{8}\\*\\*")

        /**
         * Jars are often disguised as images: `img+url` (base64 after an 8-character marker and `**`), or a plain
         * image url whose file is an image with the jar appended. Returns the jar (or dex) itself.
         */
        fun unwrap(bytes: ByteArray, isImage: Boolean, url: String): ByteArray {
            if (!isImage && (isZip(bytes, 0) || isDex(bytes))) return bytes
            val text = String(bytes, Charsets.ISO_8859_1)
            IMAGE_MARKER.find(text)?.let { marker ->
                val decoded = runCatching { Base64Compat.decode(text.substring(marker.range.last + 1).trim()) }.getOrNull()
                if (decoded != null && (isZip(decoded, 0) || isDex(decoded))) return decoded
            }
            val zipAt = (0..bytes.size - 4).firstOrNull { isZip(bytes, it) }
            if (zipAt != null) return bytes.copyOfRange(zipAt, bytes.size)
            if (isImage) throw IllegalStateException("no jar inside image $url")
            if (looksLikeText(bytes)) throw IllegalStateException("$url answered with ${describeText(bytes)}, not a jar")
            return bytes
        }

        /** A jar address that now serves a web page, a JSON error or a short message: the address is dead. */
        private fun looksLikeText(b: ByteArray): Boolean {
            if (b.isEmpty()) return true
            val head = b.copyOfRange(0, minOf(b.size, 512))
            val printable = head.count { val c = it.toInt() and 0xff; c == 9 || c == 10 || c == 13 || c >= 32 }
            return printable >= head.size * 0.95
        }

        private fun describeText(b: ByteArray): String {
            val text = String(b, 0, minOf(b.size, 512), Charsets.UTF_8).trimStart('\uFEFF', ' ', '\n', '\r', '\t')
            return when {
                text.isEmpty() -> "an empty file"
                text.startsWith("<") -> "a web page"
                else -> "text (\"${text.lineSequence().first().take(60)}\")"
            }
        }

        private fun isZip(b: ByteArray, at: Int) =
            b.size >= at + 4 && b[at] == 0x50.toByte() && b[at + 1] == 0x4b.toByte() && b[at + 2] == 3.toByte() && b[at + 3] == 4.toByte()

        private fun isDex(b: ByteArray) = b.size > 4 && b[0] == 'd'.code.toByte() && b[1] == 'e'.code.toByte() && b[2] == 'x'.code.toByte() && b[3] == '\n'.code.toByte()

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
