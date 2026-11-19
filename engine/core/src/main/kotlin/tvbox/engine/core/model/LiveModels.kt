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
    /** False for kinds the engine cannot load yet (lives served by a Python spider, `type: 3` without a spider). */
    val supported: Boolean = true,
    /** The runtime of the spider that serves the list ("jar", "js", "py"); empty for a plain playlist. */
    val spider: String = "",
)

@Serializable
data class LiveUrl(
    val url: String,
    /** The line's label (`url$label` in TXT playlists), empty when unnamed. */
    val label: String = "",
    /** Headers the player sends (the source's `ua` / `header`, M3U `#EXTVLCOPT` options). */
    val headers: Map<String, String> = emptyMap(),
    /** How this line's past programmes are addressed; stays in the engine, which builds the address when asked. */
    @kotlinx.serialization.Transient val catchup: CatchupTemplate? = null,
)

/**
 * The catch-up rule of a channel line, as playlists and configs state it (`live/Catchup.kt` reads it and builds
 * addresses from it).
 */
data class CatchupTemplate(
    /** `default`, `append`, `shift`, `flussonic`, `xc` ... in lower case; empty when not said. */
    val type: String = "",
    /** `catchup-source` / `catchup.source`: the address, or what is appended to the live one, with placeholders. */
    val source: String = "",
    /** TVBox `replace`: `regex,replacement`, done on the live address before the source is appended. */
    val replace: String = "",
    /** TVBox `regex`: only lines whose address contains or matches it have catch-up. */
    val regex: String = "",
    /** How many days back; null when not said. */
    val days: Int? = null,
    /** `catchup-correction` in seconds, taken off the times that go into the address; null when not said. */
    val correctionSeconds: Long? = null,
)

@Serializable
data class LiveChannel(
    val name: String,
    val logo: String = "",
    val urls: List<LiveUrl>,
    /** How many days back programmes of this channel can be played again (回看); 0 when it has no catch-up. */
    val catchupDays: Int = 0,
)

/** One address that may play a past time range of a channel. */
@Serializable
data class CatchupAddress(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    /** The line of the channel it was built from. */
    val line: Int = 0,
)

/**
 * The answer to "play what this channel showed from start to end": the address to try first, and the others worth
 * trying when it does not play (the same line addressed another way, then the channel's other lines).
 */
@Serializable
data class LiveCatchup(
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val line: Int = 0,
    val alternates: List<CatchupAddress> = emptyList(),
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
