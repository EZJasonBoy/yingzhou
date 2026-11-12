package tvbox.engine.core.util

import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES helpers with the exact semantics of TVBox's `com.github.tvbox.osc.util.AES`.
 *
 * Android's provider names the padding "PKCS7Padding"; on the JVM it is "PKCS5Padding".
 * For AES (16-byte blocks) the two are identical.
 */
object TvboxAes {

    /** Trims, then truncates or right-pads with [pad] to exactly [length] characters. */
    fun rightPadding(key: String, pad: String, length: Int): String {
        val trimmed = key.trim()
        return when {
            trimmed.length >= length -> trimmed.substring(0, length)
            else -> trimmed + pad.repeat(length - trimmed.length)
        }
    }

    /** Hex string to bytes. A trailing odd character is ignored, as in the original. */
    fun hexToBytes(hex: String): ByteArray {
        val n = hex.length / 2
        return ByteArray(n) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    /** Decrypts hex-encoded [data] with AES/ECB; [key] is right-padded with '0' to 16 chars. Null on failure. */
    fun ecb(data: String, key: String): String? = runCatching {
        val keySpec = SecretKeySpec(rightPadding(key, "0", 16).toByteArray(), "AES")
        val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, keySpec)
        String(cipher.doFinal(hexToBytes(data)))
    }.getOrNull()

    /** Decrypts hex-encoded [data] with AES/CBC. [key] and [iv] are used as-is. Null on failure. */
    fun cbc(data: String, key: String, iv: String): String? = runCatching {
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key.toByteArray(), "AES"), IvParameterSpec(iv.toByteArray()))
        String(cipher.doFinal(hexToBytes(data)))
    }.getOrNull()
}
