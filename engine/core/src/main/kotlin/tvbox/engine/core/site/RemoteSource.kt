package tvbox.engine.core.site

import com.google.gson.Gson
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.model.HomeResult
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.model.VodPage
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.vod.TvboxResult
import java.net.URLEncoder
import tvbox.engine.core.util.Base64Compat

/**
 * Type 4: a spider running behind an HTTP endpoint (TVBox "remote" sites). Parameters follow `SourceViewModel`:
 *
 * | call     | parameters |
 * |----------|------------|
 * | home     | `filter=true` |
 * | category | `ac=detail`, `filter=true`, `t`, `pg`, `ext` = base64(filters JSON, `{}` when none) |
 * | detail   | `ac=detail`, `ids` |
 * | search   | `wd`, `ac=detail`, `quick=true|false` |
 * | play     | `play`, `flag` |
 *
 * Every call adds `extend` (the resolved site ext) when present.
 */
class RemoteSource(
    override val bean: SiteBean,
    private val http: SiteHttp,
    private val ext: ExtResolver,
    private val playbackHttp: SiteHttp = http,
) : SiteSource {

    override suspend fun home(): HomeResult =
        TvboxResult.parseHome(bean.key, call(listOf("filter" to "true")))

    override suspend fun category(classId: String, page: Int, filters: Map<String, String>): VodPage {
        val selected = if (filters.isEmpty()) "{}" else gson.toJson(filters)
        val params = listOf(
            "ac" to "detail",
            "filter" to "true",
            "t" to classId,
            "pg" to page.toString(),
            "ext" to Base64Compat.encode(selected.toByteArray()),
        )
        return TvboxResult.parseList(bean.key, call(params))
    }

    override suspend fun detail(id: String): VodDetail =
        TvboxResult.parseDetail(bean.key, call(listOf("ac" to "detail", "ids" to id)))

    override suspend fun search(keyword: String, quick: Boolean, page: Int): VodPage {
        val params = buildList {
            add("wd" to keyword)
            add("ac" to "detail")
            add("quick" to quick.toString())
            if (page > 1) add("pg" to page.toString())
        }
        return TvboxResult.parseList(bean.key, call(params))
    }

    override suspend fun play(line: String, episodeId: String): RawPlay =
        PlayerResult.parse(call(listOf("play" to episodeId, "flag" to line), playbackHttp), defaultUrl = episodeId, flag = line)

    /** GET normally; POST form when the url-encoded `extend` would make the url too long (TVBox: >= 1000 chars). */
    private suspend fun call(params: List<Pair<String, String>>, client: SiteHttp = http): String {
        val extend = ext.resolve(bean.ext)
        val all = if (extend.isEmpty()) params else params + ("extend" to extend)
        return if (URLEncoder.encode(extend, "UTF-8").length >= 1000) {
            client.postForm(bean.api, all, timeoutMs = timeoutMs)
        } else {
            client.get(bean.api, all, timeoutMs = timeoutMs)
        }
    }

    private companion object {
        val gson = Gson()
    }
}
