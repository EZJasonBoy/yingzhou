package tvbox.engine.core.net

import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import tvbox.engine.core.EngineException
import tvbox.engine.core.model.EngineSettings
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.CopyOnWriteArraySet

class NetworkProxy {
    private data class Policy(val endpoint: String, val scopes: Set<String>, val proxy: Proxy?)

    @Volatile private var policy = Policy("", emptySet(), null)
    private val pools = CopyOnWriteArraySet<ConnectionPool>()

    fun apply(settings: EngineSettings): EngineSettings {
        val endpoint = normalize(settings.httpProxy)
        val scopes = settings.proxyScopes.distinct().filter { it in purposes }
        val next = Policy(endpoint, scopes.toSet(), endpoint.takeIf { it.isNotEmpty() }?.let {
            val uri = URI("http://$it")
            Proxy(Proxy.Type.HTTP, InetSocketAddress.createUnresolved(uri.host.removeSurrounding("[", "]"), uri.port))
        })
        if (next != policy) {
            policy = next
            pools.forEach { it.evictAll() }
        }
        return settings.copy(httpProxy = endpoint, proxyScopes = scopes)
    }

    fun endpoint(scope: String): String = policy.let { if (scope in it.scopes) it.endpoint else "" }

    fun client(base: OkHttpClient, scope: String): OkHttpClient {
        require(scope in purposes)
        pools += base.connectionPool
        val system = base.proxySelector
        val selector = object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                if (isLocal(uri.host.orEmpty())) return listOf(Proxy.NO_PROXY)
                val active = policy
                if (scope in active.scopes && active.proxy != null) return listOf(active.proxy)
                return base.proxy?.let { listOf(it) } ?: system.select(uri)
            }

            override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) {
                if (endpoint(scope).isEmpty()) system.connectFailed(uri, address, error)
            }
        }
        return base.newBuilder().proxy(null).proxySelector(selector).build()
    }

    companion object {
        const val MODULES = "modules"
        const val CONFIG = "config"
        const val PLAYBACK = "playback"
        val browserBypass = listOf("<local>", "*.localhost", "*.local", "*.lan", "*.internal", "*.home", "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "[::1]", "fc00::/7", "fe80::/10")
        private val purposes = setOf(MODULES, CONFIG, PLAYBACK)

        private fun normalize(value: String): String {
            val text = value.trim()
            if (text.isEmpty()) return ""
            val uri = runCatching { URI(if (text.contains("://")) text else "http://$text") }.getOrNull()
            if (uri == null || !uri.scheme.equals("http", true) || uri.host == null || uri.port !in 1..65535 ||
                uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null || uri.rawPath !in listOf("", "/")) {
                throw EngineException.BadRequest("HTTP 代理请填写主机和端口，例如 127.0.0.1:7890")
            }
            return "${uri.host.lowercase()}:${uri.port}"
        }

        fun isLocal(host: String): Boolean {
            val name = host.removeSurrounding("[", "]").lowercase().trimEnd('.')
            if (name.isEmpty() || name.substringAfterLast('.') in setOf("localhost", "local", "lan", "internal", "home")) return true
            if (':' in name || name.matches(Regex("[0-9.]+"))) {
                val address = runCatching { InetAddress.getByName(name) }.getOrNull() ?: return false
                return address.isAnyLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress || address.isSiteLocalAddress ||
                    address.address.size == 16 && (address.address[0].toInt() and 0xfe) == 0xfc
            }
            return '.' !in name
        }
    }
}
