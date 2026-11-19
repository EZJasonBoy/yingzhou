package tvbox.next.tvbox_client

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Tells the Flutter side what kind of device this is: a TV, or a phone / tablet (client/lib/ui/device_form.dart). */
object DeviceChannel {
    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, "yingzhou/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info(app))
                else -> result.notImplemented()
            }
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
}
