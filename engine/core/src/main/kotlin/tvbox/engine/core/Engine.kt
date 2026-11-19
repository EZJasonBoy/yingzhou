package tvbox.engine.core

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import tvbox.engine.core.config.ConfigDocument
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.RepoEntry
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
import tvbox.engine.core.live.LiveException
import tvbox.engine.core.live.LiveService
import tvbox.engine.core.model.EpgDay
import tvbox.engine.core.model.LiveList
import tvbox.engine.core.model.LiveSourceInfo
import tvbox.engine.core.play.JarParsers
import tvbox.engine.core.play.M3u8Cleaner
import tvbox.engine.core.play.PlayResolver
import tvbox.engine.core.play.PlayRules
import tvbox.engine.core.play.Sniffer
import tvbox.engine.core.search.SearchAggregator
import tvbox.engine.core.search.SearchEvent
import tvbox.engine.core.site.CmsSource
import tvbox.engine.core.site.ExtResolver
import tvbox.engine.core.site.RemoteSource
import tvbox.engine.core.site.SiteSource
import tvbox.engine.core.site.UnsupportedSiteException
import tvbox.engine.core.spider.ProxyResponse
import tvbox.engine.core.spider.SpiderLoadException
import tvbox.engine.core.spider.SpiderRuntime
import tvbox.engine.core.spider.SpiderSource
import tvbox.engine.core.store.EngineStore
import tvbox.engine.core.store.Library
import tvbox.engine.core.store.MemoryStore
import tvbox.engine.core.store.SubscriptionState
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
 * Engine state: subscriptions, the active config and its site sources, plus the user's library
 * (history, favorites). Subscriptions and the library are persisted through [store].
 */
