package tvbox.engine.core.config

import tvbox.engine.core.util.UriUtil

/**
 * A subscription address as the user typed it, resolved to something fetchable.
 *
 * @property input the original text, e.g. `a.com/tv;pk;secret`, `clan://localhost/tv/a.json`, `file:///sdcard/a.json`
 * @property fetchUrl the http(s) URL to download
 * @property key the `;pk;` AES key, if any
 * @property isClan whether the address pointed at a TVBox `clan://` / `file://` location
 */
data class ConfigLocation(
    val input: String,
    val fetchUrl: String,
    val key: String?,
    val isClan: Boolean,
)

/**
 * Port of TVBox's subscription-address handling (`ApiConfig.configUrl`, `clanToAddress`, `clanContentFix`,
 * `fixContentPath`).
 *
 * @param localFileBase where `clan://localhost/` points, ending with `/file/`, e.g. `http://127.0.0.1:9978/file/`.
 *   On Android TVBox this is its own built-in file server; here it is the engine's `/file/` route.
 */
class ConfigLocator(private val localFileBase: String) {

    fun locate(input: String): ConfigLocation {
        val normalized = input.trim().replace("file://", CLAN_LOCAL)
        val pkIndex = normalized.indexOf(PK)
        val address = if (pkIndex >= 0) normalized.substring(0, pkIndex) else normalized
        // Unlike the original (which crashes), a trailing ";pk;" with no key just means "no key".
        val key = if (pkIndex >= 0) normalized.substring(pkIndex + PK.length).ifEmpty { null } else null
        val isClan = address.startsWith("clan")
        val fetchUrl = when {
            isClan -> clanToAddress(address)
            address.startsWith("http") -> address
            else -> "http://$address"
        }
        return ConfigLocation(input, fetchUrl, key, isClan)
    }

    fun clanToAddress(clan: String): String =
        if (clan.startsWith(CLAN_LOCAL)) {
            clan.replace(CLAN_LOCAL, localFileBase)
        } else {
            val link = clan.substring("clan://".length)
            val end = link.indexOf('/')
            if (end < 0) "http://$link/file/" else "http://" + link.substring(0, end) + "/file/" + link.substring(end + 1)
        }

    /** Rewrites `clan://localhost/`, `file://` and `./`, `../` references inside downloaded config text. */
    fun fixContent(location: ConfigLocation, content: String): String {
        var result = content
        if (location.isClan) {
            val base = location.fetchUrl.substring(0, location.fetchUrl.indexOf("/file/") + "/file/".length)
            result = result.replace(CLAN_LOCAL, base).replace("file://", base)
        }
        if (result.contains("\"./") || result.contains("\"../")) {
            // Matches TVBox: every occurrence is replaced, not only the quoted ones.
            result = result.replace("../", UriUtil.resolve(location.fetchUrl, "../"))
            result = result.replace("./", UriUtil.resolve(location.fetchUrl, "./"))
        }
        return result
    }

    private companion object {
        const val PK = ";pk;"
        const val CLAN_LOCAL = "clan://localhost/"
    }
}
