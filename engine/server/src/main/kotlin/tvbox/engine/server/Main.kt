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
import java.util.concurrent.TimeUnit

/**
 * Standalone engine (desktop sidecar / Docker).
 *
 *   tvbox-engine [--port 9978] [--lan] [--subscribe <url>] [--demo] [--dev-cors]
 *
 * - Port 9978 is the TVBox default; jar spiders look for their host on 9978..9999.
 * - Without --lan the engine only listens on 127.0.0.1.
 * - --demo serves a fake site under /demo and subscribes to it (development only).
 * - --dev-cors lets pages on http://localhost:* call the engine (Flutter web during development).
 */
fun main(args: Array<String>) {
    val port = argValue(args, "--port")?.toIntOrNull() ?: 9978
    val host = if ("--lan" in args) "0.0.0.0" else "127.0.0.1"
    val local = "http://127.0.0.1:$port"

    val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    val engine = Engine(
        info = EngineInfo(
            name = "tvbox-engine",
            version = "0.1.0",
            platform = "jvm-" + System.getProperty("os.name").lowercase().substringBefore(' '),
            capabilities = Capabilities(jar = false, js = false, py = false, sniff = false),
        ),
        loader = ConfigLoader(client, ConfigLocator("$local/file/")),
        http = SiteHttp(client),
        proxyBase = "$local/proxy?",
    )
    val demo = if ("--demo" in args) DemoSite(local) else null

    val server = embeddedServer(CIO, port = port, host = host) {
        engineModule(engine, EngineModuleOptions(allowLocalhostCors = "--dev-cors" in args))
        if (demo != null) routing { demoRoutes(demo) }
    }.start(wait = false)
    println("tvbox-engine listening on http://$host:$port")

    val subscribe = argValue(args, "--subscribe") ?: demo?.let { "$local/demo/config.json" }
    subscribe?.let { url ->
        runBlocking {
            val sub = engine.addSubscription(url, if (demo != null && url.endsWith("/demo/config.json")) "演示订阅" else null)
            runCatching { engine.activate(sub.id) }
                .onSuccess { println("loaded ${it.url}: ${it.sites} sites, ${it.parses} parses, ${it.lives} live groups") }
                .onFailure { println("failed to load $url: ${it.message}") }
        }
    }

    Runtime.getRuntime().addShutdownHook(Thread { server.stop(500, 2000) })
    Thread.currentThread().join()
}

private fun argValue(args: Array<String>, name: String): String? {
    val i = args.indexOf(name)
    return if (i >= 0 && i + 1 < args.size) args[i + 1] else null
}
