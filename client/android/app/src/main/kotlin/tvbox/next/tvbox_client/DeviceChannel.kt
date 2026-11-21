package tvbox.next.tvbox_client

import android.app.Activity
import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Tells the Flutter side what kind of device this is: a TV, or a phone / tablet (client/lib/ui/device_form.dart). */
object DeviceChannel {
    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "yingzhou/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info(app))
                "openUrl" -> result.success(openUrl(context, call.argument<String>("url").orEmpty()))
                "openUpdate" -> try {
                    openUpdate(context, call.argument<String>("path").orEmpty())
                    result.success(null)
                } catch (error: Exception) {
                    result.error("INSTALLER", error.message ?: "无法打开系统安装程序", null)
                }
                else -> result.notImplemented()
            }
        }
        // With a D-pad or a keyboard Android outlines the focused view, which here is the whole Flutter view; the app
        // draws its own focus. The Flutter view is created after this, so it is caught when it takes the focus.
        (context as? Activity)?.window?.decorView?.let { root ->
            root.viewTreeObserver.addOnGlobalFocusChangeListener { _, focused -> focused?.let { noFocusHighlight(it) } }
            root.post { noFocusHighlight(root) }
        }
    }

    private fun openUpdate(context: Context, path: String) {
        val directory = File(context.filesDir, "updates").canonicalFile
        val file = File(path).canonicalFile
        require(file.parentFile == directory && file.extension.equals("apk", ignoreCase = true) && file.isFile) { "找不到已下载的安装包，请重新下载" }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            throw IllegalStateException("允许映舟安装应用后，请返回并再次点「打开安装包」")
        }
        val uri = FileProvider.getUriForFile(context, context.packageName + ".exports", file)
        val install = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(install)
    }

    fun info(context: Context): Map<String, Any> {
        val ui = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val pm = context.packageManager
        return mapOf(
            "tv" to (ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION),
            "leanback" to (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) || pm.hasSystemFeature("android.software.leanback_only")),
            "touchscreen" to pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN),
        )
    }

    private fun openUrl(context: Context, url: String): Boolean {
        if (!url.startsWith("https://") && !url.startsWith("http://")) return false
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private fun noFocusHighlight(view: View) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) view.defaultFocusHighlightEnabled = false
        if (view is ViewGroup) for (i in 0 until view.childCount) noFocusHighlight(view.getChildAt(i))
    }
}
