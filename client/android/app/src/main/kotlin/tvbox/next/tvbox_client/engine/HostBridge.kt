package tvbox.next.tvbox_client.engine

import android.annotation.SuppressLint
import android.content.Context
import okhttp3.OkHttpClient

/** State the copied TVBox host classes (com.github.catvod.*) read: app context, engine port, optional base client. */
@SuppressLint("StaticFieldLeak") // application context only
object HostBridge {
    @JvmField var context: Context? = null
    @JvmField var port: Int = 9978

    /** When null, com.github.catvod.net.OkHttp builds TVBox's lenient client (30 s timeouts, trust-all TLS). */
    @JvmField var baseClient: OkHttpClient? = null
}
