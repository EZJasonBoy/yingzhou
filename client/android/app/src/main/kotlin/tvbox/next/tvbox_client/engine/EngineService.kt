package tvbox.next.tvbox_client.engine

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import tvbox.engine.core.download.DownloadManager
import tvbox.next.tvbox_client.MainActivity
import tvbox.next.tvbox_client.R

/**
 * The foreground service that keeps the engine's process alive while it has work ([EngineKeeper.Work]): downloads
 * (type `dataSync`) and LAN sharing (type `connectedDevice`). Its notification shows the download progress with
 * pause / cancel buttons, and 「局域网共享中」 with the address, the pairing code and a button that stops sharing.
 * While it runs the CPU and Wi-Fi stay awake, so downloads and other devices are not cut off when the screen goes
 * off. It stops itself when the work is done.
 *
 * Playing in the background is not its job: the player stops with the app's screen as before.
 */
class EngineService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var types = 0
    private var lastNotified = 0L
    private var notifyPending = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        channel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Foreground at once, whatever the intent and even when the work has just ended: Android wants that within
        // seconds of startForegroundService, or it stops the app.
        if (EngineKeeper.work.needed) {
            show(force = true)
        } else {
            runCatching { foreground(build(EngineKeeper.work), DOWNLOADS) }
        }
        when (intent?.action) {
            ACTION_PAUSE -> EngineKeeper.pauseAll()
            ACTION_CANCEL -> EngineKeeper.cancelAll()
            ACTION_STOP_SHARING -> EngineKeeper.stopSharing()
        }
        if (!EngineKeeper.work.needed) finish()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        release()
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** Android 15: a `dataSync` service may run six hours a day. Then only sharing keeps it, or it stops. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "foreground time is up for type $fgsType")
        timedOut = timedOut or fgsType
        if (EngineKeeper.work.sharing && fgsType != SHARING) show(force = true) else finish()
    }

    @Deprecated("Android 14 and earlier")
    override fun onTimeout(startId: Int) = onTimeout(startId, DOWNLOADS)

    private var timedOut = 0

    /** Puts the notification up to date (at most once a second unless [force]); stops when there is nothing to do. */
    private fun show(force: Boolean = false) {
        val work = EngineKeeper.work
        if (!work.needed) {
            finish()
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (!force && now - lastNotified < MIN_GAP_MS) {
            if (!notifyPending) {
                notifyPending = true
                main.postDelayed({ notifyPending = false; show() }, MIN_GAP_MS - (now - lastNotified))
            }
            return
        }
        lastNotified = now
        val notification = build(work)
        val wanted = (if (work.downloading) DOWNLOADS else 0) or (if (work.sharing) SHARING else 0)
        val allowed = wanted and timedOut.inv()
        try {
            if (force || allowed != types) {
                foreground(notification, allowed.takeIf { it != 0 } ?: wanted)
                types = allowed
            } else {
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification)
            }
        } catch (x: Exception) {
            // E.g. a type that may not start from the background on this version: keep what runs, show the news.
            Log.w(TAG, "startForeground: ${x.message}")
            runCatching { (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification) }
        }
        hold()
    }

    private fun foreground(notification: Notification, types: Int) {
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, types) else startForeground(NOTIFICATION_ID, notification)
    }

    private fun finish() {
        release()
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }

    private fun build(work: EngineKeeper.Work): Notification {
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        b.setSmallIcon(R.drawable.ic_engine_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(if (work.downloading) Notification.CATEGORY_PROGRESS else Notification.CATEGORY_SERVICE)
            // The pairing code is not for the lock screen.
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setContentIntent(open())
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        val lanLine = if (work.sharing) sharingText(work) else null
        if (work.downloading) {
            val running = work.active.filter { it.state == DownloadManager.RUNNING }
            val shown = running.firstOrNull() ?: work.active.first()
            val title = if (work.active.size == 1) "正在下载《${shown.title}》${shown.episodeName}" else "正在下载 ${work.active.size} 集"
            val parts = ArrayList<String>()
            if (work.active.size > 1) parts += "《${shown.title}》${shown.episodeName}"
            parts += if (shown.state == DownloadManager.RUNNING) {
                listOfNotNull("${(shown.progress * 100).toInt()}%", shown.speed.takeIf { it > 0 }?.let { speed(it) }).joinToString(" · ")
            } else {
                "排队中"
            }
            val waiting = work.active.size - running.size
            if (work.active.size > 1 && waiting > 0) parts += "$waiting 集排队"
            b.setContentTitle(title).setContentText(parts.joinToString(" · "))
            val known = shown.state == DownloadManager.RUNNING && shown.progress > 0
            b.setProgress(1000, (shown.progress * 1000).toInt().coerceIn(0, 1000), !known)
            if (lanLine != null) b.setSubText("局域网共享中")
            val all = work.active.size > 1
            b.addAction(action(ACTION_PAUSE, if (all) "全部暂停" else "暂停", 1))
            b.addAction(action(ACTION_CANCEL, if (all) "全部取消" else "取消", 2))
        } else if (lanLine != null) {
            b.setContentTitle("局域网共享中").setContentText(lanLine)
            b.setStyle(Notification.BigTextStyle().bigText(lanLine))
        } else {
            // Only for the moment between the work ending and the service stopping.
            b.setContentTitle("映舟").setContentText("正在结束…")
        }
        if (work.sharing) b.addAction(action(ACTION_STOP_SHARING, "停止共享", 3))
        return b.build()
    }

    private fun sharingText(work: EngineKeeper.Work): String {
        val where = if (work.addresses.isEmpty()) "还没有连上局域网" else "其他设备连接 " + work.addresses.joinToString("  ")
        return if (work.code.isEmpty()) where else "$where · 配对码 ${work.code}"
    }

    private fun open(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun action(what: String, label: String, code: Int): Notification.Action {
        val intent = PendingIntent.getService(this, code, Intent(this, EngineService::class.java).setAction(what), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Action.Builder(Icon.createWithResource(this, R.drawable.ic_engine_notification), label, intent).build()
    }

    /** CPU and Wi-Fi stay on while the service runs. */
    private fun hold() {
        if (wake == null) {
            wake = (getSystemService(Context.POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "yingzhou:engine").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifi == null) {
            wifi = runCatching {
                @Suppress("DEPRECATION")
                (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "yingzhou:engine").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }.getOrNull()
        }
    }

    private fun release() {
        runCatching { wake?.takeIf { it.isHeld }?.release() }
        runCatching { wifi?.takeIf { it.isHeld }?.release() }
        wake = null
        wifi = null
    }

    companion object {
        private const val TAG = "EngineService"
        private const val CHANNEL = "engine"
        private const val NOTIFICATION_ID = 9978
        private const val MIN_GAP_MS = 1000L
        const val ACTION_PAUSE = "tvbox.next.engine.PAUSE"
        const val ACTION_CANCEL = "tvbox.next.engine.CANCEL"
        const val ACTION_STOP_SHARING = "tvbox.next.engine.STOP_SHARING"
        private val DOWNLOADS = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        private val SHARING = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0

        @Volatile private var instance: EngineService? = null

        val running: Boolean get() = instance != null

        /** The work changed: show it (or stop). Main thread. */
        fun refresh() {
            instance?.show()
        }

        private fun speed(bytesPerSecond: Long): String = when {
            bytesPerSecond >= 1024 * 1024 -> String.format("%.1f MB/s", bytesPerSecond / 1048576.0)
            else -> "${bytesPerSecond / 1024} KB/s"
        }

        fun channel(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "下载与局域网共享", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "离线下载的进度；局域网共享开着时的地址和配对码"
                    setShowBadge(false)
                },
            )
        }
    }
}
