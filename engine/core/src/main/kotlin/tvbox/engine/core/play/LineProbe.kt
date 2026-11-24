package tvbox.engine.core.play

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Response
import tvbox.engine.core.EngineException
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.model.ProbeLine
import tvbox.engine.core.model.ProbeRequest
import tvbox.engine.core.model.ProbeResult
import tvbox.engine.core.model.ProbeState
import tvbox.engine.core.net.SiteHttp
import tvbox.engine.core.net.SiteHttpException
import tvbox.engine.core.util.UriUtil
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReferenceArray

/**
 * 线路体检 (docs/design/line-probe.md): whether each line of an episode plays, and how fast, before anyone presses
 * play. A line is resolved by the caller's [probe] `resolve` — the engine's own `/play/resolve` code, so parsers,
 * headers, `hosts` and the playback proxy are the ones playing uses — and then the start of its video is fetched:
 * for HLS the playlist (the highest variant of a master playlist) and its first segment, for a file its first bytes.
 *
 * Everything is bounded by [Budgets], so that a detail page hears about every line within seconds; a line that has
 * not answered when the whole probe has to finish is `slow`, not `dead` (slow and broken are kept apart).
 */
class LineProbe(
    /** Fetches the video as the engine's playlist endpoint and stream cache do (the config's `hosts`, headers, DNS). */
    private val http: SiteHttp,
    /** The engine's playlist endpoint (`http://127.0.0.1:<port>/m3u8?`): HLS wrapped in it is fetched at its source, as the endpoint does. */
    private val playlistBase: String,
    /** Cuts ads out of a media playlist (text, url, final url) as the playlist endpoint does, so the first segment is the one a player gets. */
    private val cleaner: (String, String, String) -> String = { text, _, _ -> text },
    private val budgets: Budgets = Budgets(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** The probe's limits; the defaults are the design note's, tests shorten them. */
    data class Budgets(
        /** Lines tested at the same time. */
        val parallel: Int = 3,
        /** Lines one probe tests; the others are `skipped`. */
        val maxLines: Int = 6,
        /** For resolving one line's address. */
        val resolveMs: Long = 6_000,
        /** From the address to the first bytes of video (connecting, playlists, the first bytes of the segment). */
        val firstByteMs: Long = 4_000,
        /** For reading the first segment (or the file) to measure the speed, and at most this much of it. */
        val readMs: Long = 1_500,
        val readBytes: Int = 512 * 1024,
        /** The whole probe: lines not back by then are reported `slow`. */
        val requestMs: Long = 10_000,
        /** How long a line's result is reused (per site, line and episode). */
        val cacheMs: Long = 5 * 60_000,
        /** A host that failed to connect [hostFailures] times within [hostWindowMs] is not tried again until then. */
        val hostWindowMs: Long = 2 * 60_000,
        val hostFailures: Int = 2,
    )

    private class Kept(val at: Long, val result: ProbeResult)

    private val kept = ConcurrentHashMap<String, Kept>()

    /** Times the hosts (host:port) of videos failed to connect, within [Budgets.hostWindowMs]. */
    private val hostFailures = ConcurrentHashMap<String, List<Long>>()

    /**
     * Where resolving runs. A spider's `playerContent` blocks a thread and does not stop when cancelled; waiting for it
     * is given up instead (see [abandonable]), so that the probe still finishes on time and a client that goes away
     * stops it at once. The call itself ends on its own, as an abandoned `/play/resolve` would.
     */
    private val resolving = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Probes [request]'s lines and emits a result for each as it is done (the order they finish in): first the lines
     * over [Budgets.maxLines] (`skipped`) and those found in the cache, then the others as they come back. [scope]
     * keeps the cache apart per config. Cancelling the collection stops what is still running.
     */
    fun probe(request: ProbeRequest, scope: String, resolve: suspend (PlayRequest) -> PlayInfo): Flow<ProbeResult> = channelFlow {
        val lines = request.lines
        val tested = minOf(lines.size, budgets.maxLines)
        for (i in tested until lines.size) trySend(ProbeResult(i, lines[i].line, ProbeState.SKIPPED))
        val reported = AtomicReferenceArray<ProbeResult?>(tested)
        // What is known of a line still running, for the report when the probe runs out of time.
        val progress = AtomicReferenceArray<ProbeResult?>(tested)
        val permits = Semaphore(budgets.parallel)
        withTimeoutOrNull(budgets.requestMs) {
            coroutineScope {
                val probing = coroutineContext.job
                for (i in 0 until tested) launch {
                    val line = lines[i]
                    val key = scope + "\n" + request.site + "\n" + line.line + "\n" + line.episodeId
                    val result = cached(key)?.copy(index = i, line = line.line) ?: permits.withPermit {
                        // A place freed by lines cancelled with the whole probe can reach this line before its own
                        // cancelling does: the probe is going away (it is marked so before any line), nothing new starts.
                        if (!probing.isActive) throw CancellationException("the probe was cancelled")
                        val outcome = measure(ProbeResult(i, line.line, ProbeState.DEAD), line, request, resolve) { progress.set(i, it) }
                        // Cancelled meanwhile (time is up, or the client left): what failed then was the cancelling.
                        currentCoroutineContext().ensureActive()
                        outcome.failedHost?.let(::noteFailure)
                        if (outcome.keep) kept[key] = Kept(clock(), outcome.result)
                        outcome.result
                    }
                    reported.set(i, result)
                    trySend(result)
                }
            }
        }
        for (i in 0 until tested) {
            if (reported.get(i) != null) continue
            val known = progress.get(i) ?: ProbeResult(i, lines[i].line, ProbeState.SLOW)
            trySend(known.copy(state = ProbeState.SLOW, reason = TIMEOUT, firstByteMs = null, bytesPerSecond = null))
        }
    }.buffer(Channel.UNLIMITED)

    private fun cached(key: String): ProbeResult? {
        val now = clock()
        if (kept.size > MAX_KEPT) kept.entries.removeIf { now - it.value.at > budgets.cacheMs }
        val entry = kept[key] ?: return null
        return if (now - entry.at <= budgets.cacheMs) entry.result else null.also { kept.remove(key, entry) }
    }

    private fun noteFailure(host: String) {
        val now = clock()
        hostFailures.compute(host) { _, times -> (times.orEmpty() + now).filter { now - it < budgets.hostWindowMs } }
    }

    private fun hostDown(host: String): Boolean {
        val now = clock()
        return hostFailures[host].orEmpty().count { now - it < budgets.hostWindowMs } >= budgets.hostFailures
    }

    /** A line's result; [keep]: worth caching; [failedHost]: the host that did not let us connect. */
    private class Outcome(val result: ProbeResult, val keep: Boolean = true, val failedHost: String? = null)

    /** Why fetching the video stopped, in a few words for people: the line is dead, or slow when [late] (it answered, after its time). */
    private class Stop(val reason: String, val failedHost: String? = null, val late: Boolean = false) : Exception(reason)

    private suspend fun measure(
        base: ProbeResult,
        line: ProbeLine,
        request: ProbeRequest,
        resolve: suspend (PlayRequest) -> PlayInfo,
        progress: (ProbeResult) -> Unit,
    ): Outcome {
        val started = System.nanoTime()
        val info = try {
            withTimeoutOrNull(budgets.resolveMs) { abandonable { resolve(PlayRequest(request.site, line.line, line.episodeId, request.direct)) } }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return Outcome(base.copy(resolveMs = millisSince(started), reason = resolveReason(e)))
        }
        currentCoroutineContext().ensureActive()
        val resolved = base.copy(resolveMs = millisSince(started), parsedBy = info?.parsedBy.orEmpty())
        if (info == null) return Outcome(resolved.copy(reason = RESOLVE_TIMEOUT))
        progress(resolved)
        if (info.kind == "sniff") return Outcome(resolved.copy(state = ProbeState.SNIFF))
        val (url, headers) = PlayResolver.unwrapPlaylist(playlistBase, info.url) ?: (info.url to info.headers)
        if (url.isBlank()) return Outcome(resolved.copy(reason = RESOLVE_FAILED))
        // A finished download plays from the engine's disk: nothing to measure. An address that is not http (rtmp,
        // rtsp …) is the player's to open; the engine cannot look into it.
        if (info.download.isNotEmpty() || !(url.startsWith("http://") || url.startsWith("https://"))) {
            return Outcome(resolved.copy(state = ProbeState.OK, kind = if (info.download.isNotEmpty()) kindOf(url) else ""), keep = info.download.isEmpty())
        }
        val host = hostOf(url)
        if (host != null && hostDown(host)) return Outcome(resolved.copy(reason = UNREACHABLE), keep = false)
        return try {
            Outcome(fetch(resolved, url, headers, progress))
        } catch (e: Stop) {
            Outcome(resolved.copy(state = if (e.late) ProbeState.SLOW else ProbeState.DEAD, reason = e.reason), failedHost = e.failedHost)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Outcome(resolved.copy(reason = CANNOT_OPEN))
        }
    }

    /** Waits for [block] on [resolving], giving up the wait (not the call) when this coroutine is cancelled. */
    private suspend fun <T> abandonable(block: suspend () -> T): T {
        val deferred = resolving.async { block() }
        try {
            return deferred.await()
        } catch (e: CancellationException) {
            deferred.cancel()
            throw e
        }
    }

    private fun resolveReason(e: Exception): String = when {
        e is EngineException.SiteFailed && e.code == "SITE_TIMEOUT" -> RESOLVE_TIMEOUT
        e is EngineException.Unsupported -> "不支持"
        e is EngineException.NotFound -> "找不到"
        else -> RESOLVE_FAILED
    }

    /** One response read as far as the probe needs. Times are [System.nanoTime]. */
    private class Sample(
        val bytes: ByteArray,
        val headersAt: Long,
        /** When the first bytes of the body came; 0 when none did. */
        val firstAt: Long,
        val endAt: Long,
        /** The whole body was read. */
        val complete: Boolean,
        /** Reading broke off with this (a timeout, a reset). */
        val broken: IOException?,
        val finalUrl: String,
    ) {
        val text: String by lazy { String(bytes, Charsets.UTF_8).removePrefix("﻿") }
        val isPlaylist: Boolean get() = text.trimStart().startsWith("#EXTM3U")
        val isWebPage: Boolean get() = text.trimStart().take(15).lowercase().let { it.startsWith("<!doctype html") || it.startsWith("<html") }
    }

    /** Fetches the start of the video at [url]: its playlists and first segment for HLS, its first bytes for a file. */
    private suspend fun fetch(resolved: ProbeResult, url: String, headers: Map<String, String>, progress: (ProbeResult) -> Unit): ProbeResult {
        val start = System.nanoTime()
        val firstByteBy = start + budgets.firstByteMs * 1_000_000
        val endBy = firstByteBy + budgets.readMs * 1_000_000
        var late = false
        suspend fun get(target: String, range: String?): Sample {
            val sample = sample(target, if (range == null) headers else headers + ("Range" to range), endBy, late)
            if (sample.headersAt > firstByteBy) late = true
            return sample
        }

        val first = get(url, if (looksLikeHls(url)) null else "bytes=0-${budgets.readBytes - 1}")
        val media: Sample
        var width: Int? = null
        var height: Int? = null
        val kind: String
        if (first.isPlaylist) {
            kind = KIND_HLS
            var playlist = first
            var depth = 0
            while (M3u8Cleaner.isMaster(playlist.text)) {
                val variant = bestVariant(playlist.text, playlist.finalUrl)
                if (variant == null || ++depth > MAX_MASTER_DEPTH) throw Stop(EMPTY_PLAYLIST, late = late)
                if (variant.width != null) {
                    width = variant.width
                    height = variant.height
                }
                progress(resolved.copy(kind = kind, width = width, height = height))
                playlist = get(variant.url, null)
                if (!playlist.isPlaylist) throw Stop(if (playlist.isWebPage) NOT_VIDEO else EMPTY_PLAYLIST, late = late)
            }
            progress(resolved.copy(kind = kind, width = width, height = height))
            val text = runCatching { cleaner(playlist.text, url, playlist.finalUrl) }.getOrDefault(playlist.text)
            val segment = firstSegment(text, playlist.finalUrl) ?: throw Stop(EMPTY_PLAYLIST, late = late)
            media = get(segment.first, segment.second)
        } else {
            kind = KIND_FILE
            media = first
        }
        if (media.firstAt == 0L) {
            // Answered, and then nothing: an empty body, or no bytes before the time was up.
            throw Stop(if (media.broken != null) TIMEOUT else EMPTY, late = late)
        }
        // A web page, or a few bytes of text (`{"code":404}`): what a dead link of a site often answers with 200.
        if (media.isWebPage || (media.complete && media.bytes.size < MIN_VIDEO_BYTES)) throw Stop(NOT_VIDEO)
        val firstByteMs = (media.firstAt - start) / 1_000_000
        val speed = speedOf(media)
        val result = resolved.copy(kind = kind, width = width, height = height, firstByteMs = firstByteMs, bytesPerSecond = speed)
        return when {
            media.firstAt > firstByteBy -> result.copy(state = ProbeState.SLOW, reason = TIMEOUT)
            speed != null && speed < needed(width, height) -> result.copy(state = ProbeState.SLOW, reason = TOO_SLOW)
            else -> result.copy(state = ProbeState.OK)
        }
    }

    /**
     * GETs [url] and reads its body until [Budgets.readBytes] are in, [Budgets.readMs] have passed since the first
     * bytes, or [endBy] (nanoTime) comes. HTTP errors and failures to connect become a [Stop].
     */
    private suspend fun sample(url: String, headers: Map<String, String>, endBy: Long, late: Boolean): Sample {
        // A cancelled line can get here without having suspended since (a resolve that was already done), and OkHttp
        // would send the request before noticing: nothing goes out for a probe that is over.
        currentCoroutineContext().ensureActive()
        val left = (endBy - System.nanoTime()) / 1_000_000
        if (left <= 0) throw Stop(TIMEOUT, late = late)
        return try {
            http.open(url, headers, timeoutMs = left + CALL_SLACK_MS, connectTimeoutMs = minOf(budgets.firstByteMs, left)) { read(it, endBy) }
        } catch (e: SiteHttpException) {
            throw stopFor(e, url, late)
        }
    }

    /** Runs on OkHttp's thread; whatever breaks the reading off ends the sample with what came until then. */
    private fun read(response: Response, endBy: Long): Sample {
        val headersAt = System.nanoTime()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        var firstAt = 0L
        var complete = false
        var broken: IOException? = null
        val readNanos = budgets.readMs * 1_000_000
        try {
            val stream = response.body?.byteStream()
            if (stream == null) complete = true
            while (stream != null && out.size() < budgets.readBytes) {
                val now = System.nanoTime()
                if (now >= endBy || (firstAt != 0L && now - firstAt >= readNanos)) break
                val n = stream.read(buffer, 0, minOf(buffer.size, budgets.readBytes - out.size()))
                if (n < 0) {
                    complete = true
                    break
                }
                if (n > 0 && firstAt == 0L) firstAt = System.nanoTime()
                out.write(buffer, 0, n)
            }
        } catch (e: IOException) {
            broken = e
        }
        return Sample(out.toByteArray(), headersAt, firstAt, System.nanoTime(), complete, broken, response.request.url.toString())
    }

    private fun stopFor(e: SiteHttpException, url: String, late: Boolean): Stop {
        val causes = generateSequence<Throwable>(e) { it.cause }.toList()
        return when {
            e.status == 404 || e.status == 410 -> Stop("404")
            e.status == 401 || e.status == 403 || e.status == 451 -> Stop(REFUSED)
            e.status in 500..599 -> Stop("服务器出错")
            e.status != 0 -> Stop("HTTP ${e.status}")
            causes.any { it is ConnectException || it is UnknownHostException || it is NoRouteToHostException || it is javax.net.ssl.SSLHandshakeException } ||
                causes.any { it is SocketTimeoutException && it.message.orEmpty().contains("connect", ignoreCase = true) } ->
                Stop(UNREACHABLE, failedHost = hostOf(url))
            causes.any { it is InterruptedIOException } -> Stop(TIMEOUT, late = late)
            else -> Stop(UNREACHABLE)
        }
    }

    /** Bytes per second over the sample; null when it was too short to tell (a small body that came at once). */
    private fun speedOf(sample: Sample): Long? {
        val nanos = sample.endAt - sample.headersAt
        if (nanos <= 0 || (sample.complete && sample.bytes.size < MIN_SPEED_BYTES)) return null
        return sample.bytes.size * 1_000_000_000L / nanos
    }

    private class Variant(val url: String, val width: Int?, val height: Int?, val bandwidth: Long)

    /** The variant with the most pixels (then the highest bandwidth); without RESOLUTION, the highest bandwidth. */
    private fun bestVariant(text: String, baseUrl: String): Variant? {
        val lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val variants = ArrayList<Variant>()
        for ((i, line) in lines.withIndex()) {
            if (!line.startsWith("#EXT-X-STREAM-INF")) continue
            val uri = lines.drop(i + 1).firstOrNull { it.isNotBlank() && !it.startsWith("#") }?.trim() ?: continue
            val resolution = RESOLUTION.find(line)
            val bandwidth = BANDWIDTH.find(line)?.groupValues?.get(1)?.toLongOrNull() ?: 0
            variants += Variant(absolute(baseUrl, uri), resolution?.groupValues?.get(1)?.toIntOrNull(), resolution?.groupValues?.get(2)?.toIntOrNull(), bandwidth)
        }
        return variants.maxWithOrNull(compareBy<Variant>({ (it.width ?: 0).toLong() * (it.height ?: 0) }, { it.bandwidth }))
    }

    /** The first segment of a media playlist and the Range header its `#EXT-X-BYTERANGE` asks for (null: none). */
    private fun firstSegment(text: String, baseUrl: String): Pair<String, String?>? {
        var byteRange: String? = null
        for (raw in text.replace("\r\n", "\n").replace('\r', '\n').split('\n')) {
            val line = raw.trim()
            if (line.startsWith("#EXT-X-BYTERANGE:")) byteRange = line.substringAfter(':')
            if (line.isEmpty() || line.startsWith("#")) continue
            val range = byteRange?.let { spec ->
                val length = spec.substringBefore('@').trim().toLongOrNull() ?: return@let null
                val offset = spec.substringAfter('@', "0").trim().toLongOrNull() ?: 0
                "bytes=$offset-${offset + minOf(length, budgets.readBytes.toLong()) - 1}"
            }
            return absolute(baseUrl, line) to range
        }
        return null
    }

    private fun absolute(base: String, ref: String): String =
        if (ref.startsWith("http://") || ref.startsWith("https://")) ref else runCatching { UriUtil.resolve(base, ref) }.getOrDefault(ref)

    companion object {
        const val KIND_HLS = "hls"
        const val KIND_FILE = "file"

        const val TIMEOUT = "超时"
        const val RESOLVE_TIMEOUT = "解析超时"
        const val RESOLVE_FAILED = "解析失败"
        const val UNREACHABLE = "连不上"
        const val REFUSED = "被拒绝"
        const val TOO_SLOW = "网速不够"
        const val NOT_VIDEO = "不是视频"
        const val EMPTY = "没有内容"
        const val EMPTY_PLAYLIST = "播放列表是空的"
        const val CANNOT_OPEN = "打不开"

        private const val MIB = 1024L * 1024L

        /**
         * The speed a video of this size needs to play without waiting: about 0.6 MB/s for 1080p, 2.5 MB/s for 4K,
         * 0.3 MB/s below that (and when the size is not known). A wide film (1920×800) counts by its width.
         */
        fun needed(width: Int?, height: Int?): Long {
            val lines = maxOf(height ?: 0, (width ?: 0) * 9 / 16)
            return when {
                lines >= 2160 -> 5 * MIB / 2
                lines >= 1080 -> 6 * MIB / 10
                else -> 3 * MIB / 10
            }
        }

        /** Below this much, a body that came in whole says nothing about the speed. */
        private const val MIN_SPEED_BYTES = 16 * 1024

        /** No video (nor segment of one) is smaller than this; a whole body this small is an error message. */
        private const val MIN_VIDEO_BYTES = 1024

        /** OkHttp's own time limit is a little after the probe's, which stops reading by itself. */
        private const val CALL_SLACK_MS = 250L

        /** Master playlists pointing at master playlists, followed this deep. */
        private const val MAX_MASTER_DEPTH = 2

        /** Results kept before the expired ones are swept out. */
        private const val MAX_KEPT = 500

        private val RESOLUTION = Regex("RESOLUTION=(\\d+)[xX](\\d+)")
        private val BANDWIDTH = Regex("(?<![-A-Z])BANDWIDTH=(\\d+)")

        private fun looksLikeHls(url: String) = url.contains(".m3u8", ignoreCase = true)

        private fun kindOf(url: String) = if (looksLikeHls(url)) KIND_HLS else KIND_FILE

        /** host:port, so that two services on one machine (or on 127.0.0.1) are told apart. */
        private fun hostOf(url: String): String? = url.toHttpUrlOrNull()?.let { "${it.host}:${it.port}" }

        private fun millisSince(nanos: Long) = (System.nanoTime() - nanos) / 1_000_000
    }
}
