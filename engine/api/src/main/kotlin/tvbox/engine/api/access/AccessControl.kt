package tvbox.engine.api.access

import tvbox.engine.core.store.AccessState
import tvbox.engine.core.store.EngineStore
import tvbox.engine.core.store.MemoryStore
import tvbox.engine.core.store.PairedDevice
import tvbox.engine.core.util.Base64Compat
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Starts and stops listening on the network for [AccessControl]; the standalone server provides one. */
interface LanHost {
    fun apply(enabled: Boolean)
    fun status(): LanHostStatus
}

data class LanHostStatus(
    val listening: Boolean,
    /** Where other devices reach the engine, e.g. `http://192.168.1.5:9978`. */
    val addresses: List<String>,
    /** Whether the engine is announced over mDNS. */
    val discoverable: Boolean,
    val name: String,
    val port: Int,
    val error: String = "",
)

/**
 * Who may use the engine from other machines (docs/protocol.md, "鉴权").
 *
 * - Callers on this machine need nothing (decided by the plugin, see [installAccess]).
 * - Other devices pair once with a short one-time code the engine shows, and get a token
 *   (`<device id>.<secret>`); only a hash of the secret is stored. Tokens are named per device and revocable.
 * - Media players cannot send our header, so engine addresses handed to a client (`/m3u8`, `/proxy`) carry a
 *   signature in the query instead ([sign], [checkSignature]): HMAC over the path and every parameter, bound to
 *   the device and an expiry. Revoking the device or switching sharing off invalidates its signatures too.
 *
 * Wrong codes: after [MAX_TRIES] the code is burnt and pairing is locked for everybody for a minute, doubling up to
 * 15 minutes; even the right code is refused while locked. Thread-safe.
 */
