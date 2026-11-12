package tvbox.engine.core.spider

import tvbox.engine.core.config.SiteBean

/**
 * The TVBox spider contract (`com.github.catvod.crawler.Spider`), independent of how the spider runs
 * (QuickJS, JVM/ART for jar, Python). Every method returns TVBox JSON text, or "" / null when the spider
 * has nothing; [SpiderSource] turns that into normalised models.
 */
interface Spider {
    suspend fun init(ext: String)
    suspend fun home(filter: Boolean): String?
    suspend fun homeVod(): String?
    suspend fun category(tid: String, pg: String, filter: Boolean, extend: Map<String, String>): String?
    suspend fun detail(id: String): String?
    suspend fun search(key: String, quick: Boolean, pg: String): String?
    suspend fun play(flag: String, id: String, vipFlags: List<String>): String?

    /** Spider-side proxy (`/proxy?do=...`), used by some sites to serve media or rewrite playlists. */
    suspend fun proxy(params: Map<String, String>): ProxyResponse? = null

    fun destroy()
}

class ProxyResponse(
    val status: Int,
    val contentType: String,
    val body: ByteArray,
    val headers: Map<String, String> = emptyMap(),
)

/** Something that can run spiders of some kind (js / jar / py). */
interface SpiderRuntime {
    /** "js", "jar", "py": reported in engine capabilities. */
    val kind: String

    fun supports(site: SiteBean): Boolean

    /** Creates and initialises the spider for [site] with its resolved [ext]. May be slow (downloads, compilation). */
    suspend fun create(site: SiteBean, ext: String): Spider

    /** Called when the active config changes. */
    fun reset() {}
}

class SpiderLoadException(message: String, cause: Throwable? = null) : Exception(message, cause)
