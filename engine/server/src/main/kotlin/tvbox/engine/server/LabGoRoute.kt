package tvbox.engine.server

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

internal fun labGoRoute(source: String?, port: String?): ((String) -> String?)? {
    if (source.isNullOrBlank()) return null
    val origin = requireNotNull(subscriptionUrl(source)) { "YINGZHOU_LAB_GO_SOURCE requires an HTTP(S) URL without userinfo" }
    val portNumber = (port ?: "9980").trim().toIntOrNull()
    require(portNumber != null && portNumber in 1..65535) { "YINGZHOU_LAB_GO_PORT must be between 1 and 65535" }
    val endpoint = "http://127.0.0.1:$portNumber/config.json"
    return { input -> if (subscriptionUrl(input) == origin) endpoint else null }
}

private fun subscriptionUrl(input: String): HttpUrl? {
    val address = input.trim()
    val authority = address.substringAfter("://", "").takeWhile { it != '/' && it != '?' && it != '#' }
    if (authority.isEmpty() || '@' in authority) return null
    return address.toHttpUrlOrNull()
}
