package tvbox.engine.api.access

import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Makes the engine findable on the LAN (mDNS) while sharing is on: JmDNS on desktop / NAS, `NsdManager` on Android.
 * Called from one thread at a time.
 */
interface LanAnnouncer {
    /**
     * The engine now listens on [addresses] (IPv4, without the port); announce it there under [name] at [port].
     * Empty: stop announcing. Called whenever the set changes, and again every time the addresses are checked.
     */
    fun update(addresses: List<String>, name: String, port: Int)

    /** Whether the engine is announced now (as far as the announcer knows). */
    val announced: Boolean

    fun close() {}
}

/**
 * LAN sharing, the part every platform has in common ([LanHost] for [AccessControl]).
 *
 * The engine always listens on 127.0.0.1. With sharing on it also listens on each IPv4 address of this device (a
 * second server per address, same routes, started by [listen]), so switching sharing on and off never interrupts the
 * app that is using the loopback address, and nothing listens on the network while it is off. With [boundToAll]
 * (`--lan`) the main server already listens on 0.0.0.0 and no extra servers are started.
 *
 * While sharing is on the engine is announced by [announcer] (`_tvbox-engine._tcp` with TXT `protocol` and `name`),
 * and the list of addresses is checked again every [refreshSeconds] (networks come and go: Wi-Fi changes, a cable
 * is plugged in). [onSharing] hears when sharing starts and stops (the Android app keeps a foreground service then).
 */
class LanListeners(
    private val access: AccessControl,
    private val port: Int,
    private val name: String,
    private val boundToAll: Boolean = false,
    /** Starts a server with the engine's routes on `ip:port`; closing what it returns stops that server. */
    private val listen: (ip: String) -> AutoCloseable,
    private val announcer: LanAnnouncer? = null,
    /** The device's LAN addresses now. */
    private val addresses: () -> List<String> = ::lanAddresses,
    private val log: (String) -> Unit = ::println,
    private val onSharing: (Boolean) -> Unit = {},
    private val refreshSeconds: Long = 30,
) : LanHost {
    private val servers = LinkedHashMap<String, AutoCloseable>()
    private val errors = LinkedHashMap<String, String>()
    private val worker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "lan-sharing").apply { isDaemon = true } }
    @Volatile private var on = false
    @Volatile private var announcedOn: List<String> = emptyList()

    /** Takes over as [AccessControl.host] and does what the saved switch says. */
    fun start() {
        access.host = this
        worker.scheduleWithFixedDelay({ if (on) runCatching { refresh() } }, refreshSeconds, refreshSeconds, TimeUnit.SECONDS)
        apply(access.sharing)
    }

    override fun apply(enabled: Boolean) {
        var changed = false
        synchronized(this) {
            val was = on
            on = enabled
            if (enabled) refresh() else stopAll()
            if (enabled && !was) {
                val listening = status().addresses
                log(if (listening.isEmpty()) "局域网共享已开启，但没有找到局域网地址" else "局域网共享已开启：" + listening.joinToString("  "))
                access.codeOrNew()
                changed = true
            } else if (!enabled && was) {
                log("局域网共享已关闭")
                changed = true
            }
        }
        if (changed) runCatching { onSharing(enabled) }.onFailure { log("lan: ${it.message}") }
    }

    override fun status(): LanHostStatus = synchronized(this) {
        val listeningOn = if (boundToAll) (if (on) addresses() else emptyList()) else servers.keys.toList()
        LanHostStatus(
            listening = on && (boundToAll || servers.isNotEmpty()),
            addresses = listeningOn.map { "http://$it:$port" },
            discoverable = on && announcedOn.isNotEmpty() && announcer?.announced == true,
            name = name,
            port = port,
            error = errors.values.joinToString("；"),
        )
    }

    /** Whether sharing is on (the switch, not whether an address was found). */
    val sharing: Boolean get() = on

    /** Checks the addresses again now (Android calls this when the network changes). */
    fun refreshNow() {
        if (on) worker.execute { runCatching { refresh() } }
    }

    fun stop() {
        synchronized(this) { stopAll() }
        worker.shutdownNow()
        runCatching { announcer?.close() }
    }

    private fun refresh() = synchronized(this) {
        if (!on) return@synchronized
        val current = addresses()
        for (gone in servers.keys.filter { it !in current }) stopAddress(gone)
        errors.keys.retainAll(current.toSet())
        if (!boundToAll) {
            for (ip in current) {
                if (ip in servers) continue
                runCatching { listen(ip) }
                    .onSuccess { servers[ip] = it; errors.remove(ip) }
                    .onFailure { errors[ip] = "$ip:$port 无法监听：${it.message ?: it.javaClass.simpleName}" }
            }
        }
        val listening = if (boundToAll) current else servers.keys.toList()
        announcer?.let { a ->
            runCatching { a.update(listening, name, port) }.onFailure { log("mDNS：${it.message}") }
            announcedOn = listening
        }
    }

    private fun stopAddress(ip: String) {
        servers.remove(ip)?.let { s -> runCatching { s.close() } }
        errors.remove(ip)
    }

    private fun stopAll() {
        servers.keys.toList().forEach(::stopAddress)
        errors.clear()
        announcer?.let { a -> if (announcedOn.isNotEmpty()) runCatching { a.update(emptyList(), name, port) } }
        announcedOn = emptyList()
    }

    companion object {
        /** The mDNS service type the engine is announced as (without the `.local.` JmDNS wants). */
        const val SERVICE = "_tvbox-engine._tcp"

        /** IPv4 addresses of the interfaces that are up, without loopback and link-local (169.254.x.x). */
        fun lanAddresses(): List<String> = runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress && !it.isAnyLocalAddress }
                .map { it.hostAddress }
                .distinct()
        }.getOrDefault(emptyList())
    }
}
