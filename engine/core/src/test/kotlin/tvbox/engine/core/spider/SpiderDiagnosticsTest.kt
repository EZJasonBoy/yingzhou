package tvbox.engine.core.spider

import kotlinx.coroutines.CancellationException
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import java.io.IOException
import java.lang.reflect.InvocationTargetException

class SpiderDiagnosticsTest {
    @Test
    fun `only identifiers and bounded platform hints enter the report`() {
        val archive = spiderArchiveId("https://private.host/path?token=secret;md5;1234")
        val site = "https://private.host/search?token=secret"
        val diagnostics = listOf(
            spiderDiagnostic(site, "spider.create", InvocationTargetException(UnsatisfiedLinkError("/private/armeabi-v7a/libstub.so?secret")), archive),
            spiderDiagnostic(site, "jar.init", IOException("Cannot run program \"nohup\" at /private/secret", IOException("CreateProcess error=2")), archive),
            spiderDiagnostic(site, "jar.fetch", IllegalStateException("HTTP 403 for $site"), archive),
            spiderDiagnostic(site, "spider.init", ClassNotFoundException("https://android.private/secret"), archive),
            spiderDiagnostic(site, "jar.fetch", IllegalStateException("$site answered with text (\"private\"), not a jar"), archive),
        )
        assertEquals(listOf("native", "command", "network", "missing_class", "network"), diagnostics.map { it.kind })
        assertEquals(listOf("UnsatisfiedLinkError: armeabi-v7a", "IOException: nohup", "IllegalStateException: HTTP 403", "ClassNotFoundException", "IllegalStateException: response does not contain a JAR"), diagnostics.map { it.cause })
        assertEquals(12, archive?.length)
        assertFalse(diagnostics.any { "private" in it.summary() || "secret" in it.summary() })
    }

    @Test
    fun `known guest failures survive reflective wrappers and private nested causes`() {
        val reason = "Android JNI: guest timed out"
        val wrapped = InvocationTargetException(UnsatisfiedLinkError(reason).initCause(IllegalArgumentException("/private/guest")))
        val diagnostic = spiderDiagnostic("spider", "spider.home", wrapped)
        assertEquals("native", diagnostic.kind)
        assertEquals("UnsatisfiedLinkError: $reason", diagnostic.cause)
        val withPrivateDetail = UnsatisfiedLinkError("Android JNI: guest timed out loading /private/guest").initCause(IOException("secret"))
        assertEquals("UnsatisfiedLinkError", spiderDiagnostic("spider", "jar.init", withPrivateDetail).cause)
    }

    @Test
    fun `reflection does not change coroutine cancellation or VM errors into reportable site failures`() {
        val cancelled = CancellationException("cancelled")
        assertSame(cancelled, assertThrows(CancellationException::class.java) { spiderDiagnostic("site", "spider.init", InvocationTargetException(cancelled)) })
        assertThrows(OutOfMemoryError::class.java) { spiderDiagnostic("site", "spider.home", OutOfMemoryError()) }
    }
}
