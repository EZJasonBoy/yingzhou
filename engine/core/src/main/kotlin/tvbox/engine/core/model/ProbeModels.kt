package tvbox.engine.core.model

import kotlinx.serialization.Serializable

/**
 * `POST /api/v1/play/probe` (线路体检): the same episode on several lines of a site. Only the client knows which
 * `episodeId` an episode has on each line (`PlayLine.findEpisode`), so it names them.
 */
@Serializable
data class ProbeRequest(
    val site: String,
    val lines: List<ProbeLine> = emptyList(),
    /** As in [PlayRequest.direct]; the probe measures from the engine either way. */
    val direct: Boolean = false,
)

@Serializable
data class ProbeLine(
    val line: String,
    val episodeId: String,
)

/**
 * What the probe found out about one line, sent as the `line` event when the line is done. Numbers that could not be
 * measured are null, and so left out of the JSON (the engine's JSON leaves nulls out), never 0.
 */
@Serializable
data class ProbeResult(
    /** Position of the line in [ProbeRequest.lines]. */
    val index: Int,
    val line: String,
    /** ok | slow | dead | sniff | skipped (see [ProbeState]). */
    val state: String,
    /** hls | file, or "" when the video was not reached. */
    val kind: String = "",
    /** From the `RESOLUTION` of the highest variant of a master playlist; null when there is none. */
    val width: Int? = null,
    val height: Int? = null,
    /** How long resolving the address took (the site's `playerContent`, parsers). */
    val resolveMs: Long? = null,
    /** From the address being known to the first bytes of video (for HLS: of its first segment). */
    val firstByteMs: Long? = null,
    /** Read speed of the first segment (or the start of the file). */
    val bytesPerSecond: Long? = null,
    /** Which parser produced the address, as in [PlayInfo.parsedBy]. */
    val parsedBy: String = "",
    /** For dead and slow: why, in a few plain words (超时, 404, 被拒绝, 解析失败, 连不上 …); "" otherwise. */
    val reason: String = "",
)

/** The values of [ProbeResult.state]. */
object ProbeState {
    /** Resolved, and the playlist and the start of the video came in fast enough. */
    const val OK = "ok"

    /** Came in, but slower than its resolution needs, or not back when the probe had to finish. */
    const val SLOW = "slow"

    /** Did not resolve, or its address does not open. */
    const val DEAD = "dead"

    /** Needs a web page sniffed for its address; the probe does not open a browser for that. */
    const val SNIFF = "sniff"

    /** Over the number of lines one probe tests; not tested. */
    const val SKIPPED = "skipped"
}
