package tvbox.engine.server.lan

import io.ktor.server.application.Application
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.access.LanAnnouncer
import tvbox.engine.api.access.LanHost
import tvbox.engine.api.access.LanHostStatus
import tvbox.engine.api.access.LanListeners
import java.net.InetAddress
import java.text.SimpleDateFormat
import java.util.Date
import javax.jmdns.JmDNS
import javax.jmdns.ServiceInfo

/**
 * LAN sharing for the standalone engine: [LanListeners] (shared with the Android app) with a CIO server per LAN
 * address and a JmDNS announcer per address; the pairing code goes to standard output.
 *
 * Nothing listens on the network while sharing is off (Windows asks about the firewall only once the user switches
 * it on). With `--lan` ([boundToAll]) the main server already listens on 0.0.0.0.
 */
class LanSharing(
    private val access: AccessControl,
    port: Int,
    name: String,
    boundToAll: Boolean,
    module: Application.() -> Unit,
    private val log: (String) -> Unit = ::println,
) : LanHost {
    private val listeners = LanListeners(
        access, port, name, boundToAll,
        listen = { ip ->
            val server = embeddedServer(CIO, port = port, host = ip, module = module).start(wait = false)
            AutoCloseable { server.stop(200, 1000) }
        },
        announcer = JmdnsAnnouncer(log),
        log = log,
    )

    fun start() {
        access.onCode = { code, expiresAt ->
            log("配对码：$code（${SimpleDateFormat("HH:mm").format(Date(expiresAt))} 前有效）。在要连接的设备上输入它；需要新的码时在那台设备上重新打开配对窗口")
        }
        listeners.start()
    }

    override fun apply(enabled: Boolean) = listeners.apply(enabled)

    override fun status(): LanHostStatus = listeners.status()

    fun stop() = listeners.stop()

    /** One JmDNS per address the engine listens on (JmDNS binds to one interface). */
    private class JmdnsAnnouncer(private val log: (String) -> Unit) : LanAnnouncer {
        private val announcers = LinkedHashMap<String, JmDNS>()

        override fun update(addresses: List<String>, name: String, port: Int) {
            for (gone in announcers.keys.filter { it !in addresses }) {
                announcers.remove(gone)?.let { j -> runCatching { j.unregisterAllServices(); j.close() } }
            }
            for (ip in addresses) {
                if (ip in announcers) continue
                runCatching {
                    JmDNS.create(InetAddress.getByName(ip), name).apply {
                        registerService(ServiceInfo.create(SERVICE_TYPE, name, port, 0, 0, mapOf("protocol" to "1", "name" to name)))
                    }
                }.onSuccess { announcers[ip] = it }
                    .onFailure { log("mDNS 在 $ip 上不可用：${it.message}") }
            }
        }

        override val announced: Boolean get() = announcers.isNotEmpty()

        override fun close() = update(emptyList(), "", 0)
    }

    companion object {
        const val SERVICE_TYPE = LanListeners.SERVICE + ".local."

        /** IPv4 addresses of the interfaces that are up, without loopback and link-local (169.254.x.x). */
        fun lanAddresses(): List<String> = LanListeners.lanAddresses()

        /** The name other devices see: `--name`, else this computer's name. */
        fun defaultName(): String = runCatching { InetAddress.getLocalHost().hostName }.getOrNull()?.takeIf { it.isNotBlank() }
            ?.let { "映舟 · $it" } ?: "映舟引擎"
    }
}
