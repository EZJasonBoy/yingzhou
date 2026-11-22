package tvbox.engine.core.play

import tvbox.engine.core.util.UriUtil
import java.math.BigDecimal

/**
 * Removes ads from HLS playlists, after Box / TVBoxOS `M3U8` (themselves after FongMi/TV):
 *
 * - relative segment, key and map URIs are made absolute, so the cleaned playlist can be served from the engine;
 * - ad patterns from the config's `rules` ([PlayRules.adsFor]): an `#EXT...` regex removes what it matches; a
 *   number removes `#EXT-X-DISCONTINUITY` blocks whose first segment or total duration starts with it (`-n`: the
 *   last segment);
 * - optionally a cautious heuristic: segments from a minority path inside a discontinuity block, when one path
 *   serves at least 80% of the playlist (ads are usually spliced in from elsewhere).
 *
 * The original playlist is kept whenever cleaning would remove more than half of it.
 */
object M3u8Cleaner {
    class Result(val text: String, val removed: Int)

    private val BLOCK = Regex("#EXT-X-DISCONTINUITY[\\s\\S]*?(?=#EXT-X-DISCONTINUITY|$)")
    private val DURATION = Regex("#EXTINF:([\\d.]+)")
    private val URI_ATTR = Regex("URI=\"(.+?)\"")
    private const val ENDLIST = "#EXT-X-ENDLIST"

    fun isMaster(text: String) = text.contains("#EXT-X-STREAM-INF")

    /** A master playlist with every variant / rendition passed through [wrap] (absolute url in, url to use out). */
    fun rewriteMaster(text: String, baseUrl: String, wrap: (String) -> String): String {
        val lines = normalize(text).split('\n')
        return lines.mapIndexed { i, line ->
            when {
                line.isBlank() -> line
                line.startsWith("#EXT-X-MEDIA") || line.startsWith("#EXT-X-I-FRAME-STREAM-INF") ->
                    URI_ATTR.replace(line) { m -> "URI=\"${if (line.startsWith("#EXT-X-MEDIA")) wrap(abs(baseUrl, m.groupValues[1])) else abs(baseUrl, m.groupValues[1])}\"" }
                line.startsWith("#") -> line
                i > 0 && lines.subList(0, i).lastOrNull { it.isNotBlank() }?.startsWith("#EXT-X-STREAM-INF") == true -> wrap(abs(baseUrl, line.trim()))
                else -> abs(baseUrl, line.trim())
            }
        }.joinToString("\n")
    }

    fun clean(text: String, baseUrl: String, ads: List<String>, heuristic: Boolean): Result {
        val resolved = resolve(normalize(text), baseUrl)
        val total = segments(resolved).size
        var out = resolved
        var removed = 0

        var byDuration = false
        for (ad in ads) {
            if (ad.contains("#EXT-X-DISCONTINUITY") || ad.contains("#EXTINF")) {
                val regex = runCatching { Regex(ad) }.getOrNull() ?: continue
                val matches = regex.findAll(out).map { it.value }.filter { it.isNotEmpty() }.toList()
                for (m in matches) {
                    removed += DURATION.findAll(m).count()
                    out = out.replace(m.replace(ENDLIST, ""), "")
                }
            } else if ((ad.toDoubleOrNull() ?: 0.0) != 0.0) {
                byDuration = true
            }
        }
        if (byDuration) {
            val numeric = ads.filter { (it.toDoubleOrNull() ?: 0.0) != 0.0 }
            for (block in BLOCK.findAll(out).map { it.value }.toList()) {
                val durations = DURATION.findAll(block).map { BigDecimal(it.groupValues[1].trimEnd('.')) }.toList()
                if (durations.isEmpty()) continue
                val first = durations.first().toPlainString()
                val last = durations.last().toPlainString()
                val sum = durations.fold(BigDecimal.ZERO, BigDecimal::add).toPlainString()
                val isAd = numeric.any { ad -> if (ad.startsWith("-")) last.startsWith(ad.substring(1)) else first.startsWith(ad) || sum.startsWith(ad) }
                if (isAd) {
                    out = out.replace(block.replace(ENDLIST, ""), "")
                    removed += durations.size
                }
            }
        }
        if (heuristic) {
            val (text2, n) = removeMinority(out)
            out = text2
            removed += n
        }
        if (removed == 0) return Result(resolved, 0)
        val left = segments(out).size
        if (left == 0 || removed > total / 2) return Result(resolved, 0)
        return Result(out, removed)
    }

    private fun normalize(text: String) = text.removePrefix("﻿").replace("\r\n", "\n").replace('\r', '\n')

    private fun abs(base: String, ref: String) = if (ref.startsWith("http://") || ref.startsWith("https://")) ref else UriUtil.resolve(base, ref)

    private fun resolve(text: String, base: String): String = routeResources(text) { abs(base, it) }

    fun routeResources(text: String, route: (String) -> String): String = text.lineSequence().joinToString("\n") { line ->
        when {
            line.isBlank() -> line
            line.startsWith("#EXT-X-KEY") || line.startsWith("#EXT-X-MAP") -> URI_ATTR.replace(line) { m -> "URI=\"${route(m.groupValues[1])}\"" }
            line.startsWith("#") -> line
            else -> route(line.trim())
        }
    }

    private fun segments(text: String) = text.split('\n').filter { it.isNotBlank() && !it.startsWith("#") }

    /** Path key of a segment: its directory plus the file name without trailing digits and extension. */
    private fun key(url: String): String {
        val path = url.substringBefore('?')
        val name = path.substringAfterLast('/')
        return path.substringBeforeLast('/') + "/" + name.replace(Regex("\\d+(\\.\\w+)?$"), "")
    }

    private fun removeMinority(text: String): Pair<String, Int> {
        val lines = text.split('\n').toMutableList()
        val segIdx = lines.indices.filter { lines[it].isNotBlank() && !lines[it].startsWith("#") }
        if (segIdx.size < 10) return text to 0
        val keys = segIdx.associateWith { key(lines[it]) }
        val counts = keys.values.groupingBy { it }.eachCount()
        if (counts.size <= 1) return text to 0
        val (main, mainCount) = counts.maxByOrNull { it.value }!!
        if (mainCount < segIdx.size * 0.8) return text to 0
        // Only minority segments that sit in a discontinuity block (an ad splice) are removed.
        var inSplice = false
        val drop = ArrayList<Int>()
        for (i in lines.indices) {
            val line = lines[i]
            if (line.startsWith("#EXT-X-DISCONTINUITY")) inSplice = true
            val k = keys[i] ?: continue
            if (k == main) inSplice = false else if (inSplice) drop += i
        }
        if (drop.isEmpty() || drop.size > segIdx.size * 0.3) return text to 0
        for (i in drop) {
            lines[i] = ""
            // The segment's own tags (#EXTINF, #EXT-X-BYTERANGE) right above it.
            var j = i - 1
            while (j >= 0 && (lines[j].startsWith("#EXTINF") || lines[j].startsWith("#EXT-X-BYTERANGE"))) {
                lines[j] = ""
                j--
            }
        }
        return lines.filter { it.isNotEmpty() }.joinToString("\n") to drop.size
    }
}
