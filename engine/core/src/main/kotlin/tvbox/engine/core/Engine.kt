package tvbox.engine.core

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import tvbox.engine.core.config.ConfigDocument
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.SiteRuntime
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.model.ConfigSummary
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.HomeResult
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.model.RepoInfo
import tvbox.engine.core.model.SiteInfo
import tvbox.engine.core.model.Subscription
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.model.VodPage
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.net.SiteHttpException
import tvbox.engine.core.play.PlayResolveException
import tvbox.engine.core.play.PlayResolver
import tvbox.engine.core.search.SearchAggregator
import tvbox.engine.core.search.SearchEvent
import tvbox.engine.core.site.CmsSource
import tvbox.engine.core.site.ExtResolver
import tvbox.engine.core.site.RemoteSource
import tvbox.engine.core.site.SiteSource
import tvbox.engine.core.site.UnsupportedSiteException
import tvbox.engine.core.vod.SiteResultException
import java.util.UUID

/** Errors the API layer maps to HTTP status codes. */
sealed class EngineException(val code: String, message: String) : Exception(message) {
    class NotFound(message: String) : EngineException("NOT_FOUND", message)
    class BadRequest(message: String) : EngineException("BAD_REQUEST", message)
    class NoConfig : EngineException("NO_CONFIG", "no subscription is active")
    class ConfigLoadFailed(message: String) : EngineException("CONFIG_LOAD_FAILED", message)
    class Unsupported(message: String) : EngineException("UNSUPPORTED_SITE", message)
    /** The site (or a parser) failed: network, timeout, bad data. */
    class SiteFailed(code: String, message: String) : EngineException(code, message)
}

/**
 * Engine state: subscriptions, the active config and its site sources.
 * Subscriptions are in memory for now; persistence comes with the storage layer.
 */
