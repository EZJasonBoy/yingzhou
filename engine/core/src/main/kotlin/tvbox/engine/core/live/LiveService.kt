package tvbox.engine.core.live

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tvbox.engine.core.config.ConfigDecoder
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.CatchupAddress
import tvbox.engine.core.model.CatchupTemplate
import tvbox.engine.core.model.EpgDay
import tvbox.engine.core.model.LiveCatchup
import tvbox.engine.core.model.EpgProgram
import tvbox.engine.core.model.LiveList
import tvbox.engine.core.model.LiveSourceInfo
import tvbox.engine.core.net.SiteHttp
import java.util.concurrent.ConcurrentHashMap

class LiveException(val code: String, message: String) : Exception(message)

/**
 * The active config's live sources: playlists loaded on demand and cached for half an hour, programme guides
 * cached per channel and day (template APIs) or per file (XMLTV, six hours).
 */
class LiveService(
    private val http: SiteHttp,
    /** Replacement for `proxy://` in channel urls, e.g. `http://127.0.0.1:9978/proxy?`. */
    private val proxyBase: String,
    private val locator: ConfigLocator? = null,
    /** Asks the spider of a `type: 3` source for its playlist text (`liveContent`); null when no runtime can. */
    private val spiderList: (suspend (LiveSourceSpec) -> String)? = null,
    /** Spider kinds that can serve lists besides jar and js, as of now ("py" once a Python is found). */
    private val moreSpiderKinds: () -> List<String> = { emptyList() },
) {
    private class Loaded(val list: LiveList, val tvgUrl: String, val at: Long)

    @Volatile private var specs: List<LiveSourceSpec> = emptyList()
    private val lists = ConcurrentHashMap<Int, Loaded>()
    private val listLocks = ConcurrentHashMap<Int, Mutex>()
    private val jsonEpg = ConcurrentHashMap<String, Pair<Long, List<EpgProgram>>>()
    private val xmltv = ConcurrentHashMap<String, Pair<Long, Map<String, List<EpgProgram>>>>()
    private val xmltvLock = Mutex()

    fun onConfig(livesJson: String) {
        specs = LiveSourceSpec.parseAll(livesJson, locator)
        lists.clear()
    }

    fun sources(): List<LiveSourceInfo> = specs.mapIndexed { i, s ->
        LiveSourceInfo(
            index = i,
            name = s.name,
            hasEpg = s.epg.isNotBlank() || lists[i]?.tvgUrl?.isNotBlank() == true,
            supported = supported(s),
            spider = spiderKind(s),
        )
    }

    /** Same rule as for sites (TVBox `getCSP`): the api's suffix says which runtime runs the spider. */
    private fun spiderKind(spec: LiveSourceSpec): String = when {
        spec.api.isEmpty() -> ""
        spec.api.endsWith(".js") || spec.api.contains(".js?") -> "js"
        spec.api.contains(".py") -> "py"
        else -> "jar"
    }

    /** Jar and Python spiders have `liveContent`, JS spiders `live`; Python ones need a Python on this machine. */
    private fun supported(spec: LiveSourceSpec) =
        spec.supported && (spec.api.isEmpty() || (spiderList != null && (spiderKind(spec) in SPIDER_KINDS || spiderKind(spec) in moreSpiderKinds())))

    suspend fun list(index: Int, refresh: Boolean = false): LiveList {
        val spec = spec(index)
        if (!supported(spec)) throw LiveException("UNSUPPORTED", "${spec.name}：暂不支持这种直播源")
        fresh(index, refresh)?.let { return it.list }
        return listLocks.getOrPut(index) { Mutex() }.withLock {
            fresh(index, refresh)?.list ?: load(index, spec).list
        }
    }

    private fun fresh(index: Int, refresh: Boolean) = lists[index]?.takeIf { !refresh && System.currentTimeMillis() - it.at < LIST_TTL }

    private suspend fun load(index: Int, spec: LiveSourceSpec): Loaded {
        val playlist = when {
            spec.inline.isNotEmpty() -> LivePlaylist(spec.inline)
            spec.api.isNotEmpty() -> LivePlaylistParser.parse(spiderText(spec), spec.headers)
            else -> LivePlaylistParser.parse(downloadedText(spec), spec.headers)
        }
        if (playlist.groups.isEmpty()) throw LiveException("EMPTY", "${spec.name}: the playlist has no channels")
        val groups = playlist.groups.map { g ->
            g.copy(channels = g.channels.map { c ->
                val urls = c.urls.map { u -> u.copy(url = forSpider(own(u.url), spec), catchup = catchupRule(u.catchup, spec)) }
                c.copy(logo = c.logo.ifEmpty { logoFor(spec, c.name) }, urls = urls, catchupDays = urls.maxOfOrNull { Catchup.days(it.catchup, it.url) } ?: 0)
            })
        }
        return Loaded(LiveList(index, spec.name, groups), playlist.tvgUrl, System.currentTimeMillis()).also { lists[index] = it }
    }

    /**
     * The list of a `type: 3` source: what its spider answers (`liveContent(url)` of a jar, `live(url)` of a script).
     * TVBox asks a script only when the entry's `url` is the script itself; any other `url` is a playlist it
     * downloads, and the spider just serves the channels' proxy addresses. So a spider with nothing to say leaves
     * the `url` as the list.
     */
    private suspend fun spiderText(spec: LiveSourceSpec): String {
        val text = spiderList!!.invoke(spec)
        return if (text.isBlank() && spec.url.startsWith("http")) downloadedText(spec) else text
    }

    /** The playlist at the source's `url`. Some are wrapped like configs (base64 in an image, AES). */
    private suspend fun downloadedText(spec: LiveSourceSpec): String {
        val text = fetchList(spec)
        return if (LivePlaylistParser.looksLikePlaylist(text)) text else ConfigDecoder.decode(text)
    }

    /** `proxy://` and urls of TVBox's built-in server (`http://127.0.0.1:9978/proxy?`) mean this engine's proxy. */
    private fun own(url: String): String = when {
        url.startsWith("proxy://") -> url.replaceFirst("proxy://", proxyBase)
        else -> LiveSourceSpec.LOCAL_PROXY.find(url)?.let { proxyBase + url.substring(it.range.last + 1) } ?: url
    }

    /**
     * A proxy address in a list that a spider served is meant for that spider. TVBox hands such a request to the
     * spider used last, which while live TV is on screen is the live one. Here other sites can have been opened in
     * between, so the address says whose it is: `siteKey`, which TVBox adds to proxy requests itself.
     */
    private fun forSpider(url: String, spec: LiveSourceSpec): String =
        if (spec.api.isEmpty() || !url.startsWith(proxyBase) || SITE_KEY.containsMatchIn(url)) url
        else url + "&siteKey=" + java.net.URLEncoder.encode(spec.spiderKey, "UTF-8")

    private suspend fun fetchList(spec: LiveSourceSpec): String {
        val url = own(spec.url)
        if (url == spec.url) return http.get(url, headers = spec.headers, timeoutMs = 20_000)
        // A playlist served through a spider's proxy (`...proxy?do=live&url=<playlist>`): when no loaded spider
        // answers for it, the playlist it wraps is the next best thing.
        return try {
            http.get(url, headers = spec.headers, timeoutMs = 20_000)
        } catch (e: Exception) {
            val wrapped = url.substringAfter('?').split('&').firstOrNull { it.startsWith("url=") }?.removePrefix("url=")
                ?.let { java.net.URLDecoder.decode(it, "UTF-8") }?.takeIf { it.startsWith("http") } ?: throw e
            http.get(wrapped, headers = spec.headers, timeoutMs = 20_000)
        }
    }

    /**
     * A line's catch-up rule: its own when it is complete (TVBox: a channel's `catchup` with a source wins), else
     * the `lives` entry's, with what the line says (days, correction) kept.
     */
    private fun catchupRule(own: CatchupTemplate?, spec: LiveSourceSpec): CatchupTemplate? =
        if (Catchup.isComplete(own) || spec.catchup == null) own else Catchup.merge(own, spec.catchup)

    /**
     * Where to play what [channel] (in [group], when names repeat across groups) showed from [startMs] to [endMs]:
     * line [line] first, then the channel's other lines that have catch-up.
     */
    suspend fun catchup(index: Int, group: String?, channel: String, line: Int, startMs: Long, endMs: Long): LiveCatchup {
        val spec = spec(index)
        val ch = list(index).groups.filter { group.isNullOrEmpty() || it.name == group }
            .flatMap { it.channels }.firstOrNull { it.name == channel }
            ?: throw LiveException("NOT_FOUND", "no channel $channel")
        val now = System.currentTimeMillis()
        if (endMs <= startMs) throw LiveException("BAD_REQUEST", "end must be after start")
        if (startMs >= now) throw LiveException("BAD_REQUEST", "the programme has not started yet")
        if (ch.catchupDays == 0) throw LiveException("BAD_REQUEST", "$channel has no catch-up")
        val first = line.coerceIn(0, ch.urls.size - 1)
        val addresses = (listOf(first) + ch.urls.indices.filter { it != first }).flatMap { i ->
            val u = ch.urls[i]
            Catchup.build(u.catchup, u.url, startMs, endMs, now).map { CatchupAddress(forSpider(own(it), spec), u.headers, i) }
        }.distinctBy { it.url }
        val best = addresses.firstOrNull() ?: throw LiveException("BAD_REQUEST", "$channel has no catch-up")
        return LiveCatchup(best.url, best.headers, best.line, addresses.drop(1))
    }

    /** The programmes of [channel] on [date] (`yyyy-MM-dd`, China time; today when blank). */
    suspend fun epg(index: Int, channel: String, date: String): EpgDay {
        val spec = spec(index)
        val day = date.ifBlank { Epg.dayFormat().format(java.util.Date()) }
        if (!Regex("\\d{4}-\\d{2}-\\d{2}").matches(day)) throw LiveException("BAD_REQUEST", "date must be yyyy-MM-dd")
        val url = spec.epg.trim()
        val programs = when {
            url.isEmpty() -> {
                // The guides the playlist itself names (always XMLTV); the first that has anything is used.
                val named = if (supported(spec)) runCatching { list(index); lists[index]?.tvgUrl.orEmpty() }.getOrDefault("") else ""
                val guide = named.split(',').filter { it.isNotBlank() }.firstNotNullOfOrNull { u -> xmltv(u, spec.headers).takeIf { it.isNotEmpty() } }
                Epg.forDay(guide?.get(Epg.normalize(channel)) ?: emptyList(), day)
            }
            Epg.isXmltv(url) -> Epg.forDay(xmltv(url, spec.headers)[Epg.normalize(channel)] ?: emptyList(), day)
            else -> templateEpg(url, channel, day)
        }
        return EpgDay(channel, day, programs)
    }

    private suspend fun templateEpg(spec: String, channel: String, day: String): List<EpgProgram> {
        for (name in listOf(Epg.normalize(channel), channel).distinct()) {
            val url = Epg.requestUrl(spec, name, day)
            jsonEpg[url]?.takeIf { System.currentTimeMillis() - it.first < EPG_TTL }?.let { if (it.second.isNotEmpty()) return it.second }
            val programs = runCatching { Epg.parseJson(http.get(url, timeoutMs = 10_000), day) }.getOrDefault(emptyList())
            if (jsonEpg.size > 2000) jsonEpg.clear()
            jsonEpg[url] = System.currentTimeMillis() to programs
            if (programs.isNotEmpty()) return programs
        }
        return emptyList()
    }

    private suspend fun xmltv(url: String, headers: Map<String, String>): Map<String, List<EpgProgram>> {
        xmltv[url]?.takeIf { System.currentTimeMillis() - it.first < XMLTV_TTL }?.let { return it.second }
        return xmltvLock.withLock {
            xmltv[url]?.takeIf { System.currentTimeMillis() - it.first < XMLTV_TTL }?.second
                ?: runCatching { Epg.parseXmltv(http.getBytes(url, headers, timeoutMs = 60_000)) }.getOrDefault(emptyMap())
                    .also { xmltv[url] = System.currentTimeMillis() to it }
        }
    }

    private fun logoFor(spec: LiveSourceSpec, name: String): String =
        if (spec.logo.contains("{name}")) spec.logo.replace("{name}", Epg.normalize(name)) else ""

    private fun spec(index: Int) = specs.getOrNull(index) ?: throw LiveException("NOT_FOUND", "no live source $index")

    private companion object {
        /** The kinds of spider that can be asked for a list. */
        val SPIDER_KINDS = setOf("jar", "js")
        val SITE_KEY = Regex("[?&]siteKey=")
        const val LIST_TTL = 30 * 60_000L
        const val EPG_TTL = 30 * 60_000L
        const val XMLTV_TTL = 6 * 3600_000L
    }
}
