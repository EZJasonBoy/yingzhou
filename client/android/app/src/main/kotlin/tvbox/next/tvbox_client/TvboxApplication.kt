package tvbox.next.tvbox_client

import android.app.Application
import tvbox.next.tvbox_client.engine.EmbeddedEngine

/** Starts the embedded engine with the process, before the Flutter UI connects to it. */
class TvboxApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        EmbeddedEngine.start(this)
    }
}
