package tvbox.engine.jar

import android.app.Application
import android.content.Context
import dalvik.system.BaseDexClassLoader
import tvbox.engine.core.spider.JarRepository
import tvbox.engine.jarhost.HostBridge
import tvbox.engine.jarhost.JarSpiderRuntime
import java.io.File
import java.net.URLClassLoader

/**
 * Jar spiders on a desktop/NAS JVM. The spider jar's dex is converted to class files ([DexConverter]) and loaded
 * parent-first on top of this module's class loader, which provides the Android stubs and TVBox's host classes,
 * so spiders link the same way they do under Android's DexClassLoader.
 *
 * @param dataDir where the spiders' "app data" lives (files, cache, shared_prefs)
 * @param cacheDir where converted jars are cached
 */
class DesktopJarRuntime(
    dataDir: File,
    jars: JarRepository,
    port: () -> Int,
    cacheDir: File,
    log: (String) -> Unit = { System.err.println(it) },
) : JarSpiderRuntime(desktopApplication(dataDir, port), jars, port) {
    private val converter = DexConverter(cacheDir, log)

    init {
        // Spiders and shells that load extra dex files at runtime go through the same converter.
        BaseDexClassLoader.converter = BaseDexClassLoader.Converter { converter.convert(it) }
    }

    override fun classLoader(jar: File): ClassLoader =
        URLClassLoader(arrayOf(converter.convert(jar).toURI().toURL()), DesktopJarRuntime::class.java.classLoader)

    private companion object {
        fun desktopApplication(dataDir: File, port: () -> Int): Context {
            Context.setBaseDir(dataDir.also { it.mkdirs() })
            val app = Application()
            HostBridge.context = app
            HostBridge.port = port()
            return app
        }
    }
}
