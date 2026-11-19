package tvbox.engine.core.util

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.zip.GZIPInputStream
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/**
 * Text files from the network as text: subtitles and danmaku come in whatever encoding their author's editor used
 * (GBK is common for Chinese subtitles, Big5 for traditional Chinese ones, UTF-16 from Windows tools), sometimes
 * compressed (Bilibili serves its danmaku XML as raw deflate), and servers rarely say so correctly.
 */
object TextDecoding {
    /** Decompressed text is cut off here: a few MB is a long film's worth of subtitles or danmaku. */
    const val MAX_BYTES = 64 * 1024 * 1024

    /**
     * [bytes] as text. In order: a byte order mark; UTF-16 without one (every other byte zero); valid UTF-8; the
     * [declared] charset (from a Content-Type) when it reads without errors; else whichever of GB18030 (a superset
     * of GBK) and Big5 gives more of the most common Chinese characters.
     */
    fun decode(bytes: ByteArray, declared: String? = null): String {
        if (bytes.isEmpty()) return ""
        bom(bytes)?.let { (charset, skip) -> return String(bytes, skip, bytes.size - skip, charset) }
        utf16WithoutBom(bytes)?.let { return String(bytes, it) }
        strict(bytes, Charsets.UTF_8)?.let { return it }
        declared?.trim()?.takeIf { it.isNotEmpty() }?.let { name ->
            val charset = runCatching { Charset.forName(name) }.getOrNull()
            if (charset != null && charset != Charsets.UTF_8) strict(bytes, charset)?.let { return it }
        }
        val gb = strict(bytes, charset("GB18030"))
        val big5 = strict(bytes, charset("Big5"))
        return when {
            gb != null && big5 != null -> if (score(big5) > score(gb)) big5 else gb
            gb != null -> gb
            big5 != null -> big5
            // Nothing reads cleanly: UTF-8 with replacement characters keeps whatever is ASCII.
            else -> String(bytes, Charsets.UTF_8)
        }
    }

    /**
     * Undoes compression the bytes may carry without saying so: gzip (magic `1F 8B`), zlib (`78 xx`), and raw
     * deflate when the bytes do not look like text at all. Anything else comes back as it is.
     */
    fun unpack(bytes: ByteArray): ByteArray {
        if (bytes.size < 2) return bytes
        val b0 = bytes[0].toInt() and 0xFF
        val b1 = bytes[1].toInt() and 0xFF
        if (b0 == 0x1F && b1 == 0x8B) return runCatching { readAll(GZIPInputStream(ByteArrayInputStream(bytes))) }.getOrDefault(bytes)
        if (b0 == 0x78 && (b0 * 256 + b1) % 31 == 0) {
            runCatching { readAll(InflaterInputStream(ByteArrayInputStream(bytes))) }.getOrNull()?.let { return it }
        }
        return rawInflate(bytes)?.takeIf { looksLikeText(it) } ?: bytes
    }

    /** Raw deflate (no header), or null unless the bytes are one complete deflate stream. */
    private fun rawInflate(bytes: ByteArray): ByteArray? {
        val inflater = Inflater(true)
        return try {
            inflater.setInput(bytes)
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (!inflater.finished()) {
                val n = inflater.inflate(buffer)
                if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break
                out.write(buffer, 0, n)
                if (out.size() > MAX_BYTES) return null
            }
            if (inflater.finished() && out.size() > 0) out.toByteArray() else null
        } catch (e: java.util.zip.DataFormatException) {
            null
        } finally {
            inflater.end()
        }
    }

    /** Unpacks and decodes. */
    fun text(bytes: ByteArray, declared: String? = null): String = decode(unpack(bytes), declared)

    /** The charset of a Content-Type header (`text/plain; charset=gbk` → `gbk`), or null. */
    fun charsetOf(contentType: String?): String? =
        contentType?.split(';')?.map { it.trim() }?.firstOrNull { it.startsWith("charset=", ignoreCase = true) }
            ?.substringAfter('=')?.trim('"', ' ')?.takeIf { it.isNotEmpty() }

    private fun bom(b: ByteArray): Pair<Charset, Int>? = when {
        b.size >= 3 && b[0] == 0xEF.toByte() && b[1] == 0xBB.toByte() && b[2] == 0xBF.toByte() -> Charsets.UTF_8 to 3
        b.size >= 2 && b[0] == 0xFF.toByte() && b[1] == 0xFE.toByte() -> Charsets.UTF_16LE to 2
        b.size >= 2 && b[0] == 0xFE.toByte() && b[1] == 0xFF.toByte() -> Charsets.UTF_16BE to 2
        else -> null
    }

    /** Mostly ASCII text written as UTF-16 has a zero in every other byte. */
    private fun utf16WithoutBom(b: ByteArray): Charset? {
        val n = minOf(b.size and 1.inv(), 4096)
        if (n < 8) return null
        var evenZeros = 0
        var oddZeros = 0
        for (i in 0 until n step 2) {
            if (b[i].toInt() == 0) evenZeros++
            if (b[i + 1].toInt() == 0) oddZeros++
        }
        val pairs = n / 2
        return when {
            oddZeros > pairs * 0.4 && evenZeros < pairs * 0.05 -> Charsets.UTF_16LE
            evenZeros > pairs * 0.4 && oddZeros < pairs * 0.05 -> Charsets.UTF_16BE
            else -> null
        }
    }

    private fun strict(bytes: ByteArray, charset: Charset): String? = try {
        charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (e: CharacterCodingException) {
        null
    }

    private fun charset(name: String): Charset = Charset.forName(name)

    /** How many of the text's characters are among the most common ones, in simplified or traditional form. */
    private fun score(text: String): Int = text.count { it in COMMON }

    private fun looksLikeText(b: ByteArray): Boolean {
        val n = minOf(b.size, 512)
        var control = 0
        for (i in 0 until n) {
            val c = b[i].toInt() and 0xFF
            if (c < 0x09 || (c in 0x0E..0x1F)) control++
        }
        return control * 20 < n
    }

    private fun readAll(input: InputStream): ByteArray = input.use {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val read = it.read(buffer)
            if (read < 0) break
            out.write(buffer, 0, read)
            if (out.size() > MAX_BYTES) break
        }
        out.toByteArray()
    }

    private val COMMON: Set<Char> = (
        "的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知样现分将外但身些与高意进把法此实回二理美点月明其种声全工己话儿者向情部正名定女问力机给等几很最间新什打便位因重被走电四第门相次东海口使西再真听气信少关并内加由却代先山五太水万眼体别处总才场师书比住员九笑性通目马命张活难神数件安表原车白应路期叫死常提感金何更反合放做系计或利受光王果亲界及今京务制解各任至清物台象记边共风战干接它许八特觉望直服毛林题建南度统色字请交爱让认算论百吃义科怎元社术结六功指思非流每青管夫连远资队跟带花快条院变联言权往展该领传近留红治决周保达办运武半候七必城父强步完革深区即求品士转量空甚众技轻程告江语英基派满式李息写呢识极令黄德收脸钱倒未持取设始版双历越史商千片容研像找友孩站广改议形委早房音火际则首单据导影失拿网香似专石若兵弟谁校读志飞观争究包组造落视济喜离虽坏兴切" +
            "這來個們說為時過對裡後麼開發經頭見現樣實點動兩長進聲話兒問機給幾間電門東氣關內並卻萬體別處總師書員場報難數車應會學國從與當還沒當聽寫認識從來讓愛覺親邊戰許題請統論產軍廣議顯號紅運帶張隊條義遠樓種將歲視聽"
        ).toSet()
}
