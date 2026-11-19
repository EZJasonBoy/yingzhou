package tvbox.engine.core.cache

import kotlinx.serialization.Serializable
import java.io.File
import java.security.MessageDigest

/** Sizes of the engine's data cache (`/api/v1/cache`). */
@Serializable
data class CacheInfo(
    val bytes: Long = 0,
    val entries: Int = 0,
    /** By area: `config` (subscription copies), `site` (home / category / detail answers), `ext`, `live`. */
    val areas: Map<String, CacheArea> = emptyMap(),
)

@Serializable
data class CacheArea(val bytes: Long = 0, val entries: Int = 0)

/**
 * Text the engine fetched, kept so the app opens at once and keeps working when a source is slow or the network
 * is down: copies of subscriptions, answers of sites, `ext` files, live lists. One file per entry under
 * `dir/<area>/`, plus the most recently used entries in memory. Without a [dir] (demo mode, tests) only memory.
 *
 * Bounded: an area is trimmed to [maxAreaBytes] (oldest first) and entries older than [maxAgeMs] are dropped;
 * the `config` area is exempt, since it holds one small file per subscription and is what a start depends on.
 */
class DataCache(
    private val dir: File? = null,
    private val maxAreaBytes: Long = 48L * 1024 * 1024,
    private val maxAgeMs: Long = 14L * 24 * 3600_000,
    private val memoryEntries: Int = 300,
    private val now: () -> Long = System::currentTimeMillis,
) {
    class Entry(val at: Long, val text: String)

    private val lock = Any()
    private val memory = object : LinkedHashMap<String, Entry>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Entry>?): Boolean =
            // Without a disk the config copies must not fall out behind site pages.
            size > memoryEntries && (dir != null || eldest?.key?.startsWith("$CONFIG/") != true)
    }
    private var writes = 0

    fun get(area: String, key: String): Entry? = synchronized(lock) {
        memory["$area/$key"]?.let { return it }
        val file = file(area, key) ?: return null
        val entry = runCatching {
            val text = file.readText()
            val split = text.indexOf('\n')
            Entry(text.substring(0, split).toLong(), text.substring(split + 1))
        }.getOrNull() ?: return null
        memory["$area/$key"] = entry
        entry
    }

    fun put(area: String, key: String, text: String): Entry = synchronized(lock) {
        val entry = Entry(now(), text)
        memory["$area/$key"] = entry
        val file = file(area, key) ?: return entry
        runCatching {
            file.parentFile.mkdirs()
            val tmp = File(file.path + ".tmp")
            tmp.writeText("${entry.at}\n$text")
            if (!tmp.renameTo(file)) {
                file.delete()
                tmp.renameTo(file)
            }
        }
        if (area != CONFIG && ++writes % 40 == 0) trim(area)
        entry
    }

    /** Empties [areas], or everything when none is named. */
    fun clear(vararg areas: String) = synchronized(lock) {
        if (areas.isEmpty()) memory.clear() else memory.keys.removeAll { k -> areas.any { k.startsWith("$it/") } }
        val root = dir ?: return@synchronized
        val dirs = if (areas.isEmpty()) root.listFiles { f -> f.isDirectory }.orEmpty().toList() else areas.map { File(root, it) }
        dirs.forEach { d -> d.listFiles()?.forEach { it.delete() } }
    }

    fun info(): CacheInfo = synchronized(lock) {
        val root = dir
        val areas = LinkedHashMap<String, CacheArea>()
        if (root == null) {
            memory.entries.groupBy { it.key.substringBefore('/') }.forEach { (area, list) ->
                areas[area] = CacheArea(list.sumOf { it.value.text.length.toLong() }, list.size)
            }
        } else {
            root.listFiles { f -> f.isDirectory }.orEmpty().sortedBy { it.name }.forEach { d ->
                val files = d.listFiles { f -> f.isFile }.orEmpty()
                if (files.isNotEmpty()) areas[d.name] = CacheArea(files.sumOf { it.length() }, files.size)
            }
        }
        CacheInfo(areas.values.sumOf { it.bytes }, areas.values.sumOf { it.entries }, areas)
    }

    /** Caller holds the lock. */
    private fun trim(area: String) {
        val files = File(dir ?: return, area).listFiles { f -> f.isFile }.orEmpty().sortedBy { it.lastModified() }
        val cutoff = now() - maxAgeMs
        var total = files.sumOf { it.length() }
        // Over the limit: down to four fifths of it, so that the next writes do not trim again at once.
        val keep = if (total > maxAreaBytes) maxAreaBytes * 8 / 10 else Long.MAX_VALUE
        for (f in files) {
            if (f.lastModified() >= cutoff && total <= keep) break
            total -= f.length()
            f.delete()
        }
    }

    private fun file(area: String, key: String): File? = dir?.let { File(File(it, area), hash(key) + ".txt") }

    companion object {
        const val CONFIG = "config"
        const val SITE = "site"
        const val EXT = "ext"
        const val LIVE = "live"

        fun hash(text: String): String =
            MessageDigest.getInstance("MD5").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
