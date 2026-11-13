package tvbox.engine.server

import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import tvbox.engine.api.EngineModuleOptions
import tvbox.engine.api.engineModule
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.store.JsonFileStore
import tvbox.engine.core.store.MemoryStore
import tvbox.engine.js.FileJsLocalStore
import tvbox.engine.js.JsEnvironment
import tvbox.engine.js.JsHttp
import tvbox.engine.js.JsModules
import tvbox.engine.js.JsRuntime
import tvbox.engine.js.MemoryJsLocalStore
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Standalone engine (desktop sidecar / Docker).
 *
 *   tvbox-engine [--port 9978] [--lan] [--data <dir>] [--subscribe <url>] [--demo] [--dev-cors]
 *
 * - Port 9978 is the TVBox default; jar spiders look for their host on 9978..9999.
 * - Without --lan the engine only listens on 127.0.0.1.
 * - --data is where subscriptions, history and favorites are kept (default ~/.tvbox-next/engine).
 * - --demo serves a fake site under /demo and subscribes to it; it keeps data in memory unless --data is given.
 * - --dev-cors lets pages on http://localhost:* call the engine (Flutter web during development).
 */
fun main(args: Array<String>) {
    val port = argValue(args, "--port")?.toIntOrNull() ?: 9978
    val host = if ("--lan" in args) "0.0.0.0" else "127.0.0.1"
    val local = "http://127.0.0.1:$port"
    val dataDir = argValue(args, "--data")?.let(::File)
        ?: if ("--demo" in args) null else File(System.getProperty("user.home"), ".tvbox-next/engine")
    val store = dataDir?.let { JsonFileStore(it) } ?: MemoryStore()

    val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    val locator = ConfigLocator("$local/file/")
    val jsRuntime = JsRuntime(
        JsEnvironment(
            modules = JsModules(client, locator, cacheDir = dataDir?.let { File(it, "js-cache") }),
            http = JsHttp(client),
            local = dataDir?.let { FileJsLocalStore(File(it, "js-local.json")) } ?: MemoryJsLocalStore(),
            proxyUrl = "$local/proxy",
            log = { line -> if ("[log]" !in line && "[debug]" !in line && "[info]" !in line) System.err.println(line) },
        ),
    )
    val engine = Engine(
        info = EngineInfo(
            name = "tvbox-engine",
            version = "0.1.0",
            platform = "jvm-" + System.getProperty("os.name").lowercase().substringBefore(' '),
            capabilities = Capabilities(jar = false, js = false, py = false, sniff = false),
        ),
        loader = ConfigLoader(client, locator),
        http = SiteHttp(client),
        proxyBase = "$local/proxy?",
        store = store,
        runtimes = listOf(jsRuntime),
    )
    val demo = if ("--demo" in args) DemoSite() else null

    val server = embeddedServer(CIO, port = port, host = host) {
        engineModule(engine, EngineModuleOptions(allowLocalhostCors = "--dev-cors" in args))
        if (demo != null) routing { demoRoutes(demo) }
    }.start(wait = false)
    println("tvbox-engine listening on http://$host:$port" + (dataDir?.let { ", data in ${it.absolutePath}" } ?: ", data in memory"))

    val subscribe = argValue(args, "--subscribe") ?: demo?.let { "$local/demo/config.json" }
    runBlocking {
        val result = if (subscribe != null) {
            val sub = engine.addSubscription(subscribe, if (demo != null && subscribe.endsWith("/demo/config.json")) "演示订阅" else null)
            runCatching { engine.activate(sub.id) }
        } else {
            engine.restore()
        }
        result
            ?.onSuccess { println("loaded ${it.url}: ${it.sites} sites, ${it.parses} parses, ${it.lives} live groups") }
            ?.onFailure { println("failed to load the subscription: ${it.message}") }
    }

    Runtime.getRuntime().addShutdownHook(Thread { server.stop(500, 2000) })
    Thread.currentThread().join()
}

private fun argValue(args: Array<String>, name: String): String? {
    val i = args.indexOf(name)
    return if (i >= 0 && i + 1 < args.size) args[i + 1] else null
}
