package tvbox.engine.jarhost

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.config.SiteRuntime
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.play.JarParsers
import tvbox.engine.core.spider.JarRepository
import tvbox.engine.core.spider.ProxyResponse
import tvbox.engine.core.spider.Spider
import tvbox.engine.core.spider.SpiderLoadException
import tvbox.engine.core.spider.SpiderRuntime
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap
import com.github.catvod.crawler.Spider as CatSpider

/**
 * TVBox jar spiders, shared by the Android app and the desktop engine. Port of TVBox `JarLoader`; subclasses
 * only decide how a downloaded jar becomes a [ClassLoader] (Android: DexClassLoader; desktop: dex2jar + URLClassLoader).
 *
 * - every site uses its own `jar`, or the config's global `spider` jar;
 * - the spider class is `com.github.catvod.spider.<api without "csp_">`;
 * - `com.github.catvod.spider.Init.init(Context)` runs once per jar;
 * - `/proxy`: the site spider's own `proxy()`, then the jars' static `com.github.catvod.spider.Proxy.proxy(Map)`.
 */
abstract class JarSpiderRuntime(
    private val context: Context,
    private val jars: JarRepository,
    private val port: () -> Int,
) : SpiderRuntime, JarParsers {
    override val kind = "jar"

    private class LoadedJar(val loader: ClassLoader, val proxy: Method?)

    private val loaded = ConcurrentHashMap<String, LoadedJar>()
    private val siteJars = ConcurrentHashMap<String, LoadedJar>()
    private val siteSpiders = ConcurrentHashMap<String, CatSpider>()
    private val loadLock = Mutex()
    @Volatile private var globalSpider = ""
    @Volatile private var recent: LoadedJar? = null

    /** Turns a downloaded spider jar into a class loader whose parent provides the host classes. */
    protected abstract fun classLoader(jar: File): ClassLoader

    override fun supports(site: SiteBean) = site.runtime == SiteRuntime.JAR

    override fun onConfig(config: TvboxConfig) {
        globalSpider = config.spider
        siteJars.clear()
        siteSpiders.clear()
    }

    override suspend fun create(site: SiteBean, ext: String): Spider = withContext(Dispatchers.IO) {
        val spec = site.jar.ifEmpty { globalSpider }
        if (spec.isEmpty()) throw SpiderLoadException("${site.name}: the config has no spider jar")
        val jar = load(spec, site)
        val className = "com.github.catvod.spider." + if (site.api.contains("csp_")) site.api.substringAfter("csp_") else site.api
        val spider = try {
            jar.loader.loadClass(className).getDeclaredConstructor().newInstance() as CatSpider
        } catch (e: ClassNotFoundException) {
            throw SpiderLoadException("${site.name}: $className is not in the jar ${spec.substringBefore(";md5;").trim()}")
        } catch (e: Throwable) {
            throw SpiderLoadException("${site.name}: cannot create $className: ${e.message ?: e.javaClass.simpleName}", e)
        }
        try {
            spider.siteKey = site.key
            spider.initApi(com.github.catvod.crawler.SpiderApi())
            spider.init(context, ext)
        } catch (e: Throwable) {
            throw SpiderLoadException("${site.name}: init failed: ${e.message ?: e.javaClass.simpleName}", e)
        }
        siteJars[site.key] = jar
        siteSpiders[site.key] = spider
        recent = jar
        CatSpiderAdapter(spider, onUse = { recent = jar })
    }

    private suspend fun load(spec: String, site: SiteBean?): LoadedJar {
        val name = site?.name ?: "spider jar"
        loaded[spec]?.let { return it }
        return loadLock.withLock {
            loaded[spec] ?: run {
                val file = try {
                    jars.fetch(spec)
                } catch (e: Exception) {
                    throw SpiderLoadException("$name: cannot download the spider jar: ${e.message}", e)
                }
                val loader = try {
                    classLoader(file)
                } catch (e: SpiderLoadException) {
                    throw e
                } catch (e: Throwable) {
                    throw SpiderLoadException("$name: cannot load the spider jar: ${e.message ?: e.javaClass.simpleName}", e)
                }
                initJar(loader)
                LoadedJar(loader, proxyMethod(loader)).also { loaded[spec] = it }
            }
        }
    }

    /** `Init.init(Context)`, and tell the jar's own copy of com.github.catvod.Proxy (if any) where the engine is. */
    private fun initJar(loader: ClassLoader) {
        try {
            loader.loadClass("com.github.catvod.spider.Init").getMethod("init", Context::class.java).invoke(null, context)
        } catch (e: ClassNotFoundException) {
            // Some jars have no Init.
        } catch (e: Throwable) {
            System.err.println("jar Init failed: ${e.cause ?: e}")
        }
        com.github.catvod.Proxy.set(port())
        runCatching { loader.loadClass("com.github.catvod.Proxy").getMethod("set", Int::class.javaPrimitiveType).invoke(null, port()) }
    }

    private fun proxyMethod(loader: ClassLoader): Method? =
        runCatching { loader.loadClass("com.github.catvod.spider.Proxy").getMethod("proxy", Map::class.java) }.getOrNull()

    // ---- parsers in the jar (TVBox `JarLoader.jsonExt` / `jsonExtMix`) ----

    override suspend fun jsonExt(key: String, jxs: LinkedHashMap<String, String>, url: String): String? =
        parser("com.github.catvod.parser.Json$key") { cls ->
            cls.getMethod("parse", LinkedHashMap::class.java, String::class.java).invoke(null, jxs, url)
        }

    override suspend fun jsonExtMix(flag: String, key: String, name: String, jxs: LinkedHashMap<String, HashMap<String, String>>, url: String): String? =
        parser("com.github.catvod.parser.Mix$key") { cls ->
            cls.getMethod("parse", LinkedHashMap::class.java, String::class.java, String::class.java, String::class.java)
                .invoke(null, jxs, name, flag, url)
        }

    /** Looks the class up in the most recently used jar, then the config's spider jar. */
    private suspend fun parser(className: String, call: (Class<*>) -> Any?): String? = withContext(Dispatchers.IO) {
        val candidates = listOfNotNull(recent, globalSpider.takeIf { it.isNotEmpty() }?.let { runCatching { load(it, null) }.getOrNull() })
        val cls = candidates.firstNotNullOfOrNull { jar -> runCatching { jar.loader.loadClass(className) }.getOrNull() } ?: return@withContext null
        try {
            resolvingPlayback { call(cls)?.toString() }
        } catch (e: Throwable) {
            System.err.println("$className failed: ${(e.cause ?: e)}")
            null
        }
    }

    override suspend fun proxy(params: Map<String, String>): ProxyResponse? = withContext(Dispatchers.IO) {
        params["siteKey"]?.let { siteSpiders[it] }?.let { sp ->
            runCatching { sp.proxy(HashMap(params)) }.getOrNull()?.let { toProxyResponse(it) }?.let { return@withContext it }
        }
        // A proxy url can arrive before any site was opened (a live playlist served by the jar): load the config's jar.
        if (loaded.isEmpty() && globalSpider.isNotEmpty()) runCatching { load(globalSpider, null) }
        val ordered = listOfNotNull(params["siteKey"]?.let { siteJars[it] }, recent) + loaded.values
        for (jar in ordered.distinct()) {
            val method = jar.proxy ?: continue
            @Suppress("UNCHECKED_CAST")
            val result = runCatching { method.invoke(null, HashMap(params)) as Array<Any?>? }.getOrNull() ?: continue
            toProxyResponse(result)?.let { return@withContext it }
        }
        null
    }
}

