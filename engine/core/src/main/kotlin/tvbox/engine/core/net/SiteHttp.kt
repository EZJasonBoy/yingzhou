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

/** A request to a site failed (network, HTTP status, timeout). [status] is the HTTP status when there was one, else 0. */
class SiteHttpException(message: String, cause: Throwable? = null, val status: Int = 0) : IOException(message, cause)

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

    /** GET returning the raw body (gzipped files, images). */
    suspend fun getBytes(url: String, headers: Map<String, String> = emptyMap(), timeoutMs: Long = DEFAULT_TIMEOUT_MS): ByteArray {
        val base = url.toHttpUrlOrNull() ?: throw SiteHttpException("invalid url: $url")
        return execute(Request.Builder().url(base).headers(headers), timeoutMs) { it.body?.bytes() ?: ByteArray(0) }
    }

    /**
     * GET returning at most [maxBytes] of the body, sent exactly where [url] says: the GitHub proxy setting does not
     * reroute it (see [GithubProxy.probe]).
     */
    suspend fun getAsWritten(url: String, timeoutMs: Long = DEFAULT_TIMEOUT_MS, maxBytes: Long = 64 * 1024): String {
        val base = url.toHttpUrlOrNull() ?: throw SiteHttpException("invalid url: $url")
        val request = Request.Builder().url(base).tag(GithubProxy.AsWritten::class.java, GithubProxy.AsWritten)
        return execute(request, timeoutMs) { it.peekBody(maxBytes).string() }
    }

    /**
     * GET handing the response to [read] as soon as its headers are in, for a caller that reads the body as it arrives
     * and stops when it has seen enough (the line probe times the start of a video this way). [read] runs on OkHttp's
     * thread and must catch what reading throws; the call is cancelled with the coroutine. An HTTP error status throws
     * as for [get], with [SiteHttpException.status]. [connectTimeoutMs] (when above 0) gives up sooner on a host that
     * does not answer at all, which then fails with a connect timeout rather than [timeoutMs]'s.
     */
    suspend fun <T> open(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Long = DEFAULT_TIMEOUT_MS,
        connectTimeoutMs: Long = 0,
        read: (Response) -> T,
    ): T {
        val base = url.toHttpUrlOrNull() ?: throw SiteHttpException("invalid url: $url")
        return execute(Request.Builder().url(base).headers(headers), timeoutMs, connectTimeoutMs, read)
    }

    private suspend fun execute(builder: Request.Builder, timeoutMs: Long): Pair<String, String> =
        execute(builder, timeoutMs) { (it.body?.string() ?: "") to it.request.url.toString() }

    private suspend fun <T> execute(builder: Request.Builder, timeoutMs: Long, connectTimeoutMs: Long = 0, read: (Response) -> T): T {
        val call = client.newBuilder().callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .apply { if (connectTimeoutMs > 0) connectTimeout(connectTimeoutMs, TimeUnit.MILLISECONDS) }
            .build().newCall(builder.build())
        return suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resumeWithException(SiteHttpException(describe(call, e), e))
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use {
                        if (!it.isSuccessful) {
                            cont.resumeWithException(SiteHttpException("HTTP ${it.code} from ${call.request().url.host}", status = it.code))
                            return
                        }
                        val value = try {
                            read(it)
                        } catch (e: IOException) {
                            cont.resumeWithException(SiteHttpException(describe(call, e), e))
                            return
                        }
                        cont.resume(value)
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
