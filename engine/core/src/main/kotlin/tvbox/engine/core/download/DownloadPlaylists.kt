package tvbox.engine.core.download

import tvbox.engine.core.play.HlsRewriter
import tvbox.engine.core.play.M3u8Cleaner
import tvbox.engine.core.util.UriUtil

internal class DownloadPlaylists(
    val videoUrl: String,
    val durationMs: Long,
    val workDurationMs: Long,
    val resources: List<HlsRewriter.Resource>,
    val index: String,
    val tracks: Map<String, String> = emptyMap(),
) {
    private class Variant(val url: String, val bandwidth: Long, val audioUrl: String?)
    private class Track(val url: String, val media: HlsRewriter.Result, val variant: Variant?)

    companion object {
        private val attribute = Regex("(?:^|,)\\s*([A-Z0-9-]+)=(?:\"([^\"]*)\"|([^,]*))")

        fun read(url: String, fetch: (String) -> Pair<String, String>, clean: (String, String, String) -> String): DownloadPlaylists {
            fun track(start: String): Track {
                var current = start
                var selectedAudio: Variant? = null
                repeat(3) {
                    val (text, finalUrl) = fetch(current)
                    require(text.removePrefix("\uFEFF").trimStart().startsWith("#EXTM3U")) { "播放地址给的不是 HLS 播放列表" }
                    if (!M3u8Cleaner.isMaster(text)) {
                        val cleaned = clean(text, current, finalUrl)
                        val media = HlsRewriter.rewrite(cleaned, finalUrl) ?: throw IllegalArgumentException(
                            if (cleaned.lineSequence().none { it.trim() == "#EXT-X-ENDLIST" }) "这是直播流（播放列表没有结尾），不能下载" else "播放列表里没有分片",
                        )
                        return Track(current, media, selectedAudio)
                    }
                    val variant = chooseVariant(text, finalUrl)
                    if (variant.audioUrl != null) selectedAudio = variant
                    current = variant.url
                }
                throw IllegalArgumentException("主播放列表套了太多层")
            }

            val video = track(url)
            val base = DownloadExport.BASE
            val media = video.media
            val variant = video.variant
            val audioUrl = variant?.audioUrl ?: return DownloadPlaylists(video.url, media.durationMs, media.durationMs, media.resources, media.render(base))
            val audio = track(audioUrl)
            require(audio.variant == null) { "独立音轨又引用了另一份音轨，无法完整下载" }
            val audioResources = audio.media.resources.map { it.copy(name = "audio-${it.name}") }
            val tracks = mapOf("video.m3u8" to media.render(base), "audio.m3u8" to audio.media.render(base, media.resources.size))
            val index = buildString {
                appendLine("#EXTM3U")
                appendLine("#EXT-X-VERSION:7")
                appendLine("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"默认音轨\",DEFAULT=YES,AUTOSELECT=YES,URI=\"${base}audio.m3u8\"")
                appendLine("#EXT-X-STREAM-INF:BANDWIDTH=${variant.bandwidth.coerceAtLeast(1)},AUDIO=\"audio\"")
                appendLine("${base}video.m3u8")
            }
            return DownloadPlaylists(video.url, media.durationMs, media.durationMs + audio.media.durationMs, media.resources + audioResources, index, tracks)
        }

        private fun chooseVariant(text: String, base: String): Variant {
            fun attributes(line: String) = attribute.findAll(line.substringAfter(':')).associate { match ->
                match.groupValues[1] to (match.groups[2]?.value ?: match.groupValues[3].trim())
            }
            val lines = text.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
            val groups = lines.asSequence().filter { it.startsWith("#EXT-X-MEDIA:") }.map(::attributes)
                .filter { it["TYPE"] == "AUDIO" }.groupBy { it["GROUP-ID"] }
            val variants = ArrayList<Variant>()
            var pending: Map<String, String>? = null
            for (line in lines) {
                if (line.startsWith("#EXT-X-STREAM-INF:")) pending = attributes(line)
                if (line.startsWith('#')) continue
                val fields = pending ?: continue
                pending = null
                val group = fields["AUDIO"]
                if (group != null && group !in groups) continue
                val audio = group?.let { groups.getValue(it) }?.let { options ->
                    options.firstOrNull { it["DEFAULT"] == "YES" } ?: options.firstOrNull { it["AUTOSELECT"] == "YES" } ?: options.first()
                }
                val audioUrl = audio?.get("URI")?.let { UriUtil.resolve(base, it) }
                variants += Variant(UriUtil.resolve(base, line), fields["BANDWIDTH"]?.toLongOrNull() ?: 0, audioUrl)
            }
            return variants.filter { it.audioUrl == null }.ifEmpty { variants }.maxByOrNull { it.bandwidth }
                ?: throw IllegalArgumentException("主播放列表里没有可完整下载的音视频线路")
        }
    }
}
