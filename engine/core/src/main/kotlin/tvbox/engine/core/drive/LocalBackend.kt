package tvbox.engine.core.drive

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path

/**
 * A folder on the engine's machine. Desktop and server engines only: `java.nio.file` is not there on Android 7, and
 * the Android app does not offer local folders ([DriveService.localFolders]).
 *
 * Nothing outside the folder the user added is reachable: paths with `..`, backslashes or colons are refused before
 * they touch the disk, every path is resolved to its real location (symbolic links and junctions followed) and must
 * still be inside the folder's real location, and links that lead out of it are left out of listings.
 */
internal class LocalBackend(config: DriveConfig) : DriveBackend {
    private val root: Path = try {
        File(config.url).toPath().toRealPath()
    } catch (e: IOException) {
        throw DriveException.notFound("文件夹不存在：${config.url}")
    }

    /** The real location of [path] inside the folder; refused when it is not inside. */
    fun resolve(path: String): Path {
        val normalized = DriveFiles.normalize(path, local = true)
        var p = root
        for (segment in normalized.split('/').filter { it.isNotEmpty() }) p = p.resolve(segment)
        val real = try {
            p.toRealPath()
        } catch (e: NoSuchFileException) {
            throw DriveException.notFound("不存在：$normalized")
        } catch (e: IOException) {
            throw DriveException.notFound("打不开：$normalized")
        }
        if (!real.startsWith(root)) throw DriveException.outside(normalized)
        return real
    }

    override suspend fun list(path: String): List<DriveItem> = withContext(Dispatchers.IO) {
        val folder = resolve(path)
        if (!Files.isDirectory(folder)) throw DriveException.bad("不是文件夹：$path")
        val children = folder.toFile().listFiles() ?: throw DriveException.notFound("打不开文件夹：$path")
        children.mapNotNull { child ->
            val name = child.name
            val link = child.toPath()
            if (runCatching { Files.isHidden(link) }.getOrDefault(false) || name.startsWith(".")) return@mapNotNull null
            // A link that leads out of the folder, or nowhere, is not shown.
            val real = runCatching { link.toRealPath() }.getOrNull() ?: return@mapNotNull null
            if (!real.startsWith(root)) return@mapNotNull null
            val dir = Files.isDirectory(real)
            DriveItem(
                DriveEntry(
                    name = name,
                    path = DriveFiles.join(DriveFiles.normalize(path, local = true), "/$name"),
                    dir = dir,
                    size = if (dir) 0 else runCatching { Files.size(real) }.getOrDefault(0L),
                    modified = runCatching { Files.getLastModifiedTime(real).toMillis() }.getOrDefault(0L),
                    type = DriveFiles.type(name, dir),
                ),
            )
        }
    }

    /** Players always get local files through the engine. */
    override fun direct(item: DriveItem): DirectLink? = null

    override suspend fun open(path: String, range: String?, head: Boolean): DriveStream = withContext(Dispatchers.IO) {
        val file = resolve(path)
        if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) && !Files.isRegularFile(file)) throw DriveException.bad("不是文件：$path")
        val size = Files.size(file)
        val name = DriveFiles.nameOf(path)
        val headers = linkedMapOf(
            "Accept-Ranges" to "bytes",
            "Last-Modified" to DriveHttp.httpDate(Files.getLastModifiedTime(file).toMillis()),
        )
        when (val r = ByteRange.parse(range, size)) {
            ByteRange.Unsatisfiable -> {
                headers["Content-Range"] = "bytes */$size"
                DriveStream(416, DriveFiles.contentType(name), 0, headers, null)
            }
            ByteRange.Whole -> DriveStream(200, DriveFiles.contentType(name), size, headers, if (head) null else FileRangeStream(file.toFile(), 0, size))
            is ByteRange.Part -> {
                val length = r.end - r.start + 1
                headers["Content-Range"] = "bytes ${r.start}-${r.end}/$size"
                DriveStream(206, DriveFiles.contentType(name), length, headers, if (head) null else FileRangeStream(file.toFile(), r.start, length))
            }
        }
    }
}

/** [length] bytes of [file] from [start]. */
private class FileRangeStream(file: File, start: Long, private var remaining: Long) : InputStream() {
    private val raf = RandomAccessFile(file, "r").also { it.seek(start) }

    override fun read(): Int {
        if (remaining <= 0) return -1
        val b = raf.read()
        if (b >= 0) remaining--
        return b
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (remaining <= 0) return -1
        val n = raf.read(b, off, minOf(len.toLong(), remaining).toInt())
        if (n > 0) remaining -= n
        return n
    }

    override fun close() = raf.close()
}
