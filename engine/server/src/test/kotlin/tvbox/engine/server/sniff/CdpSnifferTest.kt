package tvbox.engine.server.sniff

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File

class CdpSnifferTest {
    @Test
    fun `Ubuntu's chromium snap is recognised by its path or by the script that starts it`(@TempDir dir: File) {
        assertEquals("chromium", CdpSniffer.snapName(File("/snap/bin/chromium")))
        val launcher = File(dir, "chromium-browser").apply {
            writeText("#!/bin/sh\n# transitional package\nexec /snap/bin/chromium \"\$@\"\n")
        }
        assertEquals("chromium", CdpSniffer.snapName(launcher))
        val chrome = File(dir, "google-chrome").apply { writeText("#!/bin/bash\nexec -a \"\$0\" /opt/google/chrome/chrome \"\$@\"\n") }
        assertNull(CdpSniffer.snapName(chrome))
        val binary = File(dir, "chrome").apply { writeBytes(byteArrayOf(0x7f, 'E'.code.toByte(), 'L'.code.toByte(), 'F'.code.toByte(), 0, 0)) }
        assertNull(CdpSniffer.snapName(binary))
    }

    @Test
    fun `a snap browser keeps its profile in its own folder, one per engine`(@TempDir dir: File) {
        val default = File(dir, "engine/sniff-profile")
        val chrome = File(dir, "google-chrome").apply { writeText("#!/bin/sh\nexec /opt/google/chrome/chrome \"\$@\"\n") }
        assertEquals(default, CdpSniffer.profileDirFor(chrome, default))

        val snap = File("/snap/bin/chromium")
        val profile = CdpSniffer.profileDirFor(snap, default)
        assertEquals(File(System.getProperty("user.home"), "snap/chromium/common"), profile.parentFile)
        assertNotEquals(profile, CdpSniffer.profileDirFor(snap, File(dir, "other/sniff-profile")))
        assertEquals(profile, CdpSniffer.profileDirFor(snap, File(dir, "engine/sniff-profile")))
    }
}
