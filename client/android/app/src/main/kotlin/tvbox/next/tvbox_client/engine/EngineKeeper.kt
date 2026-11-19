package tvbox.next.tvbox_client.engine

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import tvbox.engine.api.access.AccessControl
import tvbox.engine.core.download.DownloadManager
import tvbox.engine.core.model.DownloadItem
import java.lang.ref.WeakReference

/**
 * Keeps the engine alive while it has work: Android stops background processes, so while a download is queued or
 * running, or while LAN sharing is on, [EngineService] runs in the foreground with a notification. The keeper watches
 * both, starts the service when work begins and lets it stop when the work ends, and asks for the notification
 * permission (Android 13+) the first time it is needed.
 */
object EngineKeeper {
    private const val TAG = "EngineKeeper"
    private const val PREFS = "engine-keeper"
    private const val ASKED = "askedNotifications"
    private const val PERMISSION_REQUEST = 7301

    /** What the notification shows; read by [EngineService]. */
    data class Work(
        val active: List<DownloadItem> = emptyList(),
        val sharing: Boolean = false,
        val addresses: List<String> = emptyList(),
        val code: String = "",
    ) {
        val downloading: Boolean get() = active.isNotEmpty()
        val needed: Boolean get() = downloading || sharing
    }

    private lateinit var app: Application
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile private var downloads: DownloadManager? = null
    @Volatile private var access: AccessControl? = null
    @Volatile private var lan: AndroidLan? = null
    @Volatile private var sharing = false
    @Volatile private var resumed: WeakReference<Activity>? = null

    @Volatile var work = Work()
        private set

    /** Called with the process, before the engine starts. */
    fun init(application: Application) {
        app = application
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                resumed = WeakReference(activity)
                // The permission was wanted while no screen of the app was showing.
                if (work.needed) askForNotifications()
            }

            override fun onActivityPaused(activity: Activity) {
                if (resumed?.get() === activity) resumed = null
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }

    /** The engine is up: watch its downloads and its sharing switch. */
    fun attach(downloads: DownloadManager, access: AccessControl, lan: AndroidLan) {
        this.downloads = downloads
        this.access = access
        this.lan = lan
        sharing = lan.listeners.sharing
        // A new pairing code shows in the notification.
        access.onCode = { _, _ -> update() }
        scope.launch {
            downloads.changes.collectLatest { update() }
        }
        update()
    }

    /** From [AndroidLan]: sharing was switched on or off. */
    fun sharingChanged(on: Boolean) {
        sharing = on
        update()
    }

    /**
     * Works out what is going on, and starts, updates or lets go of the service accordingly. Runs on a thread of its
     * own (callers may hold the engine's locks); calls that come while one is waiting are folded into it.
     */
    fun update() {
        if (!pending.compareAndSet(false, true)) return
        worker.execute {
            pending.set(false)
            val d = downloads ?: return@execute
            val active = runCatching { d.list() }.getOrDefault(emptyList()).filter { it.state == DownloadManager.RUNNING || it.state == DownloadManager.QUEUED }
            val status = if (sharing) lan?.listeners?.status() else null
            val code = if (sharing) access?.currentCode()?.code.orEmpty() else ""
            val next = Work(active, sharing, status?.addresses.orEmpty(), code)
            val before = work
            work = next
            main.post {
                when {
                    next.needed && !before.needed -> start()
                    next.needed || before.needed -> EngineService.refresh()
                }
            }
        }
    }

    private val pending = java.util.concurrent.atomic.AtomicBoolean(false)
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "engine-keeper").apply { isDaemon = true } }

    /** What the notification's buttons do. */
    fun pauseAll() {
        val d = downloads ?: return
        scope.launch {
            d.list().filter { it.state == DownloadManager.RUNNING || it.state == DownloadManager.QUEUED }.forEach { runCatching { d.pause(it.id) } }
        }
    }

    fun cancelAll() {
        val d = downloads ?: return
        scope.launch {
            d.list().filter { it.state == DownloadManager.RUNNING || it.state == DownloadManager.QUEUED }.forEach { runCatching { d.delete(it.id) } }
        }
    }

    fun stopSharing() {
        val a = access ?: return
        scope.launch {
            a.setSharing(false)
            lan?.listeners?.apply(false)
        }
    }

    private fun start() {
        askForNotifications()
        if (EngineService.running) {
            EngineService.refresh()
            return
        }
        val intent = Intent(app, EngineService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent) else app.startService(intent)
        } catch (x: Exception) {
            // Android 12+ does not let an app in the background start a foreground service (e.g. a paired device
            // queued a download while the app was not showing). The work goes on while the process lives.
            Log.w(TAG, "could not start the foreground service: ${x.message}")
        }
    }

    /** Asks once (Android 13+) for the permission to show the service's notification, when a screen of the app is showing. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(ASKED, false)) return
        val activity = resumed?.get() ?: return
        prefs.edit().putBoolean(ASKED, true).apply()
        main.post { runCatching { activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST) } }
    }
}
