package tvbox.engine.core.drive

import okhttp3.OkHttpClient
import tvbox.engine.core.model.Episode
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.PlayLine
import tvbox.engine.core.model.Subtitle
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.store.EngineStore
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * The user's drives: AList / OpenList, WebDAV and folders on the engine's machine, kept in the engine's [store]
 * with their credentials. Clients get [DriveInfo], never a password or token.
 *
 * A drive's folder is also a video for the rest of the engine: site key `drive:<id>`, video id the folder's path,
 * one line whose episodes are the folder's video files (ids: their paths). So `/play/resolve`, the history and
 * resuming work for drive files as they do for a site's titles, and a folder of episodes plays as a playlist.
 *
 * Playing: a player gets the server's own address when it can fetch the file by itself, or else the engine's
 * `/drive/<id>/<path>`, which streams the file with `Range` ([open]): files of local folders, of drives with an
 * account (WebDAV), of drives set to go through the engine, and of servers on a loopback address when the player is
 * on another device.
 */
class DriveService(
    private val store: EngineStore,
    client: OkHttpClient,
    /** The engine as players on its own machine reach it, e.g. `http://127.0.0.1:9978`. */
    private val selfBase: String,
    /** Whether folders of the engine's machine can be drives: desktop and server engines, not the Android app. */
    val localFolders: Boolean,
    private val log: (String) -> Unit = {},
) {
    private val http: OkHttpClient = client.newBuilder()
        .followRedirects(true)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()
    private val session = AListSession()
    private val lock = Any()
    @Volatile private var drives: List<DriveConfig> = store.loadDrives()

    fun list(): List<DriveInfo> = drives.map { it.info() }

    fun get(id: String): DriveInfo = config(id).info()

    /**
     * Adds a drive. [fromThisMachine]: the caller is on the engine's machine; only such a caller may add a folder of
     * that machine (a paired device could otherwise open up any folder of it).
     */
    fun add(request: DriveRequest, fromThisMachine: Boolean): DriveInfo {
        val config = build(null, request, fromThisMachine)
        synchronized(lock) {
            drives = drives + config
            store.saveDrives(drives)
        }
        log("drive added: ${config.kind} ${config.name}")
        return config.info()
    }

    /** A folder of this machine as a drive, unless it is one already (`--drive-folder`). */
    fun ensureFolder(path: String): DriveInfo {
        val canonical = File(path).canonicalPath
        return drives.firstOrNull { it.kind == DriveKind.LOCAL && it.url == canonical }?.info()
            ?: add(DriveRequest(kind = DriveKind.LOCAL, url = path), fromThisMachine = true)
    }

    fun update(id: String, request: DriveRequest, fromThisMachine: Boolean): DriveInfo {
        val old = config(id)
        val config = build(old, request, fromThisMachine)
        synchronized(lock) {
            drives = drives.map { if (it.id == id) config else it }
            store.saveDrives(drives)
        }
        session.forget(id)
        return config.info()
    }

    fun remove(id: String) {
        config(id)
        synchronized(lock) {
            drives = drives.filter { it.id != id }
            store.saveDrives(drives)
        }
        session.forget(id)
    }

    /** Whether the drive [request] describes can be read: its first folder is listed. Nothing is saved. */
    suspend fun test(request: DriveRequest, fromThisMachine: Boolean): DriveTestResult {
        // Under an id of its own: a login of the saved drive must not stand in for the account being tried.
        val testId = "test-" + UUID.randomUUID().toString().take(8)
        return try {
            val old = request.id?.let { config(it) }
            val config = build(old, request, fromThisMachine).copy(id = testId)
            val count = backend(config).list("/").size
            DriveTestResult(ok = true, message = "连接成功，${if (count == 0) "文件夹是空的" else "有 $count 项"}", entries = count)
        } catch (e: DriveException) {
            DriveTestResult(ok = false, message = e.message.orEmpty())
        } finally {
            session.forget(testId)
        }
    }

    /** The folder [path] of a drive: folders first, then files, by name with numbers in order. */
    suspend fun listFolder(id: String, path: String): DriveListing {
        val config = config(id)
        val folder = DriveFiles.normalize(path, local = config.kind == DriveKind.LOCAL)
        val items = guarded(config, "list") { backend(config).list(folder) }
        return DriveListing(id, folder, items.map { it.entry }.sortedWith(DriveFiles.entryOrder))
    }

    /** Tries [password] on an AList folder; when AList takes it, it is kept for that folder and the ones below. */
    suspend fun unlock(id: String, path: String, password: String): DriveListing {
        val config = config(id)
        if (config.kind != DriveKind.ALIST) throw DriveException.bad("只有 AList / OpenList 的文件夹有密码")
        val folder = DriveFiles.normalize(path)
        val items = guarded(config, "unlock") { AListBackend(config, http, session, folder to password).list(folder) }
        synchronized(lock) {
            drives = drives.map { if (it.id == id) it.copy(folderPasswords = it.folderPasswords + (folder to password)) else it }
            store.saveDrives(drives)
        }
        return DriveListing(id, folder, items.map { it.entry }.sortedWith(DriveFiles.entryOrder))
    }

    /** A folder as a video: its video files are the episodes of one line, in name order. */
    suspend fun detail(id: String, path: String): VodDetail {
        val config = config(id)
        val listing = listFolder(id, path)
        val videos = listing.entries.filter { !it.dir && DriveFiles.isVideo(it.name) }.sortedWith { a, b -> DriveFiles.naturalOrder.compare(a.name, b.name) }
        val name = if (listing.path == "/") config.name else DriveFiles.nameOf(listing.path)
        return VodDetail(
            site = siteKey(id),
            id = listing.path,
            name = name,
            content = config.name + if (listing.path == "/") "" else " · " + listing.path,
            remarks = if (videos.isEmpty()) "没有视频" else "${videos.size} 个视频",
            lines = if (videos.isEmpty()) emptyList() else listOf(PlayLine(config.name, videos.map { Episode(it.path, DriveFiles.baseName(it.name)) })),
        )
    }

    /**
     * Where a player gets the file [path], and the subtitles beside it. [remote]: the player is on another device
     * than the engine (a server on a loopback address is then out of its reach).
     */
    suspend fun play(id: String, path: String, remote: Boolean): PlayInfo {
        val config = config(id)
        val file = DriveFiles.normalize(path, local = config.kind == DriveKind.LOCAL)
        if (file == "/") throw DriveException.bad("没有指定文件")
        val backend = backend(config)
        val siblings = guarded(config, "play") { backend.list(DriveFiles.parent(file)) }
        val item = siblings.firstOrNull { it.entry.path == file } ?: throw DriveException.notFound("文件不存在：$file")
        if (item.entry.dir) throw DriveException.bad("这是一个文件夹：$file")
        val viaEngine = config.proxy || (remote && DriveHttp.isLoopback(config.url))
        fun link(i: DriveItem): DirectLink = (if (viaEngine) null else backend.direct(i)) ?: DirectLink(engineUrl(config.id, i.entry.path))
        val video = link(item)
        val subtitles = DriveFiles.subtitlesFor(item.entry.name, siblings.map { it.entry }).map { (entry, lang) ->
            val sub = siblings.first { it.entry.path == entry.path }
            Subtitle(url = link(sub).url, name = entry.name, lang = lang, format = DriveFiles.extension(entry.name))
        }
        return PlayInfo(kind = "direct", url = video.url, headers = video.headers, subtitles = subtitles)
    }

    /** The bytes of a file for the engine's `/drive/<id>/<path>` route; [range] is the player's `Range` header. */
    suspend fun open(id: String, path: String, range: String?, head: Boolean): DriveStream {
        val config = config(id)
        val file = DriveFiles.normalize(path, local = config.kind == DriveKind.LOCAL)
        return guarded(config, "read") { backend(config).open(file, range, head) }
    }

    /** `/play/resolve` for a `drive:` site; null for any other site. */
    suspend fun resolveSite(site: String, episodeId: String, remote: Boolean): PlayInfo? =
        driveOf(site)?.let { play(it, episodeId, remote) }

    /** `/sites/{site}/detail` for a `drive:` site; null for any other site. */
    suspend fun detailSite(site: String, id: String): VodDetail? = driveOf(site)?.let { detail(it, id) }

    /** The engine's address of a file, for players: `<selfBase>/drive/<id>/<path>`. */
    fun engineUrl(id: String, path: String): String = "$selfBase/drive/${DriveFiles.encodeSegment(id)}${DriveFiles.encodePath(path)}"

    // ---- inside ----

    private fun config(id: String): DriveConfig = drives.firstOrNull { it.id == id } ?: throw DriveException.notFound("没有这个网盘")

    private fun backend(config: DriveConfig): DriveBackend = when (config.kind) {
        DriveKind.ALIST -> AListBackend(config, http, session)
        DriveKind.WEBDAV -> WebDavBackend(config, http)
        DriveKind.LOCAL -> if (localFolders) LocalBackend(config) else throw DriveException.bad("这台引擎不能打开本机文件夹")
        else -> throw DriveException.bad("不认识的网盘类型：${config.kind}")
    }

    /** Runs [block]; a failure is noted in the engine's log by the drive's name, never with its credentials. */
    private suspend fun <T> guarded(config: DriveConfig, what: String, block: suspend () -> T): T = try {
        block()
    } catch (e: DriveException) {
        log("drive ${config.name}: $what failed: ${e.code} ${e.message}")
        throw e
    }

    /** A new drive from [request], or [old] changed by it; checked, normalised, credentials out of the address. */
    private fun build(old: DriveConfig?, request: DriveRequest, fromThisMachine: Boolean): DriveConfig {
        val kind = (request.kind ?: old?.kind ?: throw DriveException.bad("缺少类型（alist / webdav / local）")).lowercase()
        if (kind !in DriveKind.all) throw DriveException.bad("不认识的网盘类型：$kind")
        var url = (request.url ?: old?.url ?: "").trim()
        var username = (request.username ?: old?.username ?: "").trim()
        var password = request.password ?: old?.password ?: ""
        val token = (request.token ?: old?.token ?: "").trim()
        when (kind) {
            DriveKind.LOCAL -> {
                if (!localFolders) throw DriveException.bad("这台引擎不能打开本机文件夹")
                val changed = old == null || old.kind != DriveKind.LOCAL || old.url != url
                if (changed && !fromThisMachine) throw DriveException("LOCAL_ONLY", 403, "只能在引擎所在的设备上添加本机文件夹")
                val dir = File(url)
                if (url.isEmpty() || !dir.isAbsolute) throw DriveException.bad("请填写文件夹的完整路径")
                if (!dir.isDirectory) throw DriveException.bad("文件夹不存在：$url")
                url = dir.canonicalPath
                username = ""
                password = ""
            }
            else -> {
                if (!url.startsWith("http://", true) && !url.startsWith("https://", true)) throw DriveException.bad("地址要以 http:// 或 https:// 开头")
                // user:password@host: the account goes where it is kept safe, the address keeps only the host.
                val scheme = url.substringBefore("://")
                val rest = url.substringAfter("://")
                val authority = rest.substringBefore('/')
                if ('@' in authority) {
                    val info = authority.substringBeforeLast('@')
                    if (username.isEmpty()) username = DriveFiles.decodePath(info.substringBefore(':'))
                    if (password.isEmpty() && ':' in info) password = DriveFiles.decodePath(info.substringAfter(':'))
                    url = scheme + "://" + authority.substringAfterLast('@') + rest.substring(authority.length)
                }
                url = url.trimEnd('/')
            }
        }
        val name = (request.name ?: old?.name ?: "").trim().ifEmpty { defaultName(kind, url) }
        return DriveConfig(
            id = old?.id ?: newId(),
            name = name,
            kind = kind,
            url = url,
            username = username,
            password = password,
            token = if (kind == DriveKind.ALIST) token else "",
            root = if (kind == DriveKind.LOCAL) "/" else DriveFiles.normalize(request.root ?: old?.root ?: "/"),
            proxy = request.proxy ?: old?.proxy ?: false,
            // Passwords of folders belong to the server they were typed in for.
            folderPasswords = if (old != null && old.url == url && old.kind == kind && old.root == (request.root?.let { DriveFiles.normalize(it) } ?: old.root)) old.folderPasswords else emptyMap(),
            addedAt = old?.addedAt ?: System.currentTimeMillis(),
        )
    }

    private fun defaultName(kind: String, url: String): String = when (kind) {
        DriveKind.LOCAL -> File(url).name.ifEmpty { url }
        else -> url.substringAfter("://").substringBefore('/').substringBefore(':').ifEmpty { if (kind == DriveKind.ALIST) "AList" else "WebDAV" }
    }

    private fun newId(): String {
        while (true) {
            val id = UUID.randomUUID().toString().replace("-", "").take(8)
            if (drives.none { it.id == id }) return id
        }
    }

    private fun DriveConfig.info() = DriveInfo(
        id = id,
        name = name,
        kind = kind,
        url = url,
        username = username,
        hasPassword = password.isNotEmpty(),
        hasToken = token.isNotEmpty(),
        root = root,
        proxy = proxy,
        lockedFolders = folderPasswords.keys.sorted(),
        addedAt = addedAt,
        site = siteKey(id),
    )

    companion object {
        /** Site keys of drives; TVBox site keys never look like this. */
        const val SITE_PREFIX = "drive:"

        fun siteKey(id: String) = SITE_PREFIX + id

        /** The drive id of a `drive:` site key; null for any other site. */
        fun driveOf(site: String): String? = site.takeIf { it.startsWith(SITE_PREFIX) }?.removePrefix(SITE_PREFIX)?.takeIf { it.isNotEmpty() }
    }
}
