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
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Tells the Flutter side what kind of device this is: a TV, or a phone / tablet (client/lib/ui/device_form.dart). */
object DeviceChannel {
    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "yingzhou/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info(app))
                // An address in the browser (an update's APK); false when nothing can open it (a box without one).
                "openUrl" -> result.success(openUrl(context, call.argument<String>("url").orEmpty()))
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
