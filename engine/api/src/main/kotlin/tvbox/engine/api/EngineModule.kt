package tvbox.engine.api

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.cors.routing.CORS
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.receive
import io.ktor.server.response.cacheControl
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.response.respondTextWriter
import io.ktor.server.routing.RoutingCall
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.http.CacheControl
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.model.ActivateRequest
import tvbox.engine.core.model.AddSubscriptionRequest
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.ErrorBody
import tvbox.engine.core.model.FavoriteEntry
import tvbox.engine.core.model.HistoryEntry
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.search.SearchEvent

val EngineJson = Json {
    encodeDefaults = true
    ignoreUnknownKeys = true
    explicitNulls = false
}

data class EngineModuleOptions(
    /**
     * Development only: allow browser pages on localhost (e.g. the Flutter web build) to call the engine.
     * Off by default so that arbitrary web sites cannot drive a local engine.
     */
    val allowLocalhostCors: Boolean = false,
)

/** Installs protocol v1 (docs/protocol.md) on a Ktor application. Shared by the server and the Android app. */
fun Application.engineModule(engine: Engine, options: EngineModuleOptions = EngineModuleOptions()) {
    install(ContentNegotiation) { json(EngineJson) }
    if (options.allowLocalhostCors) {
        install(CORS) {
            allowOrigins { origin ->
                origin.startsWith("http://localhost:") || origin.startsWith("http://127.0.0.1:")
            }
            allowMethod(HttpMethod.Delete)
            allowHeader(HttpHeaders.ContentType)
            allowHeader(HttpHeaders.Authorization)
        }
    }
    install(StatusPages) {
        exception<EngineException> { call, e ->
            val status = when (e) {
                is EngineException.NotFound -> HttpStatusCode.NotFound
                is EngineException.BadRequest -> HttpStatusCode.BadRequest
                is EngineException.NoConfig -> HttpStatusCode.Conflict
                is EngineException.ConfigLoadFailed -> HttpStatusCode.BadGateway
                is EngineException.Unsupported -> HttpStatusCode.NotImplemented
                is EngineException.SiteFailed -> HttpStatusCode.BadGateway
            }
            call.respond(status, ErrorBody(ApiError(e.code, e.message ?: "")))
        }
        exception<BadRequestException> { call, e ->
            call.respond(HttpStatusCode.BadRequest, ErrorBody(ApiError("BAD_REQUEST", e.message ?: "bad request")))
        }
        exception<Throwable> { call, e ->
            call.respond(HttpStatusCode.InternalServerError, ErrorBody(ApiError("INTERNAL", e.message ?: e.javaClass.simpleName)))
        }
    }

    routing {
        // TVBox 9978 compatibility: jar spiders probe 9978..9999 with /proxy?do=ck to find the host.
        get("/proxy") {
            if (call.parameters["do"] == "ck") {
                call.respondText("ok")
            } else {
                call.respond(HttpStatusCode.NotImplemented, ErrorBody(ApiError("NOT_IMPLEMENTED", "spider proxy arrives with the jar runtime")))
            }
        }

        route("/api/v1") {
            get("/info") { call.respond(engine.info) }

            get("/subscriptions") { call.respond(engine.subscriptions()) }
            post("/subscriptions") {
                val req = call.receive<AddSubscriptionRequest>()
                call.respond(HttpStatusCode.Created, engine.addSubscription(req.url, req.name))
            }
            delete("/subscriptions/{id}") {
                engine.removeSubscription(call.parameters["id"]!!)
                call.respond(HttpStatusCode.NoContent)
            }
            post("/subscriptions/{id}/activate") {
                // The body is optional; an empty body means "first repo".
                val req = runCatching { call.receive<ActivateRequest>() }.getOrNull()
                call.respond(engine.activate(call.parameters["id"]!!, req?.repo))
            }

            get("/config") { call.respond(engine.summary()) }
            get("/sites") { call.respond(engine.sites()) }

            route("/sites/{site}") {
                get("/home") { call.respond(engine.home(call.site())) }
                get("/category") {
                    val tid = call.required("tid")
                    val page = call.parameters["pg"]?.toIntOrNull() ?: 1
                    call.respond(engine.category(call.site(), tid, page, call.filters()))
                }
                get("/detail") { call.respond(engine.detail(call.site(), call.required("id"))) }
                get("/search") {
                    val page = call.parameters["pg"]?.toIntOrNull() ?: 1
                    call.respond(engine.search(call.site(), call.required("wd"), page))
                }
            }

            get("/search/stream") {
                val keyword = call.required("wd")
                val sites = call.parameters["sites"]?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }?.toSet()
                val events = engine.searchAll(keyword, sites)
                call.response.cacheControl(CacheControl.NoCache(null))
                call.respondTextWriter(ContentType.Text.EventStream) {
                    events.collect { event ->
                        val (name, data) = when (event) {
                            is SearchEvent.Site -> "site" to EngineJson.encodeToString(event.event)
                            is SearchEvent.Results -> "results" to EngineJson.encodeToString(event.event)
                            is SearchEvent.End -> "end" to EngineJson.encodeToString(event.event)
                        }
                        write("event: $name\ndata: $data\n\n")
                        flush()
                    }
                }
            }

            post("/play/resolve") {
                call.respond(engine.resolvePlay(call.receive<PlayRequest>()))
            }

            route("/history") {
                get { call.respond(engine.library.history(call.parameters["limit"]?.toIntOrNull() ?: 100)) }
                delete {
                    engine.library.clearHistory()
                    call.respond(HttpStatusCode.NoContent)
                }
                route("/{site}/{vodId}") {
                    get {
                        val entry = engine.library.historyFor(call.site(), call.vodId()) ?: throw EngineException.NotFound("no history for this video")
                        call.respond(entry)
                    }
                    put {
                        val body = call.receive<HistoryEntry>()
                        call.respond(engine.library.putHistory(body.copy(site = call.site(), vodId = call.vodId())))
                    }
                    delete {
                        engine.library.removeHistory(call.site(), call.vodId())
                        call.respond(HttpStatusCode.NoContent)
                    }
                }
            }

            route("/favorites") {
                get { call.respond(engine.library.favorites()) }
                route("/{site}/{vodId}") {
                    get {
                        val entry = engine.library.favoriteFor(call.site(), call.vodId()) ?: throw EngineException.NotFound("not a favorite")
                        call.respond(entry)
                    }
                    put {
                        val body = call.receive<FavoriteEntry>()
                        call.respond(engine.library.putFavorite(body.copy(site = call.site(), vodId = call.vodId())))
                    }
                    delete {
                        engine.library.removeFavorite(call.site(), call.vodId())
                        call.respond(HttpStatusCode.NoContent)
                    }
                }
            }
        }
    }
}

private fun RoutingCall.site(): String = parameters["site"]!!

private fun RoutingCall.vodId(): String = parameters["vodId"]!!

private fun RoutingCall.required(name: String): String =
    parameters[name]?.takeIf { it.isNotBlank() } ?: throw EngineException.BadRequest("missing parameter: $name")

/** `f` is a URL-encoded JSON object of filter key -> value. */
private fun RoutingCall.filters(): Map<String, String> {
    val raw = parameters["f"]?.takeIf { it.isNotBlank() } ?: return emptyMap()
    val obj: JsonObject = try {
        EngineJson.parseToJsonElement(raw).jsonObject
    } catch (e: Exception) {
        throw EngineException.BadRequest("f must be a JSON object")
    }
    return obj.mapValues { (_, v) -> (v as? JsonPrimitive)?.content ?: v.toString() }
}
