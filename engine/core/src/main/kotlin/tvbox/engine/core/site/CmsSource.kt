package tvbox.engine.core.site

import com.google.gson.Gson
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.model.HomeResult
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.model.VodPage
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.vod.CmsXml
import tvbox.engine.core.vod.TvboxResult
import tvbox.engine.core.vod.VideoFormat

/**
 * MacCMS-style sites: type 0 (XML) and type 1 (JSON). Request parameters follow TVBox `SourceViewModel`:
 *
 * | call     | parameters |
 * |----------|------------|
 * | home     | none |
 * | category | `ac=videolist` (0) / `ac=detail` (1), `t`, `pg`, each filter, `f` = filters as JSON |
 * | detail   | `ac=videolist` / `ac=detail`, `ids`, `extend` when the site has an ext |
 * | search   | `wd`, plus `ac=detail` for type 1 |
 */
class CmsSource(
    override val bean: SiteBean,
    private val http: SiteHttp,
    private val ext: ExtResolver,
) : SiteSource {
    private val isXml = bean.type == 0
    private val listAction = if (isXml) "videolist" else "detail"

    override suspend fun home(): HomeResult {
        val text = http.get(bean.api, timeoutMs = timeoutMs)
        return if (isXml) CmsXml.parseHome(bean.key, text) else TvboxResult.parseHome(bean.key, text)
    }

    override suspend fun category(classId: String, page: Int, filters: Map<String, String>): VodPage {
        val params = buildList {
            add("ac" to listAction)
            add("t" to classId)
            add("pg" to page.toString())
            filters.forEach { (k, v) -> add(k to v) }
            add("f" to if (filters.isEmpty()) "" else gson.toJson(filters))
        }
        return list(http.get(bean.api, params, timeoutMs = timeoutMs))
    }

    override suspend fun detail(id: String): VodDetail {
        val params = buildList {
            add("ac" to listAction)
            add("ids" to id)
            ext.resolve(bean.ext).takeIf { it.isNotEmpty() }?.let { add("extend" to it) }
        }
        val text = http.get(bean.api, params, timeoutMs = timeoutMs)
        return if (isXml) CmsXml.parseDetail(bean.key, text) else TvboxResult.parseDetail(bean.key, text)
    }

    override suspend fun search(keyword: String, quick: Boolean, page: Int): VodPage {
        val params = buildList {
            add("wd" to keyword)
            if (!isXml) add("ac" to "detail")
            if (page > 1) add("pg" to page.toString())
        }
        return list(http.get(bean.api, params, timeoutMs = timeoutMs))
    }

    /** CMS episodes are urls. Direct when it looks like media and the site has no parser prefix. */
    override suspend fun play(line: String, episodeId: String): RawPlay {
        val playUrl = bean.playUrl.trim()
        val direct = VideoFormat.isVideo(episodeId) && playUrl.isEmpty()
        return RawPlay(url = episodeId, parse = if (direct) 0 else 1, playUrl = playUrl, flag = line)
    }

    private fun list(text: String): VodPage =
        if (isXml) CmsXml.parseList(bean.key, text) else TvboxResult.parseList(bean.key, text)

    private companion object {
        val gson = Gson()
    }
}
