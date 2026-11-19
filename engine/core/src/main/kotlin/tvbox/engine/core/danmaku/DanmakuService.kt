package tvbox.engine.core.danmaku

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.util.TextDecoding
import java.net.URLEncoder

/**
 * Finds the danmaku of an episode and keeps them for a while. In order:
 *
 * 1. `site`: what the site's play answer said (`danmaku`: an address — Bilibili's comment XML, a spider's `proxy://`
 *    — or the danmaku themselves). Remembered per episode when it is resolved.
 * 2. `config`: the config's `danmaku` API, when the user switched it on.
 * 3. `custom`: the user's own danmaku service, when they gave one.
 *
 * An API is asked the way TVBoxOS asks it (`DanmakuApi`): an address with `{name}` / `{episode}` is filled in and
 * fetched; one ending in `/danmaku` gets `name` and `episode` as a form; any other is the base of a
 * dandanplay-compatible service (`/api/v2/search/episodes`, `/api/v2/comment/{id}`). The answer is either the danmaku
 * or where to get them (`{url}`, `[{url}]`, a bare address). Nothing is sent anywhere unless the site named it or
 * the user switched it on.
 */
class DanmakuService(
    private val http: SiteHttp,
    /** Replacement for `proxy://`, e.g. `http://127.0.0.1:9978/proxy?`. */
    private val proxyBase: String,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val fromSite = lru<String, String>(400)
    private val kept = lru<String, Pair<Long, DanmakuList>>(KEPT)

    private fun episodeKey(site: String, line: String, episodeId: String) = "$site\n$line\n$episodeId"

    /** What a site's play answer said about danmaku for this episode (nothing: forget what it said before). */
    fun remember(site: String, line: String, episodeId: String, raw: String) {
        synchronized(fromSite) {
            if (raw.isBlank()) fromSite.remove(episodeKey(site, line, episodeId)) else fromSite[episodeKey(site, line, episodeId)] = raw.trim()
        }
    }

    /** For display: the address the site named, or `inline` when it put the danmaku themselves in. */
    fun describe(raw: String): String = when {
        raw.isBlank() -> ""
        raw.startsWith("http://") || raw.startsWith("https://") -> raw
        raw.startsWith("proxy://") -> raw.replaceFirst("proxy://", proxyBase)
        else -> "inline"
    }

    /**
     * The danmaku of an episode from the first source that has some. [configApi] / [customApi] are null when the user
     * has not switched them on. An empty list with `source = ""` when no source applies; [DanmakuException] when the
     * ones that apply all failed.
     */
    suspend fun episode(
        site: String, line: String, episodeId: String, title: String, episode: String,
        configApi: String?, customApi: String?, refresh: Boolean = false,
    ): DanmakuList {
        val sources = buildList {
            synchronized(fromSite) { fromSite[episodeKey(site, line, episodeId)] }?.let { raw -> add(Triple("site", "site\n$raw", suspend { describe(raw) to load(raw) })) }
            if (title.isNotBlank()) {
                configApi?.trim()?.takeIf { it.isNotEmpty() }?.let { api -> add(Triple("config", "api\n$api\n$title\n$episode", suspend { query(api, title, episode) })) }
                customApi?.trim()?.takeIf { it.isNotEmpty() }?.let { api -> add(Triple("custom", "api\n$api\n$title\n$episode", suspend { query(api, title, episode) })) }
            }
        }
        if (sources.isEmpty()) return DanmakuList()
        val errors = ArrayList<String>()
        for ((source, key, fetch) in sources) {
            if (!refresh) synchronized(kept) { kept[key] }?.takeIf { now() - it.first < KEEP_MS }?.let { return it.second.copy(source = source) }
            try {
                val (from, items) = fetch()
                if (items.isEmpty()) {
                    errors += "${label(source)}没有弹幕"
                    continue
                }
                val list = DanmakuList(source, from, items.size, items)
                synchronized(kept) { kept[key] = now() to list }
                return list
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                errors += "${label(source)}：${e.message ?: e.javaClass.simpleName}"
            }
        }
        // Nothing found is an answer too (the services were asked); an error only when every one of them failed.
        if (errors.all { it.endsWith("没有弹幕") }) return DanmakuList(source = sources.first().first)
        throw DanmakuException(errors.joinToString("；"))
    }

    private fun label(source: String) = when (source) {
        "site" -> "站点给的弹幕"
        "config" -> "订阅的弹幕接口"
        else -> "自定义弹幕接口"
    }

    /** A danmaku file from a client (`POST /api/v1/danmaku/parse`). */
    fun parseFile(bytes: ByteArray): List<DanmakuComment> = DanmakuParser.parse(TextDecoding.text(bytes))

    /** The site's `danmaku`: fetched when it is an address, read as it is otherwise. */
    suspend fun load(raw: String): List<DanmakuComment> {
        val url = if (raw.startsWith("proxy://")) raw.replaceFirst("proxy://", proxyBase) else raw
        if (url.startsWith("http://") || url.startsWith("https://")) return fetch(url)
        return DanmakuParser.parse(raw)
    }

    private suspend fun fetch(url: String): List<DanmakuComment> = DanmakuParser.parse(TextDecoding.text(http.getBytes(url, timeoutMs = TIMEOUT_MS)))

    /** Asks a danmaku API for an episode: (where they came from, the danmaku). */
    suspend fun query(api: String, title: String, episode: String): Pair<String, List<DanmakuComment>> {
        val answer = when {
            "{name}" in api || "{episode}" in api ->
                http.getBytes(api.replace("{name}", enc(title)).replace("{episode}", enc(episode)), timeoutMs = TIMEOUT_MS)
            api.trimEnd('/').endsWith("/danmaku") ->
                http.postForm(api, listOf("name" to title, "episode" to episode), timeoutMs = TIMEOUT_MS).toByteArray()
            else -> return dandanplay(api, title, episode)
        }
        val text = TextDecoding.text(answer)
        DanmakuParser.parse(text).takeIf { it.isNotEmpty() }?.let { return api to it }
        // Neither danmaku nor an address: this episode has none there.
        val url = danmakuUrl(text) ?: return api to emptyList()
        return url to load(url)
    }

    /** `{url}`, `[{url}, …]` (the first), or a bare address: what TVBoxOS takes from an API's answer. */
    private fun danmakuUrl(text: String): String? {
        val t = text.trim()
        if (t.startsWith("http://") || t.startsWith("https://")) return t.lineSequence().first().trim()
        val root = runCatching { JsonParser.parseString(t) }.getOrNull() ?: return null
        val candidates = when {
            root.isJsonArray -> root.asJsonArray.toList()
            root.isJsonObject -> listOf(root) + (root.asJsonObject.get("data")?.let { if (it.isJsonArray) it.asJsonArray.toList() else listOf(it) } ?: emptyList())
            else -> emptyList()
        }
        return candidates.firstNotNullOfOrNull { e -> (e as? JsonObject)?.get("url")?.takeIf { it.isJsonPrimitive }?.asString?.trim()?.takeIf { it.startsWith("http") } }
    }

    // ---- dandanplay-compatible services ----

    private suspend fun dandanplay(api: String, title: String, episode: String): Pair<String, List<DanmakuComment>> {
        val base = api.trim().trimEnd('/').removeSuffix("/api/v2")
        if (!base.startsWith("http://") && !base.startsWith("https://")) throw DanmakuException("弹幕接口地址不对：$api")
        val number = episodeNumber(episode)
        val searches = listOfNotNull(
            number?.let { "$base/api/v2/search/episodes?anime=${enc(title)}&episode=$it" },
            "$base/api/v2/search/episodes?anime=${enc(title)}",
        )
        var failure: Exception? = null
        for (url in searches) {
            val body = try {
                TextDecoding.text(http.getBytes(url, timeoutMs = TIMEOUT_MS))
            } catch (e: Exception) {
                failure = e
                continue
            }
            val id = matchEpisode(body, title, episode, number) ?: continue
            val comments = "$base/api/v2/comment/$id?format=json"
            return comments to fetch(comments)
        }
        failure?.let { throw it }
        throw DanmakuException("没有找到《$title》${if (episode.isBlank()) "" else " $episode"}")
    }

    /** The episode id in a `/search/episodes` answer: by name, then by number, then the only one of a film. */
    internal fun matchEpisode(body: String, title: String, episode: String, number: Int?): String? {
        val root = runCatching { JsonParser.parseString(body).asJsonObject }.getOrNull() ?: return null
        val animes = (root.get("animes") ?: root.get("anime") ?: root.get("data"))?.takeIf { it.isJsonArray }?.asJsonArray?.mapNotNull { it as? JsonObject }
            ?: root.get("bangumi")?.let { listOf(it as? JsonObject ?: return null) }
            ?: return null
        val wanted = clean(title)
        // The same title first, then one that contains it, then the rest in the service's order.
        val ordered = animes.sortedBy { a ->
            val t = clean(a.str("animeTitle") ?: a.str("title") ?: "")
            when {
                t == wanted -> 0
                wanted.isNotEmpty() && (t.contains(wanted) || wanted.contains(t)) -> 1
                else -> 2
            }
        }
        for (anime in ordered) {
            val episodes = anime.get("episodes")?.takeIf { it.isJsonArray }?.asJsonArray?.mapNotNull { it as? JsonObject } ?: continue
            if (episodes.isEmpty()) continue
            fun id(e: JsonObject) = e.str("episodeId") ?: e.str("id")
            episodes.firstOrNull { e -> episode.isNotBlank() && (e.str("episodeTitle") ?: e.str("title") ?: "").contains(episode) }?.let { return id(it) }
            if (number != null) {
                episodes.firstOrNull { e ->
                    (e.str("episodeNumber") ?: e.str("number"))?.toDoubleOrNull()?.toInt() == number || episodeNumber(e.str("episodeTitle") ?: "") == number
                }?.let { return id(it) }
            }
            if (episodes.size == 1 || number == null) return id(episodes.first())
        }
        return null
    }

    private fun JsonObject.str(key: String): String? = get(key)?.takeIf { it.isJsonPrimitive }?.asString

    companion object {
        /** How long an episode's danmaku are kept, and how many episodes are. */
        const val KEEP_MS = 30 * 60_000L
        const val KEPT = 24
        const val TIMEOUT_MS = 20_000L

        private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

        private val NON_WORD = Regex("[^\\p{L}\\p{N}]+")

        private fun clean(s: String) = s.lowercase().replace(NON_WORD, "")

        private val CN_EPISODE = Regex("第\\s*(\\d+)\\s*[集话話期回]")
        private val EN_EPISODE = Regex("(?i)(?:^|[^a-z])(?:episode|ep?)\\s*(\\d+)")

        /** 第12集 → 12, EP05 / S01E05 → 5, 07 → 7; null when the name has no number (正片, 完结). */
        fun episodeNumber(name: String): Int? {
            CN_EPISODE.find(name)?.let { return it.groupValues[1].toIntOrNull() }
            EN_EPISODE.find(name)?.let { return it.groupValues[1].toIntOrNull() }
            return Regex("\\d+").findAll(name).lastOrNull()?.value?.toIntOrNull()?.takeIf { it < 10_000 }
        }

        private fun <K, V> lru(max: Int) = object : LinkedHashMap<K, V>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?) = size > max
        }
    }
}
