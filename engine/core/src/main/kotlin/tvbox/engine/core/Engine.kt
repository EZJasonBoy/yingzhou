package tvbox.engine.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import tvbox.engine.core.config.ConfigDocument
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.model.ConfigSummary
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.model.RepoInfo
import tvbox.engine.core.model.SiteInfo
import tvbox.engine.core.model.Subscription
import java.util.UUID

/** Errors the API layer maps to HTTP status codes. */
sealed class EngineException(val code: String, message: String) : Exception(message) {
    class NotFound(message: String) : EngineException("NOT_FOUND", message)
    class BadRequest(message: String) : EngineException("BAD_REQUEST", message)
    class NoConfig : EngineException("NO_CONFIG", "no subscription is active")
    class ConfigLoadFailed(message: String) : EngineException("CONFIG_LOAD_FAILED", message)
}

/**
 * Engine state: subscriptions and the active config.
 * Subscriptions are in memory for now; persistence comes with the storage layer.
 */
class Engine(
    val info: EngineInfo,
    private val loader: ConfigLoader,
) {
    private class Active(
        val subscriptionId: String,
        val url: String,
        val repos: List<RepoInfo>,
        val config: TvboxConfig,
    )

    private val lock = Mutex()
    private val subscriptions = LinkedHashMap<String, Subscription>()

    @Volatile
    private var active: Active? = null

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
        val loaded = when (val doc = first.document) {
            is ConfigDocument.Single -> Active(id, sub.url, emptyList(), doc.config)
            is ConfigDocument.Repository -> {
                val repos = doc.entries.map { RepoInfo(it.name, it.url) }
                val chosen = repoUrl?.let { url -> repos.firstOrNull { it.url == url } ?: throw EngineException.NotFound("repo $url") }
                    ?: repos.firstOrNull()
                    ?: throw EngineException.ConfigLoadFailed("repository has no entries")
                when (val inner = load(chosen.url).document) {
                    is ConfigDocument.Single -> Active(id, chosen.url, repos, inner.config)
                    is ConfigDocument.Repository -> throw EngineException.ConfigLoadFailed("nested repository at ${chosen.url}")
                }
            }
        }
        active = loaded
        return summary(loaded)
    }

    fun summary(): ConfigSummary = summary(active ?: throw EngineException.NoConfig())

    fun sites(): List<SiteInfo> {
        val config = (active ?: throw EngineException.NoConfig()).config
        return config.sites.map {
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
