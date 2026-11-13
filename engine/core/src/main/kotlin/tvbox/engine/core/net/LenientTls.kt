package tvbox.engine.core.net

import okhttp3.OkHttpClient
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/**
 * HTTPS the way TVBox does it (`OkGoHelper`, `com.github.catvod.net.OkHttp`): any certificate and any host name
 * are accepted. Sites, playlists and guides in real configs are full of expired, self-signed and mismatched
 * certificates, and they only work in TVBox because it does not check; an engine that checks cannot open them.
 *
 * What is given up: someone on the network path can read or change what these requests carry. That is no worse
 * than the plain http most of those configs use anyway, and it applies only to what subscriptions point at.
 * `--strict-tls` (desktop engine) turns the checks back on.
 */
object LenientTls {
    private val trustAll = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    fun apply(builder: OkHttpClient.Builder): OkHttpClient.Builder {
        val context = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustAll), SecureRandom()) }
        return builder.sslSocketFactory(context.socketFactory, trustAll).hostnameVerifier { _, _ -> true }
    }
}
