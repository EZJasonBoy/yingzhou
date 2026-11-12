package tvbox.engine.core.config

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class ConfigDecoderTest {
    private val json = """{"sites":[{"key":"a","type":1,"api":"http://x/api.php"}]}"""

    @Test
    fun `plain json passes through`() {
        assertEquals(json, ConfigDecoder.decode(json))
    }

    @Test
    fun `utf8 bom is stripped`() {
        assertEquals(json, ConfigDecoder.decode("﻿" + json))
    }

    @Test
    fun `json with comments counts as json`() {
        assertTrue(ConfigDecoder.isJson("// note\n{\"a\":1}"))
        assertFalse(ConfigDecoder.isJson("not json"))
        assertFalse(ConfigDecoder.isJson("[1,2]"))
    }

    @Test
    fun `image embedded base64 payload`() {
        val fakeJpeg = "ÿØÿàJFIF garbage "
        val body = fakeJpeg + "Abcd1234**" + Base64.getEncoder().encodeToString(json.toByteArray())
        assertEquals(json, ConfigDecoder.decode(body))
    }

    @Test
    fun `pk key aes ecb`() {
        val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec("secret0000000000".toByteArray(), "AES"))
        val hex = cipher.doFinal(json.toByteArray()).toHex()
        assertEquals(json, ConfigDecoder.decode(hex, "secret"))
    }

    @Test
    fun `image embedded payload that is itself ecb encrypted`() {
        val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec("secret0000000000".toByteArray(), "AES"))
        val hex = cipher.doFinal(json.toByteArray()).toHex()
        val body = "ÿØxx" + "Zz9Yy8Xx**" + Base64.getEncoder().encodeToString(hex.toByteArray())
        assertEquals(json, ConfigDecoder.decode(body, "secret"))
    }

    @Test
    fun `2423 aes cbc format`() {
        val key = "abcd1234"
        val iv13 = "0123456789abc"
        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec("abcd123400000000".toByteArray(), "AES"),
            IvParameterSpec("0123456789abc000".toByteArray()),
        )
        val ciphertext = cipher.doFinal(json.toByteArray())
        val hex = "$#".toByteArray().toHex() + key.toByteArray().toHex() + "#$".toByteArray().toHex() +
            ciphertext.toHex() + iv13.toByteArray().toHex()
        assertTrue(hex.startsWith("2423"))
        assertEquals(json, ConfigDecoder.decode(hex))
    }

    @Test
    fun `undecodable input is returned unchanged`() {
        assertEquals("hello", ConfigDecoder.decode("hello", "secret"))
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
