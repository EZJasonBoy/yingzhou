package tvbox.engine.core.site

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import tvbox.engine.core.vod.SiteResultException
import tvbox.engine.core.vod.TvboxResult
import tvbox.engine.core.vod.VideoFormat

/** Reads a TVBox `playerContent` JSON result. Port of `SourceViewModel.normalizePlayerResult`. */
object PlayerResult {

    fun parse(text: String, defaultUrl: String, flag: String): RawPlay {
        val obj = TvboxResult.parseObject(text)
        var url = obj.str("url") ?: ""
        var parse = obj.intOrNull("parse")
        val jx = obj.intOrNull("jx") ?: 0
        val playUrl = obj.str("playUrl") ?: ""

        when {
            url.isEmpty() -> {
                if (defaultUrl.isEmpty()) throw SiteResultException("site returned no play url")
            }
            // Multi-quality: ["标清","url1","高清","url2"] -> the first url.
            url.startsWith("[") && url.endsWith("]") -> {
                url = firstQualityUrl(url) ?: throw SiteResultException("empty quality list")
                parse = 0
            }
            url.startsWith("video://") -> {
                url = url.removePrefix("video://")
                parse = 1
            }
            url.startsWith("proxy://") -> parse = 0
            playUrl.isEmpty() && VideoFormat.isVideo(url) && parse == null && !obj.has("jx") -> parse = 0
        }

        return RawPlay(
            url = url.ifEmpty { defaultUrl },
            parse = parse ?: 0,
            jx = jx,
            headers = headers(obj),
            playUrl = playUrl,
            flag = obj.str("flag") ?: flag,
        )
    }

    /** `header` and `headers`, each either an object or a JSON string. */
    fun headers(obj: JsonObject): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        for (key in listOf("header", "headers")) {
            val raw: JsonElement = obj.get(key) ?: continue
            val headerObj = when {
                raw.isJsonObject -> raw.asJsonObject
                raw.isJsonPrimitive && raw.asString.isNotBlank() ->
                    runCatching { JsonParser.parseString(raw.asString).asJsonObject }.getOrNull()
                else -> null
            } ?: continue
            for ((k, v) in headerObj.entrySet()) {
                if (k.isNotEmpty() && v.isJsonPrimitive) result[k] = v.asString
            }
        }
        return result
    }

    private fun firstQualityUrl(json: String): String? = runCatching {
        val items = JsonParser.parseString(json).asJsonArray.map { it.asString }
        // Pairs of (name, url); fall back to the first http-looking entry.
        items.getOrNull(1) ?: items.firstOrNull { it.startsWith("http") }
    }.getOrNull()?.removePrefix("video://")

    private fun JsonObject.str(key: String): String? {
        val v = get(key) ?: return null
        return if (v.isJsonPrimitive) v.asString else null
    }

    private fun JsonObject.intOrNull(key: String): Int? = str(key)?.trim()?.toIntOrNull()
}
