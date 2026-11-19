package tvbox.engine.core.spider

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.model.HomeResult
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.model.VodPage
import tvbox.engine.core.site.ExtResolver
import tvbox.engine.core.site.PlayerResult
import tvbox.engine.core.site.RawPlay
import tvbox.engine.core.site.SiteSource
import tvbox.engine.core.vod.SiteResultException
import tvbox.engine.core.vod.TvboxResult

/**
 * A type-3 site backed by a [Spider]. The spider is created on first use (loading can take a while) and reused.
 * Mirrors the type-3 branches of TVBox `SourceViewModel`.
 */
class SpiderSource(
    override val bean: SiteBean,
    private val runtime: SpiderRuntime,
    private val ext: ExtResolver,
    private val vipFlags: () -> List<String>,
) : SiteSource {
    private val lock = Mutex()
    @Volatile private var spider: Spider? = null

    /** Loading a spider (download + compile + init) gets more time than a normal call. */
    override val timeoutMs: Long
        get() = if (spider == null) maxOf(super.timeoutMs, 30_000L) else super.timeoutMs

    private suspend fun spider(): Spider = spider ?: lock.withLock {
        spider ?: runtime.create(bean, ext.resolve(bean.ext)).also { spider = it }
    }

    override suspend fun home(): HomeResult {
        val sp = spider()
        val home = TvboxResult.parseHome(bean.key, sp.home(true).orEmptyObject())
        if (home.list.isNotEmpty()) return home
        // Like TVBox: when home has no videos, ask homeVideoContent for the "推荐" list.
        val vod = runCatching { sp.homeVod() }.getOrNull()
        val list = if (vod.isNullOrBlank()) emptyList() else runCatching { TvboxResult.parseList(bean.key, vod).list }.getOrDefault(emptyList())
        return home.copy(list = list)
    }

    override suspend fun category(classId: String, page: Int, filters: Map<String, String>): VodPage =
        TvboxResult.parseList(bean.key, spider().category(classId, page.toString(), true, filters).orEmptyObject())

    override suspend fun detail(id: String): VodDetail =
        TvboxResult.parseDetail(bean.key, spider().detail(id) ?: throw SiteResultException("detail is empty"))

    override suspend fun search(keyword: String, quick: Boolean, page: Int): VodPage =
        TvboxResult.parseList(bean.key, spider().search(keyword, quick, page.toString()).orEmptyObject())

    override suspend fun play(line: String, episodeId: String): RawPlay {
        val text = spider().play(line, episodeId, vipFlags())
        if (text.isNullOrBlank()) {
            // TVBox plays an http id directly when the spider has no answer.
            if (episodeId.startsWith("http://") || episodeId.startsWith("https://")) return RawPlay(url = episodeId, flag = line)
            throw SiteResultException("spider returned no play info")
        }
        return PlayerResult.parse(text, defaultUrl = if (episodeId.startsWith("http")) episodeId else "", flag = line)
    }

    suspend fun proxy(params: Map<String, String>): ProxyResponse? = spider().proxy(params)

    /** False while the runtime cannot run spiders (no Python yet): searches leave the site out. */
    val available: Boolean get() = runtime.available

    fun destroy() {
        spider?.destroy()
        spider = null
    }

    private fun String?.orEmptyObject(): String = if (isNullOrBlank()) "{}" else this
}
