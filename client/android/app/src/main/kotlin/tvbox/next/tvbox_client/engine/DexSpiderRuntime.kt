package tvbox.next.tvbox_client.engine

import android.content.Context
import dalvik.system.DexClassLoader
import tvbox.engine.core.spider.JarRepository
import tvbox.engine.jarhost.JarSpiderRuntime
import java.io.File

/**
 * Jar spiders on Android: the jar's dex runs natively through [DexClassLoader] on top of the app's class loader,
 * which provides TVBox's host API (com.github.catvod.*, OkHttp, Gson, Jsoup). Everything else is shared with the
 * desktop engine in [JarSpiderRuntime].
 */
class DexSpiderRuntime(
    private val context: Context,
    jars: JarRepository,
    port: () -> Int,
) : JarSpiderRuntime(context, jars, port) {
    override fun classLoader(jar: File): ClassLoader {
        // Android 14+ refuses to load writable dex files.
        jar.setReadOnly()
        return DexClassLoader(jar.absolutePath, context.codeCacheDir.absolutePath, null, context.classLoader)
    }
}
