package tvbox.engine.core.store

import kotlinx.serialization.Serializable

/** A device that was paired with this engine and may use it from the network. */
@Serializable
data class PairedDevice(
    /** Short random id; it is the first half of the device's token and part of its signed media addresses. */
    val id: String,
    /** What the device called itself when it paired, for the list the owner sees. */
    val name: String,
    /** SHA-256 of the token's secret half, in hex. The token itself is never stored. */
    val tokenHash: String,
    val createdAt: Long,
    val lastSeenAt: Long = 0,
    val lastAddress: String = "",
)

/** Who may reach the engine from other machines: the LAN sharing switch and the paired devices. */
@Serializable
data class AccessState(
    /** The owner's switch. Off: the engine listens on this machine only and refuses everybody else. */
    val sharing: Boolean = false,
    val devices: List<PairedDevice> = emptyList(),
)
