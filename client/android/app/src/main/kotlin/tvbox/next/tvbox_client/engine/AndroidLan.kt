package tvbox.next.tvbox_client.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.ktor.server.application.Application
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import tvbox.engine.api.access.AccessControl
import tvbox.engine.api.access.LanListeners
import java.net.Inet4Address

/**
 * LAN sharing from an Android device: the same [LanListeners] as the desktop engine (a second CIO server on each
 * LAN address while sharing is on, nothing on the network while it is off), announced through [NsdAnnouncer], and
 * kept alive by [EngineKeeper]'s foreground service while it is on. The addresses are checked again whenever the
 * network changes (Wi-Fi, Ethernet on a TV box) and every 15 seconds.
 */
class AndroidLan(
    private val context: Context,
    access: AccessControl,
    port: Int,
    module: Application.() -> Unit,
) {
    val name: String = "映舟 · " + deviceName(context)
    val announcer = NsdAnnouncer(context) { Log.i(TAG, it) }

    val listeners = LanListeners(
        access, port, name,
        listen = { ip ->
            val server = embeddedServer(CIO, port = port, host = ip, module = module).start(wait = false)
            Log.i(TAG, "listening on http://$ip:$port")
            AutoCloseable { server.stop(200, 1000) }
        },
        announcer = announcer,
        addresses = { lanAddresses(context) },
        log = { Log.i(TAG, it) },
        onSharing = { on -> EngineKeeper.sharingChanged(on) },
        refreshSeconds = 15,
    )

    fun start() {
        listeners.start()
        runCatching {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = listeners.refreshNow()
                override fun onLost(network: Network) = listeners.refreshNow()
                override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = listeners.refreshNow()
            })
        }.onFailure { Log.w(TAG, "no network callback: ${it.message}") }
    }

    companion object {
        private const val TAG = "EngineLan"

        /**
         * The device's IPv4 addresses on Wi-Fi and Ethernet networks only: a phone never listens on mobile data, where
         * other devices of the user are not, and where some carriers hand out public addresses.
         */
        @Suppress("DEPRECATION")
        fun lanAddresses(context: Context): List<String> = runCatching {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.allNetworks.filter { n ->
                val caps = cm.getNetworkCapabilities(n) ?: return@filter false
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            }.flatMap { n -> cm.getLinkProperties(n)?.linkAddresses.orEmpty() }
                .map { it.address }
                .filterIsInstance<Inet4Address>()
                .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress && !it.isAnyLocalAddress }
                .mapNotNull { it.hostAddress }
                .distinct()
        }.getOrElse {
            Log.w(TAG, "addresses: ${it.message}")
            emptyList()
        }

        /** The name the user gave the device (Settings → About), else its model. */
        fun deviceName(context: Context): String {
            val named = if (Build.VERSION.SDK_INT >= 25) {
                runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
            } else {
                null
            }
            return named?.trim()?.takeIf { it.isNotEmpty() } ?: Build.MODEL?.trim()?.takeIf { it.isNotEmpty() } ?: "Android"
        }
    }
}
