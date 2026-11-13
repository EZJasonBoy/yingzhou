package tvbox.next.tvbox_client.engine

import android.content.Context
import android.util.Log
import dalvik.system.DexClassLoader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.config.SiteRuntime
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.spider.ProxyResponse
import tvbox.engine.core.spider.Spider
import tvbox.engine.core.spider.SpiderLoadException
import tvbox.engine.core.spider.SpiderRuntime
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap
import com.github.catvod.crawler.Spider as CatSpider

/**
 * Jar spiders on Android: the jar's dex is loaded with [DexClassLoader] on top of the app's class loader, which
 * provides TVBox's host API (com.github.catvod.*, OkHttp, Gson, Jsoup). Port of TVBox `JarLoader`.
 *
 * Every site uses its own `jar`, or the config's global `spider` jar. The spider class is
 * `com.github.catvod.spider.<api without "csp_">`.
 */
class DexSpiderRuntime(
    private val context: Context,
    private val jars: JarRepository,
    private val port: () -> Int,
) : SpiderRuntime {
    override val kind = "jar"

    private class LoadedJar(val loader: DexClassLoader, val proxy: Method?)

    private val loaded = ConcurrentHashMap<String, LoadedJar>()
    private val siteJars = ConcurrentHashMap<String, LoadedJar>()
    private val loadLock = Mutex()
    @Volatile private var globalSpider = ""
    @Volatile private var recent: LoadedJar? = null

    override fun supports(site: SiteBean) = site.runtime == SiteRuntime.JAR

    override fun onConfig(config: TvboxConfig) {
        globalSpider = config.spider
        siteJars.clear()
    }

    override suspend fun create(site: SiteBean, ext: String): Spider = withContext(Dispatchers.IO) {
        val spec = site.jar.ifEmpty { globalSpider }
        if (spec.isEmpty()) throw SpiderLoadException("${site.name}: the config has no spider jar")
        val jar = load(spec, site)
        val className = "com.github.catvod.spider." + if (site.api.contains("csp_")) site.api.substringAfter("csp_") else site.api
        val spider = try {
            jar.loader.loadClass(className).getDeclaredConstructor().newInstance() as CatSpider
        } catch (e: ClassNotFoundException) {
            throw SpiderLoadException("${site.name}: $className is not in the jar")
        } catch (e: Throwable) {
            throw SpiderLoadException("${site.name}: cannot create $className: ${e.message}", e)
        }
        try {
            spider.siteKey = site.key
            spider.initApi(com.github.catvod.crawler.SpiderApi())
            spider.init(context, ext)
        } catch (e: Throwable) {
            throw SpiderLoadException("${site.name}: init failed: ${e.message}", e)
        }
        siteJars[site.key] = jar
        recent = jar
        DexSpider(spider, onUse = { recent = jar })
    }

    private suspend fun load(spec: String, site: SiteBean): LoadedJar {
        loaded[spec]?.let { return it }
        return loadLock.withLock {
            loaded[spec] ?: run {
                val file = try {
                    jars.fetch(spec)
                } catch (e: Exception) {
                    throw SpiderLoadException("${site.name}: cannot download the spider jar: ${e.message}", e)
                }
                file.setReadOnly()
                val loader = DexClassLoader(file.absolutePath, context.codeCacheDir.absolutePath, null, context.classLoader)
                initJar(loader)
                LoadedJar(loader, proxyMethod(loader)).also { loaded[spec] = it }
            }
        }
    }

    /** `com.github.catvod.spider.Init.init(Context)`, and tell the jar's own Proxy copy (if any) where the engine is. */
    private fun initJar(loader: DexClassLoader) {
        try {
            loader.loadClass("com.github.catvod.spider.Init").getMethod("init", Context::class.java).invoke(null, context)
        } catch (e: Throwable) {
            Log.w(TAG, "jar Init failed: ${e.cause ?: e}")
        }
        com.github.catvod.Proxy.set(port())
        runCatching { loader.loadClass("com.github.catvod.Proxy").getMethod("set", Int::class.javaPrimitiveType).invoke(null, port()) }
    }

    private fun proxyMethod(loader: DexClassLoader): Method? =
        runCatching { loader.loadClass("com.github.catvod.spider.Proxy").getMethod("proxy", Map::class.java) }.getOrNull()

    /** TVBox `JarLoader.proxyInvoke`: the site's jar first, then the most recently used one, then every other. */
    override suspend fun proxy(params: Map<String, String>): ProxyResponse? = withContext(Dispatchers.IO) {
        val ordered = listOfNotNull(params["siteKey"]?.let { siteJars[it] }, recent) + loaded.values
        for (jar in ordered.distinct()) {
            val method = jar.proxy ?: continue
            @Suppress("UNCHECKED_CAST")
            val result = runCatching { method.invoke(null, HashMap(params)) as Array<Any?>? }.getOrNull() ?: continue
            toProxyResponse(result)?.let { return@withContext it }
        }
        null
    }

    private companion object {
        const val TAG = "DexSpiderRuntime"
    }
}

/** Adapts a TVBox jar spider (blocking calls) to the engine's suspending [Spider]. */
private class DexSpider(private val spider: CatSpider, private val onUse: () -> Unit) : Spider {
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
    override suspend fun play(flag: String, id: String, vipFlags: List<String>): String? = io { spider.playerContent(flag, id, vipFlags) }
    override suspend fun proxy(params: Map<String, String>): ProxyResponse? =
        io { spider.proxy(HashMap(params)) }?.let { toProxyResponse(it) }

    override fun destroy() {
        runCatching { spider.destroy() }
    }
}

/** TVBox proxy results: `[code, mime, InputStream | byte[] | String, headers?]`. */
private fun toProxyResponse(result: Array<Any?>): ProxyResponse? {
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
