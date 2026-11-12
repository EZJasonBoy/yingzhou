package tvbox.engine.api

import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import kotlinx.serialization.json.Json
import tvbox.engine.core.Engine
import tvbox.engine.core.EngineException
import tvbox.engine.core.model.ActivateRequest
import tvbox.engine.core.model.AddSubscriptionRequest
import tvbox.engine.core.model.ApiError
import tvbox.engine.core.model.ErrorBody

val EngineJson = Json {
    encodeDefaults = true
    ignoreUnknownKeys = true
    explicitNulls = false
}

/** Installs protocol v1 (docs/protocol.md) on a Ktor application. Shared by the server and the Android app. */
fun Application.engineModule(engine: Engine) {
    install(ContentNegotiation) { json(EngineJson) }
    install(StatusPages) {
        exception<EngineException> { call, e ->
            val status = when (e) {
                is EngineException.NotFound -> HttpStatusCode.NotFound
                is EngineException.BadRequest -> HttpStatusCode.BadRequest
                is EngineException.NoConfig -> HttpStatusCode.Conflict
                is EngineException.ConfigLoadFailed -> HttpStatusCode.BadGateway
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
                call.respond(HttpStatusCode.NotImplemented, ErrorBody(ApiError("NOT_IMPLEMENTED", "spider proxy arrives in M2")))
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
        }
    }
}
