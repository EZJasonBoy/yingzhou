package tvbox.next.tvbox_client

import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // Phone and tablet playback: brightness, media volume, keep-screen-on, picture-in-picture.
    private var playback: PlaybackChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DeviceChannel.register(flutterEngine, this)
        playback = PlaybackChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        playback?.dispose()
        playback = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        playback?.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        playback?.onPictureInPictureModeChanged(isInPictureInPictureMode)
    }
}
