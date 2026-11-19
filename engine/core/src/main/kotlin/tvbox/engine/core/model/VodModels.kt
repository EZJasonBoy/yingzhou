package tvbox.engine.core.model

import kotlinx.serialization.Serializable

// Normalised video data (protocol v1). Clients never see TVBox's "$$$" / "#" / "$" encodings.

@Serializable
data class VodCard(
    val site: String,
    val id: String,
    val name: String,
    val pic: String = "",
    val remarks: String = "",
)

@Serializable
data class VodClass(
    val id: String,
    val name: String,
)

@Serializable
data class FilterValue(
    val name: String,
    val value: String,
)

@Serializable
data class VodFilter(
    val key: String,
    val name: String,
    val values: List<FilterValue>,
)

@Serializable
data class HomeResult(
    val classes: List<VodClass> = emptyList(),
    /** Keyed by class id. */
    val filters: Map<String, List<VodFilter>> = emptyMap(),
    val list: List<VodCard> = emptyList(),
)

@Serializable
data class VodPage(
    val page: Int = 1,
    /** 0 when unknown. */
    val pageCount: Int = 0,
    val total: Int = 0,
    val list: List<VodCard> = emptyList(),
)

@Serializable
data class Episode(
    /** Opaque to clients; pass back to /play/resolve unchanged. */
    val id: String,
    val name: String,
)

@Serializable
data class PlayLine(
    val name: String,
    val episodes: List<Episode>,
)

@Serializable
data class VodDetail(
    val site: String,
    val id: String,
    val name: String,
    val pic: String = "",
    val year: String = "",
    val area: String = "",
    val type: String = "",
    val actor: String = "",
    val director: String = "",
    val content: String = "",
    val remarks: String = "",
    val lines: List<PlayLine> = emptyList(),
)

@Serializable
data class PlayRequest(
    val site: String,
    val line: String,
    val episodeId: String,
)

@Serializable
data class SniffRequest(
    val pageUrl: String,
    val headers: Map<String, String> = emptyMap(),
    val timeoutMs: Long = 15_000,
    /** JavaScript to run once the page has loaded (the config's click scripts for this page). */
    val scripts: List<String> = emptyList(),
)

@Serializable
data class PlayInfo(
    /** "direct": play [url]; "sniff": load [sniff] in a web view and play the first media request. */
    val kind: String,
    val url: String = "",
    val headers: Map<String, String> = emptyMap(),
    val sniff: SniffRequest? = null,
    /** Which parser produced the url, for display ("" when none was needed). */
    val parsedBy: String = "",
    /**
     * Not empty when the engine's stream cache serves [url]: what was played or read ahead stays on the engine's
     * disk, and `/api/v1/stream-cache/coverage?key=` with this value says which parts are there.
     */
    val cache: String = "",
    /** Subtitles that go with [url] (TVBox `subs`), e.g. the `.srt` / `.ass` / `.vtt` files beside a drive's video. */
    val subtitles: List<Subtitle> = emptyList(),
)

/** A subtitle file a player can load next to the video. */
@Serializable
data class Subtitle(
    val url: String,
    /** For the menu: the file name, or what a spider called it. */
    val name: String = "",
    /** Language tag when known (`zh`, `chs`, `en` from `film.zh.srt`); empty when not. */
    val lang: String = "",
    /** `srt` | `ass` | `ssa` | `vtt`; empty when not known. */
    val format: String = "",
)

/** Aggregated search events (SSE). */
@Serializable
data class SearchSiteEvent(
    val site: String,
    /** started | done | error */
    val status: String,
    val count: Int = 0,
    val ms: Long = 0,
    val code: String? = null,
    val message: String? = null,
)

@Serializable
data class SearchResultsEvent(
    val site: String,
    val items: List<VodCard>,
)

@Serializable
data class SearchEndEvent(
    val sites: Int,
    val ms: Long,
)
