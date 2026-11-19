package tvbox.engine.core.cache

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class StreamStoreTest {
    @TempDir
    lateinit var dir: File

    private var now = 1_000_000L

    private fun store(max: Long = 1_000_000) = StreamStore(dir, max) { now }

    /** Writes a finished file of [size] bytes, one tick of the clock after the one before. */
    private fun StreamStore.put(stream: String, name: String, size: Int) {
        now += 1000
        partFile(stream, name).writeBytes(ByteArray(size) { it.toByte() })
        assertTrue(commit(stream, name))
    }

    @Test
    fun `a finished file is found again, also after a restart, and unfinished ones are swept away`() {
        val first = store()
        assertNull(first.file("s1", "a"))
        first.put("s1", "a", 300)
        first.partFile("s1", "b").writeBytes(ByteArray(50))
        assertEquals(300, first.file("s1", "a")!!.length())
        assertFalse(first.has("s1", "b"))
        assertEquals(300, first.stats().bytes)

        val second = store()
        assertEquals(300, second.file("s1", "a")!!.length())
        assertFalse(File(dir, "s1/b.part").exists(), "a download cut off by the last shutdown is not kept")
        assertEquals(1, second.stats().files)
        assertEquals(1, second.stats().streams)
    }

    @Test
    fun `over the cap the files used longest ago go first, whichever stream they are in`() {
        val store = store(max = 1000)
        store.put("old", "a", 300)
        store.put("old", "b", 300)
        store.put("new", "c", 300)
        // Reading a file makes it young again.
        now += 1000
        assertNotNull(store.file("old", "a"))
        // 1200 bytes is over the cap of 1000: trimmed down to 900 or less, oldest first.
        store.put("new", "d", 300)
        assertFalse(store.has("old", "b"), "b was used longest ago")
        assertTrue(store.has("old", "a") && store.has("new", "c") && store.has("new", "d"))
        assertEquals(900, store.stats().bytes)

        // Lowering the cap trims at once; a stream that loses its last file loses its folder.
        store.maxBytes = 400
        assertEquals(listOf(false, false, false, true), listOf(store.has("old", "a"), store.has("old", "b"), store.has("new", "c"), store.has("new", "d")))
        assertFalse(File(dir, "old").exists())
    }

    @Test
    fun `the order of use survives a restart`() {
        val first = store(max = 10_000)
        first.put("s", "a", 300)
        first.put("s", "b", 300)
        first.put("s", "c", 300)
        now += 120_000
        first.file("s", "a")
        val second = store(max = 10_000)
        second.maxBytes = 700
        assertEquals(setOf("a", "c"), second.names("s"))
    }

    @Test
    fun `a pinned stream is never trimmed and does not count towards the cap`() {
        val store = store(max = 1000)
        store.put("kept", "a", 800)
        store.pin("kept", true)
        assertEquals(0, store.stats().bytes)
        assertEquals(800, store.stats().pinnedBytes)
        store.put("other", "b", 600)
        store.put("other", "c", 600)
        assertTrue(store.has("kept", "a"))
        assertFalse(store.has("other", "b"))
        assertEquals(0, store.clear().let { store.stats().bytes })
        assertTrue(store.has("kept", "a"), "clearing the cache leaves what is pinned")
        // Still pinned after a restart; unpinned it counts again.
        val again = store(max = 1000)
        assertTrue(again.isPinned("kept"))
        again.pin("kept", false)
        assertEquals(800, again.stats().bytes)
    }

    @Test
    fun `clearing removes everything but what is held on to, and the notes go with the last file`() {
        val store = store()
        store.put("s1", "a", 100)
        store.put("s1", "b", 100)
        store.put("s2", "c", 100)
        store.writeNote("s2", "playlist.json", "{}")
        assertEquals("{}", store.readNote("s2", "playlist.json"))
        val freed = store.clear { stream, name -> stream == "s1" && name == "b" }
        assertEquals(200, freed)
        assertEquals(setOf("b"), store.names("s1"))
        assertNull(store.readNote("s2", "playlist.json"))
        assertFalse(File(dir, "s2").exists())
        assertEquals(100, store.stats().bytes)
    }

    @Test
    fun `a file deleted behind its back is forgotten`() {
        val store = store()
        store.put("s", "a", 100)
        File(dir, "s/a").delete()
        assertNull(store.file("s", "a"))
        assertEquals(0, store.stats().bytes)
    }

    @Test
    fun `committing over an older file replaces it`() {
        val store = store()
        store.put("s", "a", 100)
        store.put("s", "a", 250)
        assertEquals(250, store.file("s", "a")!!.length())
        assertEquals(250, store.stats().bytes)
        assertEquals(1, store.stats().files)
    }

    @Test
    fun `without a reserve free space is not looked at`() {
        var asked = 0
        val store = StreamStore(dir, 1_000_000, freeSpace = { asked++; 0L }) { now }
        store.put("s", "a", 300)
        assertFalse(store.lowOnSpace())
        assertEquals(-1, store.stats().freeBytes)
        assertEquals(0, asked)
    }

    @Test
    fun `with a reserve the store gives way to the disk, and says when nothing new can be kept`() {
        // A small phone: 20 000 bytes of disk, of which the cache leaves 5 000 free; its own cap is far away.
        val disk = 20_000L
        fun used() = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        val store = StreamStore(dir, 1_000_000, reserveBytes = 5_000, freeSpace = { disk - used() }) { now }
        store.put("a", "1", 4000)
        store.put("a", "2", 4000)
        store.put("b", "3", 4000)
        assertEquals(12_000, store.stats().bytes)
        assertEquals(disk - used(), store.stats().freeBytes)
        assertEquals(5_000, store.stats().reserveBytes)
        assertFalse(store.lowOnSpace())

        // The next file would leave only 4 000 free: the oldest goes, although the cap is nowhere near.
        store.put("b", "4", 4000)
        assertFalse(store.has("a", "1"), "the file used longest ago made room")
        assertTrue(store.has("a", "2") && store.has("b", "3") && store.has("b", "4"))
        assertTrue(disk - used() >= 5_000)

        // A download (a pinned stream) takes the disk: the cache gives way, the download is never touched.
        store.pin("dl", true)
        store.put("dl", "x", 7000)
        store.put("dl", "y", 6000)
        assertTrue(store.has("dl", "x") && store.has("dl", "y"))
        assertTrue(disk - used() >= 5_000 || store.stats().bytes == 0L, "the cache gave up its files first")
        store.put("dl", "z", 4000)
        assertEquals(0, store.stats().bytes, "nothing of the cache is left")
        assertTrue(store.lowOnSpace(), "and the disk is still below the reserve: nothing new is kept")

        // The download is deleted: room again.
        store.remove("dl")
        now += 1000
        assertFalse(store.lowOnSpace())
    }
}
