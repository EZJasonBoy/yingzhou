package tvbox.engine.core.download

import java.io.File
import java.io.IOException
import java.io.OutputStream
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Turns a downloaded HLS episode into one file people can keep: the segments one after the other, AES-128 segments
 * decrypted with their keys on the way.
 *
 * - MPEG-TS segments make a `.ts` file. Every segment must be plain MPEG-TS (it starts with the sync byte 0x47 once
 *   decrypted); sources that dress segments up as something else (a picture header in front, say) cannot be joined
 *   like this.
 * - Fragmented MP4 (one `#EXT-X-MAP`) makes an `.mp4`: the initialisation map, then the fragments.
 * - Anything else (`SAMPLE-AES`, several maps) would need ffmpeg to remux, which the engine does not bring and does
 *   not install.
 *
 * Works from the download's playlist as the engine keeps it ([BASE] in front of the number of each file).
 */
object DownloadExport {
    /** What the addresses of a download's own files begin with in the playlist it keeps. */
    const val BASE = "{{DL}}/"

    class Unsupported(message: String) : Exception(message)

    class Piece(val number: Int, val key: Int?, val iv: ByteArray?)

    class Plan(val format: String, val map: Int?, val pieces: List<Piece>)

    fun plan(playlist: String): Plan {
        var sequence = 0L
        var key: Int? = null
        var iv: ByteArray? = null
        var map: Int? = null
        val pieces = ArrayList<Piece>()
        for (raw in playlist.replace("\r\n", "\n").split('\n')) {
            val line = raw.trim()
            when {
                line.isEmpty() -> Unit
                line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> sequence = line.substringAfter(':').trim().toLongOrNull() ?: 0
                line.startsWith("#EXT-X-KEY") -> {
                    val method = attr(line, "METHOD") ?: "NONE"
                    when {
                        method.equals("NONE", ignoreCase = true) -> {
                            key = null
                            iv = null
                        }
                        method.equals("AES-128", ignoreCase = true) -> {
                            key = attr(line, "URI")?.let(::number) ?: throw Unsupported("这一集的密钥不在下载的文件里，导出不了")
                            iv = attr(line, "IV")?.let(::hex)
                        }
                        else -> throw Unsupported("这一集用 $method 加密，只能在映舟里播放；导出成一个文件需要 ffmpeg 转换，映舟没有附带 ffmpeg")
                    }
                }
                line.startsWith("#EXT-X-MAP") -> {
                    val n = attr(line, "URI")?.let(::number) ?: throw Unsupported("这一集的初始化分段不在下载的文件里，导出不了")
                    if (map != null && map != n) throw Unsupported("这一集中途换了编码（有多个初始化分段），拼接成一个文件需要 ffmpeg，映舟没有附带 ffmpeg")
                    map = n
                }
                line.startsWith("#") -> Unit
                else -> {
                    val n = number(line) ?: throw Unsupported("这一集有分片不在下载的文件里，导出不了")
                    pieces += Piece(n, key, if (key == null) null else iv ?: sequenceIv(sequence + pieces.size))
                }
            }
        }
        if (pieces.isEmpty()) throw Unsupported("这一集没有分片")
        return Plan(if (map != null) "mp4" else "ts", map, pieces)
    }

    /**
     * Writes the file of [plan] to [out]; [file] finds a file of the download by its number. Answers the bytes
     * written. Throws [Unsupported] when a segment turns out not to be MPEG-TS (nothing useful has been written then
     * only if it is the first; the caller throws away what it wrote).
     */
    fun write(plan: Plan, file: (Int) -> File?, out: OutputStream): Long {
        var written = 0L
        val keys = HashMap<Int, ByteArray>()
        fun open(n: Int): File = file(n) ?: throw IOException("下载的文件少了一个（$n），请重新下载这一集")
        plan.map?.let { m ->
            val bytes = open(m).readBytes()
            out.write(bytes)
            written += bytes.size
        }
        for ((i, piece) in plan.pieces.withIndex()) {
            var bytes = open(piece.number).readBytes()
            if (piece.key != null) {
                val key = keys.getOrPut(piece.key) { open(piece.key).readBytes() }
                bytes = decrypt(bytes, key, piece.iv!!, i)
            }
            if (plan.format == "ts" && (bytes.isEmpty() || bytes[0] != TS_SYNC)) {
                throw Unsupported("第 ${i + 1} 个分片不是标准的 MPEG-TS（片源可能给分片加了伪装），拼接成一个文件需要 ffmpeg 转换，映舟没有附带 ffmpeg；这一集仍可在映舟里离线播放")
            }
            out.write(bytes)
            written += bytes.size
        }
        out.flush()
        return written
    }

