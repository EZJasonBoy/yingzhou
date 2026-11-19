package tvbox.next.tvbox_client.engine

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * `yingzhou/android`: what the Flutter side asks of Android for downloads (client/lib/engine/download_files_io.dart).
 *
 * - `share` {uri, title}: the share sheet for an exported file (a `content://` address from an export).
 * - `saveExport` {url, token}: fetches the export of a download from an engine on another device straight into the
 *   system's Downloads; answers {path, bytes, uri}.
 */
object AndroidChannel {
    const val NAME = "yingzhou/android"

    fun attach(activity: Activity, engine: FlutterEngine) {
        val main = Handler(Looper.getMainLooper())
        MethodChannel(engine.dartExecutor.binaryMessenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "share" -> try {
                    AndroidExports.share(activity, call.argument<String>("uri").orEmpty(), call.argument<String>("title") ?: "分享")
                    result.success(null)
                } catch (x: Exception) {
                    result.error("SHARE_FAILED", x.message ?: x.javaClass.simpleName, null)
                }
                "saveExport" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val token = call.argument<String>("token")
                    if (!url.startsWith("http://") && !url.startsWith("https://")) {
                        result.error("BAD_URL", "not an engine address", null)
                        return@setMethodCallHandler
                    }
                    thread(name = "save-export", isDaemon = true) {
                        try {
                            val saved = AndroidExports.saveFromEngine(activity.applicationContext, url, token)
                            main.post { result.success(mapOf("path" to saved.path, "bytes" to saved.bytes, "uri" to saved.uri.toString())) }
                        } catch (x: Exception) {
                            main.post { result.error("EXPORT_FAILED", x.message ?: x.javaClass.simpleName, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
