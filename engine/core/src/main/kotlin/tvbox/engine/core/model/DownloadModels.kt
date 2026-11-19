package tvbox.engine.core.model

import kotlinx.serialization.Serializable

// Wire types of the engine's downloads (docs/protocol.md, "离线下载").

/** One episode to download: what `/play/resolve` takes, plus what the list shows. */
@Serializable
data class DownloadRequest(
    val site: String,
    val line: String,
    val episodeId: String,
    val vodId: String = "",
    val title: String = "",
    val pic: String = "",
    val episodeName: String = "",
    /** Where the episode is in its line (for ordering); -1 when unknown. */
    val episodeIndex: Int = -1,
)

@Serializable
data class DownloadAddRequest(val items: List<DownloadRequest> = emptyList())

@Serializable
data class DownloadItem(
    val id: String,
    val site: String,
    val line: String,
    val episodeId: String,
    val vodId: String = "",
    val title: String = "",
    val pic: String = "",
    val episodeName: String = "",
    val episodeIndex: Int = -1,
    /** queued | running | paused | done | failed */
    val state: String,
    /** "" until the episode has been resolved; then "hls" or "file" (a direct link: mp4, flv, mkv…). */
    val kind: String = "",
    /** Bytes on disk so far. */
    val bytes: Long = 0,
    /** All the bytes there will be: a direct file's size, a finished download's; -1 while unknown. */
    val totalBytes: Long = -1,
    /** 0 to 1. HLS: the part of the film's duration that is on disk. */
    val progress: Double = 0.0,
    /** Bytes a second over the last few seconds; 0 when not running. */
    val speed: Long = 0,
    /** HLS: files of the stream (segments, keys, initialisation maps) on disk, and in all. */
    val partsDone: Int = 0,
    val parts: Int = 0,
    val durationMs: Long = 0,
    /** Why it failed (or why it stopped), for people. */
    val error: String = "",
    val createdAt: Long = 0,
    val finishedAt: Long = 0,
)

@Serializable
data class DownloadList(
    /** False when this engine cannot download (the engine inside the Android app). */
    val available: Boolean,
    val items: List<DownloadItem> = emptyList(),
)

/** `PUT /api/v1/downloads/settings`: fields left out stay as they are. */
@Serializable
data class DownloadSettingsUpdate(
    /** A folder on the engine's machine; "" goes back to the default. */
    val dir: String? = null,
    val concurrency: Int? = null,
)

@Serializable
data class DownloadSettingsInfo(
    val available: Boolean,
    /** What the user chose; "" for the default. */
    val dir: String = "",
    /** Where new downloads go now. */
    val path: String = "",
    val defaultPath: String = "",
    /** Episodes downloaded at the same time. */
    val concurrency: Int = 2,
    val maxConcurrency: Int = 5,
    /** Free space where new downloads go; -1 unknown. */
    val freeBytes: Long = -1,
    /** Downloads stop before the disk has less than this left. */
    val reserveBytes: Long = 0,
    /** Everything downloaded, wherever it is. */
    val bytes: Long = 0,
)

@Serializable
data class DownloadExportRequest(
    /** A folder or a file on the engine's machine; "" for the default folder. */
    val path: String = "",
)

@Serializable
data class DownloadExportResult(
    /** The file written, on the engine's machine. */
    val path: String,
    val bytes: Long,
    /** "ts", "mp4", or a direct file's own extension. */
    val format: String,
)