class AccessControl(
    private val store: EngineStore = MemoryStore(),
    /** False where the engine never listens on the network (the Android app): nobody else gets in. */
    val supported: Boolean = false,
    /** `--lan`: sharing is on whatever the saved switch says. */
    val forced: Boolean = false,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: SecureRandom = SecureRandom(),
) {
    /** Called whenever a new pairing code is made (a headless engine prints it). */
    @Volatile var onCode: (code: String, expiresAt: Long) -> Unit = { _, _ -> }

    /** Listens on the network when sharing is on; null where the engine cannot (tests, Android). */
    @Volatile var host: LanHost? = null

    /** Paths anybody may use (raw path prefixes, e.g. `/demo/` for the demo site). */
    @Volatile var publicPrefixes: List<String> = emptyList()

    private val lock = Any()
    @Volatile private var state: AccessState = store.loadAccess()
    private val localKey = ByteArray(32).also { random.nextBytes(it) }

    private var code: String? = null
    private var codeExpiresAt = 0L
    private var failures = 0
    private var lockLevel = 0
    private var lockedUntil = 0L

    data class Code(val code: String, val expiresAt: Long)

    sealed interface PairResult {
        data class Paired(val token: String, val device: PairedDevice) : PairResult
        /** No code was entered; one is showing on the engine now. */
        data object CodeRequired : PairResult
        data class Wrong(val triesLeft: Int) : PairResult
        data class Locked(val retryAfterMs: Long) : PairResult
        data object Off : PairResult
    }

    /** Who a request acts for: [LOCAL] or a paired device's id, and until when a signature it came with is good. */
    data class Grant(val subject: String, val expiresAt: Long? = null)

    val sharing: Boolean get() = supported && (forced || state.sharing)

    /** The owner's saved switch (without `--lan`). */
    val sharingSetting: Boolean get() = state.sharing

    fun devices(): List<PairedDevice> = state.devices

    fun setSharing(on: Boolean) {
        synchronized(lock) {
            state = state.copy(sharing = on)
            store.saveAccess(state)
        }
    }

    // ---- pairing codes ----

    fun currentCode(): Code? = synchronized(lock) { validCode() }

    fun lockedUntil(): Long = synchronized(lock) { if (clock() < lockedUntil) lockedUntil else 0 }

    /** A fresh code, replacing the one showing. */
    fun newCode(): Code = synchronized(lock) { mint() }.also { onCode(it.code, it.expiresAt) }

    /** The code showing, or a new one. */
    fun codeOrNew(): Code {
        var minted = false
        val c = synchronized(lock) { validCode() ?: mint().also { minted = true } }
        if (minted) onCode(c.code, c.expiresAt)
        return c
    }

    private fun validCode(): Code? {
        val c = code ?: return null
        if (clock() < codeExpiresAt) return Code(c, codeExpiresAt)
        code = null
        return null
    }

    private fun mint(): Code {
        val c = String.format("%06d", random.nextInt(1_000_000))
        code = c
        codeExpiresAt = clock() + CODE_TTL_MS
        failures = 0
        return Code(c, codeExpiresAt)
    }

    /** Trades a code for a token. [address] is the device's network address, for the device list. */
    fun pair(entered: String, name: String, address: String): PairResult {
        if (!sharing) return PairResult.Off
        var minted: Code? = null
        val result = synchronized(lock) {
            val now = clock()
            if (now < lockedUntil) return@synchronized PairResult.Locked(lockedUntil - now)
            val digits = entered.filter { it in '0'..'9' }
            if (digits.isEmpty()) {
                if (validCode() == null) minted = mint()
                return@synchronized PairResult.CodeRequired
            }
            val current = validCode()
            if (current == null || !MessageDigest.isEqual(digits.toByteArray(), current.code.toByteArray())) {
                failures++
                if (failures >= MAX_TRIES) {
                    code = null
                    failures = 0
                    lockedUntil = now + minOf(LOCK_BASE_MS shl lockLevel, LOCK_MAX_MS)
                    lockLevel = minOf(lockLevel + 1, 8)
                    return@synchronized PairResult.Locked(lockedUntil - now)
                }
                return@synchronized PairResult.Wrong(MAX_TRIES - failures)
            }
            code = null
            failures = 0
            lockLevel = 0
            val id = hex(bytes(8))
            val secret = Base64Compat.encode(bytes(32), urlSafe = true, padding = false)
            val device = PairedDevice(id, cleanName(name), sha256Hex(secret), createdAt = now, lastSeenAt = now, lastAddress = address)
            state = state.copy(devices = state.devices + device)
            store.saveAccess(state)
            PairResult.Paired("$id.$secret", device)
        }
        minted?.let { onCode(it.code, it.expiresAt) }
        return result
    }

    // ---- tokens ----

    /** The paired device a bearer token belongs to, or null. Does not look at the sharing switch. */
    fun deviceForToken(token: String): PairedDevice? {
        val id = token.substringBefore('.', "")
        val secret = token.substringAfter('.', "")
        if (id.isEmpty() || secret.isEmpty()) return null
        val device = state.devices.firstOrNull { it.id == id } ?: return null
        return device.takeIf { MessageDigest.isEqual(sha256Hex(secret).toByteArray(), it.tokenHash.toByteArray()) }
    }

    /** Notes when and from where a device was last seen; written at most once a minute per device. */
    fun seen(device: PairedDevice, address: String) {
        val now = clock()
        if (now - device.lastSeenAt < 60_000 && device.lastAddress == address) return
        synchronized(lock) {
            state = state.copy(devices = state.devices.map { if (it.id == device.id) it.copy(lastSeenAt = now, lastAddress = address) else it })
            store.saveAccess(state)
        }
    }

    fun revoke(id: String): Boolean = synchronized(lock) {
        val left = state.devices.filter { it.id != id }
        if (left.size == state.devices.size) return@synchronized false
        state = state.copy(devices = left)
        store.saveAccess(state)
        true
    }

    // ---- signed media addresses ----

    /**
     * [url] (absolute, `http://host[:port]/path?query`) with a `tvsig` parameter added that lets [subject]
     * ([LOCAL] or a device id) fetch exactly this address with GET until [expiresAt] (epoch ms).
     * A `tvsig` already on the url is replaced.
     */
    fun sign(url: String, subject: String, expiresAt: Long): String {
        val key = keyFor(subject) ?: return url
        val schemeEnd = url.indexOf("://")
        if (schemeEnd < 0) return url
        val pathStart = url.indexOf('/', schemeEnd + 3).let { if (it < 0) url.length else it }
        val origin = url.substring(0, pathStart)
        val rest = url.substring(pathStart).substringBefore('#')
        val rawPath = rest.substringBefore('?').ifEmpty { "/" }
        val rawQuery = rest.substringAfter('?', "").split('&').filter { it.isNotEmpty() && Canonical.name(it) != PARAM }.joinToString("&")
        val exp = (expiresAt / 1000).toString(36)
        val canonical = Canonical.of(rawPath, rawQuery) ?: return url
        val mac = mac(key, subject, exp, canonical)
        val sig = "$exp.$subject.$mac"
        return origin + rawPath + "?" + (if (rawQuery.isEmpty()) "" else "$rawQuery&") + PARAM + "=" + sig
    }

    /**
     * The grant a signed request carries, or null when the signature is missing, malformed, expired, for another
     * address, of a revoked device, or of a device while sharing is off. [LOCAL] signatures are only honoured for
     * callers on this machine ([peerLoopback]). Paths under `/api/` are never accepted with a signature.
     */
    fun checkSignature(rawPath: String, rawQuery: String, peerLoopback: Boolean): Grant? {
        val sigs = rawQuery.split('&').filter { Canonical.name(it) == PARAM }
        if (sigs.size != 1) return null
        val sig = Canonical.value(sigs[0]) ?: return null
        val parts = sig.split('.')
        if (parts.size != 3) return null
        val (exp, subject, mac) = parts
        val expiresAt = exp.toLongOrNull(36)?.takeIf { it in 1..Long.MAX_VALUE / 1000 }?.times(1000) ?: return null
        if (clock() >= expiresAt) return null
        if (subject == LOCAL) {
            if (!peerLoopback) return null
        } else if (!sharing) {
            return null
        }
        if (!Canonical.mediaPath(rawPath)) return null
        val key = keyFor(subject) ?: return null
        val canonical = Canonical.of(rawPath, rawQuery) ?: return null
        val expected = mac(key, subject, exp, canonical)
        return if (MessageDigest.isEqual(expected.toByteArray(), mac.toByteArray())) Grant(subject, expiresAt) else null
    }

    private fun keyFor(subject: String): ByteArray? =
        if (subject == LOCAL) localKey else state.devices.firstOrNull { it.id == subject }?.let { unhex(it.tokenHash) }

    private fun mac(key: ByteArray, subject: String, exp: String, canonical: String): String {
        val m = Mac.getInstance("HmacSHA256")
        m.init(SecretKeySpec(key, "HmacSHA256"))
        val out = m.doFinal("tvsig1\n$subject\n$exp\n$canonical".toByteArray(Charsets.UTF_8))
        return Base64Compat.encode(out.copyOf(16), urlSafe = true, padding = false)
    }

    private fun bytes(n: Int) = ByteArray(n).also { random.nextBytes(it) }

    companion object {
        const val PARAM = "tvsig"
        const val LOCAL = "local"
        const val MAX_TRIES = 5
        const val CODE_TTL_MS = 10 * 60_000L
        const val LOCK_BASE_MS = 60_000L
        const val LOCK_MAX_MS = 15 * 60_000L

        /** How long engine addresses in a play answer stay good; live lists are kept longer by clients. */
        const val PLAY_TTL_MS = 24 * 3600_000L
        const val LIVE_TTL_MS = 30 * 24 * 3600_000L

        internal fun sha256Hex(s: String): String = hex(MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8)))

        private fun hex(b: ByteArray): String = buildString(b.size * 2) { b.forEach { append(String.format("%02x", it.toInt() and 0xff)) } }

        private fun unhex(s: String): ByteArray? {
            if (s.length % 2 != 0) return null
            return runCatching { ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() } }.getOrNull()
        }

        private fun cleanName(name: String): String =
            name.filter { !it.isISOControl() }.trim().take(40).ifEmpty { "未命名设备" }
    }
}

