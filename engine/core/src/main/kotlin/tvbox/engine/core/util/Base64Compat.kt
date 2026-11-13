package tvbox.engine.core.util

import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString

/**
 * Base64 that works on every Android version the client supports (java.util.Base64 needs Android 8.0,
 * many TV boxes run 7.x). Backed by okio, which OkHttp already brings.
 */
object Base64Compat {
    /** Like android.util.Base64.DEFAULT: characters outside the alphabet (line breaks, spaces) are ignored. URL-safe input is accepted. */
    fun decode(text: String): ByteArray {
        val cleaned = buildString(text.length) {
            for (c in text) {
                if (c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '+' || c == '/' || c == '-' || c == '_' || c == '=') append(c)
            }
        }
        return cleaned.decodeBase64()?.toByteArray() ?: throw IllegalArgumentException("invalid base64")
    }

    fun encode(bytes: ByteArray, urlSafe: Boolean = false, padding: Boolean = true): String {
        val s = if (urlSafe) bytes.toByteString().base64Url() else bytes.toByteString().base64()
        return if (padding) s else s.trimEnd('=')
    }
}
