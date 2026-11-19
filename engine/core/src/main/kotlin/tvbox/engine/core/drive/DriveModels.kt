package tvbox.engine.core.drive

import kotlinx.serialization.Serializable

// Cloud drives and folders the user plays their own videos from (docs/protocol.md, "网盘"). A drive's password and
// token stay in the engine's store: clients only ever see [DriveInfo].

/** A drive as the engine keeps it, credentials included. Never sent to clients. */
@Serializable
data class DriveConfig(
    val id: String,
    val name: String,
    /** [DriveKind.ALIST], [DriveKind.WEBDAV] or [DriveKind.LOCAL]. */
    val kind: String,
    /** AList / OpenList: the site's address. WebDAV: the address of the DAV folder. Local: a folder on the engine's machine. */
    val url: String,
    val username: String = "",
    val password: String = "",
    /** AList: a token from its settings, sent instead of logging in. */
    val token: String = "",
    /** AList / WebDAV: the folder on the server the drive starts at; the drive's "/" is this folder. */
    val root: String = "/",
    /** True: players always get files through the engine, never from the server directly. */
    val proxy: Boolean = false,
    /** AList folder passwords the user typed in, by folder path inside the drive. */
    val folderPasswords: Map<String, String> = emptyMap(),
    val addedAt: Long = 0,
)

object DriveKind {
    const val ALIST = "alist"
    const val WEBDAV = "webdav"
    const val LOCAL = "local"
    val all = listOf(ALIST, WEBDAV, LOCAL)
}

/** What clients see of a drive. Whether it has a password or token, but never what it is. */
@Serializable
data class DriveInfo(
    val id: String,
    val name: String,
    val kind: String,
    val url: String,
    val username: String = "",
    val hasPassword: Boolean = false,
    val hasToken: Boolean = false,
    val root: String = "/",
    val proxy: Boolean = false,
    /** AList folders the engine knows a password for (the passwords themselves stay in the engine). */
    val lockedFolders: List<String> = emptyList(),
    val addedAt: Long = 0,
    /** The site key the drive's folders go by in `/play/resolve`, `/sites/{site}/detail` and the history. */
    val site: String = "",
)

/**
 * Adding, changing or testing a drive. On a change a field that is null stays as it was; for [password] and [token]
 * an empty string removes them.
 */
@Serializable
data class DriveRequest(
    val name: String? = null,
    val kind: String? = null,
    val url: String? = null,
    val username: String? = null,
    val password: String? = null,
    val token: String? = null,
    val root: String? = null,
    val proxy: Boolean? = null,
    /** For a test: the saved drive whose password / token stand in for those this request leaves out (an edit form). */
    val id: String? = null,
)

@Serializable
data class DriveEntry(
    val name: String,
    /** Path inside the drive, from its "/". */
    val path: String,
    val dir: Boolean,
    /** Bytes; 0 when unknown. */
    val size: Long = 0,
    /** Epoch ms; 0 when unknown. */
    val modified: Long = 0,
    /** folder | video | subtitle | other */
    val type: String = "other",
)

@Serializable
data class DriveListing(
    val drive: String,
    val path: String,
    val entries: List<DriveEntry> = emptyList(),
)

@Serializable
data class DriveTestResult(
    val ok: Boolean,
    val message: String = "",
    /** How many entries the drive's first folder has. */
    val entries: Int = 0,
)

@Serializable
data class DriveUnlockRequest(
    val path: String = "/",
    val password: String = "",
)

/** Why a drive operation failed; [status] is the HTTP status the API answers with. */
class DriveException(val code: String, val status: Int, message: String) : Exception(message) {
    companion object {
        fun notFound(message: String) = DriveException("NOT_FOUND", 404, message)
        fun bad(message: String) = DriveException("BAD_REQUEST", 400, message)
        /** The folder (an AList folder) needs a password; [path] is the folder. */
        fun password(path: String, wrong: Boolean) =
            DriveException("DRIVE_PASSWORD", 403, if (wrong) "文件夹密码不对：$path" else "这个文件夹需要密码：$path")
        /** The server did not accept the drive's account. Not 401: that tells clients their engine token is bad. */
        fun auth(message: String) = DriveException("DRIVE_AUTH", 403, message)
        fun unreachable(message: String) = DriveException("DRIVE_UNREACHABLE", 502, message)
        fun outside(path: String) = DriveException("DRIVE_PATH", 403, "不在添加的文件夹里：$path")
    }
}
