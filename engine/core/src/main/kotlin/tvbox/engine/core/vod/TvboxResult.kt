package tvbox.engine.core.vod

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import tvbox.engine.core.model.Episode
import tvbox.engine.core.model.FilterValue
import tvbox.engine.core.model.HomeResult
import tvbox.engine.core.model.PlayLine
import tvbox.engine.core.model.VodCard
import tvbox.engine.core.model.VodClass
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.model.VodFilter
import tvbox.engine.core.model.VodPage

class SiteResultException(message: String) : Exception(message)

/**
 * Reads the JSON that TVBox sites return (JSON CMS, remote spiders, and later js/jar/py spiders).
 * Ports `AbsJson`, `AbsSortJson`, `SourceViewModel.sortJson/getSortFilter` and the episode splitting
 * in `SourceViewModel.checkThunder…` (`"$$$"` lines, `"#"` episodes, `"$"` name/url).
 */
object TvboxResult {

    fun parseHome(site: String, text: String): HomeResult {
        val obj = parseObject(text)
        val classes = obj.arrayItems("class").mapNotNull { el ->
            val c = el.asObjectOrNull() ?: return@mapNotNull null
            val id = c.string("type_id") ?: c.string("id") ?: return@mapNotNull null
            val name = c.string("type_name") ?: c.string("name") ?: return@mapNotNull null
            VodClass(id, name)
        }
        val filters = LinkedHashMap<String, List<VodFilter>>()
        obj.get("filters")?.asObjectOrNull()?.let { all ->
            for ((classId, value) in all.entrySet()) {
                val groups = when {
                    value.isJsonObject -> listOf(value)
                    value.isJsonArray -> value.asJsonArray.toList()
                    else -> emptyList()
                }
                val parsed = groups.mapNotNull { parseFilter(it) }
                if (parsed.isNotEmpty()) filters[classId] = parsed
            }
        }
        return HomeResult(classes, filters, cards(site, obj))
    }

    fun parseList(site: String, text: String): VodPage {
        val obj = parseObject(text)
        return VodPage(
            page = obj.int("page") ?: 1,
            pageCount = obj.int("pagecount") ?: 0,
            total = obj.int("total") ?: 0,
            list = cards(site, obj),
        )
    }

    /** The first entry of `list`. Throws when the site returned nothing usable. */
    fun parseDetail(site: String, text: String): VodDetail {
        val vod = parseObject(text).arrayItems("list").firstNotNullOfOrNull { it.asObjectOrNull() }
            ?: throw SiteResultException("detail is empty")
        return VodDetail(
            site = site,
            id = vod.string("vod_id") ?: "",
            name = vod.string("vod_name") ?: "",
            pic = vod.string("vod_pic") ?: "",
            year = vod.string("vod_year") ?: "",
            area = vod.string("vod_area") ?: "",
            type = vod.string("type_name") ?: "",
            actor = vod.string("vod_actor") ?: "",
            director = vod.string("vod_director") ?: "",
            content = vod.string("vod_content") ?: "",
            remarks = vod.string("vod_remarks") ?: "",
            lines = splitLines(vod.string("vod_play_from"), vod.string("vod_play_url")),
        )
    }

    /** Splits `vod_play_from` / `vod_play_url` into lines; blank lines are dropped as in TVBox. */
    fun splitLines(from: String?, urls: String?): List<PlayLine> {
        if (from == null || urls == null) return emptyList()
        val flags = from.split("$$$")
        val lineUrls = urls.split("$$$")
        return flags.indices.mapNotNull { i ->
            if (i >= lineUrls.size) return@mapNotNull null
            val flag = flags[i].trim()
            val episodes = splitEpisodes(lineUrls[i])
            if (flag.isEmpty() || lineUrls[i].isBlank() || episodes.isEmpty()) null else PlayLine(flag, episodes)
        }
    }

    /** `name$url#name$url`; an entry without '$' is named by its position. */
    fun splitEpisodes(urls: String): List<Episode> {
        val result = ArrayList<Episode>()
        for (part in urls.split("#")) {
            if (part.isEmpty()) continue
            val pieces = part.split("$", limit = 2)
            result += if (pieces.size >= 2) Episode(pieces[1], pieces[0]) else Episode(pieces[0], (result.size + 1).toString())
        }
        return result
    }

    /**
     * A card without a `vod_id` is kept with the id "": TVBox opens such a card (and a `msearch:` one) by searching
     * for its title on the other sites. Only a card with neither an id nor a name is dropped.
     */
    private fun cards(site: String, obj: JsonObject): List<VodCard> =
        obj.arrayItems("list").mapNotNull { el ->
            val v = el.asObjectOrNull() ?: return@mapNotNull null
            val id = v.string("vod_id") ?: ""
            val name = v.string("vod_name") ?: ""
            if (id.isBlank() && name.isBlank()) return@mapNotNull null
            VodCard(site, id, name, v.string("vod_pic") ?: "", v.string("vod_remarks") ?: "")
        }

    private fun parseFilter(el: JsonElement): VodFilter? {
        val f = el.asObjectOrNull() ?: return null
        val key = f.string("key") ?: return null
        val values = f.arrayItems("value").mapNotNull { v ->
            val o = v.asObjectOrNull() ?: return@mapNotNull null
            FilterValue(o.string("n") ?: "", o.string("v") ?: "")
        }
        return VodFilter(key, f.string("name") ?: key, values)
    }

    internal fun parseObject(text: String): JsonObject {
        val element = try {
            JsonParser.parseString(text.trim().trimStart('﻿'))
        } catch (e: Exception) {
            throw SiteResultException("site returned invalid JSON")
        }
        return element.asObjectOrNull() ?: throw SiteResultException("site returned non-object JSON")
    }
}

internal fun JsonElement.asObjectOrNull(): JsonObject? = if (isJsonObject) asJsonObject else null

internal fun JsonObject.arrayItems(key: String): List<JsonElement> =
    get(key)?.takeIf { it.isJsonArray }?.asJsonArray?.toList() ?: emptyList()

/** Primitive values as strings (numbers included); null for missing, JSON null, objects and arrays. */
internal fun JsonObject.string(key: String): String? {
    val v = get(key) ?: return null
    return if (v.isJsonPrimitive) v.asString else null
}

internal fun JsonObject.int(key: String): Int? = string(key)?.trim()?.toIntOrNull()
