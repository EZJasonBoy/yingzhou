package tvbox.engine.core.drive

import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.StringReader
import java.util.Locale
import javax.xml.parsers.DocumentBuilderFactory
import org.xml.sax.InputSource

/**
 * WebDAV (AList's and OpenList's `/dav`, Nextcloud, Synology, Jianguoyun, rclone, ...): `PROPFIND` with `Depth: 1`
 * for folders, `GET` for files, Basic authentication. Only reads.
 *
 * Files of a drive with an account are served to players by the engine, which adds the credentials; the account
 * never goes to a player or a client.
 */
internal class WebDavBackend(private val config: DriveConfig, private val http: OkHttpClient) : DriveBackend {
    private val base = config.url.trimEnd('/')

    /** The DAV folder's own path on the server (`/dav`), plus the drive's start folder: what hrefs are relative to. */
    private val serverRoot = DriveFiles.join(
        DriveFiles.normalize(DriveFiles.decodePath(base.substringAfter("://").substringAfter('/', "").substringBefore('?'))),
        DriveFiles.normalize(config.root),
    )

    private val auth: String? = config.username.takeIf { it.isNotEmpty() }?.let { Credentials.basic(it, config.password, Charsets.UTF_8) }

    private fun url(path: String, folder: Boolean): String {
        val rest = DriveFiles.encodePath(DriveFiles.join(DriveFiles.normalize(config.root), path))
        return base + (if (rest == "/") "" else rest) + if (folder) "/" else ""
    }

    override suspend fun list(path: String): List<DriveItem> {
        val request = Request.Builder()
            .url(url(path, folder = true))
            .method("PROPFIND", Propfind.BODY.toRequestBody(XML))
            .header("Depth", "1")
            .apply { auth?.let { header("Authorization", it) } }
            .build()
        val (status, text) = DriveHttp.execute(http.newCall(request)).use { it.code to DriveHttp.text(it) }
        when (status) {
            207, 200 -> Unit
            401 -> throw DriveException.auth(if (auth == null) "这个 WebDAV 需要用户名和密码" else "WebDAV 的用户名或密码不对")
            403 -> throw DriveException.auth("WebDAV 服务器不让访问这个文件夹")
            404 -> throw DriveException.notFound("文件夹不存在：$path")
            405 -> throw DriveException.unreachable("这个地址不支持 WebDAV（HTTP 405），地址通常以 /dav 之类结尾")
            else -> throw DriveException.unreachable("WebDAV 服务器回答 HTTP $status")
        }
        val raw = Propfind.parse(text) ?: throw DriveException.unreachable("服务器的回答不是 WebDAV 目录")
        val folder = DriveFiles.join(serverRoot, path)
        return raw.mapNotNull { r ->
            runCatching {
                val serverPath = DriveFiles.normalize(DriveFiles.decodePath(hrefPath(r.href)))
                val inDrive = DriveFiles.relative(serverPath, serverRoot) ?: return@mapNotNull null
                // The folder itself is in the answer too; and only its children belong in the list.
                if (serverPath == folder || DriveFiles.parent(inDrive) != path) return@mapNotNull null
                val name = DriveFiles.nameOf(inDrive)
                DriveItem(DriveEntry(name, inDrive, r.dir, if (r.dir) 0 else r.size, r.modified, DriveFiles.type(name, r.dir)))
            }.getOrNull()
        }
    }

    /** Without an account players fetch the file themselves; with one, through the engine. */
    override fun direct(item: DriveItem): DirectLink? = if (auth == null) DirectLink(url(item.entry.path, folder = false)) else null

    override suspend fun open(path: String, range: String?, head: Boolean): DriveStream {
        val request = Request.Builder().url(url(path, folder = false)).apply {
            if (head) head() else get()
            range?.let { header("Range", it) }
            auth?.let { header("Authorization", it) }
        }.build()
        return DriveHttp.relay(DriveHttp.execute(http.newCall(request)), DriveFiles.nameOf(path), head)
    }

    /** An href is an absolute path or a whole url; its path, query and fragment cut off. */
    private fun hrefPath(href: String): String {
        val h = href.trim()
        val path = if (h.startsWith("http://", true) || h.startsWith("https://", true)) "/" + h.substringAfter("://").substringAfter('/', "") else h
        return path.substringBefore('?').substringBefore('#')
    }

    companion object {
        private val XML = "application/xml; charset=utf-8".toMediaType()
    }
}

/**
 * `PROPFIND` request body and answer. Ported from MisaTV (GPL-3.0, `lib/services/webdav/dav.dart`): servers write
 * the `DAV:` prefix differently (`d:`, `D:`, `lp1:`...), so elements are matched by local name, and the `propstat`
 * with status 200 is taken when there are several.
 */
internal object Propfind {
    const val BODY = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" +
        "<d:propfind xmlns:d=\"DAV:\"><d:prop>" +
        "<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/><d:getcontenttype/>" +
        "</d:prop></d:propfind>"

    data class Raw(val href: String, val displayName: String, val dir: Boolean, val size: Long, val modified: Long)

    /** The responses in a `multistatus`; null when [xml] is not one. Text from the network: parsed, nothing in it runs. */
    fun parse(xml: String): List<Raw>? {
        val text = xml.trim()
        if (text.isEmpty()) return null
        // No document type, no entities: nothing in the answer can make the parser read files or other addresses.
        val upper = text.uppercase(Locale.ROOT)
        if ("<!DOCTYPE" in upper || "<!ENTITY" in upper) return null
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            isExpandEntityReferences = false
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
        }
        val doc = runCatching { factory.newDocumentBuilder().parse(InputSource(StringReader(text))) }.getOrNull() ?: return null
        val root = doc.documentElement ?: return null
        if (root.local() != "multistatus") return null
        return root.children().filter { it.local() == "response" }.mapNotNull { response ->
            val href = response.child("href")?.textContent?.trim().orEmpty()
            if (href.isEmpty()) return@mapNotNull null
            val prop = firstProp(response) ?: return@mapNotNull null
            val dir = prop.child("resourcetype")?.children()?.any { it.local() == "collection" } ?: false
            Raw(
                href = href,
                displayName = prop.child("displayname")?.textContent?.trim().orEmpty(),
                dir = dir,
                size = prop.child("getcontentlength")?.textContent?.trim()?.toLongOrNull()?.coerceAtLeast(0) ?: 0,
                modified = DriveFiles.parseHttpDate(prop.child("getlastmodified")?.textContent.orEmpty()),
            )
        }
    }

    /** The `prop` of the `propstat` with status 200, else the first one. */
    private fun firstProp(response: Element): Element? {
        var fallback: Element? = null
        for (propstat in response.children().filter { it.local() == "propstat" }) {
            val prop = propstat.child("prop") ?: continue
            if (propstat.child("status")?.textContent?.contains("200") == true) return prop
            if (fallback == null) fallback = prop
        }
        return fallback
    }

    private fun Element.local(): String = (localName ?: nodeName.substringAfter(':')).lowercase(Locale.ROOT)

    private fun Element.children(): List<Element> {
        val out = ArrayList<Element>()
        val nodes = childNodes
        for (i in 0 until nodes.length) (nodes.item(i) as? Element)?.let { if (it.nodeType == Node.ELEMENT_NODE) out += it }
        return out
    }

    private fun Element.child(local: String): Element? = children().firstOrNull { it.local() == local }
}
