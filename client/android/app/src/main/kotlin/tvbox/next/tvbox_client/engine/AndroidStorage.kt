package tvbox.next.tvbox_client.engine

import android.content.Context
import android.os.Build
import android.os.Environment
import android.util.Log
import okhttp3.OkHttpClient
import tvbox.engine.core.Engine
import tvbox.engine.core.cache.StreamCache
import tvbox.engine.core.cache.StreamStore
import tvbox.engine.core.download.DownloadManager
import tvbox.engine.core.model.DownloadLocation
import tvbox.engine.core.store.JsonFileStore
import java.io.File

/**
 * Where the Android engine keeps video, on a device that may be short of space:
 *
 * - the stream cache in the app's cache folder (the system may clear it when space runs out, which the cache copes
 *   with), 1 GB by default instead of the desktop's 2 GB, and it never leaves less than [RESERVE] free;
 * - downloads in the app's folder on the shared storage (`Android/data/<app>/files/downloads`: no permission
 *   needed, kept until the app is uninstalled), or on an SD card or USB drive the user picks among
 *   [locations] — there is no folder a user could type in; downloads stop before less than [RESERVE] is left;
 * - exports go to the system's Downloads ([AndroidExports]).
 */
object AndroidStorage {
    private const val TAG = "EngineStorage"
    const val RESERVE = 500L * 1024 * 1024
    private const val DEFAULT_CACHE_MB = 1024

    fun streamCache(context: Context, client: OkHttpClient, data: File): StreamCache {
        smallerDefaultCache(data)
        val store = StreamStore(File(context.cacheDir, "stream"), DEFAULT_CACHE_MB * 1024L * 1024L, reserveBytes = RESERVE)
        return StreamCache(client, store, log = { Log.w(TAG, it) })
    }

    fun downloads(context: Context, client: OkHttpClient, data: File, engine: Engine, local: String): DownloadManager = DownloadManager(
        client,
        // Pinned throughout, so no cap.
        StreamStore(defaultDownloads(context), Long.MAX_VALUE),
        stateFile = File(data, "downloads.json"),
        resolver = { engine.config(); engine.resolvePlay(it) },
        cleaner = engine::cleanPlaylist,
        localBase = local,
        exportDir = { context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: File(context.filesDir, "exports") },
        reserveBytes = RESERVE,
        locations = { locations(context) },
        publish = { export -> AndroidExports.publish(context, export) },
        log = { Log.i(TAG, it) },
    )

    /** The app's own downloads folder on the shared storage, or in its private files when there is none. */
    private fun defaultDownloads(context: Context): File =
        File(context.getExternalFilesDir(null) ?: context.filesDir, "downloads").also { it.mkdirs() }

    /**
     * The app's folder on every storage volume that is there now: the shared (internal) storage first — that is the
     * default, `dir` "" — then SD cards and USB drives.
     */
    fun locations(context: Context): List<DownloadLocation> {
        val default = defaultDownloads(context)
        val primary = context.getExternalFilesDir(null)?.absoluteFile
        val volumes = context.getExternalFilesDirs(null).orEmpty().filterNotNull().map { it.absoluteFile }.filter { it != primary }
        val out = ArrayList<DownloadLocation>()
        out += DownloadLocation(
            name = if (primary == null) "应用内部" else "内部存储",
            dir = "",
            path = default.absolutePath,
            freeBytes = runCatching { default.usableSpace }.getOrDefault(-1),
            totalBytes = runCatching { default.totalSpace }.getOrDefault(-1),
        )
        var cards = 0
        for (volume in volumes) {
            val removable = runCatching { Environment.isExternalStorageRemovable(volume) }.getOrDefault(true)
            val mounted = runCatching { Environment.getExternalStorageState(volume) == Environment.MEDIA_MOUNTED }.getOrDefault(false)
            if (!mounted) continue
            cards++
            val folder = File(volume, "downloads").also { it.mkdirs() }
            out += DownloadLocation(
                name = describe(context, volume) ?: if (cards == 1) "SD 卡 / U 盘" else "SD 卡 / U 盘 $cards",
                dir = folder.absolutePath,
                path = folder.absolutePath,
                freeBytes = runCatching { folder.usableSpace }.getOrDefault(-1),
                totalBytes = runCatching { folder.totalSpace }.getOrDefault(-1),
                removable = removable,
            )
        }
        return out
    }

    /** The volume's name as the system shows it (e.g. 「SanDisk U 盘」), Android 7+. */
    private fun describe(context: Context, folder: File): String? = runCatching {
        val sm = context.getSystemService(Context.STORAGE_SERVICE) as android.os.storage.StorageManager
        if (Build.VERSION.SDK_INT >= 24) sm.getStorageVolume(folder)?.getDescription(context) else null
    }.getOrNull()?.takeIf { it.isNotBlank() }

    /**
     * Android had no stream cache before this version, so a saved cap of 2 GB (the desktop default every saved
     * settings file carries) was never chosen by anybody: it becomes the Android default, once. Later choices stay.
     */
    private fun smallerDefaultCache(data: File) {
        val marker = File(data, ".android-cache-default")
        if (marker.exists()) return
        runCatching {
            val store = JsonFileStore(data)
            val settings = store.loadSettings()
            if (settings.streamCacheMaxMB == 2048) store.saveSettings(settings.copy(streamCacheMaxMB = DEFAULT_CACHE_MB))
            marker.writeText("")
        }.onFailure { Log.w(TAG, "cache default: ${it.message}") }
    }
}
