package tvbox.next.tvbox_client.engine

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import tvbox.engine.api.access.LanAnnouncer
import tvbox.engine.api.access.LanListeners

/**
 * Announces the engine over mDNS through Android's own service ([NsdManager], the system's mdnsd), as
 * `_tvbox-engine._tcp` with TXT `protocol=1` and `name` — what the desktop engine announces through JmDNS and what
 * the client's discovery looks for. One registration covers every interface; it is made again when the addresses the
 * engine listens on change (older Android versions do not follow a network change on their own), and tried again
 * at the next check when it failed.
 */
class NsdAnnouncer(context: Context, private val log: (String) -> Unit) : LanAnnouncer {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val lock = Any()
    private var listener: NsdManager.RegistrationListener? = null
    private var registeredFor: Set<String> = emptySet()
    @Volatile private var registered = false

    /** The name the service got (NSD renames it when another device on the LAN has the same one). */
    @Volatile var registeredName: String? = null
        private set

    override fun update(addresses: List<String>, name: String, port: Int) {
        synchronized(lock) {
            if (addresses.isEmpty()) {
                unregister()
                return
            }
            if (listener != null && addresses.toSet() == registeredFor) return
            unregister()
            registeredFor = addresses.toSet()
            val info = NsdServiceInfo().apply {
                serviceName = serviceNameOf(name)
                serviceType = LanListeners.SERVICE
                setPort(port)
                setAttribute("protocol", "1")
                setAttribute("name", name)
            }
            val l = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(service: NsdServiceInfo) {
                    registered = true
                    registeredName = service.serviceName
                    log("mDNS: announced as ${service.serviceName} on ${registeredFor.joinToString()}")
                }

                override fun onRegistrationFailed(service: NsdServiceInfo, errorCode: Int) {
                    synchronized(lock) {
                        if (listener === this) {
                            listener = null
                            registeredFor = emptySet()
                        }
                    }
                    registered = false
                    log("mDNS: registration failed ($errorCode), tried again at the next check")
                }

                override fun onServiceUnregistered(service: NsdServiceInfo) {
                    if (listener == null) registered = false
                }

                override fun onUnregistrationFailed(service: NsdServiceInfo, errorCode: Int) {
                    log("mDNS: unregistration failed ($errorCode)")
                }
            }
            listener = l
            runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l) }.onFailure {
                listener = null
                registeredFor = emptySet()
                log("mDNS: ${it.message}")
            }
        }
    }

    override val announced: Boolean get() = registered

    override fun close() = synchronized(lock) { unregister() }

    /** Caller holds [lock]. */
    private fun unregister() {
        listener?.let { l -> runCatching { nsd.unregisterService(l) } }
        listener = null
        registeredFor = emptySet()
        registered = false
        registeredName = null
    }

    companion object {
        /** DNS-SD instance names are at most 63 bytes of UTF-8. */
        fun serviceNameOf(name: String): String {
            var out = name
            while (out.toByteArray(Charsets.UTF_8).size > 63) out = out.dropLast(1)
            return out
        }
    }
}
