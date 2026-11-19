package tvbox.engine.server

import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import tvbox.engine.api.access.isLocal
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.ErrorBody
import tvbox.engine.py.PyRuntime
import tvbox.engine.py.PythonInstallRequest
import tvbox.engine.py.PythonSettingsUpdate

/**
 * `/api/v1/python`: the 「Python 蜘蛛」 settings. Anyone allowed to use the engine may look; only the app on the
 * engine's own machine may change anything, because a Python path is a program the engine will run and installing
 * puts software on that machine.
 *
 * - `GET` the status (`?refresh=1` looks for a Python again);
 * - `PUT` settings (`path`, `indexUrl`, `downloadMirror`);
 * - `POST /download` starts downloading the embeddable CPython (Windows), `DELETE /download` removes it;
 * - `POST /packages` `{packages: [...]}` starts installing packages (empty: the common ones).
 *
 * Downloads and installations run in the background; the status shows how far they are.
 */
fun Route.pythonRoutes(py: PyRuntime) {
    route("/api/v1/python") {
        get {
            val status = withContext(Dispatchers.IO) {
                if (call.request.queryParameters["refresh"] == "1") py.manager.relocate()
                py.status()
            }
            call.respond(status)
        }
        put {
            if (!call.requireLocal()) return@put
            val update = call.receive<PythonSettingsUpdate>()
            call.managed { py.manager.updateSettings(update) } ?: return@put
            call.respond(withContext(Dispatchers.IO) { py.status() })
        }
        post("/download") {
            if (!call.requireLocal()) return@post
            call.managed { py.manager.startDownload() } ?: return@post
            call.respond(withContext(Dispatchers.IO) { py.status() })
        }
        delete("/download") {
            if (!call.requireLocal()) return@delete
            call.managed { py.manager.removeDownloaded() } ?: return@delete
            call.respond(withContext(Dispatchers.IO) { py.status() })
        }
        post("/packages") {
            if (!call.requireLocal()) return@post
            val request = runCatching { call.receive<PythonInstallRequest>() }.getOrDefault(PythonInstallRequest())
            call.managed { py.manager.startInstall(request.packages) } ?: return@post
            call.respond(withContext(Dispatchers.IO) { py.status() })
        }
    }
}

private suspend fun ApplicationCall.requireLocal(): Boolean {
    if (isLocal()) return true
    respond(HttpStatusCode.Forbidden, ErrorBody(ApiError("LOCAL_ONLY", "Python 只能在引擎所在的电脑上设置")))
    return false
}

/** Runs a management step; refusals become 400 / 409 answers (and null). */
private suspend fun <T> ApplicationCall.managed(block: () -> T): T? = try {
    withContext(Dispatchers.IO) { block() }
} catch (e: IllegalArgumentException) {
    respond(HttpStatusCode.BadRequest, ErrorBody(ApiError("BAD_REQUEST", e.message ?: "bad request")))
    null
} catch (e: IllegalStateException) {
    respond(HttpStatusCode.Conflict, ErrorBody(ApiError("PYTHON_BUSY", e.message ?: "busy")))
    null
} catch (e: java.io.IOException) {
    respond(HttpStatusCode.InternalServerError, ErrorBody(ApiError("PYTHON_FAILED", e.message ?: "failed")))
    null
}
