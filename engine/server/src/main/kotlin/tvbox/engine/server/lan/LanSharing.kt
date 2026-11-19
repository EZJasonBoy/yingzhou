package tvbox.engine.server.lan

import io.ktor.server.application.Application
import io.ktor.server.cio.CIO
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.access.LanHost
import tvbox.engine.api.access.LanHostStatus
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.jmdns.JmDNS
import javax.jmdns.ServiceInfo

/**
 * LAN sharing for the standalone engine.
 *
 * The engine always listens on 127.0.0.1. With sharing on it also listens on each IPv4 address of this machine
 * (a second server per address, same routes), so switching sharing on and off never interrupts the app that is
 * using the loopback address, and nothing listens on the network while it is off (Windows asks about the firewall
 * only once the user switches it on). With `--lan` ([boundToAll]) the main server already listens on 0.0.0.0.
 *
 * While sharing is on the engine is announced over mDNS as `_tvbox-engine._tcp` with TXT `protocol` and `name`,
 * on every address, and the list of addresses is checked again every 30 seconds (networks come and go).
 */
class LanSharing(
    private val access: AccessControl,
    private val port: Int,
    private val name: String,
    private val boundToAll: Boolean,
    private val module: Application.() -> Unit,
    private val log: (String) -> Unit = ::println,
) : LanHost {
    private val servers = LinkedHashMap<String, EmbeddedServer<*, *>>()
    private val announcers = LinkedHashMap<String, JmDNS>()
    private val errors = LinkedHashMap<String, String>()
    private val worker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "lan-sharing").apply { isDaemon = true } }
    @Volatile private var on = false

    fun start() {
        access.host = this
        access.onCode = { code, expiresAt ->
            log("配对码：$code（${SimpleDateFormat("HH:mm").format(Date(expiresAt))} 前有效）。在要连接的设备上输入它；需要新的码时在那台设备上重新打开配对窗口")
        }
        worker.scheduleWithFixedDelay({ if (on) runCatching { refresh() } }, 30, 30, TimeUnit.SECONDS)
        apply(access.sharing)
    }

    override fun apply(enabled: Boolean) {
        synchronized(this) {
            val was = on
            on = enabled
            if (enabled) refresh() else stopAll()
            if (enabled && !was) {
                val addresses = status().addresses
                log(if (addresses.isEmpty()) "局域网共享已开启，但没有找到局域网地址" else "局域网共享已开启：" + addresses.joinToString("  "))
                access.codeOrNew()
            } else if (!enabled && was) {
                log("局域网共享已关闭")
            }
        }
    }

    override fun status(): LanHostStatus = synchronized(this) {
        val listeningOn = if (boundToAll) (if (on) lanAddresses() else emptyList()) else servers.keys.toList()
        LanHostStatus(
            listening = on && (boundToAll || servers.isNotEmpty()),
            addresses = listeningOn.map { "http://$it:$port" },
            discoverable = announcers.isNotEmpty(),
            name = name,
            port = port,
            error = errors.values.joinToString("；"),
        )
    }

    fun stop() {
        synchronized(this) { stopAll() }
        worker.shutdownNow()
    }

    private fun refresh() = synchronized(this) {
        if (!on) return@synchronized
        val current = lanAddresses()
        for (gone in (servers.keys + announcers.keys).filter { it !in current }.toSet()) stopAddress(gone)
        for (ip in current) {
            if (!boundToAll && ip !in servers) {
                runCatching { embeddedServer(CIO, port = port, host = ip, module = module).start(wait = false) }
                    .onSuccess { servers[ip] = it; errors.remove(ip) }
                    .onFailure { errors[ip] = "$ip:$port 无法监听：${it.message ?: it.javaClass.simpleName}" }
            }
            if (ip !in announcers && (boundToAll || ip in servers)) {
                runCatching {
                    JmDNS.create(InetAddress.getByName(ip), name).apply {
                        registerService(ServiceInfo.create(SERVICE_TYPE, name, port, 0, 0, mapOf("protocol" to "1", "name" to name)))
                    }
                }.onSuccess { announcers[ip] = it }
                    .onFailure { log("mDNS 在 $ip 上不可用：${it.message}") }
            }
        }
    }

    private fun stopAddress(ip: String) {
        announcers.remove(ip)?.let { j -> runCatching { j.unregisterAllServices(); j.close() } }
        servers.remove(ip)?.let { s -> runCatching { s.stop(200, 1000) } }
        errors.remove(ip)
    }

    private fun stopAll() {
        (servers.keys + announcers.keys).toSet().forEach(::stopAddress)
        errors.clear()
    }

    companion object {
        const val SERVICE_TYPE = "_tvbox-engine._tcp.local."

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

        /** The name other devices see: `--name`, else this computer's name. */
        fun defaultName(): String = runCatching { InetAddress.getLocalHost().hostName }.getOrNull()?.takeIf { it.isNotBlank() }
            ?.let { "映舟 · $it" } ?: "映舟引擎"
    }
}
