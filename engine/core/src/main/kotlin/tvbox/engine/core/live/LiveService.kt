package tvbox.engine.core.live

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tvbox.engine.core.config.ConfigDecoder
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.EpgDay
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
        LiveSourceInfo(index = i, name = s.name, hasEpg = s.epg.isNotBlank() || lists[i]?.tvgUrl?.isNotBlank() == true, supported = s.supported)
    }

    suspend fun list(index: Int, refresh: Boolean = false): LiveList {
        val spec = spec(index)
        if (!spec.supported) throw LiveException("UNSUPPORTED", "${spec.name}: this kind of live source is not supported yet")
        fresh(index, refresh)?.let { return it.list }
        return listLocks.getOrPut(index) { Mutex() }.withLock {
            fresh(index, refresh)?.list ?: load(index, spec).list
        }
    }

    private fun fresh(index: Int, refresh: Boolean) = lists[index]?.takeIf { !refresh && System.currentTimeMillis() - it.at < LIST_TTL }

    private suspend fun load(index: Int, spec: LiveSourceSpec): Loaded {
        val playlist = if (spec.inline.isNotEmpty()) {
            LivePlaylist(spec.inline)
        } else {
            var text = http.get(spec.url, headers = spec.headers, timeoutMs = 20_000)
            // Some playlists are wrapped like configs (base64 in an image, AES).
            if (!LivePlaylistParser.looksLikePlaylist(text)) text = ConfigDecoder.decode(text)
            LivePlaylistParser.parse(text, spec.headers)
        }
        if (playlist.groups.isEmpty()) throw LiveException("EMPTY", "${spec.name}: the playlist has no channels")
        val groups = playlist.groups.map { g ->
            g.copy(channels = g.channels.map { c ->
                c.copy(
                    logo = c.logo.ifEmpty { logoFor(spec, c.name) },
                    urls = c.urls.map { u -> u.copy(url = if (u.url.startsWith("proxy://")) u.url.replaceFirst("proxy://", proxyBase) else u.url) },
                )
            })
        }
        return Loaded(LiveList(index, spec.name, groups), playlist.tvgUrl, System.currentTimeMillis()).also { lists[index] = it }
    }

    /** The programmes of [channel] on [date] (`yyyy-MM-dd`, China time; today when blank). */
    suspend fun epg(index: Int, channel: String, date: String): EpgDay {
        val spec = spec(index)
        val day = date.ifBlank { Epg.dayFormat().format(java.util.Date()) }
        if (!Regex("\\d{4}-\\d{2}-\\d{2}").matches(day)) throw LiveException("BAD_REQUEST", "date must be yyyy-MM-dd")
        var url = spec.epg.trim()
        if (url.isEmpty() && spec.supported) url = runCatching { list(index); lists[index]?.tvgUrl.orEmpty() }.getOrDefault("")
        if (url.isEmpty()) return EpgDay(channel, day, emptyList())
        val programs = if (Epg.isXmltv(url)) {
            val guide = xmltv(url, spec.headers)
            Epg.forDay(guide[Epg.normalize(channel)] ?: emptyList(), day)
        } else {
            templateEpg(url, channel, day)
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
        const val LIST_TTL = 30 * 60_000L
        const val EPG_TTL = 30 * 60_000L
        const val XMLTV_TTL = 6 * 3600_000L
    }
}
