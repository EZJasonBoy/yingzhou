package tvbox.engine.server

import java.io.ByteArrayOutputStream

/**
 * Makes up the video of the demo's slow source: H.264 in MPEG-TS, written here bit by bit, so the demo needs no
 * encoder, no video files in the repository and no third-party stream.
 *
 * The picture says where it is: the number of the segment, the time of its two seconds, a colour of its own per
 * segment, and a marker that moves with every frame. A frame that starts a group of pictures is stored raw (I_PCM
 * macroblocks); the frames after it only move the marker (two raw macroblocks, the rest skipped). Every frame is
 * padded with filler data to a fixed size, which gives the stream the bit rate asked for and makes every segment
 * exactly [segmentBytes] long: the byte-range playlist and the transport stream's continuity counters rely on that.
 */
class DemoVideo(
    /** Seconds per segment. */
    val segmentSeconds: Int = 6,
    /** Video bit rate, about; the transport stream adds a few percent. */
    kbit: Int = 2000,
) {
    private val mbCols = WIDTH / 16
    private val mbRows = CODED_HEIGHT / 16
    private val mbCount = mbCols * mbRows

    private val sps = nal(0x67, sps())
    private val pps = nal(0x68, pps())

    /** Sizes of the two kinds of access unit; whatever the picture does not need is filler. */
    private val keyBytes: Int
    private val deltaBytes: Int

    init {
        val perGop = kbit * 1000L / 8 * GOP_SECONDS
        val minKey = AUD.size + sps.size + pps.size + mbCount * (2 + 384) + 64
        val minDelta = AUD.size + 2 * (4 + 384) + 64
        keyBytes = maxOf(minKey, (perGop / 5).toInt())
        deltaBytes = maxOf(minDelta, ((perGop - keyBytes) / (GOP_FRAMES - 1)).toInt())
    }

    private val keyPackets = packetsFor(keyBytes)
    private val deltaPackets = packetsFor(deltaBytes)
    private val gopsPerSegment = segmentSeconds / GOP_SECONDS
    private val videoPacketsPerSegment = gopsPerSegment * (keyPackets + (GOP_FRAMES - 1) * deltaPackets)

    /** Every segment has this many bytes. */
    val segmentBytes: Int = (2 + videoPacketsPerSegment) * TS_PACKET

    init {
        require(segmentSeconds > 0 && segmentSeconds % GOP_SECONDS == 0) { "a segment is a whole number of ${GOP_SECONDS}s groups" }
    }

    /** Segment [index] (from 0) as a transport stream: PAT, PMT and [segmentSeconds] seconds of video. */
    fun segment(index: Int): ByteArray {
        val out = ByteArrayOutputStream(segmentBytes)
        out.write(psi(0, index and 15, PAT))
        out.write(psi(PMT_PID, index and 15, PMT))
        var counter = (index.toLong() * videoPacketsPerSegment % 16).toInt()
        val picture = Picture()
        for (g in 0 until gopsPerSegment) {
            val gop = index * gopsPerSegment + g
            picture.draw(index, gop * GOP_SECONDS)
            for (f in 0 until GOP_FRAMES) {
                val frame = gop.toLong() * GOP_FRAMES + f
                val unit = if (f == 0) keyFrame(picture, gop) else deltaFrame(picture, f)
                val pts = PTS_START + frame * TICKS_PER_FRAME
                counter = writePes(out, unit, pts, key = f == 0, counter)
            }
        }
        return out.toByteArray()
    }

    // ---- H.264 ----

    private fun sps(): ByteArray = Bits().apply {
        u(8, 66) // baseline profile
        u(8, 0xC0) // constraint_set0 and 1
        u(8, 31) // level 3.1
        ue(0) // seq_parameter_set_id
        ue(0) // log2_max_frame_num_minus4: frame_num has 4 bits
        ue(2) // pic_order_cnt_type: output order is decoding order
        ue(1) // max_num_ref_frames
        u(1, 0) // gaps_in_frame_num_value_allowed_flag
        ue(mbCols - 1)
        ue(mbRows - 1)
        u(1, 1) // frame_mbs_only_flag
        u(1, 1) // direct_8x8_inference_flag
        u(1, 1) // frame_cropping_flag: 192 coded rows, 180 shown
        ue(0); ue(0); ue(0); ue((CODED_HEIGHT - HEIGHT) / 2)
        u(1, 1) // vui_parameters_present_flag
        u(1, 0); u(1, 0); u(1, 0); u(1, 0) // aspect ratio, overscan, video signal type, chroma location
        u(1, 1) // timing_info_present_flag
        u(16, 0); u(16, 1) // num_units_in_tick = 1
        u(16, 0); u(16, 2 * FPS) // time_scale: two ticks per frame
        u(1, 1) // fixed_frame_rate_flag
        u(1, 0); u(1, 0) // no HRD parameters
        u(1, 0) // pic_struct_present_flag
        u(1, 1) // bitstream_restriction_flag: frames come out as they go in
        u(1, 1) // motion_vectors_over_pic_boundaries_flag
        ue(0); ue(0) // max_bytes_per_pic_denom, max_bits_per_mb_denom
        ue(10); ue(10) // log2_max_mv_length
        ue(0) // max_num_reorder_frames
        ue(1) // max_dec_frame_buffering
        trailing()
    }.bytes()

    private fun pps(): ByteArray = Bits().apply {
        ue(0); ue(0) // pic_parameter_set_id, seq_parameter_set_id
        u(1, 0) // entropy_coding_mode_flag: CAVLC
        u(1, 0) // bottom_field_pic_order_in_frame_present_flag
        ue(0) // num_slice_groups_minus1
        ue(0); ue(0) // num_ref_idx default active
        u(1, 0); u(2, 0) // weighted prediction
        se(0); se(0); se(0) // qp, qs, chroma qp offset
        u(1, 1) // deblocking_filter_control_present_flag (the slices switch the filter off)
        u(1, 0) // constrained_intra_pred_flag
        u(1, 0) // redundant_pic_cnt_present_flag
        trailing()
    }.bytes()

    /** An IDR picture with every macroblock stored raw, padded to [keyBytes]. */
    private fun keyFrame(picture: Picture, gop: Int): ByteArray {
        val slice = Bits(mbCount * 386 + 32).apply {
            ue(0) // first_mb_in_slice
            ue(7) // slice_type: I
            ue(0) // pic_parameter_set_id
            u(4, 0) // frame_num
            ue(gop and 0xFFFF) // idr_pic_id
            u(1, 0); u(1, 0) // no_output_of_prior_pics_flag, long_term_reference_flag
            se(0) // slice_qp_delta
            ue(1) // disable_deblocking_filter_idc
            for (mb in 0 until mbCount) {
                ue(25) // mb_type: I_PCM
                align()
                picture.macroblock(mb, this)
            }
            trailing()
        }.bytes()
        return unit(keyBytes, sps, pps, nal(0x65, slice))
    }

    /**
     * A P picture that copies the one before, except for the marker: its old place is restored and its new place
     * drawn, both as raw macroblocks. Padded to [deltaBytes].
     */
    private fun deltaFrame(picture: Picture, frameInGop: Int): ByteArray {
        val changed = picture.moveMarker(frameInGop)
        val slice = Bits(changed.size * 390 + 32).apply {
            ue(0) // first_mb_in_slice
            ue(5) // slice_type: P
            ue(0) // pic_parameter_set_id
            u(4, frameInGop and 15) // frame_num
            u(1, 0) // num_ref_idx_active_override_flag
            u(1, 0) // ref_pic_list_modification_flag_l0
            u(1, 0) // adaptive_ref_pic_marking_mode_flag
            se(0) // slice_qp_delta
            ue(1) // disable_deblocking_filter_idc
            var previous = -1
            for (mb in changed) {
                ue(mb - previous - 1) // mb_skip_run
                ue(30) // mb_type: I_PCM in a P slice
                align()
                picture.macroblock(mb, this)
                previous = mb
            }
            if (previous < mbCount - 1) ue(mbCount - 1 - previous)
            trailing()
        }.bytes()
        return unit(deltaBytes, nal(0x41, slice))
    }

    /** An access unit of exactly [size] bytes: delimiter, the given NAL units, filler. */
    private fun unit(size: Int, vararg nals: ByteArray): ByteArray {
        val out = ByteArray(size)
        var at = 0
        fun put(b: ByteArray) {
            System.arraycopy(b, 0, out, at, b.size)
            at += b.size
        }
        put(AUD)
        nals.forEach(::put)
        val filler = size - at - 6
        check(filler >= 0) { "the picture does not fit in $size bytes" }
        put(byteArrayOf(0, 0, 0, 1, 0x0C))
        java.util.Arrays.fill(out, at, at + filler, 0xFF.toByte())
        out[size - 1] = 0x80.toByte()
        return out
    }

    /** Start code, header byte and the payload with emulation prevention bytes. */
    private fun nal(header: Int, payload: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(payload.size + 16)
        out.write(byteArrayOf(0, 0, 0, 1, header.toByte()))
        var zeros = 0
        for (b in payload) {
            val v = b.toInt() and 0xFF
            if (zeros >= 2 && v <= 3) {
                out.write(3)
                zeros = 0
            }
            out.write(v)
            zeros = if (v == 0) zeros + 1 else 0
        }
        return out.toByteArray()
    }

    /** The frame being shown, as planes of samples. Sample values stay clear of 0..3, so nothing needs escaping. */
    private inner class Picture {
        private val y = ByteArray(WIDTH * CODED_HEIGHT)
        private val cb = ByteArray(WIDTH / 2 * (CODED_HEIGHT / 2))
        private val cr = ByteArray(WIDTH / 2 * (CODED_HEIGHT / 2))
        private var markerAt = -1

        /** The still picture of two seconds: segment number, time, a colour per segment. */
        fun draw(segment: Int, second: Int) {
            val hue = (segment * 67 % 360) / 360.0 * 2 * Math.PI
            val u = (128 + 60 * Math.cos(hue)).toInt().toByte()
            val v = (128 + 60 * Math.sin(hue)).toInt().toByte()
            for (row in 0 until CODED_HEIGHT) java.util.Arrays.fill(y, row * WIDTH, (row + 1) * WIDTH, shade(row))
            java.util.Arrays.fill(cb, u)
            java.util.Arrays.fill(cr, v)
            text("#%03d".format(segment), 20, 22, 9)
            text("%02d:%02d".format(second / 60, second % 60), 20, 96, 6)
            markerAt = -1
            paintMarker(0, on = true)
        }

        /** Moves the marker for frame [frameInGop]; the macroblocks that changed, in order. */
        fun moveMarker(frameInGop: Int): List<Int> {
            val old = markerAt
            paintMarker(old - MARKER_ROW * mbCols, on = false)
            paintMarker(frameInGop % mbCols, on = true)
            return listOf(old, markerAt).distinct().sorted()
        }

        /** The background: a little lighter towards the bottom. */
        private fun shade(row: Int): Byte = (48 + row * 40 / CODED_HEIGHT).toByte()

        private fun paintMarker(col: Int, on: Boolean) {
            val top = MARKER_ROW * 16
            for (r in top until top + 16) java.util.Arrays.fill(y, r * WIDTH + col * 16, r * WIDTH + col * 16 + 16, if (on) 235.toByte() else shade(r))
            if (on) markerAt = MARKER_ROW * mbCols + col
        }

        private fun text(s: String, left: Int, top: Int, scale: Int) {
            var x = left
            for (c in s) {
                val glyph = FONT[c] ?: continue
                for (gy in 0 until 7) for (gx in 0 until 5) {
                    if (glyph[gy][gx] != '#') continue
                    for (py in 0 until scale) {
                        val row = top + gy * scale + py
                        java.util.Arrays.fill(y, row * WIDTH + x + gx * scale, row * WIDTH + x + (gx + 1) * scale, 235.toByte())
                    }
                }
                x += 6 * scale
            }
        }

        /** The 384 samples of macroblock [mb]: 16x16 luma, then the two 8x8 chroma blocks. */
        fun macroblock(mb: Int, out: Bits) {
            val x = mb % mbCols * 16
            val top = mb / mbCols * 16
            for (r in 0 until 16) out.raw(y, (top + r) * WIDTH + x, 16)
            for (r in 0 until 8) out.raw(cb, (top / 2 + r) * (WIDTH / 2) + x / 2, 8)
            for (r in 0 until 8) out.raw(cr, (top / 2 + r) * (WIDTH / 2) + x / 2, 8)
        }
    }

    /** A bit writer for headers; [raw] copies whole bytes once the position is on a byte. */
    private class Bits(capacity: Int = 64) {
        private val out = ByteArrayOutputStream(capacity)
        private var current = 0
        private var filled = 0

        fun u(bits: Int, value: Int) {
            for (i in bits - 1 downTo 0) {
                current = (current shl 1) or ((value ushr i) and 1)
                if (++filled == 8) {
                    out.write(current)
                    current = 0
                    filled = 0
                }
            }
        }

        /** Exp-Golomb, unsigned and signed. */
        fun ue(value: Int) {
            val x = value + 1
            val length = 32 - Integer.numberOfLeadingZeros(x)
            u(length - 1, 0)
            u(length, x)
        }

        fun se(value: Int) = ue(if (value > 0) 2 * value - 1 else -2 * value)

        fun align() {
            while (filled != 0) u(1, 0)
        }

        fun raw(bytes: ByteArray, offset: Int, length: Int) {
            check(filled == 0)
            out.write(bytes, offset, length)
        }

        /** rbsp_trailing_bits */
        fun trailing() {
            u(1, 1)
            align()
        }

        fun bytes(): ByteArray = out.toByteArray()
    }

    // ---- MPEG-TS ----

    /** TS packets a frame of [unitBytes] takes: the first carries the clock reference and the PES header. */
    private fun packetsFor(unitBytes: Int): Int = 1 + (unitBytes + PES_HEADER - FIRST_PAYLOAD + 183) / 184

    /** One frame as a PES packet on the video PID; the continuity counter after it. */
    private fun writePes(out: ByteArrayOutputStream, unit: ByteArray, pts: Long, key: Boolean, counterIn: Int): Int {
        var counter = counterIn
        val pes = ByteArray(PES_HEADER + unit.size)
        pes[2] = 1
        pes[3] = 0xE0.toByte() // video stream; the length stays 0 (unbounded)
        pes[6] = 0x84.toByte() // data_alignment_indicator
        pes[7] = 0x80.toByte() // PTS only
        pes[8] = 5
        pes[9] = (0x21 or ((pts ushr 29).toInt() and 0x0E)).toByte()
        pes[10] = (pts ushr 22).toByte()
        pes[11] = (((pts ushr 14).toInt() and 0xFE) or 1).toByte()
        pes[12] = (pts ushr 7).toByte()
        pes[13] = (((pts shl 1).toInt() and 0xFE) or 1).toByte()
        System.arraycopy(unit, 0, pes, PES_HEADER, unit.size)

        val packet = ByteArray(TS_PACKET)
        var at = 0
        var first = true
        while (at < pes.size) {
            packet[0] = 0x47
            packet[1] = ((if (first) 0x40 else 0) or (VIDEO_PID shr 8)).toByte()
            packet[2] = VIDEO_PID.toByte()
            var payloadAt = 4
            val left = pes.size - at
            if (first) {
                // Adaptation field with the clock reference, half a second behind the picture.
                val pcr = pts - PCR_LEAD
                packet[3] = (0x30 or counter).toByte()
                packet[4] = 7
                packet[5] = (if (key) 0x50 else 0x10).toByte() // PCR, and random access on a key frame
                packet[6] = (pcr ushr 25).toByte()
                packet[7] = (pcr ushr 17).toByte()
                packet[8] = (pcr ushr 9).toByte()
                packet[9] = (pcr ushr 1).toByte()
                packet[10] = (((pcr shl 7).toInt() and 0x80) or 0x7E).toByte()
                packet[11] = 0
                payloadAt = 12
            } else if (left < 184) {
                // The last packet: stuffing in an adaptation field in front of what is left.
                val stuffing = 183 - left
                packet[3] = (0x30 or counter).toByte()
                packet[4] = stuffing.toByte()
                if (stuffing > 0) {
                    packet[5] = 0
                    java.util.Arrays.fill(packet, 6, 5 + stuffing, 0xFF.toByte())
                }
                payloadAt = 5 + stuffing
            } else {
                packet[3] = (0x10 or counter).toByte()
            }
            val n = TS_PACKET - payloadAt
            check(n <= left) { "frames are sized to fill their first packet" }
            System.arraycopy(pes, at, packet, payloadAt, n)
            at += n
            out.write(packet)
            counter = (counter + 1) and 15
            first = false
        }
        return counter
    }

    /** A PAT or PMT section in a packet of its own. */
    private fun psi(pid: Int, counter: Int, section: ByteArray): ByteArray {
        val packet = ByteArray(TS_PACKET) { 0xFF.toByte() }
        packet[0] = 0x47
        packet[1] = (0x40 or (pid shr 8)).toByte()
        packet[2] = pid.toByte()
        packet[3] = (0x10 or counter).toByte()
        packet[4] = 0 // pointer_field
        System.arraycopy(section, 0, packet, 5, section.size)
        return packet
    }

    companion object {
        const val WIDTH = 320
        const val HEIGHT = 180
        private const val CODED_HEIGHT = 192
        const val FPS = 25
        const val GOP_SECONDS = 2
        private const val GOP_FRAMES = FPS * GOP_SECONDS
        private const val MARKER_ROW = 10

        private const val TS_PACKET = 188
        private const val PMT_PID = 0x1000
        private const val VIDEO_PID = 0x100
        private const val PES_HEADER = 14
        private const val FIRST_PAYLOAD = TS_PACKET - 12
        private const val TICKS_PER_FRAME = 90_000L / FPS
        private const val PTS_START = 180_000L
        private const val PCR_LEAD = 45_000L

        private val AUD = byteArrayOf(0, 0, 0, 1, 0x09, 0xF0.toByte())

        private val PAT = section(0x00, 1, byteArrayOf(0, 1, (0xE0 or (PMT_PID shr 8)).toByte(), PMT_PID.toByte()))
        private val PMT = section(
            0x02,
            1,
            byteArrayOf(
                (0xE0 or (VIDEO_PID shr 8)).toByte(), VIDEO_PID.toByte(), // PCR_PID
                0xF0.toByte(), 0, // program_info_length
                0x1B, (0xE0 or (VIDEO_PID shr 8)).toByte(), VIDEO_PID.toByte(), 0xF0.toByte(), 0, // H.264 on the video PID
            ),
        )

        /** A PSI section: header, [body], CRC. */
        private fun section(tableId: Int, id: Int, body: ByteArray): ByteArray {
            val length = 5 + body.size + 4
            val out = ByteArray(3 + length)
            out[0] = tableId.toByte()
            out[1] = (0xB0 or (length shr 8)).toByte()
            out[2] = length.toByte()
            out[3] = (id shr 8).toByte()
            out[4] = id.toByte()
            out[5] = 0xC1.toByte() // version 0, current
            out[6] = 0
            out[7] = 0
            System.arraycopy(body, 0, out, 8, body.size)
            var crc = -1
            for (i in 0 until out.size - 4) {
                crc = crc xor (out[i].toInt() shl 24)
                repeat(8) { crc = if (crc < 0) (crc shl 1) xor 0x04C11DB7 else crc shl 1 }
            }
            for (i in 0 until 4) out[out.size - 4 + i] = (crc ushr (24 - 8 * i)).toByte()
            return out
        }

        private val FONT: Map<Char, List<String>> = mapOf(
            '0' to listOf(".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."),
            '1' to listOf("..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."),
            '2' to listOf(".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"),
            '3' to listOf(".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."),
            '4' to listOf("...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."),
            '5' to listOf("#####", "#....", "####.", "....#", "....#", "#...#", ".###."),
            '6' to listOf(".###.", "#....", "####.", "#...#", "#...#", "#...#", ".###."),
            '7' to listOf("#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."),
            '8' to listOf(".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."),
            '9' to listOf(".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."),
            ':' to listOf(".....", "..#..", "..#..", ".....", "..#..", "..#..", "....."),
            '#' to listOf(".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."),
        )
    }
}
