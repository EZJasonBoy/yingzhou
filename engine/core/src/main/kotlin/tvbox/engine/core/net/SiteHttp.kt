package tvbox.engine.core.net

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A request to a site failed (network, HTTP status, timeout). */
class SiteHttpException(message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * Suspending HTTP for site calls. No User-Agent is set, so OkHttp sends its default `okhttp/x.y.z`,
 * like TVBox (which uses OkHttp's `Version.userAgent()`).
 */
class SiteHttp(private val client: OkHttpClient) {

    suspend fun get(
        url: String,
        params: List<Pair<String, String>> = emptyList(),
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    ): String {
        val base = url.toHttpUrlOrNull() ?: throw SiteHttpException("invalid url: $url")
        val full = base.newBuilder().apply { params.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
        return execute(Request.Builder().url(full).headers(headers), timeoutMs).first
    }

    /** GET returning the body and the final url after redirects (to resolve relative references). */
    suspend fun getWithUrl(url: String, headers: Map<String, String> = emptyMap(), timeoutMs: Long = DEFAULT_TIMEOUT_MS): Pair<String, String> {
        val base = url.toHttpUrlOrNull() ?: throw SiteHttpException("invalid url: $url")
        return execute(Request.Builder().url(base).headers(headers), timeoutMs)
    }

    suspend fun postForm(
        url: String,
        form: List<Pair<String, String>>,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    ): String {
        val base: HttpUrl = url.toHttpUrlOrNull() ?: throw SiteHttpException("invalid url: $url")
        val body = FormBody.Builder().apply { form.forEach { (k, v) -> add(k, v) } }.build()
        return execute(Request.Builder().url(base).headers(headers).post(body), timeoutMs).first
    }

    private suspend fun execute(builder: Request.Builder, timeoutMs: Long): Pair<String, String> {
        val call = client.newBuilder().callTimeout(timeoutMs, TimeUnit.MILLISECONDS).build().newCall(builder.build())
        return suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resumeWithException(SiteHttpException(describe(call, e), e))
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use {
                        if (!it.isSuccessful) {
                            cont.resumeWithException(SiteHttpException("HTTP ${it.code} from ${call.request().url.host}"))
                            return
                        }
                        val text = try {
                            it.body?.string() ?: ""
                        } catch (e: IOException) {
                            cont.resumeWithException(SiteHttpException(describe(call, e), e))
                            return
                        }
                        cont.resume(text to it.request.url.toString())
                    }
                }
            })
        }
    }

    private fun describe(call: Call, e: IOException): String {
        val host = call.request().url.host
        return if (e is java.io.InterruptedIOException) "timeout talking to $host" else "${e.message ?: e.javaClass.simpleName} ($host)"
    }

    private fun Request.Builder.headers(headers: Map<String, String>): Request.Builder = apply {
        headers.forEach { (k, v) -> runCatching { header(k, v) } }
    }

    companion object {
        const val DEFAULT_TIMEOUT_MS = 15_000L
    }
}
