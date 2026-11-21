package tvbox.next.tvbox_client.engine

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Application
import android.net.http.SslError
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import tvbox.engine.core.model.SniffRequest
import tvbox.engine.core.net.NetworkProxy
import tvbox.engine.core.play.SniffResult
import tvbox.engine.core.play.Sniffer
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/**
 * Sniffing on Android, like TVBox: a WebView loads the page with the site's headers and the first request the sniff
 * rules accept wins. The WebView is attached (1x1, transparent) to the visible activity when there is one, since
 * some players only start loading inside a window; otherwise it runs detached.
 */
class WebViewSniffer(private val app: Application, private val proxy: NetworkProxy) : Sniffer {
    private val main = Handler(Looper.getMainLooper())
    private val sniffLock = Mutex()
    @Volatile private var resumed: WeakReference<Activity>? = null

    init {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                resumed = WeakReference(activity)
            }

            override fun onActivityPaused(activity: Activity) {
                if (resumed?.get() === activity) resumed = null
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    override suspend fun sniff(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult? = sniffLock.withLock {
        val endpoint = proxy.endpoint(NetworkProxy.PLAYBACK)
        if (endpoint.isEmpty()) return@withLock load(request, isMedia)
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) throw IllegalStateException("当前 Android System WebView 不支持播放解析代理，请更新 WebView")
        val config = ProxyConfig.Builder().addProxyRule("http://$endpoint").apply { NetworkProxy.browserBypass.forEach { addBypassRule(it) } }.build()
        try {
            setProxy(config)
            load(request, isMedia)
        } finally {
            withContext(NonCancellable) { setProxy(null) }
        }
    }

    private suspend fun setProxy(config: ProxyConfig?) = withContext(Dispatchers.Main.immediate) {
        kotlin.coroutines.suspendCoroutine<Unit> { continuation ->
            val executor = java.util.concurrent.Executor { it.run() }
            val complete = Runnable { continuation.resume(Unit) }
            val controller = ProxyController.getInstance()
            if (config == null) controller.clearProxyOverride(executor, complete) else controller.setProxyOverride(config, executor, complete)
        }
    }

    private suspend fun load(request: SniffRequest, isMedia: (String) -> Boolean): SniffResult? {
        var web: WebView? = null
        try {
            return withTimeoutOrNull(request.timeoutMs) {
                suspendCancellableCoroutine { cont ->
                    val done = AtomicBoolean(false)
                    main.post {
                        if (!cont.isActive) return@post
                        val view = createWebView(request)
                        web = view
                        view.webViewClient = SniffClient(isMedia, request.scripts) { url, sent ->
                            if (done.compareAndSet(false, true)) cont.resume(SniffResult(url, keptHeaders(url, sent, request)))
                        }
                        val extra = request.headers.filterKeys { !it.equals("User-Agent", true) }
                        view.loadUrl(request.pageUrl, extra)
                    }
                }
            }
        } finally {
            main.post { web?.let(::dispose) }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWebView(request: SniffRequest): WebView {
        val activity = resumed?.get()
        val view = WebView(activity ?: app)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            blockNetworkImage = true
            loadsImagesAutomatically = false
            javaScriptCanOpenWindowsAutomatically = false
            request.headers.entries.firstOrNull { it.key.equals("User-Agent", true) }?.value?.let { userAgentString = it }
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        if (activity != null && !activity.isFinishing) {
            view.alpha = 0f
            (activity.window.decorView as? ViewGroup)?.addView(view, ViewGroup.LayoutParams(1, 1))
        }
        return view
    }

    private fun dispose(view: WebView) {
        runCatching {
            view.stopLoading()
            (view.parent as? ViewGroup)?.removeView(view)
            view.loadUrl("about:blank")
            view.destroy()
        }
    }

    private fun keptHeaders(url: String, sent: Map<String, String>, request: SniffRequest): Map<String, String> {
        val headers = LinkedHashMap<String, String>()
        for ((k, v) in sent) if (k.lowercase() in KEPT) headers[k] = v
        if (headers.keys.none { it.equals("Referer", true) }) headers["Referer"] = request.pageUrl
        CookieManager.getInstance().getCookie(url)?.takeIf { it.isNotEmpty() }?.let { headers["Cookie"] = it }
        return headers
    }

    private class SniffClient(
        private val isMedia: (String) -> Boolean,
        private val scripts: List<String>,
        private val onMedia: (String, Map<String, String>) -> Unit,
    ) : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url.toString()
            if (isMedia(url)) onMedia(url, request.requestHeaders ?: emptyMap())
            return null
        }

        // The config's click scripts for this page (TVBox runs them when the page has finished loading).
        override fun onPageFinished(view: WebView, url: String) {
            for (script in scripts) view.evaluateJavascript("(function(){try{$script\n}catch(e){}})()", null)
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            // Players sometimes navigate to the stream itself.
            val url = request.url.toString()
            if (isMedia(url)) {
                onMedia(url, request.requestHeaders ?: emptyMap())
                return true
            }
            return false
        }

        @SuppressLint("WebViewClientOnReceivedSslError")
        override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
            // Only used to find a stream url on parser pages, which often have broken certificates (TVBox does the same).
            handler.proceed()
        }
    }

    private companion object {
        val KEPT = setOf("referer", "user-agent", "origin")
    }
}

