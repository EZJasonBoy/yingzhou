package tvbox.engine.server

import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import tvbox.engine.api.engineModule
import tvbox.engine.core.Engine
import tvbox.engine.core.config.ConfigLoader
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.model.Capabilities
import tvbox.engine.core.model.EngineInfo
import java.util.concurrent.TimeUnit

/**
 * Standalone engine (desktop sidecar / Docker).
 *
 *   tvbox-engine [--port 9978] [--lan] [--subscribe <url>]
 *
 * Port 9978 is the TVBox default; jar spiders look for their host on 9978..9999.
 * Without --lan the engine only listens on 127.0.0.1.
 */
fun main(args: Array<String>) {
    val port = argValue(args, "--port")?.toIntOrNull() ?: 9978
    val host = if ("--lan" in args) "0.0.0.0" else "127.0.0.1"

    val http = OkHttpClient.Builder()
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
        loader = ConfigLoader(http, ConfigLocator("http://127.0.0.1:$port/file/")),
    )

    argValue(args, "--subscribe")?.let { url ->
        runBlocking {
            val sub = engine.addSubscription(url, null)
            runCatching { engine.activate(sub.id) }
                .onSuccess { println("loaded ${it.url}: ${it.sites} sites, ${it.parses} parses, ${it.lives} live groups") }
                .onFailure { println("failed to load $url: ${it.message}") }
        }
    }

    println("tvbox-engine listening on http://$host:$port")
    embeddedServer(CIO, port = port, host = host) { engineModule(engine) }.start(wait = true)
}

private fun argValue(args: Array<String>, name: String): String? {
    val i = args.indexOf(name)
    return if (i >= 0 && i + 1 < args.size) args[i + 1] else null
}
