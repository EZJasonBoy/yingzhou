package tvbox.engine.core.search

import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout
import tvbox.engine.core.model.SearchEndEvent
import tvbox.engine.core.model.SearchResultsEvent
import tvbox.engine.core.model.SearchSiteEvent
import tvbox.engine.core.site.SiteSource

sealed interface SearchEvent {
    data class Site(val event: SearchSiteEvent) : SearchEvent
    data class Results(val event: SearchResultsEvent) : SearchEvent
    data class End(val event: SearchEndEvent) : SearchEvent
}

/**
 * Searches many sites at once and streams results as each site answers.
 * Each site gets its own timeout (its `timeout` setting), so one slow site never holds the others up.
 */
class SearchAggregator(private val concurrency: Int = 8) {

    fun search(sources: List<SiteSource>, keyword: String, errorMapper: (Throwable) -> Pair<String, String>): Flow<SearchEvent> =
        channelFlow {
            val start = System.currentTimeMillis()
            val gate = Semaphore(concurrency)
            coroutineScope {
                for (source in sources) {
                    launch {
                        gate.withPermit {
                            val key = source.bean.key
                            val t0 = System.currentTimeMillis()
                            send(SearchEvent.Site(SearchSiteEvent(key, "started")))
                            try {
                                val page = withTimeout(source.timeoutMs) { source.search(keyword, quick = false, page = 1) }
                                if (page.list.isNotEmpty()) send(SearchEvent.Results(SearchResultsEvent(key, page.list)))
                                send(SearchEvent.Site(SearchSiteEvent(key, "done", count = page.list.size, ms = System.currentTimeMillis() - t0)))
                            } catch (e: Throwable) {
                                if (e is kotlinx.coroutines.CancellationException && e !is kotlinx.coroutines.TimeoutCancellationException) throw e
                                val (code, message) = errorMapper(e)
                                send(SearchEvent.Site(SearchSiteEvent(key, "error", ms = System.currentTimeMillis() - t0, code = code, message = message)))
                            }
                        }
                    }
                }
            }
            send(SearchEvent.End(SearchEndEvent(sources.size, System.currentTimeMillis() - start)))
        }
}
