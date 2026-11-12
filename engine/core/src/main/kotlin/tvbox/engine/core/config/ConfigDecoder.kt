package tvbox.engine.core.config

import com.google.gson.JsonParser
import com.google.gson.Strictness
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import tvbox.engine.core.util.TvboxAes
import java.io.StringReader
import java.util.Base64

/**
 * Turns a downloaded subscription body into config JSON text.
 * Port of TVBox `ApiConfig.FindResult`, which recognises three wrappers:
 *
 * 1. **Image-embedded**: arbitrary bytes (usually a JPEG), then an 8-char alphanumeric marker followed by `**`,
 *    then base64 of the payload. The payload may itself be one of the formats below.
 * 2. **`2423…` AES-CBC**: a hex string; see [decodeCbc].
 * 3. **`;pk;` AES-ECB**: hex ciphertext, key supplied after `;pk;` in the subscription URL.
 *
 * Anything that is already JSON is returned unchanged. On any failure the raw input is returned, as in the original.
 */
object ConfigDecoder {
    private val IMAGE_MARKER = Regex("[A-Za-z0-9]{8}\\*\\*")
    private const val BOM = '﻿'

    fun decode(raw: String, key: String? = null): String {
        // Not in the original: strip a UTF-8 BOM, which some hand-edited configs carry.
        val input = raw.trimStart(BOM)
        if (isJson(input)) return input
        return try {
            var content = input
            IMAGE_MARKER.find(content)?.let { match ->
                content = content.substring(content.indexOf(match.value) + 10)
                content = String(Base64.getMimeDecoder().decode(content))
            }
            content = content.trim().trimStart(BOM)
            when {
                content.startsWith("2423") -> decodeCbc(content) ?: input
                key != null && !isJson(content) -> TvboxAes.ecb(content, key) ?: input
                else -> content
            }
        } catch (e: Exception) {
            input
        }
    }

    /**
     * `2423…` format. The whole string is hex; decoded as text it reads `$#<key>#$<ciphertext bytes><13-char iv>`.
     * The ciphertext used for decryption is the hex between `2324` (`#$`) and the last 26 hex chars (the iv).
     * Key and iv are lower-cased and right-padded with '0' to 16 chars.
     */
    private fun decodeCbc(hexIn: String): String? {
        val hex = hexIn.replace(Regex("\\s+"), "")
        val data = hex.substring(hex.indexOf("2324") + 4, hex.length - 26)
        val text = String(TvboxAes.hexToBytes(hex)).lowercase()
        val key = TvboxAes.rightPadding(text.substring(text.indexOf("$#") + 2, text.indexOf("#$")), "0", 16)
        val iv = TvboxAes.rightPadding(text.substring(text.length - 13), "0", 16)
        return TvboxAes.cbc(data, key, iv)
    }

    /**
     * Mirrors Android's `new JSONObject(content)` check: lenient, and true when the first value is an object
     * (trailing content is ignored, comments are allowed).
     */
    fun isJson(content: String): Boolean = try {
        val reader = JsonReader(StringReader(content)).apply { strictness = Strictness.LENIENT }
        reader.peek() == JsonToken.BEGIN_OBJECT && JsonParser.parseReader(reader).isJsonObject
    } catch (e: Exception) {
        false
    }
}
