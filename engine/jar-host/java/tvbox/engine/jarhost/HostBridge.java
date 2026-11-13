package tvbox.engine.jarhost;

import android.content.Context;

import okhttp3.OkHttpClient;

/**
 * State the TVBox host classes (com.github.catvod.*) read: the context handed to spiders, the engine port,
 * and an optional base HTTP client. Shared by the Android app (real Context) and the desktop runtime (stub Context).
 */
public final class HostBridge {
    private HostBridge() {}

    public static volatile Context context;
    public static volatile int port = 9978;

    /** When null, com.github.catvod.net.OkHttp builds TVBox's lenient client (30 s timeouts, trust-all TLS). */
    public static volatile OkHttpClient baseClient;
}
