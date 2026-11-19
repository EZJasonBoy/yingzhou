package tvbox.engine.core.model

import kotlinx.serialization.Serializable

/** Where the user is in a video. One entry per (site, vodId); the latest update wins. */
@Serializable
data class HistoryEntry(
    val site: String,
    val vodId: String,
    val name: String,
    val pic: String = "",
    val line: String = "",
    val episodeId: String = "",
    val episodeName: String = "",
    val episodeIndex: Int = 0,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    /** Epoch millis; set by the engine. */
    val updatedAt: Long = 0,
    /**
     * The subtitle chosen for this title, kept for the next episode and the next visit: `off`, `lang:<language>` or
     * `name:<track name>`; empty for the player's own choice. Written by clients, opaque to the engine.
     */
    val subtitle: String = "",
    /** The audio track chosen, `lang:<language>` or `name:<track name>`; empty for the default. */
    val audio: String = "",
)

@Serializable
data class FavoriteEntry(
    val site: String,
    val vodId: String,
    val name: String,
    val pic: String = "",
    val remarks: String = "",
    /** Epoch millis; set by the engine. */
    val addedAt: Long = 0,
)
