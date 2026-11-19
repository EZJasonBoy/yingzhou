package tvbox.engine.core.model

import kotlinx.serialization.Serializable

// What the active config and the user's settings do to the engine's network requests (`/api/v1/network`).

/** A DNS-over-HTTPS server the user can choose ([EngineSettings.doh] holds the [url] of the chosen one). */
@Serializable
data class DohOption(
    val name: String,
    val url: String,
    /** Addresses of the server itself, so that finding it does not depend on the DNS it replaces. */
    val ips: List<String> = emptyList(),
    /** `builtin`: offered by the engine; `config`: listed by the active config's `doh`; `saved`: chosen earlier, no longer offered. */
    val source: String = "builtin",
)

@Serializable
data class NetworkInfo(
    /** The chosen DoH server's url; empty when the system's DNS is used. */
    val doh: String = "",
    val dohOptions: List<DohOption> = emptyList(),
    /** Empty until a name was looked up through the chosen server; then `ok`, or `failed: <reason>` (the system's DNS answered instead). */
    val dohStatus: String = "",
    /** The active config's `hosts`: name (may contain `*`) -> the name or address it is resolved as. */
    val hosts: Map<String, String> = emptyMap(),
    /** The hosts the active config's `headers` add request headers for. */
    val headerHosts: List<String> = emptyList(),
    /** The active config's `ads`: hosts blocked while sniffing. */
    val ads: List<String> = emptyList(),
)
