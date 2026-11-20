package tvbox.next.tvbox_client

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * `yingzhou/diagnostics`: what the diagnostics page (client/lib/diagnostics/) asks of Android.
 *
 * - `info`: {release, sdk, manufacturer, model, dir}: the system and the folder [CrashRecorder] writes to.
 * - `logcat` {lines}: the last lines of this app's own log (an app may read its own without a permission); the
 *   embedded engine logs there.
 * - `openUrl` {url}: opens an http(s) address in the browser; false when there is none (many TVs).
 */
object DiagnosticsChannel {
    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        MethodChannel(engine.dartExecutor.binaryMessenger, "yingzhou/diagnostics").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(
                    mapOf(
                        "release" to Build.VERSION.RELEASE,
                        "sdk" to Build.VERSION.SDK_INT,
                        "manufacturer" to Build.MANUFACTURER,
                        "model" to Build.MODEL,
                        "dir" to CrashRecorder.dir(app).path,
                    ),
                )
                "logcat" -> {
                    val lines = (call.argument<Int>("lines") ?: 300).coerceIn(1, 2000)
                    thread(name = "logcat", isDaemon = true) {
                        val text = try {
                            logcat(lines)
                        } catch (e: Exception) {
                            "（读不到日志：${e.message ?: e.javaClass.simpleName}）"
                        }
                        main.post { result.success(text) }
                    }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url").orEmpty()
                    if (!url.startsWith("https://") && !url.startsWith("http://")) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: ActivityNotFoundException) {
                        result.success(false)
                    } catch (e: SecurityException) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun logcat(lines: Int): String {
        val pid = android.os.Process.myPid()
        val command = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            listOf("logcat", "-d", "-v", "time", "-t", "$lines", "--pid=$pid")
        } else {
            listOf("logcat", "-d", "-v", "time", "-t", "$lines")
        }
        val process = ProcessBuilder(command).redirectErrorStream(true).start()
        val text = process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor()
        return text
    }
}
