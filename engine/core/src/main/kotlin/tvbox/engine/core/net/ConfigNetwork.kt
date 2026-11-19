package tvbox.engine.core.net

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import okhttp3.ConnectionPool
import okhttp3.Dns
import okhttp3.Headers
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.dnsoverhttps.DnsOverHttps
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.model.DohOption
import tvbox.engine.core.model.NetworkInfo
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * The network items of the active TVBox config, and the user's choice of DNS:
 *
 * - `hosts` (`"name=target"`): `name` is resolved as `target`, which is another name or an address. One step, as in
 *   TVBoxOS `OkGoHelper.CustomDns`; a `*` in the name stands for any run of characters, as in the forks the item
 *   comes from (FongMi/TV writes `cache.ott.*.itv.cmvideo.cn=...`).
 * - `headers` (`[{"host", "header": {...}}]`): headers set on every request to that host, replacing what the
 *   request carried under the same name; [headersFor] gives the same headers for what a player fetches itself.
 * - `doh` (`[{"name", "url", "ips"}]`): DNS-over-HTTPS servers the config offers on top of the built-in ones.
 *   Whether one is used, and which, is the user's setting ([setDoh]) and never the config's: off means the
 *   system's DNS. A name the chosen server cannot answer is asked of the system's DNS, as TVBox does.
 * - `ads`: hosts whose requests are blocked while sniffing (TVBoxOS `AdBlocker`).
 *
 * [install] puts all of it on the engine's HTTP client, so every client derived from that one (site requests,
 * spiders' host classes, playlists, programme guides, parsers) follows the active config. [onConfig] is called
 * when a config becomes active; connections opened under the previous rules are dropped.
 *
 * Addresses and `localhost` are never redirected: the engine talks to itself over 127.0.0.1.
 */