class Engine(
    val info: EngineInfo,
    private val loader: ConfigLoader,
    private val http: SiteHttp,
    /** Where `proxy://` urls point, e.g. `http://127.0.0.1:9978/proxy?`. */
    proxyBase: String,
) {
    private class Active(
        val subscriptionId: String,
        val url: String,
        val repos: List<RepoInfo>,
        val config: TvboxConfig,
        val sources: Map<String, SiteSource>,
    )

    private val lock = Mutex()
    private val subscriptions = LinkedHashMap<String, Subscription>()
    private val ext = ExtResolver(http)
    private val playResolver = PlayResolver(http, proxyBase)
    private val searchAggregator = SearchAggregator()

    @Volatile
    private var active: Active? = null

    // ---- subscriptions ----

    suspend fun subscriptions(): List<Subscription> = lock.withLock { subscriptions.values.toList() }

    suspend fun addSubscription(url: String, name: String?): Subscription {
        val trimmed = url.trim()
        if (trimmed.isEmpty()) throw EngineException.BadRequest("url is empty")
        return lock.withLock {
            subscriptions.values.firstOrNull { it.url == trimmed }?.let { return@withLock it }
            val sub = Subscription(UUID.randomUUID().toString().take(8), name?.trim()?.ifEmpty { null } ?: trimmed, trimmed)
            subscriptions[sub.id] = sub
            sub
        }
    }

    suspend fun removeSubscription(id: String) {
        lock.withLock {
            subscriptions.remove(id) ?: throw EngineException.NotFound("subscription $id")
            if (active?.subscriptionId == id) active = null
        }
    }

    /**
     * Loads the subscription. A multi-repository subscription loads [repoUrl], or its first entry
     * (TVBox switches to the first entry automatically too).
     */
    suspend fun activate(id: String, repoUrl: String? = null): ConfigSummary {
        val sub = lock.withLock { subscriptions[id] } ?: throw EngineException.NotFound("subscription $id")
        val first = load(sub.url)
        val (url, repos, config) = when (val doc = first.document) {
            is ConfigDocument.Single -> Triple(sub.url, emptyList<RepoInfo>(), doc.config)
            is ConfigDocument.Repository -> {
                val repos = doc.entries.map { RepoInfo(it.name, it.url) }
                val chosen = repoUrl?.let { u -> repos.firstOrNull { it.url == u } ?: throw EngineException.NotFound("repo $u") }
                    ?: repos.firstOrNull()
                    ?: throw EngineException.ConfigLoadFailed("repository has no entries")
                when (val inner = load(chosen.url).document) {
                    is ConfigDocument.Single -> Triple(chosen.url, repos, inner.config)
                    is ConfigDocument.Repository -> throw EngineException.ConfigLoadFailed("nested repository at ${chosen.url}")
                }
            }
        }
        ext.clear()
        val loaded = Active(id, url, repos, config, config.sites.associate { it.key to createSource(it) })
        active = loaded
        return summary(loaded)
    }

    fun summary(): ConfigSummary = summary(current())

    fun sites(): List<SiteInfo> = current().config.sites.map {
        SiteInfo(
            key = it.key,
            name = it.name,
            type = it.type,
            searchable = it.isSearchable,
            quickSearch = it.quickSearch != 0,
            filterable = it.filterable != 0,
            runtime = it.runtime.name.lowercase(),
        )
    }

    // ---- browsing ----

    suspend fun home(site: String): HomeResult = siteCall(site) { it.home() }

    suspend fun category(site: String, classId: String, page: Int, filters: Map<String, String>): VodPage =
        siteCall(site) { it.category(classId, page.coerceAtLeast(1), filters) }

    suspend fun detail(site: String, id: String): VodDetail = siteCall(site) { it.detail(id) }

    suspend fun search(site: String, keyword: String, page: Int): VodPage =
        siteCall(site) { it.search(keyword, quick = false, page = page.coerceAtLeast(1)) }

    /** Streams results from every searchable, supported site (or only [siteKeys] when given). */
    fun searchAll(keyword: String, siteKeys: Set<String>? = null): Flow<SearchEvent> {
        if (keyword.isBlank()) throw EngineException.BadRequest("keyword is empty")
        val sources = current().sources.values.filter { src ->
            val bean = src.bean
            bean.isSearchable && isSupported(bean.runtime) && (siteKeys == null || bean.key in siteKeys)
        }
        return searchAggregator.search(sources, keyword.trim()) { describe(it) }
    }

    suspend fun resolvePlay(request: PlayRequest): PlayInfo {
        val a = current()
        val raw = siteCall(request.site) { it.play(request.line, request.episodeId) }
        return try {
            playResolver.resolve(raw, a.config)
        } catch (e: PlayResolveException) {
            throw EngineException.SiteFailed("PLAY_FAILED", e.message ?: "play failed")
        } catch (e: Exception) {
            val (code, message) = describe(e)
            throw EngineException.SiteFailed(code, message)
        }
    }

    // ---- internals ----

    private fun current(): Active = active ?: throw EngineException.NoConfig()

    private fun createSource(bean: tvbox.engine.core.config.SiteBean): SiteSource = when (bean.runtime) {
        SiteRuntime.CMS -> CmsSource(bean, http, ext)
        SiteRuntime.REMOTE -> RemoteSource(bean, http, ext)
        else -> UnsupportedSource(bean)
    }

    private fun isSupported(runtime: SiteRuntime) = runtime == SiteRuntime.CMS || runtime == SiteRuntime.REMOTE

    private suspend fun <T> siteCall(site: String, block: suspend (SiteSource) -> T): T {
        val source = current().sources[site] ?: throw EngineException.NotFound("site $site")
        return try {
            withTimeout(source.timeoutMs + 2_000) { block(source) }
        } catch (e: EngineException) {
            throw e
        } catch (e: UnsupportedSiteException) {
            throw EngineException.Unsupported(e.message ?: "unsupported site")
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException && e !is TimeoutCancellationException) throw e
            val (code, message) = describe(e)
            throw EngineException.SiteFailed(code, message)
        }
    }

    /** Maps failures to (code, message) for API errors and search events. */
    private fun describe(e: Throwable): Pair<String, String> = when (e) {
        is TimeoutCancellationException -> "SITE_TIMEOUT" to "site did not answer in time"
        is SiteHttpException -> (if (e.message?.startsWith("timeout") == true) "SITE_TIMEOUT" else "SITE_UNREACHABLE") to (e.message ?: "network error")
        is SiteResultException -> "SITE_BAD_RESULT" to (e.message ?: "unexpected data")
        is UnsupportedSiteException -> "UNSUPPORTED_SITE" to (e.message ?: "unsupported")
        else -> "SITE_ERROR" to (e.message ?: e.javaClass.simpleName)
    }

    private suspend fun load(url: String): ConfigLoader.Result = try {
        loader.load(url)
    } catch (e: ConfigLoader.LoadException) {
        throw EngineException.ConfigLoadFailed(e.message ?: "load failed")
    }

    private fun summary(a: Active): ConfigSummary = ConfigSummary(
        subscriptionId = a.subscriptionId,
        url = a.url,
        repos = a.repos,
        sites = a.config.sites.size,
        parses = a.config.parses.size,
        lives = countJsonArray(a.config.livesJson),
        spider = a.config.spider,
        wallpaper = a.config.wallpaper,
    )

    private fun countJsonArray(json: String): Int =
        if (json.isBlank()) 0 else runCatching { com.google.gson.JsonParser.parseString(json).asJsonArray.size() }.getOrDefault(0)
}

/** Placeholder for js/jar/py sites until their runtimes land. */
private class UnsupportedSource(override val bean: tvbox.engine.core.config.SiteBean) : SiteSource {
    override suspend fun home() = throw UnsupportedSiteException(bean)
    override suspend fun category(classId: String, page: Int, filters: Map<String, String>) = throw UnsupportedSiteException(bean)
    override suspend fun detail(id: String) = throw UnsupportedSiteException(bean)
    override suspend fun search(keyword: String, quick: Boolean, page: Int) = throw UnsupportedSiteException(bean)
    override suspend fun play(line: String, episodeId: String) = throw UnsupportedSiteException(bean)
}
