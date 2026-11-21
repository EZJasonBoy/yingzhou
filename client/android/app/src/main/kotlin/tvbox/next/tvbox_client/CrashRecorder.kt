package tvbox.next.tvbox_client

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Crash records on Android: an uncaught exception on any thread of the app (the UI, the embedded engine, a channel's
 * worker) is written to `<files>/diagnostics/crash-<time>-android.txt` before the process dies, in the format of
 * client/lib/diagnostics/crash_record.dart, so the diagnostics page lists it after the next start. The handler that
 * was there before still runs (Android's crash dialog, the process ending). Nothing is sent anywhere.
 */
object CrashRecorder {
    private const val TAG = "CrashRecorder"
    private const val DIR = "diagnostics"
    private const val MAX_RECORDS = 20
    private const val MAX_BYTES = 64 * 1024

    @Volatile private var installed = false

    /** The folder the Dart side reads as well (path_provider's support directory is the files directory). */
    fun dir(context: Context): File = File(context.applicationContext.filesDir, DIR)

    fun install(context: Context) {
        if (installed) return
        installed = true
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                record(app, "线程 ${thread.name} 里没有被处理的异常", error)
            } catch (ignored: Throwable) {
                // A crash record must not stop the crash from being handled.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** Writes a record of [error]; [what] says where it happened. Also used where the app catches a fatal error itself. */
    fun record(context: Context, what: String, error: Throwable) {
        try {
            val now = Date()
            val text = buildString {
                appendLine("映舟崩溃记录")
                appendLine("time: " + SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS XXX", Locale.ROOT).format(now))
                appendLine("version: " + version(context))
                appendLine("platform: " + platform())
                appendLine("form: " + form(context))
                appendLine("source: android")
                appendLine()
                appendLine("error:")
                appendLine(error.toString())
                appendLine("（$what）")
                appendLine()
                appendLine("stack:")
                append(Log.getStackTraceString(error).trimEnd())
                appendLine()
            }
            val dir = dir(context).apply { mkdirs() }
            val name = "crash-" + SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.ROOT).format(now) + "-android.txt"
            val bytes = text.toByteArray(Charsets.UTF_8)
            File(dir, name).writeBytes(if (bytes.size <= MAX_BYTES) bytes else bytes.copyOf(MAX_BYTES - 64) + "\n…（记录太长，后面的部分没有保存）\n".toByteArray())
            dir.listFiles { f -> f.name.startsWith("crash-") && f.name.endsWith(".txt") }
                ?.sortedByDescending { it.name }
                ?.drop(MAX_RECORDS)
                ?.forEach { it.delete() }
        } catch (e: Throwable) {
            Log.e(TAG, "could not write a crash record", e)
        }
    }

    private fun version(context: Context): String = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        "${info.versionName ?: "?"}+$code"
    } catch (ignored: Exception) {
        "未知"
    }

    fun platform(): String = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}"

    /**
     * The form as the Flutter side decides it (client/lib/ui/device_form.dart): the user's choice in 界面模式 (kept by
     * shared_preferences as `flutter.ui.form`), else what the system says.
     */
    private fun form(context: Context): String {
        val override = try {
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).getString("flutter.ui.form", null)
        } catch (ignored: Exception) {
            null
        }
        val info = DeviceChannel.info(context)
        val tv = when (override) {
            "tv" -> true
            "touch" -> false
            else -> info["tv"] == true || (info["leanback"] == true && info["touchscreen"] != true)
        }
        if (tv) return "tv"
        return if (context.resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "phone"
    }
}

