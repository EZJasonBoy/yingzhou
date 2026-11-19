package tvbox.engine.core.drive

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import tvbox.engine.core.store.JsonFileStore
import tvbox.engine.core.store.MemoryStore
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList

class DriveServiceTest {
    @TempDir
    lateinit var dir: File

    private val logs = CopyOnWriteArrayList<String>()
    private val servers = ArrayList<() -> Unit>()

    private fun service(store: tvbox.engine.core.store.EngineStore = MemoryStore(), localFolders: Boolean = true) =
        DriveService(store, OkHttpClient(), "http://127.0.0.1:9978", localFolders, log = { logs += it })

    @AfterEach
    fun stop() = servers.forEach { it() }

    private fun dav(user: String? = null, password: String? = null) = TestDav(user = user, password = password).also { servers += it::shutdown }
    private fun alist(token: String? = null, user: Pair<String, String>? = null, locked: Map<String, String> = emptyMap()) =
        TestAList(token, user, locked).also { servers += it::shutdown }

    private fun DriveStream.bytes(): ByteArray = use { it.body!!.readBytes() }

    // ---- AList ----

    @Test
    fun `AList lists folders with the token and plays files from its download route with their subtitles`(): Unit = runBlocking {
        val server = alist(token = "secret-token").apply {
            files["/剧集/第2集.mp4"] = testBytes("2")
            files["/剧集/第10集.mp4"] = testBytes("10")
            files["/剧集/第2集.srt"] = testBytes("s", 100)
            files["/剧集/说明.nfo"] = testBytes("n", 10)
            files["/电影/片.mkv"] = testBytes("m")
        }.start()
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "alist", url = server.url + "/", token = "secret-token"), fromThisMachine = false)
        assertEquals("drive:${drive.id}", drive.site)
        assertTrue(drive.hasToken)

        val root = drives.listFolder(drive.id, "/")
        assertEquals(listOf("剧集", "电影"), root.entries.map { it.name })
        assertTrue(server.requests.all { it.third == "secret-token" }, "AList's token goes in Authorization as it is")
        val folder = drives.listFolder(drive.id, "/剧集")
        assertEquals(listOf("第2集.mp4", "第2集.srt", "第10集.mp4", "说明.nfo"), folder.entries.map { it.name })
        assertEquals(listOf("video", "subtitle", "video", "other"), folder.entries.map { it.type })
        assertEquals(1714538096789L, folder.entries[0].modified)

        val detail = drives.detail(drive.id, "/剧集")
        assertEquals(listOf("/剧集/第2集.mp4", "/剧集/第10集.mp4"), detail.lines.single().episodes.map { it.id })
        assertEquals(listOf("第2集", "第10集"), detail.lines.single().episodes.map { it.name })

        // On this machine the player fetches from AList itself.
        val play = drives.play(drive.id, "/剧集/第2集.mp4", remote = false)
        assertTrue(play.url.startsWith(server.url + "/d/%E5%89%A7%E9%9B%86/%E7%AC%AC2%E9%9B%86.mp4?sign=sig-"), play.url)
        assertEquals(1, play.subtitles.size)
        assertEquals("srt", play.subtitles[0].format)
        assertTrue(play.subtitles[0].url.startsWith(server.url + "/d/"), play.subtitles[0].url)
        assertFalse(play.url.contains("secret-token") || play.headers.values.any { "secret-token" in it }, "the token never goes to a player")
        val fetched = OkHttpClient().newCall(okhttp3.Request.Builder().url(play.url).build()).execute().use { it.body!!.bytes() }
        assertArrayEquals(testBytes("2"), fetched, "the address works")

        // This AList is on a loopback address: a player on another device gets the file through the engine.
        val remote = drives.play(drive.id, "/剧集/第2集.mp4", remote = true)
        assertEquals("http://127.0.0.1:9978/drive/${drive.id}/%E5%89%A7%E9%9B%86/%E7%AC%AC2%E9%9B%86.mp4", remote.url)
        assertTrue(remote.subtitles.single().url.startsWith("http://127.0.0.1:9978/drive/${drive.id}/"))

        // Through the engine: the signature from fs/get, the player's range passed on; fs/get once per file.
        val part = drives.open(drive.id, "/剧集/第2集.mp4", "bytes=100-199", head = false)
        assertEquals(206, part.status)
        assertEquals("bytes 100-199/50000", part.headers["Content-Range"])
        assertArrayEquals(testBytes("2").copyOfRange(100, 200), part.bytes())
        drives.open(drive.id, "/剧集/第2集.mp4", "bytes=200-", head = false).close()
        assertEquals(1, server.requests.count { it.first == "/api/fs/get" })
        assertThrows(DriveException::class.java) { runBlocking { drives.play(drive.id, "/剧集/没有.mp4", remote = false) } }
        Unit
    }

    @Test
    fun `AList logs in with an account and logs in again when the token is refused`(): Unit = runBlocking {
        val server = alist(user = "me" to "pass word").apply { files["/a.mp4"] = testBytes("a") }.start()
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "alist", url = server.url, username = "me", password = "pass word"), fromThisMachine = true)
        drives.listFolder(drive.id, "/")
        drives.listFolder(drive.id, "/")
        assertEquals(1, server.requests.count { it.first == "/api/auth/login" }, "the login is kept")
        server.revoked = true
        assertEquals(listOf("a.mp4"), drives.listFolder(drive.id, "/").entries.map { it.name })
        assertEquals(2, server.requests.count { it.first == "/api/auth/login" })

        val wrong = drives.test(DriveRequest(kind = "alist", url = server.url, username = "me", password = "nope"), fromThisMachine = true)
        assertFalse(wrong.ok)
        assertTrue(wrong.message.contains("登录失败"), wrong.message)
        assertFalse(wrong.message.contains("nope"))
        val right = drives.test(DriveRequest(id = drive.id), fromThisMachine = true)
        assertTrue(right.ok, right.message)
        assertEquals(1, right.entries)
    }

    @Test
    fun `AList folder passwords are asked for, kept for the folder and below, and never shown`(): Unit = runBlocking {
        val server = alist(locked = mapOf("/私密" to "folder-pw")).apply {
            files["/私密/子/片.mp4"] = testBytes("p")
            files["/公开/片.mp4"] = testBytes("o")
        }.start()
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "alist", url = server.url), fromThisMachine = true)
        assertEquals(2, drives.listFolder(drive.id, "/").entries.size)
        val asked = assertThrows(DriveException::class.java) { runBlocking { drives.listFolder(drive.id, "/私密") } }
        assertEquals("DRIVE_PASSWORD", asked.code)
        assertEquals(403, asked.status)
        val wrong = assertThrows(DriveException::class.java) { runBlocking { drives.unlock(drive.id, "/私密", "guess") } }
        assertTrue(wrong.message!!.contains("不对"))
        assertEquals(listOf("子"), drives.unlock(drive.id, "/私密", "folder-pw").entries.map { it.name })
        assertEquals(listOf("片.mp4"), drives.listFolder(drive.id, "/私密/子").entries.map { it.name }, "the password counts for the folders below")
        val play = drives.play(drive.id, "/私密/子/片.mp4", remote = false)
        assertTrue(play.url.contains("sign="))
        assertEquals(listOf("/私密"), drives.get(drive.id).lockedFolders)
        assertFalse(Json.encodeToString(drives.list()).contains("folder-pw"))
        assertFalse(logs.any { "folder-pw" in it || "guess" in it })
    }

    @Test
    fun `an address that is not AList says so`(): Unit = runBlocking {
        val server = TestDav().also { servers += it::shutdown }.start()
        val drives = service()
        val result = drives.test(DriveRequest(kind = "alist", url = server.server.url("/").toString()), fromThisMachine = true)
        assertFalse(result.ok)
        assertTrue(result.message.contains("AList"), result.message)
    }

    // ---- WebDAV ----

    @Test
    fun `WebDAV with an account lists through PROPFIND and plays through the engine`(): Unit = runBlocking {
        val server = dav(user = "u", password = "dav-secret").apply {
            files["/media/剧 集/第1集.mkv"] = testBytes("1")
            files["/media/剧 集/第1集.zh.ass"] = testBytes("s", 100)
            files["/media/剧 集/第2集.mkv"] = testBytes("2")
            files["/media/a.mp4"] = testBytes("a")
            files["/other/x.mp4"] = testBytes("x")
            absoluteHrefs = true
        }.start()
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "webdav", url = server.url, username = "u", password = "dav-secret", root = "/media"), fromThisMachine = true)
        assertEquals(listOf("剧 集", "a.mp4"), drives.listFolder(drive.id, "/").entries.map { it.name }, "the drive starts at its root folder")
        val folder = drives.listFolder(drive.id, "/剧 集")
        assertEquals(listOf("/剧 集/第1集.mkv", "/剧 集/第1集.zh.ass", "/剧 集/第2集.mkv"), folder.entries.map { it.path })
        assertEquals(50_000L, folder.entries[0].size)
        assertEquals(1707732000000L, folder.entries[0].modified)

        val play = drives.play(drive.id, "/剧 集/第1集.mkv", remote = false)
        assertEquals("http://127.0.0.1:9978/drive/${drive.id}/%E5%89%A7%20%E9%9B%86/%E7%AC%AC1%E9%9B%86.mkv", play.url, "an account means the engine serves it")
        assertEquals("zh", play.subtitles.single().lang)
        assertTrue(play.headers.isEmpty())

        val part = drives.open(drive.id, "/剧 集/第1集.mkv", "bytes=10-", head = false)
        assertEquals(206, part.status)
        assertEquals("video/x-matroska", part.contentType, "the type by extension when the server says octet-stream")
        assertArrayEquals(testBytes("1").copyOfRange(10, 50_000), part.bytes())
        val head = drives.open(drive.id, "/剧 集/第1集.mkv", null, head = true)
        assertEquals(200, head.status)
        assertNull(head.body)
        assertEquals(50_000L, head.length)
        assertTrue(server.requests.all { it.second?.startsWith("Basic ") == true })
        assertThrows(DriveException::class.java) { runBlocking { drives.listFolder(drive.id, "/没有") } }

        val wrong = drives.test(DriveRequest(id = drive.id, password = "wrong"), fromThisMachine = true)
        assertFalse(wrong.ok)
        assertTrue(wrong.message.contains("用户名或密码"), wrong.message)
        assertFalse(logs.any { "dav-secret" in it })
    }

    @Test
    fun `a WebDAV without an account is played straight from the server`(): Unit = runBlocking {
        val server = dav().apply { files["/a b.mp4"] = testBytes("a") }.start()
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "webdav", url = server.url + "/"), fromThisMachine = true)
        assertEquals(listOf("a b.mp4"), drives.listFolder(drive.id, "/").entries.map { it.name })
        assertEquals(server.url + "/a%20b.mp4", drives.play(drive.id, "/a b.mp4", remote = false).url)
        val proxied = drives.update(drive.id, DriveRequest(proxy = true), fromThisMachine = true)
        assertTrue(proxied.proxy)
        assertTrue(drives.play(drive.id, "/a b.mp4", remote = false).url.startsWith("http://127.0.0.1:9978/drive/"), "set to go through the engine")
    }

    // ---- folders of this machine ----

    private fun folder(): File = File(dir, "videos").apply {
        File(this, "剧集").mkdirs()
        File(this, "剧集/第1集.mp4").writeBytes(testBytes("1"))
        File(this, "剧集/第1集.srt").writeBytes(testBytes("s", 100))
        File(this, ".hidden.mp4").writeBytes(testBytes("h"))
        File(this, "a.mp4").writeBytes(testBytes("a"))
    }

    @Test
    fun `a local folder is listed and streamed with ranges`(): Unit = runBlocking {
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "local", url = folder().path), fromThisMachine = true)
        assertEquals("videos", drive.name)
        assertEquals(listOf("剧集", "a.mp4"), drives.listFolder(drive.id, "/").entries.map { it.name }, "hidden files are left out")
        val play = drives.play(drive.id, "/剧集/第1集.mp4", remote = false)
        assertEquals("http://127.0.0.1:9978/drive/${drive.id}/%E5%89%A7%E9%9B%86/%E7%AC%AC1%E9%9B%86.mp4", play.url)
        assertEquals(1, play.subtitles.size)
        val whole = drives.open(drive.id, "/剧集/第1集.mp4", null, head = false)
        assertEquals(200, whole.status)
        assertEquals("video/mp4", whole.contentType)
        assertArrayEquals(testBytes("1"), whole.bytes())
        val tail = drives.open(drive.id, "/剧集/第1集.mp4", "bytes=-100", head = false)
        assertEquals("bytes 49900-49999/50000", tail.headers["Content-Range"])
        assertArrayEquals(testBytes("1").copyOfRange(49_900, 50_000), tail.bytes())
        val none = drives.open(drive.id, "/剧集/第1集.mp4", "bytes=60000-", head = false)
        assertEquals(416, none.status)
        assertEquals("bytes */50000", none.headers["Content-Range"])
    }

    @Test
    fun `nothing outside the added folder can be reached`(): Unit = runBlocking {
        val inside = folder()
        File(dir, "secret.txt").writeText("outside")
        File(dir, "videos2").mkdirs()
        File(dir, "videos2/x.mp4").writeBytes(testBytes("x"))
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "local", url = inside.path), fromThisMachine = true)
        for (path in listOf("/../secret.txt", "/剧集/../../secret.txt", "..\\secret.txt", "/${dir.absolutePath.replace('\\', '/')}/secret.txt", "/C:/Windows/win.ini", "/a.mp4:stream")) {
            val e = assertThrows(DriveException::class.java, { runBlocking { drives.open(drive.id, path, null, head = false) } }, path)
            assertTrue(e.status in listOf(400, 403, 404), "$path: ${e.code}")
        }
        assertThrows(DriveException::class.java) { runBlocking { drives.open(drive.id, "/../videos2/x.mp4", null, head = false) } }

        // Links: one to a folder outside is left out and refused; one inside the folder works.
        val outsideLink = File(inside, "出去").toPath()
        val insideLink = File(inside, "捷径.mp4").toPath()
        val links = runCatching {
            Files.createSymbolicLink(outsideLink, dir.toPath())
            Files.createSymbolicLink(insideLink, File(inside, "a.mp4").toPath())
        }.isSuccess
        assumeTrue(links, "this machine does not allow symbolic links (Windows without developer mode)")
        val names = drives.listFolder(drive.id, "/").entries.map { it.name }
        assertFalse("出去" in names, "a link out of the folder is not listed: $names")
        assertTrue("捷径.mp4" in names)
        val out = assertThrows(DriveException::class.java) { runBlocking { drives.open(drive.id, "/出去/secret.txt", null, head = false) } }
        assertEquals("DRIVE_PATH", out.code)
        assertThrows(DriveException::class.java) { runBlocking { drives.listFolder(drive.id, "/出去") } }
        assertArrayEquals(testBytes("a"), drives.open(drive.id, "/捷径.mp4", null, head = false).bytes())
    }

    @Test
    fun `only this machine adds local folders, and engines without them refuse`() {
        val drives = service()
        val path = folder().path
        val remote = assertThrows(DriveException::class.java) { drives.add(DriveRequest(kind = "local", url = path), fromThisMachine = false) }
        assertEquals("LOCAL_ONLY", remote.code)
        val drive = drives.add(DriveRequest(kind = "local", url = path), fromThisMachine = true)
        assertEquals("改名", drives.update(drive.id, DriveRequest(name = "改名"), fromThisMachine = false).name, "a name can be changed from anywhere")
        assertThrows(DriveException::class.java) { drives.update(drive.id, DriveRequest(url = dir.path), fromThisMachine = false) }
        val dav = drives.add(DriveRequest(kind = "webdav", url = "http://192.168.1.2/dav"), fromThisMachine = false)
        assertThrows(DriveException::class.java) { drives.update(dav.id, DriveRequest(kind = "local", url = path), fromThisMachine = false) }
        assertThrows(DriveException::class.java) { drives.add(DriveRequest(kind = "local", url = File(dir, "missing").path), fromThisMachine = true) }
        assertThrows(DriveException::class.java) { drives.add(DriveRequest(kind = "local", url = "relative/path"), fromThisMachine = true) }
        val android = service(localFolders = false)
        assertThrows(DriveException::class.java) { android.add(DriveRequest(kind = "local", url = path), fromThisMachine = true) }
        assertThrows(DriveException::class.java) { drives.add(DriveRequest(kind = "ftp", url = "ftp://x"), fromThisMachine = true) }
        assertThrows(DriveException::class.java) { drives.add(DriveRequest(kind = "alist", url = "pan.example"), fromThisMachine = true) }
    }

    // ---- what is kept, and what never leaves ----

    @Test
    fun `credentials are kept by the engine and never in what it tells clients`(): Unit = runBlocking {
        val store = JsonFileStore(File(dir, "data"))
        val drives = service(store)
        val webdav = drives.add(DriveRequest(kind = "webdav", url = "https://user%40x:p%40ss-in-url@dav.example.com/dav/"), fromThisMachine = true)
        assertEquals("https://dav.example.com/dav", webdav.url, "the account is taken out of the address")
        assertEquals("user@x", webdav.username)
        assertTrue(webdav.hasPassword)
        val alist = drives.add(DriveRequest(kind = "alist", url = "http://pan.example", token = "alist-token-123", name = "盘"), fromThisMachine = true)
        val shown = Json.encodeToString(drives.list()) + Json.encodeToString(drives.get(alist.id)) + Json.encodeToString(webdav)
        for (secret in listOf("p@ss-in-url", "p%40ss", "alist-token-123")) assertFalse(shown.contains(secret), secret)

        // Kept on the engine's disk, and loaded again by the next engine.
        val again = service(JsonFileStore(File(dir, "data")))
        assertEquals(listOf("dav.example.com", "盘"), again.list().map { it.name })
        assertTrue(File(dir, "data/drives.json").readText().contains("alist-token-123"))

        // A change without a password keeps it; an empty one removes it.
        assertTrue(again.update(webdav.id, DriveRequest(name = "新名字"), fromThisMachine = true).hasPassword)
        assertFalse(again.update(webdav.id, DriveRequest(password = ""), fromThisMachine = true).hasPassword)
        assertFalse(again.update(alist.id, DriveRequest(token = ""), fromThisMachine = true).hasToken)
        again.remove(alist.id)
        assertEquals(1, again.list().size)
        assertThrows(DriveException::class.java) { again.remove(alist.id) }
        assertFalse(logs.any { "alist-token-123" in it || "p@ss-in-url" in it })
    }

    @Test
    fun `drive sites are recognised by their key`(): Unit = runBlocking {
        val drives = service()
        val drive = drives.add(DriveRequest(kind = "local", url = folder().path), fromThisMachine = true)
        assertNull(drives.resolveSite("csp_AList", "/a.mp4", remote = false), "other sites are not drives")
        assertNull(DriveService.driveOf("drive:"))
        assertEquals(drive.id, DriveService.driveOf(drive.site))
        val detail = drives.detailSite(drive.site, "/")!!
        assertEquals("videos", detail.name)
        assertEquals(listOf("a"), detail.lines.single().episodes.map { it.name })
        assertTrue(drives.resolveSite(drive.site, "/a.mp4", remote = false)!!.url.endsWith("/a.mp4"))
        val empty = drives.detail(drive.id, "/剧集").copy()
        assertEquals("1 个视频", empty.remarks)
    }
}
