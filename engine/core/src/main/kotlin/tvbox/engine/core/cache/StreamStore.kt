package tvbox.engine.core.cache

import java.io.File

/**
 * Files of streams on disk, kept under a size cap: `<root>/<stream>/<name>` is a finished file (a segment, a key, an
 * initialisation map), `<name>.part` one that is still being written, and `_<name>` a note that goes with the stream
 * (what its files are called at the source).
 *
 * Over the cap, the files used longest ago go first, whichever stream they belong to; a stream that is [pin]ned is
 * left alone and does not count. That is what a download for offline viewing is meant to be: a pinned stream that has
 * all its files. The time a file was last used is its modification time, so the order survives a restart.
 *
 * With a [reserveBytes] (a phone may be low on space) the store also gives way to the disk: it never fills the disk
 * beyond leaving that much free, trimming below its cap when it has to, and [lowOnSpace] tells the cache to stop
 * keeping anything new.
 *
 * Only `java.io` is used (the engine also runs on Android 7). Safe to call from any thread.
 */
class StreamStore(
    val root: File,
    maxBytes: Long = DEFAULT_MAX_BYTES,
    /** The disk is left at least this much free; 0: free space is not looked at (only the cap counts). */
    val reserveBytes: Long = 0,
    private val freeSpace: (File) -> Long = { it.usableSpace },
    private val now: () -> Long = System::currentTimeMillis,
) {
    class Stats(
        val bytes: Long,
        val files: Int,
        val streams: Int,
        val pinnedBytes: Long,
        val maxBytes: Long,
        /** Free space on the disk the store is on; -1 when the store does not look at it (no [reserveBytes]). */
        val freeBytes: Long = -1,
        val reserveBytes: Long = 0,
    )

    private class Entry(@Volatile var size: Long, @Volatile var usedAt: Long)

    private class Stream(val dir: File) {
        val files = HashMap<String, Entry>()
        var pinned = false
    }

    private val lock = Any()
    private val streams = HashMap<String, Stream>()
    private var loaded = false

    /** Bytes of the finished files of streams that are not pinned. */
    private var total = 0L

    /** The cap; lowering it trims at once. */
    @Volatile var maxBytes: Long = maxBytes
        set(value) {
            field = value
            trim()
        }

    /** The finished file, or null. Counts as a use. */
    fun file(stream: String, name: String): File? = synchronized(lock) {
        val s = load()[stream] ?: return null
        val entry = s.files[name] ?: return null
        val file = File(s.dir, name)
        if (!file.isFile) {
            // Removed behind our back (the user emptied the folder).
            s.files.remove(name)
            if (!s.pinned) total -= entry.size
            return null
        }
        val t = now()
        // The modification time is only moved now and then: it is there to order files after a restart.
        if (t - entry.usedAt > TOUCH_EVERY_MS) file.setLastModified(t)
        entry.usedAt = t
        file
    }

    fun has(stream: String, name: String): Boolean = synchronized(lock) { load()[stream]?.files?.containsKey(name) == true }

    /** Where to write [name] while it is incomplete; [commit] makes it a finished file. */
    fun partFile(stream: String, name: String): File = synchronized(lock) {
        // What earlier runs left unfinished is swept away before anything new is written.
        load()
        File(dirOf(stream), "$name$PART")
    }

    /**
     * The `.part` file has everything: it becomes the finished file. False when it cannot be renamed yet (on Windows,
     * while someone still reads it); the caller tries again later.
     */
    fun commit(stream: String, name: String): Boolean {
        synchronized(lock) {
            val s = load().getOrPut(stream) { Stream(dirOf(stream)) }
            val part = File(s.dir, "$name$PART")
            val file = File(s.dir, name)
            if (!part.isFile) return file.isFile
            if (file.exists() && !file.delete()) return false
            if (!part.renameTo(file)) return false
            val t = now()
            file.setLastModified(t)
            s.files.put(name, Entry(file.length(), t))?.let { if (!s.pinned) total -= it.size }
            if (!s.pinned) total += file.length()
        }
        if (overCap()) trim()
        return true
    }

    /**
     * Moves [finished], a complete file written somewhere in the stream's folder by someone else (a download, see
     * [workFile]), in as [name]. When [name] is there already (a player had it fetched meanwhile) that copy stays and
     * [finished] goes. False when the file cannot be moved in yet.
     */
    fun adopt(stream: String, name: String, finished: File): Boolean {
        synchronized(lock) {
            val s = load().getOrPut(stream) { Stream(dirOf(stream)) }
            val file = File(s.dir, name)
            if (s.files.containsKey(name) && file.isFile) {
                finished.delete()
                return true
            }
            if (!finished.isFile) return false
            if (file.exists() && !file.delete()) return false
            if (!finished.renameTo(file)) return false
            val t = now()
            file.setLastModified(t)
            s.files.put(name, Entry(file.length(), t))?.let { if (!s.pinned) total -= it.size }
            if (!s.pinned) total += file.length()
        }
        if (overCap()) trim()
        return true
    }

    /**
     * A file in the stream's folder for work in progress that is not one of the stream's files: the store neither
     * counts it nor serves it. Its name starts with `_`; one that ends in `.part` is swept away at the next start,
     * any other (a resumable download's) stays.
     */
    fun workFile(stream: String, name: String): File = synchronized(lock) {
        load()
        File(dirOf(stream), "_$name")
    }

    /** Bytes of the stream's finished files. */
    fun size(stream: String): Long = synchronized(lock) { load()[stream]?.files?.values?.sumOf { it.size } ?: 0L }

    /**
     * Deletes the stream: its files, notes and work files (a download that was deleted). A file someone is reading
     * right now stays, no longer pinned, and goes with the cache's next trim. The `.part` files a player's download
     * is writing are left to it. Returns the bytes freed.
     */
    fun remove(stream: String): Long {
        var freed = 0L
        synchronized(lock) {
            val s = load()[stream]
            if (s == null) {
                File(root, stream).listFiles()?.forEach { if (it.name.startsWith("_") || !it.name.endsWith(PART)) it.delete() }
                File(root, stream).delete()
                return 0
            }
            for ((name, entry) in s.files.entries.toList()) {
                if (!File(s.dir, name).delete()) continue
                s.files.remove(name)
                if (!s.pinned) total -= entry.size
                freed += entry.size
            }
            if (s.pinned) {
                s.pinned = false
                total += s.files.values.sumOf { it.size }
            }
            s.dir.listFiles()?.forEach { f ->
                if (f.name !in s.files && (f.name.startsWith("_") || !f.name.endsWith(PART))) f.delete()
            }
            dropIfEmpty(stream, s)
        }
        trim()
        return freed
    }

    /** Gives up an unfinished file. */
    fun discard(stream: String, name: String) {
        synchronized(lock) { File(File(root, stream), "$name$PART").delete() }
    }

    /** A small text that belongs to the stream; it goes when the stream's last file goes. */
    fun writeNote(stream: String, name: String, text: String) = synchronized(lock) {
        load()
        val target = File(dirOf(stream), "_$name")
        val tmp = File(target.path + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) tmp.delete()
        }
    }

    fun readNote(stream: String, name: String): String? = synchronized(lock) {
        load()
        File(File(root, stream), "_$name").takeIf { it.isFile }?.let { runCatching { it.readText() }.getOrNull() }
    }

    /** A pinned stream is never trimmed and does not count towards the cap. */
    fun pin(stream: String, pinned: Boolean) {
        synchronized(lock) {
            val s = load().getOrPut(stream) { Stream(dirOf(stream)) }
            if (s.pinned == pinned) return
            val bytes = s.files.values.sumOf { it.size }
            total += if (pinned) -bytes else bytes
            s.pinned = pinned
            val marker = File(s.dir, PIN)
            if (pinned) marker.writeText("") else marker.delete()
        }
        if (!pinned) trim()
    }

    fun isPinned(stream: String): Boolean = synchronized(lock) { load()[stream]?.pinned == true }

    /** The names of the stream's finished files. */
    fun names(stream: String): Set<String> = synchronized(lock) { load()[stream]?.files?.keys?.toSet().orEmpty() }

    fun stats(): Stats = synchronized(lock) {
        val all = load().values
        Stats(
            bytes = total,
            files = all.filter { !it.pinned }.sumOf { it.files.size },
            streams = all.count { !it.pinned && it.files.isNotEmpty() },
            pinnedBytes = all.filter { it.pinned }.sumOf { s -> s.files.values.sumOf { it.size } },
            maxBytes = maxBytes,
            freeBytes = if (reserveBytes > 0) free(fresh = true) else -1,
            reserveBytes = reserveBytes,
        )
    }

    /**
     * True when even deleting everything of the cache would leave hardly any room above [reserveBytes] (a tenth of
     * it): nothing new should be kept then. Always false without a reserve. Deletes nothing itself.
     */
    fun lowOnSpace(): Boolean {
        if (reserveBytes <= 0) return false
        val free = free()
        if (free < 0) return false
        return total + free - reserveBytes < reserveBytes / 10
    }

    @Volatile private var freeAt = 0L
    @Volatile private var freeSeen = -1L

    /** Free space on the store's disk (looked up at most once a second unless [fresh]); -1 unknown. */
    private fun free(fresh: Boolean = false): Long {
        val t = now()
        if (!fresh && freeSeen >= 0 && t - freeAt in 0 until FREE_EVERY_MS) return freeSeen
        root.mkdirs()
        freeSeen = runCatching { freeSpace(root) }.getOrDefault(-1L)
        freeAt = t
        return freeSeen
    }

    /** What the store may hold now: the cap, or less when the disk would otherwise have less than the reserve left. */
    private fun limit(): Long {
        if (reserveBytes <= 0) return maxBytes
        val free = free()
        if (free < 0) return maxBytes
        return minOf(maxBytes, (total + free - reserveBytes).coerceAtLeast(0))
    }

    /**
     * Deletes every finished file that is not pinned and that [keep] does not hold on to (files being read right
     * now). Returns the bytes freed.
     */
    fun clear(keep: (stream: String, name: String) -> Boolean = { _, _ -> false }): Long = synchronized(lock) {
        var freed = 0L
        for ((id, s) in load().entries.toList()) {
            if (s.pinned) continue
            for ((name, entry) in s.files.entries.toList()) {
                if (keep(id, name) || !File(s.dir, name).delete()) continue
                s.files.remove(name)
                total -= entry.size
                freed += entry.size
            }
            dropIfEmpty(id, s)
        }
        freed
    }

    /**
     * Brings the store back under the cap (a little below it, so that it does not trim on every file); with a
     * [reserveBytes], under what the disk has room for.
     */
    fun trim(keep: (stream: String, name: String) -> Boolean = { _, _ -> false }) {
        synchronized(lock) {
            load()
            val cap = limit()
            if (total <= cap) return
            val target = cap - cap / 10
            val oldest = streams.entries.filter { !it.value.pinned }
                .flatMap { (id, s) -> s.files.entries.map { Triple(id, it.key, it.value) } }
                .sortedBy { it.third.usedAt }
            for ((id, name, entry) in oldest) {
                if (total <= target) break
                val s = streams[id] ?: continue
                // A file that is open (Windows refuses to delete it) or wanted stays for now.
                if (keep(id, name) || !File(s.dir, name).delete()) continue
                s.files.remove(name)
                total -= entry.size
                dropIfEmpty(id, s)
            }
        }
    }

    private fun overCap(): Boolean = synchronized(lock) { total > limit() }

    private fun dirOf(stream: String): File = File(root, stream).also { it.mkdirs() }

    /** Caller holds [lock]. A stream without files takes its notes and its folder with it. */
    private fun dropIfEmpty(id: String, s: Stream) {
        if (s.files.isNotEmpty() || s.pinned) return
        if (s.dir.listFiles()?.any { it.name.endsWith(PART) } == true) return
        s.dir.listFiles()?.forEach { it.delete() }
        s.dir.delete()
        streams.remove(id)
    }

    /** Caller holds [lock]. Reads the folder once: what is there from earlier runs, without the unfinished files. */
    private fun load(): HashMap<String, Stream> {
        if (loaded) return streams
        loaded = true
        for (dir in root.listFiles().orEmpty()) {
            if (!dir.isDirectory) continue
            val s = Stream(dir)
            for (f in dir.listFiles().orEmpty()) {
                when {
                    f.name == PIN -> s.pinned = true
                    f.name.endsWith(PART) || f.name.endsWith(".tmp") -> f.delete()
                    f.name.startsWith("_") -> Unit
                    f.isFile -> s.files[f.name] = Entry(f.length(), f.lastModified())
                }
            }
            streams[dir.name] = s
            if (!s.pinned) total += s.files.values.sumOf { it.size }
            dropIfEmpty(dir.name, s)
        }
        return streams
    }

    companion object {
        const val DEFAULT_MAX_BYTES = 2L * 1024 * 1024 * 1024
        private const val PART = ".part"
        private const val PIN = "_pinned"
        private const val TOUCH_EVERY_MS = 60_000L
        private const val FREE_EVERY_MS = 1_000L
    }
}
