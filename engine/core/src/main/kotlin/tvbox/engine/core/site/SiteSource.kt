package tvbox.engine.core.site

import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.model.HomeResult
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.model.VodPage

/**
 * What a site's play call returned, before the parse chain runs. Mirrors the TVBox player result
 * (`parse`, `jx`, `url`, `header`, `playUrl`, `flag`).
 */
data class RawPlay(
    val url: String,
    /** 1 = the url is a web page that needs a parser or sniffing. */
    val parse: Int = 0,
    /** 1 = force the VIP parse list. */
    val jx: Int = 0,
    val headers: Map<String, String> = emptyMap(),
    /** Site-level parser prefix (`playUrl` from the site config or the result), e.g. `json:http://…?url=`. */
    val playUrl: String = "",
    val flag: String = "",
)

/** One site of the active config, whatever its type. */
interface SiteSource {
    val bean: SiteBean

    suspend fun home(): HomeResult
    suspend fun category(classId: String, page: Int, filters: Map<String, String>): VodPage
    suspend fun detail(id: String): VodDetail
    suspend fun search(keyword: String, quick: Boolean, page: Int): VodPage
    suspend fun play(line: String, episodeId: String): RawPlay

    /** Per-call timeout: the site's `timeout` (seconds) clamped to 5..60, default 15 (TVBox `getPlayTimeoutSeconds`). */
    val timeoutMs: Long
        get() = if (bean.timeout > 0) bean.timeout.coerceIn(5, 60) * 1000L else 15_000L
}

class UnsupportedSiteException(site: SiteBean) :
    Exception("${site.name}: ${site.runtime.name.lowercase()} sites are not supported yet")