class ConfigNetwork(
    /** Resolves names nothing else answers for; tests put their own here. */
    private val system: Dns = Dns.SYSTEM,
    /**
     * Sends the DoH queries. Unlike the engine's other requests these check the server's certificate: a resolver
     * that anybody on the path can impersonate would be no use.
     */
    dohHttp: OkHttpClient? = null,
    private val log: (String) -> Unit = {},
) {
    /** Values by host name: exact names first, then the patterns (names with `*`) in the order they were written. */
    private class HostRules<T : Any>(val entries: List<Pair<String, T>>) {
        private val exact = HashMap<String, T>()
        private val patterns = ArrayList<Pair<Regex, T>>()

        init {
            for ((name, value) in entries) {
                if ('*' in name) patterns += Regex(name.split('*').joinToString(".*") { Regex.escape(it) }) to value else exact[name] = value
            }
        }

        val isEmpty get() = entries.isEmpty()

        fun find(host: String): T? = exact[host] ?: patterns.firstOrNull { it.first.matches(host) }?.second
    }

    private class State(val hosts: HostRules<String>, val headers: HostRules<Headers>, val doh: List<DohOption>, val ads: List<String>)

    /** The chosen DoH server with what it answered lately. */
    private class Resolver(val option: DohOption, val dns: Dns) {
        val answers = ConcurrentHashMap<String, Pair<Long, List<InetAddress>>>()

        /** "", "ok" or "failed: <reason>". */
        @Volatile var status = ""

        /** After a failure the server is left alone until then, so that a dead one costs one timeout, not one per request. */
        @Volatile var retryAt = 0L
    }

    private val dohHttp: OkHttpClient by lazy {
        dohHttp ?: OkHttpClient.Builder().connectTimeout(4, TimeUnit.SECONDS).readTimeout(4, TimeUnit.SECONDS).callTimeout(6, TimeUnit.SECONDS).build()
    }

    /** Shared by every client built with [install], so that a change of rules can drop the connections made before it. */
    private val pool = ConnectionPool()

    @Volatile private var state = EMPTY
    @Volatile private var dohUrl = ""
    @Volatile private var resolver: Resolver? = null

    val dns: Dns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> = resolve(hostname)

        override fun toString() = "ConfigNetwork.dns"
    }

    /** Adds the config's `headers` to matching requests. A network interceptor: redirects are covered too. */
    val headers: Interceptor = object : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            val extra = state.headers.takeUnless { it.isEmpty }?.find(request.url.host) ?: return chain.proceed(request)
            val builder = request.newBuilder()
            for (i in 0 until extra.size) builder.header(extra.name(i), extra.value(i))
            return chain.proceed(builder.build())
        }
    }

    fun install(builder: OkHttpClient.Builder): OkHttpClient.Builder = builder.dns(dns).addNetworkInterceptor(headers).connectionPool(pool)

    /** The config that became active, or null when none is. */
    @Synchronized
    fun onConfig(config: TvboxConfig?) {
        state = if (config == null) EMPTY else parse(config)
        // The chosen server may have gained or lost the addresses a config gives for it.
        chooseResolver()
        pool.evictAll()
    }

    /** The user's DoH server: its url, or blank for the system's DNS. Returns the url as it is kept. */
    @Synchronized
    fun setDoh(url: String): String {
        val normalized = normalizeDoh(url)
        if (normalized != dohUrl) {
            dohUrl = normalized
            chooseResolver()
            pool.evictAll()
        }
        return normalized
    }

    /** Caller holds the lock. */
    private fun chooseResolver() {
        val option = dohUrl.takeIf { it.isNotEmpty() }?.let { url -> dohOptions().firstOrNull { it.url == url } }
        if (option == resolver?.option) return
        resolver = option?.let { o ->
            val url = o.url.toHttpUrlOrNull() ?: return@let null
            val dns = DnsOverHttps.Builder().client(dohHttp).url(url)
                .bootstrapDnsHosts(o.ips.mapNotNull(::literal).ifEmpty { null })
                .systemDns(system)
                // Which names go to the server is decided in resolve(); this only stops the library refusing some.
                .resolvePrivateAddresses(true)
                .build()
            Resolver(o, dns)
        }
    }

    /** The servers to choose from: the built-in ones, the active config's, and the chosen one if neither lists it. */
    fun dohOptions(): List<DohOption> {
        val out = LinkedHashMap<String, DohOption>()
        BUILTIN_DOH.forEach { out[it.url] = it }
        for (o in state.doh) {
            val known = out[o.url]
            out[o.url] = if (known == null) o else known.copy(ips = known.ips.ifEmpty { o.ips })
        }
        val chosen = dohUrl
        if (chosen.isNotEmpty() && chosen !in out) {
            out[chosen] = DohOption(name = chosen.toHttpUrlOrNull()?.host ?: chosen, url = chosen, source = "saved")
        }
        return out.values.toList()
    }

    fun info(): NetworkInfo {
        val s = state
        return NetworkInfo(
            doh = dohUrl,
            dohOptions = dohOptions(),
            dohStatus = resolver?.status.orEmpty(),
            hosts = s.hosts.entries.toMap(),
            headerHosts = s.headers.entries.map { it.first },
            ads = s.ads,
        )
    }

    /** `hosts` as checked and lower-cased, name (maybe with `*`) to target; for runtimes outside the JVM (Python). */
    fun hostRules(): Map<String, String> = state.hosts.entries.toMap()

    /** `headers` by host name (maybe with `*`); for runtimes outside the JVM (Python). */
    fun headerRules(): Map<String, Map<String, String>> = state.headers.entries.associate { (host, headers) -> host to headers.toMap() }

    /** Whether the active config names headers for any host. */
    val hasHeaders: Boolean get() = !state.headers.isEmpty

    /** The config's headers for [url]'s host; empty when it has none. */
    fun headersFor(url: String): Map<String, String> {
        val rules = state.headers
        if (rules.isEmpty) return emptyMap()
        val host = url.toHttpUrlOrNull()?.host ?: return emptyMap()
        return rules.find(host)?.toMap().orEmpty()
    }

    /**
     * [headers] as a player should send them to [url]: the config's headers for that host replace same-named ones.
     * A url that starts with [wrapper] (the engine's playlist endpoint, `http://<engine>/m3u8?`) stands for the
     * media url in its `url` parameter.
     */
    fun playerHeaders(url: String, headers: Map<String, String>, wrapper: String? = null): Map<String, String> {
        val media = if (wrapper != null && url.startsWith(wrapper)) url.toHttpUrlOrNull()?.queryParameter("url") ?: url else url
        val extra = headersFor(media)
        if (extra.isEmpty()) return headers
        val out = LinkedHashMap<String, String>()
        headers.forEach { (k, v) -> if (extra.keys.none { it.equals(k, ignoreCase = true) }) out[k] = v }
        out.putAll(extra)
        return out
    }

    /** `hosts` as Chromium's `--host-resolver-rules`; empty when the config has none. */
    fun hostResolverRules(): String =
        state.hosts.entries.joinToString(", ") { (name, target) -> "MAP $name " + if (':' in target) "[$target]" else target }

    /** TVBoxOS `AdBlocker.isAd`: the url contains one of the config's ad hosts. */
    fun isAd(url: String): Boolean {
        val ads = state.ads
        if (ads.isEmpty()) return false
        val lower = url.lowercase()
        return ads.any { it in lower }
    }

    val ads: List<String> get() = state.ads

    private fun resolve(hostname: String): List<InetAddress> {
        val asked = hostname.lowercase()
        literal(asked)?.let { return listOf(it) }
        if (asked == "localhost" || asked.endsWith(".localhost")) return system.lookup(hostname)
        val name = state.hosts.find(asked) ?: asked
        // TVBox: a target that is an address is the answer.
        literal(name)?.let { return listOf(it) }
        val doh = resolver
        if (doh != null && isPublicName(name)) viaDoh(doh, name)?.let { return it }
        return system.lookup(name)
    }

    /** Null when the server did not give an answer (it is down, or does not know the name): the system's DNS is next. */
    private fun viaDoh(doh: Resolver, name: String): List<InetAddress>? {
        val now = System.currentTimeMillis()
        doh.answers[name]?.takeIf { now - it.first < DOH_TTL_MS }?.let { return it.second }
        if (now < doh.retryAt) return null
        return try {
            // IPv4 first: an AAAA answer on a network without IPv6 would cost a failed connection attempt.
            val found = doh.dns.lookup(name).sortedBy { it is Inet6Address }
            if (found.isEmpty()) return null
            if (doh.answers.size >= DOH_CACHE_SIZE) doh.answers.clear()
            doh.answers[name] = now to found
            report(doh, "ok")
            found
        } catch (e: UnknownHostException) {
            // With a cause the query itself failed; without one the server answered that there is no such name.
            val cause = e.cause
            if (cause != null) {
                doh.retryAt = now + DOH_RETRY_MS
                report(doh, "failed: " + (cause.message ?: cause.javaClass.simpleName))
            }
            null
        } catch (e: Exception) {
            doh.retryAt = now + DOH_RETRY_MS
            report(doh, "failed: " + (e.message ?: e.javaClass.simpleName))
            null
        }
    }

    private fun report(doh: Resolver, status: String) {
        val before = doh.status
        doh.status = status
        if (before.substringBefore(':') != status.substringBefore(':')) {
            log(if (status == "ok") "DoH ${doh.option.url}: answering" else "DoH ${doh.option.url} $status; using the system's DNS meanwhile")
        }
    }

    companion object {
        /** What TVBoxOS (the first three) and takagen99's Box offer under "安全 DNS". */
        val BUILTIN_DOH = listOf(
            DohOption("腾讯", "https://doh.pub/dns-query"),
            DohOption("阿里", "https://dns.alidns.com/dns-query"),
            DohOption("360", "https://doh.360.cn/dns-query"),
            DohOption("Google", "https://dns.google/dns-query"),
            DohOption("AdGuard", "https://dns.adguard.com/dns-query"),
            DohOption("Quad9", "https://dns.quad9.net/dns-query"),
        )

        private const val DOH_TTL_MS = 2 * 60_000L
        private const val DOH_RETRY_MS = 30_000L
        private const val DOH_CACHE_SIZE = 2000

        private val EMPTY = State(HostRules(emptyList()), HostRules(emptyList()), emptyList(), emptyList())

        private val IPV4 = Regex("^\\d{1,3}(\\.\\d{1,3}){3}$")
        private val HOST_NAME = Regex("^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$")
        private val HOST_PATTERN = Regex("^[a-z0-9*]([a-z0-9._*-]*[a-z0-9*])?$")

        /** Names only this network knows are not sent to a public resolver. */
        private val LOCAL_SUFFIXES = setOf("local", "lan", "localdomain", "home", "internal", "intranet", "corp", "localhost", "arpa")

        /** The url as it is kept and compared: blank unless it is an http(s) address. */
        fun normalizeDoh(url: String): String = url.trim().toHttpUrlOrNull()?.toString().orEmpty()

        /** [text] as an address when it is written as one (`1.2.3.4`, `::1`, `[::1]`); never a lookup. */
        fun literal(text: String): InetAddress? {
            if (IPV4.matches(text)) {
                val parts = text.split('.').map { it.toInt() }
                if (parts.any { it > 255 }) return null
                return InetAddress.getByAddress(ByteArray(4) { parts[it].toByte() })
            }
            // With a colon in it Java treats the text as an IPv6 literal and fails without asking any DNS.
            if (':' in text) return runCatching { InetAddress.getByName(text.removePrefix("[").removeSuffix("]")) }.getOrNull()
            return null
        }

        private fun isPublicName(name: String): Boolean = '.' in name && name.substringAfterLast('.') !in LOCAL_SUFFIXES

        private fun parse(config: TvboxConfig): State {
            val hosts = ArrayList<Pair<String, String>>()
            for ((rawName, rawTarget) in config.hosts) {
                val name = rawName.trim().lowercase()
                val target = rawTarget.trim().lowercase().removePrefix("[").removeSuffix("]")
                if (!redirectable(name) || name == target) continue
                if (!HOST_NAME.matches(target) && literal(target) == null) continue
                hosts += name to target
            }
            return State(HostRules(hosts), HostRules(parseHeaders(config.headersJson)), parseDoh(config.dohJson), config.ads.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.distinct())
        }

        /** A name `hosts` or `headers` may be written for: a host name, possibly with `*`, that is not an address. */
        private fun redirectable(name: String): Boolean =
            HOST_PATTERN.matches(name) && name.any { it.isLetterOrDigit() } && literal(name) == null && name != "localhost" && !name.endsWith(".localhost")

        private fun parseHeaders(json: String): List<Pair<String, Headers>> {
            val merged = LinkedHashMap<String, Headers.Builder>()
            for (o in objects(json)) {
                val host = o.string("host").trim().lowercase()
                if (!HOST_PATTERN.matches(host)) continue
                val header = (o.get("header") ?: o.get("headers")) as? JsonObject ?: continue
                val builder = merged.getOrPut(host) { Headers.Builder() }
                for ((name, value) in header.entrySet()) {
                    if (!value.isJsonPrimitive) continue
                    // OkHttp refuses names and values a request cannot carry; such an entry is left out.
                    runCatching { builder.set(name.trim(), value.asString.trim()) }
                }
            }
            return merged.mapNotNull { (host, builder) -> builder.build().takeIf { it.size > 0 }?.let { host to it } }
        }

        private fun parseDoh(json: String): List<DohOption> = objects(json).mapNotNull { o ->
            val url = normalizeDoh(o.string("url"))
            if (url.isEmpty()) return@mapNotNull null
            val ips = (o.get("ips") as? JsonArray)?.mapNotNull { ip -> ip.takeIf { it.isJsonPrimitive }?.asString?.trim()?.takeIf { literal(it) != null } }.orEmpty()
            DohOption(name = o.string("name").trim().ifEmpty { url.toHttpUrlOrNull()?.host ?: url }, url = url, ips = ips, source = "config")
        }.distinctBy { it.url }

        private fun objects(json: String): List<JsonObject> {
            if (json.isBlank()) return emptyList()
            val array = runCatching { JsonParser.parseString(json).asJsonArray }.getOrNull() ?: return emptyList()
            return array.mapNotNull { it as? JsonObject }
        }

        private fun JsonObject.string(key: String): String = get(key)?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
    }
}
