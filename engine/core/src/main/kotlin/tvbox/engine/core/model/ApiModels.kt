package tvbox.engine.core.model

import kotlinx.serialization.Serializable

// Wire types of protocol v1 (docs/protocol.md). Keep field names stable; add, don't rename.

const val PROTOCOL_VERSION = 1

@Serializable
data class Capabilities(
    val jar: Boolean,
    val js: Boolean,
    val py: Boolean,
    val sniff: Boolean,
)

@Serializable
data class EngineInfo(
    val name: String,
    val version: String,
    val protocol: Int = PROTOCOL_VERSION,
    val platform: String,
    val capabilities: Capabilities,
)

@Serializable
data class Subscription(
    val id: String,
    val name: String,
    val url: String,
)

@Serializable
data class AddSubscriptionRequest(
    val url: String,
    val name: String? = null,
)

@Serializable
data class ActivateRequest(
    /** For multi-repository subscriptions: the url of the repo entry to use. Defaults to the first one. */
    val repo: String? = null,
)

@Serializable
data class RepoInfo(
    val name: String,
    val url: String,
    /** Url of the entry this one was listed by; empty at the top level. */
    val parent: String = "",
    /** True once the entry turned out to be a list of configs itself (its entries follow it). */
    val group: Boolean = false,
    /** 0 at the top level; for indenting. */
    val depth: Int = 0,
)

/** Engine-wide settings a client can change (`/api/v1/settings`). Kept with the engine's data. */
@Serializable
data class EngineSettings(
    /**
     * False (default): files on GitHub are fetched from GitHub, and a proxy a subscription put in front of such
     * an address is taken off. True: they are fetched through [githubProxyPrefix], falling back to GitHub.
     */
    val githubProxy: Boolean = false,
    /** E.g. `https://ghfast.top/`; the GitHub address is appended to it. */
    val githubProxyPrefix: String = tvbox.engine.core.net.GithubProxy.DEFAULT_PREFIX,
)

@Serializable
data class ConfigSummary(
    val subscriptionId: String,
    /** The config actually loaded (for a repository, the chosen entry's url), as the subscription wrote it. */
    val url: String,
    /** Where [url] is really fetched from, when the GitHub proxy setting changes that; otherwise equal to [url]. */
    val fetchedUrl: String = "",
    /**
     * Entries of a multi-repository subscription; empty for a plain config. An entry can be a list itself
     * ("多仓" inside "多仓"): activating it marks it as a group, lists its entries after it and loads the first
     * of them that works.
     */
    val repos: List<RepoInfo> = emptyList(),
    val sites: Int,
    val parses: Int,
    val lives: Int,
    val spider: String,
    val wallpaper: String,
)

@Serializable
data class SiteInfo(
    val key: String,
    val name: String,
    val type: Int,
    val searchable: Boolean,
    val quickSearch: Boolean,
    val filterable: Boolean,
    /** cms | js | jar | py | remote | unknown */
    val runtime: String,
)

@Serializable
data class ApiError(
    val code: String,
    val message: String,
)

@Serializable
data class ErrorBody(
    val error: ApiError,
)
