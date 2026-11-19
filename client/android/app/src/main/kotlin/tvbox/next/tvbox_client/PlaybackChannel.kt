package tvbox.next.tvbox_client

import android.annotation.TargetApi
import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.util.Rational
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * What the players need from the phone itself (lib/mobile/playback_host.dart), channel `yingzhou/playback`:
 *
 * - `keepScreenOn {on}`: the screen does not go off while a video plays.
 * - `getBrightness` / `setBrightness {value}`: the brightness of this window only (0..1; null gives it back to the
 *   system), as phone video players do; the system's own setting is never changed.
 * - `getVolume` / `setVolume {value}`: the media volume (0..1), without the system's volume panel.
 * - `setPip {enabled, width, height, playing}` / `enterPip`: picture-in-picture. While enabled, leaving the app (home
 *   gesture, recent apps) shrinks the video into a window: Android 12+ does that by itself (auto-enter), earlier ones
 *   from [onUserLeaveHint]. The window has a play / pause button.
 *
 * Calls to Dart: `pip {inPip}` when the window goes in or out of picture-in-picture, `pipAction {action}` when its
 * button is pressed.
 */
class PlaybackChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "yingzhou/playback")
    private val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var pipEnabled = false
    private var pipAspect = Rational(16, 9)
    private var pipPlaying = true
    private var receiverRegistered = false
    private val pipAction = activity.packageName + ".PIP_ACTION"

    private val pipReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            channel.invokeMethod("pipAction", mapOf("action" to (intent.getStringExtra(EXTRA_ACTION) ?: "")))
        }
    }

    init {
        channel.setMethodCallHandler(::onCall)
    }

    private val pipSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "keepScreenOn" -> {
                    if (call.argument<Boolean>("on") == true) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "getBrightness" -> result.success(brightness())
                "setBrightness" -> {
                    val value = call.argument<Double>("value")
                    val attrs = activity.window.attributes
                    attrs.screenBrightness = value?.toFloat()?.coerceIn(0.01f, 1f) ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    activity.window.attributes = attrs
                    result.success(null)
                }
                "getVolume" -> result.success(volume())
                "setVolume" -> {
                    val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val value = call.argument<Double>("value") ?: 0.0
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, (value * max).roundToInt().coerceIn(0, max), 0)
                    result.success(volume())
                }
                "setPip" -> {
                    pipEnabled = call.argument<Boolean>("enabled") == true
                    pipPlaying = call.argument<Boolean>("playing") != false
                    val w = call.argument<Int>("width") ?: 0
                    val h = call.argument<Int>("height") ?: 0
                    pipAspect = aspect(w, h)
                    updatePipParams()
                    result.success(pipSupported)
                }
                "enterPip" -> result.success(enterPip())
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("playback", e.message, null)
        }
    }

    /** The window's brightness if the player set one, else the system's (its setting is 0..255 on most phones). */
    private fun brightness(): Double {
        val own = activity.window.attributes.screenBrightness
        if (own >= 0) return own.toDouble()
        val system = try {
            Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS)
        } catch (_: Settings.SettingNotFoundException) {
            128
        }
        return (system / 255.0).coerceIn(0.0, 1.0)
    }

    private fun volume(): Double {
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return if (max <= 0) 0.0 else audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max
    }

    /** The picture's shape, within what Android accepts for a picture-in-picture window (2.39:1 either way). */
    private fun aspect(w: Int, h: Int): Rational {
        if (w <= 0 || h <= 0) return Rational(16, 9)
        val ratio = w.toDouble() / h
        return when {
            ratio > 2.39 -> Rational(239, 100)
            ratio < 1 / 2.39 -> Rational(100, 239)
            else -> Rational(w, h)
        }
    }

    @TargetApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(pipAspect).setActions(listOf(playPauseAction()))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipEnabled)
            // Video: no cross-fade while the window is resized.
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    @TargetApi(Build.VERSION_CODES.O)
    private fun playPauseAction(): RemoteAction {
        val intent = Intent(pipAction).setPackage(activity.packageName).putExtra(EXTRA_ACTION, "toggle")
        val pending = PendingIntent.getBroadcast(activity, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val icon = Icon.createWithResource(activity, if (pipPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
        val title = if (pipPlaying) "暂停" else "播放"
        return RemoteAction(icon, title, title, pending)
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !pipSupported) return
        try {
            activity.setPictureInPictureParams(pipParams())
        } catch (e: Exception) {
            Log.w(TAG, "picture-in-picture params: $e")
        }
    }

    private fun enterPip(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !pipSupported) return false
        return try {
            activity.enterPictureInPictureMode(pipParams())
        } catch (e: Exception) {
            Log.w(TAG, "picture-in-picture: $e")
            false
        }
    }

    /** The user is leaving the app: before Android 12 picture-in-picture has to be entered here. */
    fun onUserLeaveHint() {
        if (pipEnabled && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    fun onPictureInPictureModeChanged(inPip: Boolean) {
        if (inPip && !receiverRegistered) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(pipReceiver, IntentFilter(pipAction), Context.RECEIVER_NOT_EXPORTED)
            } else {
                activity.registerReceiver(pipReceiver, IntentFilter(pipAction))
            }
            receiverRegistered = true
        } else if (!inPip && receiverRegistered) {
            activity.unregisterReceiver(pipReceiver)
            receiverRegistered = false
        }
        channel.invokeMethod("pip", mapOf("inPip" to inPip))
    }

    fun dispose() {
        if (receiverRegistered) {
            activity.unregisterReceiver(pipReceiver)
            receiverRegistered = false
        }
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val TAG = "yingzhou"
        const val EXTRA_ACTION = "action"
    }
}