/**
 * The form a request address is signed in: path segments and query parameters percent-decoded to bytes and encoded
 * again strictly (only unreserved characters stay as they are), parameters other than `tvsig` sorted by name with the
 * order of repeated names kept. Two addresses the routes would read differently never share a canonical form, and a
 * parameter added to a signed address breaks the signature.
 */
internal object Canonical {
    fun of(rawPath: String, rawQuery: String): String? {
        val path = rawPath.split('/').map { encode(decode(it, plusIsSpace = false) ?: return null) }.joinToString("/")
        val pairs = ArrayList<Pair<String, String>>()
        for (part in rawQuery.split('&')) {
            if (part.isEmpty()) continue
            val n = decode(part.substringBefore('='), plusIsSpace = true) ?: return null
            val v = decode(part.substringAfter('=', ""), plusIsSpace = true) ?: return null
            val name = encode(n)
            if (name == AccessControl.PARAM) continue
            pairs += name to encode(v)
        }
        return path + "?" + pairs.sortedBy { it.first }.joinToString("&") { "${it.first}=${it.second}" }
    }

    /** The decoded name of a raw `name=value` pair, or null when it is malformed. */
    fun name(pair: String): String? = decode(pair.substringBefore('='), plusIsSpace = true)?.let { String(it, Charsets.UTF_8) }

    fun value(pair: String): String? = decode(pair.substringAfter('=', ""), plusIsSpace = true)?.let { String(it, Charsets.UTF_8) }

    /** Signatures are for media and spider proxies, never for the API, and never for paths with dot segments. */
    fun mediaPath(rawPath: String): Boolean {
        val segments = rawPath.split('/').map { decode(it, plusIsSpace = false)?.let { b -> String(b, Charsets.UTF_8) } ?: return false }
        if (segments.any { it == "." || it == ".." }) return false
        val first = segments.firstOrNull { it.isNotEmpty() } ?: return false
        return !first.equals("api", ignoreCase = true)
    }

    private fun decode(s: String, plusIsSpace: Boolean): ByteArray? {
        val out = java.io.ByteArrayOutputStream(s.length)
        var i = 0
        val raw = s.toByteArray(Charsets.UTF_8)
        while (i < raw.size) {
            val b = raw[i]
            when {
                b == '%'.code.toByte() -> {
                    if (i + 2 >= raw.size) return null
                    val hi = Character.digit(raw[i + 1].toInt(), 16)
                    val lo = Character.digit(raw[i + 2].toInt(), 16)
                    if (hi < 0 || lo < 0) return null
                    out.write(hi * 16 + lo)
                    i += 3
                    continue
                }
                plusIsSpace && b == '+'.code.toByte() -> out.write(' '.code)
                else -> out.write(b.toInt())
            }
            i++
        }
        return out.toByteArray()
    }

    private fun encode(bytes: ByteArray): String = buildString(bytes.size) {
        for (byte in bytes) {
            val c = byte.toInt() and 0xff
            if ((c in 'A'.code..'Z'.code) || (c in 'a'.code..'z'.code) || (c in '0'.code..'9'.code) || c == '-'.code || c == '.'.code || c == '_'.code || c == '~'.code) {
                append(c.toChar())
            } else {
                append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
            }
        }
    }
}
