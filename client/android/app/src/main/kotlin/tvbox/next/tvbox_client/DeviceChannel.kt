package tvbox.next.tvbox_client

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * What kind of device this is, for the client's `FormFactors` (lib/ui/form_factor.dart): channel `yingzhou/device`,
 * method `info` → `{tv: Boolean, touchscreen: Boolean}`.
 *
 * A TV is one whose UI mode is television, or that has the leanback feature, or that has no touchscreen at all: many
 * boxes run phone Android and declare neither of the first two.
 */
object DeviceChannel {
    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, "yingzhou/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(mapOf("tv" to isTv(app), "touchscreen" to hasTouchscreen(app), "emulator" to isEmulator()))
                else -> result.notImplemented()
            }
        }
    }

    fun isTv(context: Context): Boolean {
        val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        val pm = context.packageManager
        @Suppress("DEPRECATION")
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) || pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION)) return true
        return !hasTouchscreen(context)
    }

    private fun hasTouchscreen(context: Context): Boolean = context.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)

    /** The Android emulator (its GL cannot host libmpv's video output; see lib/player_backend.dart). */
    fun isEmulator(): Boolean =
        Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish" || Build.FINGERPRINT.startsWith("generic") || Build.PRODUCT.contains("sdk_gphone")
}
