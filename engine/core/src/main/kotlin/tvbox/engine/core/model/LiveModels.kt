package tvbox.engine.core.model

import kotlinx.serialization.Serializable

// Live TV (protocol v1): the config's `lives` as sources, each a list of channel groups, plus EPG.

/** One entry of the config's `lives`. */
@Serializable
data class LiveSourceInfo(
    val index: Int,
    val name: String,
    /** Whether the source has an EPG (from the config or the playlist's `x-tvg-url`). */
    val hasEpg: Boolean,
    /** False for kinds the engine cannot load yet (spider-based lives). */
    val supported: Boolean = true,
)

@Serializable
data class LiveUrl(
    val url: String,
    /** The line's label (`url$label` in TXT playlists), empty when unnamed. */
    val label: String = "",
    /** Headers the player sends (the source's `ua` / `header`, M3U `#EXTVLCOPT` options). */
    val headers: Map<String, String> = emptyMap(),
)

@Serializable
data class LiveChannel(
    val name: String,
    val logo: String = "",
    val urls: List<LiveUrl>,
)

@Serializable
data class LiveGroup(val name: String, val channels: List<LiveChannel>)

@Serializable
data class LiveList(val source: Int, val name: String, val groups: List<LiveGroup>)

@Serializable
data class EpgProgram(
    /** Epoch milliseconds. */
    val start: Long,
    val end: Long,
    val title: String,
)

@Serializable
data class EpgDay(
    val channel: String,
    /** `yyyy-MM-dd`, China time like TVBox. */
    val date: String,
    val programs: List<EpgProgram>,
)
