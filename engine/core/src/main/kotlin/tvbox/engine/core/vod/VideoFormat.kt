package tvbox.engine.core.vod

/** TVBox `DefaultConfig.isVideoFormat`: whether a url can be played directly without a parser. */
object VideoFormat {
    private val SNIFFER = Regex(
        "http((?!http).){12,}?\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3|aac|mpd)\\?.*|" +
            "http((?!http).){12,}\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3|aac|mpd)|" +
            "http((?!http).)*?video/tos*|" +
            "http((?!http).){20,}?/m3u8\\?pt=m3u8.*|" +
            "http((?!http).)*?default\\.ixigua\\.com/.*|" +
            "http((?!http).)*?dycdn-tos\\.pstatp[^\\?]*|" +
            "http.*?/player/m3u8play\\.php\\?url=.*|" +
            "http.*?/player/.*?[pP]lay\\.php\\?url=.*|" +
            "http.*?/playlist/m3u8/\\?vid=.*|" +
            "http.*?\\.php\\?type=m3u8&.*|" +
            "http.*?/download.aspx\\?.*|" +
            "http.*?/api/up_api.php\\?.*|" +
            "https.*?\\.66yk\\.cn.*|" +
            "http((?!http).)*?netease\\.com/file/.*",
    )

    fun isVideo(url: String): Boolean {
        // Original first requires a non-empty Uri path.
        val afterScheme = url.substringAfter("://", "")
        val path = afterScheme.substringAfter('/', "")
        if (afterScheme.isEmpty() || path.isEmpty()) return false
        return SNIFFER.containsMatchIn(url)
    }
}
