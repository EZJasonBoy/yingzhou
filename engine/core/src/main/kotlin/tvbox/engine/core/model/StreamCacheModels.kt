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
)

/** `GET /api/v1/stream-cache/coverage?key=`: the parts of a film that are in the cache, as `[startMs, endMs]` pairs in order. */
@Serializable
data class StreamCoverage(
    val durationMs: Long = 0,
    val ranges: List<List<Long>> = emptyList(),
)