class Engine(
    info: EngineInfo,
    private val loader: ConfigLoader,
    private val http: SiteHttp,
    /** Where `proxy://` urls point, e.g. `http://127.0.0.1:9978/proxy?`. */
    proxyBase: String,
    private val store: EngineStore = MemoryStore(),
    /** Spider runtimes available on this platform (js, jar, py). */
    private val runtimes: List<SpiderRuntime> = emptyList(),
    /** Web page sniffing (headless browser / WebView), when the platform has one. */
    sniffer: Sniffer? = null,
    /** The interceptor on the engine's http client that the GitHub proxy setting drives; null when there is none. */
    private val githubProxy: tvbox.engine.core.net.GithubProxy? = null,
    /** The active config's `hosts` / `headers` / `doh` / `ads`, installed on the engine's http client; null when there is none. */
    private val network: tvbox.engine.core.net.ConfigNetwork? = null,
    /** Copies of configs, site answers, `ext` files and live lists (the same instance the [loader] keeps copies in); null: nothing is kept. */
    private val cache: tvbox.engine.core.cache.DataCache? = null,
) {
    /** Capabilities are derived from the runtimes actually present. */
    val info: EngineInfo = info.copy(
        capabilities = info.capabilities.copy(
            js = runtimes.any { it.kind == "js" },
            jar = runtimes.any { it.kind == "jar" },
            py = runtimes.any { it.kind == "py" },
            sniff = sniffer != null,
        ),
    )
    val library = Library(store)
    private class Active(
        val subscriptionId: String,
        val url: String,
        /** Top-level entries of a multi-repository subscription; empty for a plain config. */
        val repos: List<RepoEntry>,
        val config: TvboxConfig,
        val sources: Map<String, SiteSource>,
        /** What was loaded to get here: address and text hash of the subscription, the groups on the way, the config. */
        val trace: List<Pair<String, String>> = emptyList(),
        /** When the texts in use were downloaded; 0 when unknown. */
        @Volatile var fetchedAt: Long = 0,
        /** True while the config comes from the kept copies and the network has not confirmed it yet. */
        @Volatile var stored: Boolean = false,
        /** Why the last refresh of a stored config failed; empty when it did not. */
        @Volatile var refreshError: String = "",
    ) {
        /** Site answers are kept under this: another subscription, entry or text is another scope. */
        val scope: String = tvbox.engine.core.cache.DataCache.hash(subscriptionId + "\n" + url + "\n" + trace.joinToString("\n") { it.second })
    }

    private val background = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)
    private val siteData = cache?.let { tvbox.engine.core.cache.SiteDataCache(it, background) }

    /** True while a config that was started from its kept copy is being checked against the network. */
    @Volatile private var refreshing = false

    private val lock = Mutex()
    private val subscriptions = LinkedHashMap<String, Subscription>()
    private val ext = ExtResolver(http, cache)
    private val playResolver = PlayResolver(
        http = http,
        proxyBase = proxyBase,
        sniffer = sniffer,
        jarParsers = runtimes.filterIsInstance<JarParsers>().firstOrNull(),
        playlistBase = proxyBase.substringBefore("/proxy") + "/m3u8?",
    )
    private val searchAggregator = SearchAggregator()
    private val live = LiveService(http, proxyBase, spiderList = ::spiderLive)

    /** Spiders created for `lives` entries of `type: 3`, by source name; released with the config. */
    private val liveSpiders = java.util.concurrent.ConcurrentHashMap<String, tvbox.engine.core.spider.Spider>()
    private val liveSpiderLock = Mutex()

    /** The playlist text of a `type: 3` live source: its spider's `liveContent(url)`. */
    private suspend fun spiderLive(spec: tvbox.engine.core.live.LiveSourceSpec): String {
        val bean = tvbox.engine.core.config.SiteBean(key = "live_" + spec.name, name = spec.name, type = 3, api = spec.api, ext = spec.ext, jar = spec.jar)
        val runtime = runtimes.firstOrNull { it.supports(bean) }
            ?: throw tvbox.engine.core.live.LiveException("UNSUPPORTED", "${spec.name}: no runtime for the live spider ${spec.api}")
        val spider = liveSpiders[bean.key] ?: liveSpiderLock.withLock {
            liveSpiders[bean.key] ?: withTimeout(40_000) { runtime.create(bean, ext.resolve(bean.ext)) }.also { liveSpiders[bean.key] = it }
        }
        return withTimeout(30_000) { spider.live(spec.url) }.orEmpty()
    }

    @Volatile
    private var active: Active? = null

    /** The subscription to restore on the next start (persisted). */
    private var savedActiveId: String? = null
    private var savedActiveRepo: String? = null
    private var savedActiveRepoPath: List<String> = emptyList()

    /**
     * Entries of the nested repositories opened so far: subscription id -> group url -> its entries.
     * Kept when a switch fails, so the entries stay available to choose from.
     */
    private val repoGroups = java.util.concurrent.ConcurrentHashMap<String, MutableMap<String, List<RepoEntry>>>()

    // Declared before the init block that fills it: property initialisers run in order.
    @Volatile private var currentSettings = tvbox.engine.core.model.EngineSettings()

    init {
        val saved = store.loadSubscriptions()
        saved.subscriptions.forEach { subscriptions[it.id] = it }
        savedActiveId = saved.activeId
        savedActiveRepo = saved.activeRepo
        savedActiveRepoPath = saved.activeRepoPath
        applySettings(store.loadSettings())
    }

    // ---- settings ----

    fun settings(): tvbox.engine.core.model.EngineSettings = currentSettings

    /** Saves and applies the settings. The active config is not loaded again; the caller decides that. */
    fun updateSettings(settings: tvbox.engine.core.model.EngineSettings): tvbox.engine.core.model.EngineSettings {
        applySettings(settings)
        store.saveSettings(currentSettings)
        // What an `ext` url pointed at may have been fetched the other way.
        ext.clear()
        return currentSettings
    }

    /** What the active config's `hosts` / `headers` / `doh` / `ads` and the DNS setting do to requests. */
    fun network(): tvbox.engine.core.model.NetworkInfo = network?.info() ?: tvbox.engine.core.model.NetworkInfo()

    private val playlistPrefix = proxyBase.substringBefore("/proxy") + "/m3u8?"

    /** The config's `headers` for the media host, added to what the player is told to send. */
    private fun playerHeaders(info: PlayInfo): PlayInfo {
        val net = network?.takeIf { it.hasHeaders && info.kind == "direct" } ?: return info
        return info.copy(headers = net.playerHeaders(info.url, info.headers, wrapper = playlistPrefix))
    }

    private fun playerHeaders(list: LiveList): LiveList {
        val net = network?.takeIf { it.hasHeaders } ?: return list
        return list.copy(groups = list.groups.map { g ->
            g.copy(channels = g.channels.map { c -> c.copy(urls = c.urls.map { u -> u.copy(headers = net.playerHeaders(u.url, u.headers)) }) })
        })
    }

    private fun applySettings(settings: tvbox.engine.core.model.EngineSettings) {
        val prefix = tvbox.engine.core.net.GithubProxy.normalize(settings.githubProxyPrefix).ifEmpty { tvbox.engine.core.net.GithubProxy.DEFAULT_PREFIX }
        currentSettings = settings.copy(githubProxyPrefix = prefix)
        // Which DNS answers is the user's choice as well; kept as the url the choice is compared by.
        currentSettings = currentSettings.copy(doh = network?.setDoh(settings.doh) ?: tvbox.engine.core.net.ConfigNetwork.normalizeDoh(settings.doh))
        githubProxy?.let {
            it.prefix = prefix
            it.enabled = settings.githubProxy
        }
    }

    // ---- subscriptions ----

    suspend fun subscriptions(): List<Subscription> = lock.withLock { subscriptions.values.toList() }

    suspend fun addSubscription(url: String, name: String?): Subscription {
        val trimmed = url.trim()
        if (trimmed.isEmpty()) throw EngineException.BadRequest("url is empty")
        return lock.withLock {
            subscriptions.values.firstOrNull { it.url == trimmed }?.let { return@withLock it }
            val sub = Subscription(UUID.randomUUID().toString().take(8), name?.trim()?.ifEmpty { null } ?: trimmed, trimmed)
            subscriptions[sub.id] = sub
            persistSubscriptions()
            sub
        }
    }

    suspend fun removeSubscription(id: String) {
        lock.withLock {
            subscriptions.remove(id) ?: throw EngineException.NotFound("subscription $id")
            if (active?.subscriptionId == id) network?.onConfig(null)
            if (active?.subscriptionId == id) active = null
            if (savedActiveId == id) {
                savedActiveId = null
                savedActiveRepo = null
                savedActiveRepoPath = emptyList()
            }
            repoGroups.remove(id)
            persistSubscriptions()
        }
    }

    private val restoreLock = Mutex()

    @Volatile private var restoreRuns = 0

    @Volatile private var lastRestore: Result<ConfigSummary>? = null

    /**
     * Re-activates the subscription that was active when the engine last ran. Null when there is none.
     * A call made while another restore runs waits for it and shares its result instead of loading again.
     */
    suspend fun restore(): Result<ConfigSummary>? {
        val seen = restoreRuns
        return restoreLock.withLock {
            if (restoreRuns != seen) return@withLock lastRestore
            val id = savedActiveId
            val result = if (id == null) null else runCatching { fromCopies(id, savedActiveRepo) ?: activate(id, savedActiveRepo) }
            lastRestore = result
            restoreRuns++
            result
        }
    }

    /**
     * The active config for clients. The engine starts listening before the last subscription is loaded again
     * (that takes a few seconds over the network), so this waits for that instead of answering "nothing active",
     * reports why it failed, and tries again when asked after a failure.
     */
    suspend fun config(): ConfigSummary {
        active?.let { return summary(it) }
        val restored = restore()
        active?.let { return summary(it) }
        restored?.exceptionOrNull()?.let { e ->
            throw e as? EngineException ?: EngineException.ConfigLoadFailed(e.message ?: e.toString())
        }
        throw EngineException.NoConfig()
    }

    /** Caller holds [lock]. */
    private fun persistSubscriptions() {
        store.saveSubscriptions(SubscriptionState(subscriptions.values.toList(), savedActiveId, savedActiveRepo, savedActiveRepoPath))
    }

    /**
     * Loads the subscription. A multi-repository subscription loads [repoUrl], or its first entry
     * (TVBox switches to the first entry automatically too).
     *
     * Entries can be repositories themselves. Choosing one (or meeting one as the first entry) opens it and
     * loads the first of its entries that works; its entries then show up in [ConfigSummary.repos].
     * When the choice was not the user's (no [repoUrl], or a group), a dead entry is skipped for the next one.
     */
    suspend fun activate(id: String, repoUrl: String? = null): ConfigSummary =
        kotlinx.coroutines.withContext(tvbox.engine.core.cache.LoadTrace()) { activateTraced(id, repoUrl) }

    /**
     * The config as it was last downloaded, from the kept copies: no network, so a start does not wait for the
     * subscription's server. Null when a copy is missing or no longer parses. The network is asked afterwards, in
     * the background: nothing changes when it gives the same texts, the config is replaced when they differ, and
     * the copies stay in use (with the reason in the summary) when it cannot be reached.
     */
    private suspend fun fromCopies(id: String, repoUrl: String?): ConfigSummary? {
        if (cache == null || lock.withLock { subscriptions[id] }?.let { loader.hasCopy(it.url) } != true) return null
        val summary = try {
            kotlinx.coroutines.withContext(tvbox.engine.core.cache.LoadTrace(stored = true)) { activateTraced(id, repoUrl) }
        } catch (e: EngineException) {
            return null
        }
        refreshing = true
        background.launch { refreshStored() }
        return summary.copy(refreshing = true)
    }

    private suspend fun refreshStored() {
        val a = active ?: return
        try {
            val trace = tvbox.engine.core.cache.LoadTrace()
            kotlinx.coroutines.withContext(trace) { a.trace.forEach { (url, _) -> load(url) } }
            if (active !== a) return
            if (trace.loaded.toList() == a.trace) {
                a.fetchedAt = trace.fetchedAt
                a.stored = false
            } else {
                activate(a.subscriptionId, if (a.repos.isEmpty()) null else a.url)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            a.refreshError = e.message ?: e.toString()
        } finally {
            refreshing = false
        }
    }

    /** Downloads the active config again (`POST /config/reload`). When that fails the config in use stays. */
    suspend fun reloadConfig(): ConfigSummary {
        val a = active ?: return config()
        return try {
            activate(a.subscriptionId, if (a.repos.isEmpty()) null else a.url)
        } catch (e: EngineException) {
            a.refreshError = e.message ?: e.code
            throw e
        }
    }

    fun cacheInfo(): tvbox.engine.core.cache.CacheInfo = cache?.info() ?: tvbox.engine.core.cache.CacheInfo()

    /** Empties the data cache. The active config stays loaded; its copy is written again by the next download. */
    fun clearCache(): tvbox.engine.core.cache.CacheInfo {
        cache?.clear()
        return cacheInfo()
    }

    private suspend fun activateTraced(id: String, repoUrl: String?): ConfigSummary {
        val sub = lock.withLock { subscriptions[id] } ?: throw EngineException.NotFound("subscription $id")
        val first = load(sub.url)
        val (url, repos, config) = when (val doc = first.document) {
            is ConfigDocument.Single -> Triple(sub.url, emptyList<RepoEntry>(), doc.config)
            is ConfigDocument.Repository -> {
                if (doc.entries.isEmpty()) throw EngineException.ConfigLoadFailed("repository has no entries")
                val groups = repoGroups.getOrPut(id) { java.util.concurrent.ConcurrentHashMap() }
                // After a restart the groups around the saved repo are not known yet: open them again.
                if (repoUrl != null && repoUrl == savedActiveRepo && id == savedActiveId) {
                    for (group in savedActiveRepoPath) {
                        if (group in groups) continue
                        (runCatching { load(group).document }.getOrNull() as? ConfigDocument.Repository)?.let { groups[group] = it.entries }
                    }
                }
                val known = doc.entries.any { it.url == repoUrl } || groups.values.any { list -> list.any { it.url == repoUrl } }
                if (repoUrl != null && !known) throw EngineException.NotFound("repo $repoUrl")
                val (leaf, leafConfig) = if (repoUrl != null) {
                    openRepo(repoUrl, groups, HashSet(), MAX_REPO_DEPTH)
                } else {
                    openFirst(doc.entries, groups, HashSet(), MAX_REPO_DEPTH)
                }
                Triple(leaf, doc.entries, leafConfig)
            }
        }
        ext.clear()
        val trace = kotlin.coroutines.coroutineContext[tvbox.engine.core.cache.LoadTrace]
        val loaded = Active(
            id, url, repos, config, config.sites.associate { it.key to createSource(it, config) },
            trace = trace?.loaded?.toList().orEmpty(), fetchedAt = trace?.fetchedAt ?: 0, stored = trace?.stored == true,
        )
        lock.withLock {
            // Spiders of the previous config are released before the new ones take over.
            active?.sources?.values?.forEach { (it as? SpiderSource)?.destroy() }
            liveSpiders.values.forEach { runCatching { it.destroy() } }
            liveSpiders.clear()
            runtimes.forEach { it.onConfig(config) }
            network?.onConfig(config)
            live.onConfig(config.livesJson)
            active = loaded
            savedActiveId = id
            savedActiveRepo = if (repos.isEmpty()) null else url
            savedActiveRepoPath = repoInfos(loaded).let { all ->
                generateSequence(all.firstOrNull { it.url == url }?.parent?.ifEmpty { null }) { p ->
                    all.firstOrNull { it.url == p }?.parent?.ifEmpty { null }
                }.toList().reversed()
            }
            persistSubscriptions()
        }
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

    /** A site's `categories` (TVBox) keeps only those classes, in that order. */
    suspend fun home(site: String, refresh: Boolean = false): HomeResult =
        kept(site, "home", refresh, HOME_LIFETIME, HomeResult.serializer(), { it.classes.isNotEmpty() || it.list.isNotEmpty() }) { homeNow(site) }

    /**
     * A site answer through the data cache: served from it while young, served stale while a fresh one is fetched,
     * fetched now with [refresh]. The scope in the key keeps configs apart, the site keeps sites apart.
     */
    private suspend fun <T> kept(
        site: String, what: String, refresh: Boolean, lifetimeMs: Long,
        serializer: kotlinx.serialization.KSerializer<T>, worthKeeping: (T) -> Boolean, fetch: suspend () -> T,
    ): T {
        val data = siteData ?: return fetch()
        val a = current()
        if (site !in a.sources) throw EngineException.NotFound("site $site")
        return data.get(a.scope + "|" + site + "|" + what, lifetimeMs, refresh, serializer, worthKeeping, fetch)
    }

    private suspend fun homeNow(site: String): HomeResult = siteCall(site) { src ->
        val home = src.home()
        val wanted = src.bean.categories
        if (wanted.isEmpty()) home else home.copy(classes = wanted.mapNotNull { name -> home.classes.firstOrNull { it.name == name } })
    }

    /**
     * An HLS playlist for the player, cleaned of ads with the active config's rules. Variants of a master playlist
     * point back here through [selfBase] (`http://<engine>/m3u8?`).
     */
    suspend fun playlist(url: String, headers: Map<String, String>, selfBase: String): String {
        val (text, finalUrl) = http.getWithUrl(url, headers)
        if (!text.removePrefix("\uFEFF").trimStart().startsWith("#EXTM3U")) throw EngineException.BadRequest("not an HLS playlist")
        if (M3u8Cleaner.isMaster(text)) return M3u8Cleaner.rewriteMaster(text, finalUrl) { PlayResolver.playlistUrl(selfBase, it, headers) }
        val rules = active?.config?.let { playResolver.rules(it) } ?: PlayRules.NONE
        val ads = (rules.adsFor(url) + rules.adsFor(finalUrl)).distinct()
        return M3u8Cleaner.clean(text, finalUrl, ads, heuristic = true).text
    }

    // ---- live TV ----

    fun liveSources(): List<LiveSourceInfo> {
        current()
        return live.sources()
    }

    suspend fun liveList(index: Int, refresh: Boolean = false): LiveList = liveCall { playerHeaders(liveKept(index, refresh)) }

    /** The list from the source; when that fails, the list as it was last received. */
    private suspend fun liveKept(index: Int, refresh: Boolean): LiveList {
        val data = siteData ?: return live.list(index, refresh)
        return data.orStored(tvbox.engine.core.cache.DataCache.LIVE, current().scope + "|" + index, LiveList.serializer()) { live.list(index, refresh) }
    }

    suspend fun epg(index: Int, channel: String, date: String): EpgDay = liveCall { live.epg(index, channel, date) }

    private suspend fun <T> liveCall(block: suspend () -> T): T {
        current()
        return try {
            block()
        } catch (e: LiveException) {
            throw when (e.code) {
                "NOT_FOUND" -> EngineException.NotFound(e.message ?: "")
                "BAD_REQUEST" -> EngineException.BadRequest(e.message ?: "")
                "UNSUPPORTED" -> EngineException.Unsupported(e.message ?: "")
                else -> EngineException.SiteFailed("LIVE_FAILED", e.message ?: "")
            }
        } catch (e: EngineException) {
            throw e
        } catch (e: Exception) {
            val (code, message) = describe(e)
            throw EngineException.SiteFailed(code, message)
        }
    }

    suspend fun category(site: String, classId: String, page: Int, filters: Map<String, String>, refresh: Boolean = false): VodPage =
        kept(site, "category|$classId|${page.coerceAtLeast(1)}|${filters.toSortedMap()}", refresh, CATEGORY_LIFETIME, VodPage.serializer(), { it.list.isNotEmpty() }) {
            siteCall(site) { it.category(classId, page.coerceAtLeast(1), filters) }
        }

    suspend fun detail(site: String, id: String, refresh: Boolean = false): VodDetail =
        kept(site, "detail|$id", refresh, DETAIL_LIFETIME, VodDetail.serializer(), { it.lines.isNotEmpty() }) { siteCall(site) { it.detail(id) } }

    suspend fun search(site: String, keyword: String, page: Int): VodPage =
        siteCall(site) { it.search(keyword, quick = false, page = page.coerceAtLeast(1)) }

    /** Streams results from every searchable, supported site (or only [siteKeys] when given). */
    fun searchAll(keyword: String, siteKeys: Set<String>? = null): Flow<SearchEvent> {
        if (keyword.isBlank()) throw EngineException.BadRequest("keyword is empty")
        val sources = current().sources.values.filter { src ->
            val bean = src.bean
            bean.isSearchable && src !is UnsupportedSource && (siteKeys == null || bean.key in siteKeys)
        }
        return searchAggregator.search(sources, keyword.trim()) { describe(it) }
    }

    suspend fun resolvePlay(request: PlayRequest): PlayInfo {
        val a = current()
        val raw = siteCall(request.site) { it.play(request.line, request.episodeId) }
        return try {
            playerHeaders(playResolver.resolve(raw, a.config))
        } catch (e: PlayResolveException) {
            throw EngineException.SiteFailed("PLAY_FAILED", e.message ?: "play failed")
        } catch (e: Exception) {
            val (code, message) = describe(e)
            throw EngineException.SiteFailed(code, message)
        }
    }

    /**
     * `/proxy?do=...` (TVBox 9978 compatibility): asks each spider runtime in turn; `do=js` goes to the JS runtime
     * first. Null when nobody handles it.
     */
    suspend fun proxy(params: Map<String, String>): ProxyResponse? {
        val ordered = if (params["do"] == "js") runtimes.sortedByDescending { it.kind == "js" } else runtimes.sortedBy { it.kind == "js" }
        for (runtime in ordered) {
            val response = try {
                runtime.proxy(params)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
            if (response != null) return response
        }
        return null
    }

    // ---- internals ----

    private fun current(): Active = active ?: throw EngineException.NoConfig()

    private fun createSource(bean: tvbox.engine.core.config.SiteBean, config: TvboxConfig): SiteSource = when (bean.runtime) {
        SiteRuntime.CMS -> CmsSource(bean, http, ext)
        SiteRuntime.REMOTE -> RemoteSource(bean, http, ext)
        else -> runtimes.firstOrNull { it.supports(bean) }
            ?.let { SpiderSource(bean, it, ext, vipFlags = { config.flags }) }
            ?: UnsupportedSource(bean)
    }

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
        } catch (e: LinkageError) {
            // A jar spider that needs a class or method this platform does not have.
            throw EngineException.SiteFailed("SPIDER_INCOMPATIBLE", e.javaClass.simpleName + ": " + (e.message ?: ""))
        }
    }

    /** Maps failures to (code, message) for API errors and search events. */
    private fun describe(e: Throwable): Pair<String, String> = when (e) {
        is TimeoutCancellationException -> "SITE_TIMEOUT" to "site did not answer in time"
        is SiteHttpException -> (if (e.message?.startsWith("timeout") == true) "SITE_TIMEOUT" else "SITE_UNREACHABLE") to (e.message ?: "network error")
        is SiteResultException -> "SITE_BAD_RESULT" to (e.message ?: "unexpected data")
        is UnsupportedSiteException -> "UNSUPPORTED_SITE" to (e.message ?: "unsupported")
        is SpiderLoadException -> "SPIDER_LOAD_FAILED" to (e.message ?: "spider failed to load")
        else -> "SITE_ERROR" to (e.message ?: e.javaClass.simpleName)
    }

    private suspend fun load(url: String): ConfigLoader.Result = try {
        val trace = kotlin.coroutines.coroutineContext[tvbox.engine.core.cache.LoadTrace]
        loader.load(url, stored = trace?.stored == true).also { trace?.add(url, it.text, it.fetchedAt) }
    } catch (e: ConfigLoader.LoadException) {
        throw EngineException.ConfigLoadFailed(e.message ?: "load failed")
    }

    /**
     * Loads [url]; when it is a repository, remembers its entries in [groups] and loads the first that works.
     * [visited] stops repositories that list each other.
     */
    private suspend fun openRepo(
        url: String,
        groups: MutableMap<String, List<RepoEntry>>,
        visited: MutableSet<String>,
        depthLeft: Int,
    ): Pair<String, TvboxConfig> {
        if (!visited.add(url)) throw EngineException.ConfigLoadFailed("repository lists itself: $url")
        return when (val doc = load(url).document) {
            is ConfigDocument.Single -> url to doc.config
            is ConfigDocument.Repository -> {
                groups[url] = doc.entries
                if (depthLeft <= 0) throw EngineException.ConfigLoadFailed("repositories nested too deep at $url")
                if (doc.entries.isEmpty()) throw EngineException.ConfigLoadFailed("repository has no entries: $url")
                openFirst(doc.entries, groups, visited, depthLeft - 1)
            }
        }
    }

    /** The first of [entries] that loads; the first failure is reported when none of the first few does. */
    private suspend fun openFirst(
        entries: List<RepoEntry>,
        groups: MutableMap<String, List<RepoEntry>>,
        visited: MutableSet<String>,
        depthLeft: Int,
    ): Pair<String, TvboxConfig> {
        var failure: EngineException? = null
        for (entry in entries.take(MAX_REPO_TRIES)) {
            try {
                return openRepo(entry.url, groups, visited, depthLeft)
            } catch (e: EngineException) {
                if (failure == null) failure = e
            }
        }
        throw failure ?: EngineException.ConfigLoadFailed("repository has no entries")
    }

    /** The repository entries as a flat list for the picker: each opened group is followed by its entries. */
    private fun repoInfos(a: Active): List<RepoInfo> {
        if (a.repos.isEmpty()) return emptyList()
        val groups = repoGroups[a.subscriptionId].orEmpty()
        val out = ArrayList<RepoInfo>()
        val seen = HashSet<String>()
        fun emit(entries: List<RepoEntry>, parent: String, depth: Int) {
            for (entry in entries) {
                if (!seen.add(entry.url)) continue
                val children = groups[entry.url]
                out += RepoInfo(entry.name, entry.url, parent = parent, group = children != null, depth = depth)
                if (children != null) emit(children, entry.url, depth + 1)
            }
        }
        emit(a.repos, "", 0)
        return out
    }

    private fun summary(a: Active): ConfigSummary = ConfigSummary(
        subscriptionId = a.subscriptionId,
        url = a.url,
        fetchedUrl = githubProxy?.route(a.url) ?: a.url,
        repos = repoInfos(a),
        sites = a.config.sites.size,
        parses = a.config.parses.size,
        lives = countJsonArray(a.config.livesJson),
        spider = a.config.spider,
        wallpaper = a.config.wallpaper,
        fetchedAt = a.fetchedAt,
        stored = a.stored,
        refreshing = refreshing && a.stored,
        refreshError = a.refreshError,
    )

    private fun countJsonArray(json: String): Int =
        if (json.isBlank()) 0 else runCatching { com.google.gson.JsonParser.parseString(json).asJsonArray.size() }.getOrDefault(0)

    private companion object {
        /** How many repositories may be nested inside the subscription. */
        const val MAX_REPO_DEPTH = 3

        /** How many entries are tried when the choice of entry is the engine's. */
        const val MAX_REPO_TRIES = 6

        /** How long a kept site answer is served without asking the site again; older ones are served while a new one is fetched. */
        const val HOME_LIFETIME = 15 * 60_000L
        const val CATEGORY_LIFETIME = 15 * 60_000L
        const val DETAIL_LIFETIME = 60 * 60_000L
    }
}

/** Placeholder for js/jar/py sites until their runtimes land. */
private class UnsupportedSource(override val bean: tvbox.engine.core.config.SiteBean) : SiteSource {
    override suspend fun home() = throw UnsupportedSiteException(bean)
    override suspend fun category(classId: String, page: Int, filters: Map<String, String>) = throw UnsupportedSiteException(bean)
    override suspend fun detail(id: String) = throw UnsupportedSiteException(bean)
    override suspend fun search(keyword: String, quick: Boolean, page: Int) = throw UnsupportedSiteException(bean)
    override suspend fun play(line: String, episodeId: String) = throw UnsupportedSiteException(bean)
}
