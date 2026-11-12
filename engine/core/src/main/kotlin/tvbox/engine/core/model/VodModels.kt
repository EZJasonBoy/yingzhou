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
