package tvbox.engine.js

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.nio.charset.Charset
import tvbox.engine.core.util.Base64Compat
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/**
 * `req` / `_http` for JS spiders (port of TVBox `Req` + `Connect`). Options and the result travel as JSON text
 * so that no QuickJS object conversion is involved.
 *
 * Options: `method` (get | post | header), `headers`, `postType` (json | form | form-data), `data`, `body`,
 * `buffer` (0 text, 1 byte array, 2 base64), `timeout` (ms, default 10000), `redirect` (1 follow, 0 not).
 * Result: `{ headers, content }`; on failure `{ headers: {}, content: "" }`.
 */
class JsHttp(private val client: OkHttpClient) {

    fun request(url: String, optionsJson: String): String {
        val options = runCatching { JsonParser.parseString(optionsJson).asJsonObject }.getOrNull() ?: JsonObject()
        return try {
            val call = clientFor(options).newCall(buildRequest(url, options))
            call.execute().use { success(it, options) }
        } catch (e: Exception) {
            ERROR
        }
    }

    private fun clientFor(options: JsonObject): OkHttpClient {
        val timeout = options.int("timeout") ?: 10_000
        val redirect = (options.int("redirect") ?: 1) == 1
        return client.newBuilder()
            .callTimeout(timeout.toLong().coerceIn(1_000, 120_000), TimeUnit.MILLISECONDS)
            .followRedirects(redirect)
            .followSslRedirects(redirect)
            .build()
    }

    private fun buildRequest(url: String, options: JsonObject): Request {
        val headers = Headers.Builder().apply {
            stringMap(options.get("headers")).forEach { (k, v) -> runCatching { add(k, v) } }
        }.build()
        val builder = Request.Builder().url(url).headers(headers)
        when ((options.str("method") ?: "get").lowercase()) {
            "post" -> builder.post(postBody(options, headers["Content-Type"]))
            "header", "head" -> builder.head()
            else -> builder.get()
        }
        return builder.build()
    }

    private fun postBody(options: JsonObject, contentType: String?): RequestBody {
        val data = options.get("data")?.takeUnless { it.isJsonNull }
        val postType = options.str("postType")?.ifEmpty { null } ?: "json"
        if (data != null) {
            when (postType) {
                "json" -> return data.toString().toRequestBody("application/json".toMediaTypeOrNull())
                "form" -> return FormBody.Builder().apply { stringMap(data).forEach { (k, v) -> add(k, v) } }.build()
                "form-data" -> {
                    val boundary = "--dio-boundary-" + Random.nextInt(42949) + Random.nextInt(67296)
                    return MultipartBody.Builder(boundary).setType(MultipartBody.FORM)
                        .apply { stringMap(data).forEach { (k, v) -> addFormDataPart(k, v) } }
                        .build()
                }
            }
        }
        val body = options.str("body")
        if (body != null && contentType != null) return body.toRequestBody(contentType.toMediaTypeOrNull())
        return "".toRequestBody(null)
    }

    private fun success(res: Response, options: JsonObject): String {
        val out = JsonObject()
        val headers = JsonObject()
        for ((name, values) in res.headers.toMultimap()) {
            if (values.size == 1) headers.addProperty(name, values[0])
            else headers.add(name, JsonArray().apply { values.forEach { add(it) } })
        }
        out.add("headers", headers)
        val bytes = res.body?.bytes() ?: ByteArray(0)
        when (options.int("buffer") ?: 0) {
            1 -> out.add("content", JsonArray().apply { bytes.forEach { add(it.toInt()) } })
            2 -> out.addProperty("content", Base64Compat.encode(bytes))
            else -> out.addProperty("content", String(bytes, charset(options)))
        }
        out.addProperty("code", res.code)
        return gson.toJson(out)
    }

    /** Like TVBox: the charset comes from the request's Content-Type header, default UTF-8. */
    private fun charset(options: JsonObject): Charset {
        val headers = stringMap(options.get("headers"))
        val contentType = headers["Content-Type"] ?: headers["content-type"] ?: return Charsets.UTF_8
        val name = contentType.split(";").firstOrNull { it.contains("charset=") }?.substringAfter("=")?.trim()
        return name?.let { runCatching { Charset.forName(it) }.getOrNull() } ?: Charsets.UTF_8
    }

    private fun stringMap(el: JsonElement?): Map<String, String> {
        val obj = when {
            el == null || el.isJsonNull -> return emptyMap()
            el.isJsonObject -> el.asJsonObject
            el.isJsonPrimitive -> runCatching { JsonParser.parseString(el.asString).asJsonObject }.getOrNull() ?: return emptyMap()
            else -> return emptyMap()
        }
        return obj.entrySet().associate { (k, v) -> k to (if (v.isJsonPrimitive) v.asString else v.toString()) }
    }

    private fun JsonObject.str(key: String): String? = get(key)?.takeIf { it.isJsonPrimitive }?.asString

    private fun JsonObject.int(key: String): Int? = str(key)?.toDoubleOrNull()?.toInt()

    companion object {
        private val gson = Gson()
        const val ERROR = """{"headers":{},"content":""}"""
    }
}