/** Adapts a TVBox jar spider (blocking calls) to the engine's suspending [Spider]. */
class CatSpiderAdapter(private val spider: CatSpider, private val onUse: () -> Unit) : Spider {
    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) {
        onUse()
        block()
    }

    override suspend fun init(ext: String) {}
    override suspend fun home(filter: Boolean): String? = io { spider.homeContent(filter) }
    override suspend fun homeVod(): String? = io { spider.homeVideoContent() }
    override suspend fun category(tid: String, pg: String, filter: Boolean, extend: Map<String, String>): String? =
        io { spider.categoryContent(tid, pg, filter, HashMap(extend)) }
    override suspend fun detail(id: String): String? = io { spider.detailContent(listOf(id)) }
    override suspend fun search(key: String, quick: Boolean, pg: String): String? = io { spider.searchContent(key, quick, pg) }
    override suspend fun play(flag: String, id: String, vipFlags: List<String>): String? = io { resolvingPlayback { spider.playerContent(flag, id, vipFlags) } }
    override suspend fun live(url: String): String? = io { spider.liveContent(url) }

    override suspend fun proxy(params: Map<String, String>): ProxyResponse? =
        io { spider.proxy(HashMap(params)) }?.let { toProxyResponse(it) }

    override fun destroy() {
        runCatching { spider.destroy() }
    }
}

private inline fun <T> resolvingPlayback(block: () -> T): T {
    val previous = HostBridge.resolvingPlayback.get()
    HostBridge.resolvingPlayback.set(true)
    return try {
        block()
    } finally {
        if (previous == null) HostBridge.resolvingPlayback.remove() else HostBridge.resolvingPlayback.set(previous)
    }
}

/** TVBox proxy results: `[code, mime, InputStream | byte[] | String, headers?]`. */
fun toProxyResponse(result: Array<Any?>): ProxyResponse? {
    if (result.size < 3) return null
    val code = (result[0] as? Number)?.toInt() ?: return null
    val mime = result[1] as? String ?: "application/octet-stream"
    val body: InputStream? = when (val b = result[2]) {
        is InputStream -> b
        is ByteArray -> ByteArrayInputStream(b)
        is String -> ByteArrayInputStream(b.toByteArray())
        else -> null
    }
    val headers = (result.getOrNull(3) as? Map<*, *>)?.entries?.associate { (k, v) -> k.toString() to v.toString() } ?: emptyMap()
    return ProxyResponse(code, mime, body, headers)
}
