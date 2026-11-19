package tvbox.next.tvbox_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DeviceChannel.register(flutterEngine, this)
        // Share sheet and Downloads for exports of downloads (see AndroidChannel).
        tvbox.next.tvbox_client.engine.AndroidChannel.attach(this, flutterEngine)
    }
}