    /**
     * Looks at the start of every file before anything is written, so that a download that cannot be joined is
     * reported as such instead of as a file broken off half way: every segment must be there, and for `.ts` start
     * with the sync byte once decrypted (only the first block is decrypted for that).
     */
    fun check(plan: Plan, file: (Int) -> File?) {
        val keys = HashMap<Int, ByteArray>()
        plan.map?.let { if (file(it)?.isFile != true) throw IOException("下载的文件少了一个（$it），请重新下载这一集") }
        for ((i, piece) in plan.pieces.withIndex()) {
            val f = file(piece.number)?.takeIf { it.isFile } ?: throw IOException("下载的文件少了一个（${piece.number}），请重新下载这一集")
            if (plan.format != "ts") continue
            val head = ByteArray(16)
            val n = f.inputStream().use { input -> var got = 0; while (got < 16) { val r = input.read(head, got, 16 - got); if (r < 0) break; got += r }; got }
            val first = if (piece.key != null) {
                val key = keys.getOrPut(piece.key) { file(piece.key)?.readBytes() ?: throw IOException("下载的密钥不见了，请重新下载这一集") }
                if (key.size != 16 || n < 16) throw Unsupported("第 ${i + 1} 个分片解密不了，导出不了")
                Cipher.getInstance("AES/CBC/NoPadding").run {
                    init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(piece.iv!!))
                    doFinal(head)
                }[0]
            } else if (n > 0) head[0] else 0
            if (first != TS_SYNC) {
                throw Unsupported("第 ${i + 1} 个分片不是标准的 MPEG-TS（片源可能给分片加了伪装），拼接成一个文件需要 ffmpeg 转换，映舟没有附带 ffmpeg；这一集仍可在映舟里离线播放")
            }
        }
    }

    /** AES-128-CBC; the padding is taken off when it is valid PKCS#7 (some sources leave it out altogether). */
    private fun decrypt(data: ByteArray, key: ByteArray, iv: ByteArray, index: Int): ByteArray {
        if (key.size != 16) throw Unsupported("密钥应是 16 字节，下载到的是 ${key.size} 字节，导出不了")
        if (data.size % 16 != 0) throw Unsupported("第 ${index + 1} 个分片的长度不是 16 的倍数，解密不了")
        val plain = Cipher.getInstance("AES/CBC/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            doFinal(data)
        }
        val pad = plain.lastOrNull()?.toInt()?.and(0xFF) ?: 0
        val padded = pad in 1..16 && pad <= plain.size && (plain.size - pad until plain.size).all { plain[it].toInt() and 0xFF == pad }
        return if (padded) plain.copyOf(plain.size - pad) else plain
    }

    /** The initialisation vector HLS uses when the key names none: the segment's sequence number, big-endian. */
    fun sequenceIv(sequence: Long): ByteArray = ByteArray(16).also { iv ->
        for (i in 0 until 8) iv[15 - i] = (sequence ushr (8 * i)).toByte()
    }

    private fun number(uri: String): Int? = uri.takeIf { it.startsWith(BASE) }?.removePrefix(BASE)?.substringBefore('.')?.toIntOrNull()

    private fun attr(line: String, name: String): String? {
        val m = Regex("(?:^|[:,])\\s*$name=(\"([^\"]*)\"|[^,]*)").find(line) ?: return null
        return if (m.groupValues[2].isNotEmpty() || m.groupValues[1].startsWith("\"")) m.groupValues[2] else m.groupValues[1].trim()
    }

    private fun hex(text: String): ByteArray? {
        val digits = text.removePrefix("0x").removePrefix("0X")
        if (digits.isEmpty() || digits.length > 32 || digits.any { Character.digit(it, 16) < 0 }) return null
        val padded = digits.padStart(32, '0')
        return ByteArray(16) { i -> padded.substring(2 * i, 2 * i + 2).toInt(16).toByte() }
    }

    private const val TS_SYNC = 0x47.toByte()
}
