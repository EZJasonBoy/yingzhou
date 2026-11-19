package tvbox.engine.api

import io.ktor.http.ContentType
import io.ktor.server.application.ApplicationCall
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.response.respondText
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import tvbox.engine.core.Engine
import tvbox.engine.core.play.SubtitleConverter
import tvbox.engine.core.play.Subtitles
import tvbox.engine.core.util.Base64Compat

/**
 * What goes with a video besides the picture.
 *
 * `/subtitle?url=&h=&f=` is what `PlayInfo.subtitles` point at: the engine fetches the site's file (with the play
 * answer's request headers, `h`, URL-safe base64 of a JSON object) and gives the player UTF-8 text in a format libmpv
 * reads (`f` is the format the site named, used when the text does not tell). It sits outside `/api/` because players
 * open it: LAN players get it signed (see `AccessPlugin`).
 */
fun Route.mediaExtrasRoutes(engine: Engine) {
    get("/subtitle") {
        val url = call.parameters["url"].orEmpty()
        if (!url.startsWith("http://") && !url.startsWith("https://")) throw BadRequestException("url is required")
        val headers = call.parameters["h"]?.let { h ->
            runCatching { Json.parseToJsonElement(String(Base64Compat.decode(h))).jsonObject.mapValues { (it.value as JsonPrimitive).content } }.getOrNull()
        } ?: emptyMap()
        val converted = engine.subtitle(url, headers, call.parameters["f"].orEmpty())
        call.respondText(converted.text, ContentType.parse(converted.contentType))
    }

    // A subtitle file from the client's disk, in whatever encoding and format: back as UTF-8 the player reads.
    post("/api/v1/subtitle/convert") {
        val (name, bytes) = call.receiveFile()
        val converted = SubtitleConverter.convert(bytes, hint = Subtitles.formatOfName(name))
        call.respond(ConvertedSubtitle(converted.format, converted.text))
    }
}

@Serializable
data class ConvertedSubtitle(val format: String, val text: String)

/** `{name, data}` with the file's bytes as base64; at most [MAX_UPLOAD] of them. */
@Serializable
data class FileUpload(val name: String = "", val data: String = "")

private const val MAX_UPLOAD = 32 * 1024 * 1024

internal suspend fun ApplicationCall.receiveFile(): Pair<String, ByteArray> {
    val upload = receive<FileUpload>()
    val bytes = runCatching { Base64Compat.decode(upload.data) }.getOrNull() ?: throw BadRequestException("data must be base64")
    if (bytes.isEmpty()) throw BadRequestException("the file is empty")
    if (bytes.size > MAX_UPLOAD) throw BadRequestException("the file is too big")
    return upload.name to bytes
}
