package tvbox.next.tvbox_client

import android.app.Application
import tvbox.next.tvbox_client.engine.EmbeddedEngine

/** Starts the embedded engine with the process, before the Flutter UI connects to it. */
class TvboxApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Crash records of the app and its embedded engine, for the diagnostics page (see CrashRecorder).
        CrashRecorder.install(this)
        EmbeddedEngine.start(this)
    }
}
