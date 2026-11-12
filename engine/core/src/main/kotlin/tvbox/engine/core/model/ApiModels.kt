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
)

@Serializable
data class ConfigSummary(
    val subscriptionId: String,
    /** The config actually loaded (for a repository, the chosen entry's url). */
    val url: String,
    /** Entries of a multi-repository subscription; empty for a plain config. */
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
