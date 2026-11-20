package tvbox.next.tvbox_client.engine

import android.content.Context
import android.util.Log
import io.ktor.server.cio.CIO
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import tvbox.engine.api.engineModule
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.spider.JarRepository
import tvbox.engine.core.store.JsonFileStore
import tvbox.engine.jarhost.HostBridge
import tvbox.engine.js.FileJsLocalStore
import tvbox.engine.js.JsEnvironment
import tvbox.engine.js.JsHttp
import tvbox.engine.js.JsModules
import tvbox.engine.js.JsRuntime
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * The engine inside the Android app: the same engine as on desktop/NAS, plus jar spiders through [DexSpiderRuntime].
 * Listens on 127.0.0.1:9978 (the client's default), so the app works on its own without a PC.
 */
object EmbeddedEngine {
    private const val TAG = "EmbeddedEngine"
    const val PORT = 9978

    @Volatile private var server: EmbeddedServer<*, *>? = null

    fun start(context: Context) {
        if (server != null) return
        val app = context.applicationContext
        HostBridge.context = app
        HostBridge.port = PORT
        // Created on the main thread, before any activity resumes, so it knows which activity can host its WebView.
        val sniffer = WebViewSniffer(app as android.app.Application)
        // The same goes for the foreground service's keeper (it asks for the notification permission in an activity).
        EngineKeeper.init(app)
        thread(name = "embedded-engine", isDaemon = true) {
            try {
                run(app, sniffer)
            } catch (e: Throwable) {
                Log.e(TAG, "engine failed to start", e)
            }
        }
    }

    private fun run(app: Context, sniffer: WebViewSniffer) {
        val local = "http://127.0.0.1:$PORT"
        val data = File(app.filesDir, "engine")
        val githubProxy = tvbox.engine.core.net.GithubProxy()
        // The active config's hosts / headers and the user's DNS choice, for everything built from this client.
        val network = tvbox.engine.core.net.ConfigNetwork(log = { Log.w(TAG, it) })
        val client = tvbox.engine.core.net.LenientTls.apply(
            network.install(OkHttpClient.Builder())
                .addInterceptor(githubProxy)
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS),
        ).build()
        HostBridge.baseClient = client
        // Copies of configs and site answers, so a start does not wait for the network.
        val dataCache = tvbox.engine.core.cache.DataCache(File(data, "cache/data"))
        val locator = ConfigLocator("$local/file/")
        val js = JsRuntime(
            JsEnvironment(
                modules = JsModules(client, locator, cacheDir = File(app.cacheDir, "js"), log = { Log.w(TAG, it) }),
                http = JsHttp(client),
                local = FileJsLocalStore(File(data, "js-local.json")),
                proxyUrl = "$local/proxy",
                log = { Log.i(TAG, it) },
            ),
        )
        val jar = DexSpiderRuntime(app, JarRepository(client, locator, File(app.cacheDir, "jar")), port = { PORT })
        // The HLS stream cache, in the app's cache folder: 1 GB by default, and it gives way when the device runs low.
        val streamCache = AndroidStorage.streamCache(app, client, data)
        val engine = Engine(
            info = EngineInfo(
                name = "tvbox-engine",
                version = "0.3.0",
                platform = "android-${android.os.Build.VERSION.SDK_INT}",
                capabilities = Capabilities(jar = false, js = false, py = false, sniff = false),
            ),
            loader = ConfigLoader(client, locator, dataCache),
            http = SiteHttp(client),
            cache = dataCache,
            proxyBase = "$local/proxy?",
            store = JsonFileStore(data),
            runtimes = listOf(jar, js),
            sniffer = sniffer,
            githubProxy = githubProxy,
            network = network,
            streamCache = streamCache,
        )
        // Episodes downloaded for offline viewing (see AndroidStorage); they keep the engine alive (EngineKeeper).
        val downloads = AndroidStorage.downloads(app, client, data, engine, local)
        engine.downloads = downloads
        // AList / WebDAV drives; folders of the device are not offered here.
        val drives = tvbox.engine.core.drive.DriveService(JsonFileStore(data), client, local, localFolders = false, log = { Log.w(TAG, it) })
        // Pairing, tokens and signed addresses, as on desktop: other devices get in only while LAN sharing is on.
        val access = tvbox.engine.api.access.AccessControl(JsonFileStore(data), supported = true)
        val module: io.ktor.server.application.Application.() -> Unit = {
            engineModule(engine, tvbox.engine.api.EngineModuleOptions(access = access, drives = drives))
        }
        server = embeddedServer(CIO, port = PORT, host = "127.0.0.1", module = module).start(wait = false)
        Log.i(TAG, "listening on $local")
        // LAN sharing (off by default): more listeners on the LAN addresses, mDNS, the foreground service.
        val lan = AndroidLan(app, access, PORT, module)
        EngineKeeper.attach(downloads, access, lan)
        lan.start()
        runBlocking {
            engine.restore()
                ?.onSuccess { Log.i(TAG, "restored ${it.url}: ${it.sites} sites") }
                ?.onFailure { Log.w(TAG, "could not restore the subscription: ${it.message}") }
        }
        // Downloads that were running when the app was stopped carry on, now that episodes can be resolved.
        downloads.start()
    }
}
