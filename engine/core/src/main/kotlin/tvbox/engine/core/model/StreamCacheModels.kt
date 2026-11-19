package tvbox.engine.core.model

import kotlinx.serialization.Serializable

// Wire types of the stream cache (docs/protocol.md, "播放缓存").

/** `GET /api/v1/stream-cache`: what the engine keeps of the streams it served. */
@Serializable
data class StreamCacheInfo(
    /** False when this engine has no stream cache at all (then nothing else here means anything). */
    val available: Boolean,
    val enabled: Boolean = false,
    val bytes: Long = 0,
    val files: Int = 0,
    /** Films (episodes, or one quality of one) that have something in the cache. */
    val streams: Int = 0,
    val maxBytes: Long = 0,
    /** Where it is on the engine's machine. */
    val path: String = "",
    /** Downloads kept in the same folder (pinned streams): not in [bytes], never removed to make room. */
    val pinnedBytes: Long = 0,
    /** Free space on that disk; -1 when the engine does not watch it (only the Android engine does). */
    val freeBytes: Long = -1,
    /** The cache gives way before the disk has less than this left; 0: it only keeps to [maxBytes]. */
    val reserveBytes: Long = 0,
)

/** `GET /api/v1/stream-cache/coverage?key=`: the parts of a film that are in the cache, as `[startMs, endMs]` pairs in order. */
@Serializable
data class StreamCoverage(
    val durationMs: Long = 0,
    val ranges: List<List<Long>> = emptyList(),
)
