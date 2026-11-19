package tvbox.engine.core.download

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import tvbox.engine.core.EngineException
import tvbox.engine.core.cache.StreamStore
import tvbox.engine.core.model.DownloadExportResult
import tvbox.engine.core.model.DownloadItem
import tvbox.engine.core.model.DownloadRequest
import tvbox.engine.core.model.DownloadSettingsInfo
import tvbox.engine.core.model.DownloadSettingsUpdate
import tvbox.engine.core.model.PlayInfo
import tvbox.engine.core.model.PlayRequest
import tvbox.engine.core.play.HlsRewriter
import tvbox.engine.core.play.HlsRewriter.Kind
import tvbox.engine.core.play.HlsRewriter.Resource
import tvbox.engine.core.play.M3u8Cleaner
import tvbox.engine.core.util.Base64Compat
import tvbox.engine.core.util.UriUtil
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.URLDecoder
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Episodes downloaded for watching offline, queued and fetched by the engine — so an engine on a NAS downloads for
 * every device that uses it.
 *
 * - A download is an episode of a site's title. It is resolved the way playing it is ([resolver], i.e.
 *   `Engine.resolvePlay`: parsers, sniffing) every time it starts, because play addresses expire; a download whose
 *   source starts refusing half way is resolved once more before it gives up.
 * - HLS is fetched into a [StreamStore] as a pinned stream: every segment, key and initialisation map, several at a
 *   time. By default that is the stream cache's own store, under the folder name the cache would give the episode,
 *   so what was watched is not fetched again, a download can be watched while it runs, and the cache's size cap never
 *   touches it. A folder the user chose gets a store of its own.
 * - A direct file (mp4, flv, mkv…) is fetched with byte ranges into a work file that survives pauses and restarts.
 * - Live streams are refused. At most [concurrency] downloads run at once; the queue and the settings are kept in
 *   [stateFile] and running downloads carry on after a restart.
 * - A finished download plays without the network: [offlinePlay] answers `/play/resolve` with the engine's own
 *   `/dl/<id>/…` addresses. [export] writes it as one file.
 */
class DownloadManager(
    client: OkHttpClient,
    /** Where downloads go unless the user chose a folder: the stream cache's store. */
    private val defaultStore: StreamStore,
    /** Where the queue and the settings are kept; null keeps them in memory. */
    private val stateFile: File?,
    /** Resolves an episode as playing it would. */
    private val resolver: suspend (PlayRequest) -> PlayInfo,
    /** Cleans a media playlist of ads with the active config's rules: (text, playlist address, final address) -> text. */
    private val cleaner: (String, String, String) -> String = { text, _, _ -> text },
    /** What the engine's own addresses begin with, e.g. `http://127.0.0.1:9978`. */
    private val localBase: String,
    /** Where an export goes when no folder is given. */
    private val exportDir: () -> File = { File(defaultStore.root.parentFile ?: defaultStore.root, "exports") },
    /** Downloads stop before the disk has less than this left. */
    private val reserveBytes: Long = DEFAULT_RESERVE,
    private val freeSpace: (File) -> Long = { it.usableSpace },
    private val now: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private val http: OkHttpClient = client.newBuilder()
        // One connection per request: slow sources are usually slow per connection.
        .protocols(listOf(Protocol.HTTP_1_1))
        .connectionPool(ConnectionPool(MAX_CONCURRENCY * CONNECTIONS, 2, TimeUnit.MINUTES))
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private val stores = HashMap<String, StreamStore>()

    @Volatile private var dir = ""

    /** How many downloads run at the same time. */
    @Volatile var concurrency = DEFAULT_CONCURRENCY
        private set

    @Volatile private var started = false
    @Volatile private var closed = false

    private val version = MutableStateFlow(0L)

    /** Changes whenever something in [list] does (at most a few times a second while downloads run). */
    val changes: StateFlow<Long> get() = version

    init {
        load()
    }

    // ---- the queue ----

    /** Downloads queued before this wait; called once the engine can resolve episodes (its config is loaded). */
    fun start() {
        started = true
        pump()
    }

    fun list(): List<DownloadItem> = synchronized(lock) { entries.values.toList() }.map { it.item() }

    fun get(id: String): DownloadItem = entry(id).item()

    /** Queues episodes; one that is in the list already is answered as it is. */
    fun add(requests: List<DownloadRequest>): List<DownloadItem> {
        val out = ArrayList<Entry>()
        synchronized(lock) {
            for (req in requests) {
                if (req.site.isBlank() || req.line.isBlank() || req.episodeId.isBlank()) throw EngineException.BadRequest("site, line and episodeId are required")
                val known = entries.values.firstOrNull { it.r.site == req.site && it.r.line == req.line && it.r.episodeId == req.episodeId }
                if (known != null) {
                    out += known
                    continue
                }
                val r = Record(
                    id = UUID.randomUUID().toString().replace("-", "").take(12),
                    site = req.site, line = req.line, episodeId = req.episodeId, vodId = req.vodId, title = req.title, pic = req.pic,
                    episodeName = req.episodeName, episodeIndex = req.episodeIndex, state = QUEUED, createdAt = now(),
                )
                val e = Entry(r)
                entries[r.id] = e
                out += e
            }
        }
        changed(save = true)
        pump()
        return out.map { it.item() }
    }

    fun pause(id: String): DownloadItem {
        val e = entry(id)
        synchronized(lock) {
            when (e.r.state) {
                RUNNING -> {
                    e.r = e.r.copy(state = PAUSED)
                    e.stop()
                }
                QUEUED -> e.r = e.r.copy(state = PAUSED)
            }
        }
        changed(save = true)
        pump()
        return e.item()
    }

    /** Resumes a paused download, or tries a failed one again (resolving it anew). */
    fun resume(id: String): DownloadItem {
        val e = entry(id)
        synchronized(lock) {
            if (e.r.state == PAUSED || e.r.state == FAILED) e.r = e.r.copy(state = QUEUED, error = "")
        }
        changed(save = true)
        pump()
        return e.item()
    }

    /** Stops it and deletes its files. */
    suspend fun delete(id: String) {
        val e = synchronized(lock) { entries.remove(id) } ?: throw EngineException.NotFound("no download $id")
        e.stop()
        e.job?.cancelAndJoin()
        changed(save = true)
        if (e.r.stream.isNotEmpty() && e.r.root.isNotEmpty()) withContext(Dispatchers.IO) { storeAt(File(e.r.root)).remove(e.r.stream) }
        pump()
    }

    /** Stops every download (they carry on at the next start) and waits until their files are closed. */
    fun close() {
        closed = true
        val jobs = synchronized(lock) { entries.values.mapNotNull { e -> e.stop(); e.job } }
        runBlocking { jobs.forEach { it.cancelAndJoin() } }
        scope.coroutineContext[Job]?.cancel()
        save()
    }

    // ---- settings ----

    fun settings(): DownloadSettingsInfo {
        val path = currentStore().root
        path.mkdirs()
        return DownloadSettingsInfo(
            available = true,
            dir = dir,
            path = path.absolutePath,
            defaultPath = defaultStore.root.absolutePath,
            concurrency = concurrency,
            maxConcurrency = MAX_CONCURRENCY,
            freeBytes = runCatching { freeSpace(path) }.getOrDefault(-1),
            reserveBytes = reserveBytes,
            bytes = synchronized(lock) { entries.values.sumOf { it.bytes.get() } },
        )
    }

    fun updateSettings(update: DownloadSettingsUpdate): DownloadSettingsInfo {
        update.dir?.let { wanted ->
            val text = wanted.trim()
            dir = if (text.isEmpty()) "" else {
                val folder = File(text)
                if (!folder.isAbsolute) throw EngineException.BadRequest("下载位置要写完整的路径（引擎所在设备上的文件夹）")
                folder.mkdirs()
                val probe = File(folder, ".tvbox-write-test")
                val writable = folder.isDirectory && runCatching { probe.writeText("x"); probe.delete() }.getOrDefault(false)
                if (!writable) throw EngineException.BadRequest("这个文件夹不能写入：${folder.absolutePath}")
                if (folder.absoluteFile == defaultStore.root.absoluteFile) "" else folder.absolutePath
            }
        }
        update.concurrency?.let { concurrency = it.coerceIn(1, MAX_CONCURRENCY) }
        changed(save = true)
        pump()
        return settings()
    }

    // ---- playing and exporting what was downloaded ----

    /** A finished download of the episode: its engine address, which plays without the network. Null otherwise. */
    fun offlinePlay(request: PlayRequest): PlayInfo? {
        val e = synchronized(lock) {
            entries.values.firstOrNull { it.r.state == DONE && it.r.site == request.site && it.r.line == request.line && it.r.episodeId == request.episodeId }
        } ?: return null
        if (!intact(e)) {
            synchronized(lock) { if (e.r.state == DONE) e.r = e.r.copy(state = FAILED, error = "下载的文件不见了（可能被删掉了），请重新下载") }
            changed(save = true)
            return null
        }
        val path = if (e.r.kind == HLS) "index.m3u8" else e.r.file
        return PlayInfo(kind = "direct", url = "$localBase/dl/${e.r.id}/$path", download = e.r.id)
    }

    /** The playlist of a downloaded HLS episode whose files a player reaches under [base] (`http://<engine>/dl/<id>/`). */
    fun offlinePlaylist(id: String, base: String): String? {
        val e = synchronized(lock) { entries[id] } ?: return null
        return note(e)?.playlist?.replace(DownloadExport.BASE, base)
    }

    /** A file of a download as the player asks for it: `<number>.<ext>` of an HLS episode, or the direct file. */
    fun offlineFile(id: String, name: String): Pair<File, String>? {
        val e = synchronized(lock) { entries[id] } ?: return null
        val r = e.r
        if (r.stream.isEmpty() || r.root.isEmpty()) return null
        val store = storeAt(File(r.root))
        if (r.kind == FILE) return if (name == r.file) store.file(r.stream, name)?.let { it to typeOf(name.substringAfterLast('.')) } else null
        val number = name.substringBefore('.').toIntOrNull() ?: return null
        val res = note(e)?.resources?.getOrNull(number) ?: return null
        val type = if (res.k == Kind.KEY.name) "application/octet-stream" else typeOf(res.e)
        return store.file(r.stream, res.n)?.let { it to type }
    }

    /** What exporting a finished download gives: the file's name, its format, and how to write it. */
    class Export(val fileName: String, val format: String, val write: (OutputStream) -> Long)

    fun exportOf(id: String): Export {
        val e = entry(id)
        val r = e.r
        if (r.state != DONE) throw EngineException.BadRequest("还没下载完，不能导出")
        val store = storeAt(File(r.root))
        val name = safeName(listOf(r.title, r.episodeName).filter { it.isNotBlank() }.joinToString(" ").ifBlank { "video-${r.id}" })
        if (r.kind == FILE) {
            val ext = r.file.substringAfterLast('.', "mp4")
            return Export("$name.$ext", ext) { out -> (store.file(r.stream, r.file) ?: throw IOException("下载的文件不见了，请重新下载")).inputStream().use { it.copyTo(out, 256 * 1024) } }
        }
        val note = note(e) ?: throw IOException("下载的文件不见了，请重新下载")
        val file = { n: Int -> note.resources.getOrNull(n)?.let { store.file(r.stream, it.n) } }
        val plan = try {
            DownloadExport.plan(note.playlist).also { DownloadExport.check(it, file) }
        } catch (x: DownloadExport.Unsupported) {
            throw EngineException.Unsupported(x.message ?: "导出不了")
        }
        return Export("$name.${plan.format}", plan.format) { out ->
            try {
                DownloadExport.write(plan, file, out)
            } catch (x: DownloadExport.Unsupported) {
                throw EngineException.Unsupported(x.message ?: "导出不了")
            }
        }
    }

    /** Writes a finished download as one file into [path] (a folder, or a file name), or into the export folder. */
    fun export(id: String, path: String = ""): DownloadExportResult {
        val export = exportOf(id)
        val wanted = path.trim()
        // A path that names a video file is the file; any other is a folder (made when it is not there).
        val namesFile = wanted.isNotEmpty() && !File(wanted).isDirectory && wanted.substringAfterLast('.', "").lowercase() in VIDEO_EXT
        val target = when {
            wanted.isEmpty() -> unused(exportDir().also { it.mkdirs() }, export.fileName)
            namesFile -> File(wanted).also { it.absoluteFile.parentFile?.mkdirs() }
            else -> unused(File(wanted).also { it.mkdirs() }, export.fileName)
        }
        if (!target.isAbsolute) throw EngineException.BadRequest("导出位置要写完整的路径")
        val tmp = File(target.path + ".part")
        val bytes = try {
            FileOutputStream(tmp).buffered(256 * 1024).use { export.write(it) }
        } catch (x: Throwable) {
            tmp.delete()
            throw x
        }
        if (target.exists() && !target.delete()) {
            tmp.delete()
            throw EngineException.BadRequest("${target.absolutePath} 已存在且删不掉")
        }
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IOException("写不进 ${target.absolutePath}")
        }
        return DownloadExportResult(target.absolutePath, bytes, export.format)
    }

    // ---- running downloads ----

    private class Failure(message: String) : Exception(message)

    /** The source would not give a file (or gave something else); resolving the episode again may help. */
    private class Refused(message: String, val status: Int) : IOException(message)

    /** A direct address that turned out to be an HLS playlist. */
    private class IsPlaylist : Exception()

    private sealed class Source {
        class Hls(val url: String, val headers: Map<String, String>, val key: String) : Source()
        class Plain(val url: String, val headers: Map<String, String>) : Source()
    }

    private fun pump() {
        if (!started || closed) return
        synchronized(lock) {
            var running = entries.values.count { it.r.state == RUNNING }
            for (e in entries.values) {
                if (running >= concurrency) break
                if (e.r.state != QUEUED || e.job != null) continue
                e.r = e.r.copy(state = RUNNING, error = "")
                e.stopped = false
                e.aborted = false
                running++
                e.job = scope.launch { run(e) }
            }
        }
        changed(save = false)
    }

    private suspend fun run(e: Entry) {
        var failure: String? = null
        var ended = false
        try {
            e.resetSpeed()
            when (val source = resolve(e)) {
                is Source.Hls -> runHls(e, source)
                is Source.Plain -> try {
                    runFile(e, source)
                } catch (x: IsPlaylist) {
                    runHls(e, Source.Hls(source.url, source.headers, ""))
                }
            }
            synchronized(lock) {
                if (e.r.state == RUNNING) e.r = e.r.copy(state = DONE, error = "", finishedAt = now(), bytes = e.bytes.get(), totalBytes = e.bytes.get())
            }
            log("download ${e.r.id}: ${e.r.title} ${e.r.episodeName} done, ${e.bytes.get()} bytes")
            ended = true
        } catch (x: CancellationException) {
            // Paused, deleted, or the engine is stopping: whoever did that has set the state.
            ended = e.stopped || closed
        } catch (x: Failure) {
            failure = x.message
            ended = true
        } catch (x: Exception) {
            failure = if (e.stopped) null else describe(x)
            ended = true
        } finally {
            // Anything else that ended it without a reason must not leave it "running" for ever.
            if (!ended && failure == null && !e.stopped && !closed) failure = "下载意外中断，请重试"
            synchronized(lock) {
                e.job = null
                if (failure != null && e.r.state == RUNNING && !e.stopped) e.r = e.r.copy(state = FAILED, error = failure)
            }
            if (failure != null) log("download ${e.r.id}: $failure")
            changed(save = true)
            if (!closed) pump()
        }
    }

    /** What playing the episode would play, resolved now. */
    private suspend fun resolve(e: Entry): Source {
        val info = try {
            resolver(PlayRequest(e.r.site, e.r.line, e.r.episodeId))
        } catch (x: CancellationException) {
            throw x
        } catch (x: Exception) {
            throw Failure("解析失败：" + (x.message ?: x.javaClass.simpleName))
        }
        if (info.kind != "direct" || info.url.isBlank()) throw Failure("这条线路要在客户端嗅探网页才能播放，引擎下载不了；换一条线路试试")
        if (info.download.isNotEmpty()) throw Failure("这一集已经下载过了")
        val playlistBase = "$localBase/m3u8?"
        if (info.url.startsWith(playlistBase)) {
            val q = query(info.url.removePrefix(playlistBase))
            val url = q["url"] ?: throw Failure("播放地址不完整")
            val headers = q["h"]?.let { h ->
                runCatching { Json.parseToJsonElement(String(Base64Compat.decode(h))).let { el -> (el as kotlinx.serialization.json.JsonObject).mapValues { (it.value as kotlinx.serialization.json.JsonPrimitive).content } } }.getOrNull()
            } ?: info.headers
            return Source.Hls(url, headers, info.cache.ifEmpty { q["k"].orEmpty() })
        }
        return Source.Plain(info.url, info.headers)
    }

    // -- HLS --

    private suspend fun runHls(e: Entry, first: Source.Hls) {
        var source = first
        var resolvedAgain = false
        while (true) {
            val (mediaUrl, text, finalUrl) = mediaPlaylist(e, source)
            val rewritten = HlsRewriter.rewrite(text, finalUrl)
                ?: throw Failure(if (text.lines().none { it.trim() == "#EXT-X-ENDLIST" }) "这是直播流（播放列表没有结尾），不能下载" else "播放列表里没有分片")
            val store = storeFor(e)
            val stream = e.r.stream.ifEmpty {
                // The folder the stream cache keeps this episode in, so that both use the same files.
                HlsRewriter.sha1(if (source.key.isNotEmpty()) "${source.key}|${HlsRewriter.path(mediaUrl)}" else "dl|${e.r.site}|${e.r.line}|${e.r.episodeId}").take(20)
            }
            val resources = rewritten.resources
            store.pin(stream, true)
            val note = Note(rewritten.render(DownloadExport.BASE), resources.map { NotedResource(it.kind.name, it.name, it.ext, it.startMs, it.durationMs) })
            store.writeNote(stream, NOTE, json.encodeToString(Note.serializer(), note))
            val present = store.names(stream)
            val missing = resources.indices.filter { resources[it].name !in present }
            e.note = note
            e.bytes.set(resources.filter { it.name in present }.distinctBy { it.name }.sumOf { store.file(stream, it.name)?.length() ?: 0L })
            e.doneMs.set(resources.filter { it.kind == Kind.SEGMENT && it.name in present }.sumOf { it.durationMs })
            e.partsDone.set(resources.size - missing.size)
            synchronized(lock) {
                e.r = e.r.copy(kind = HLS, root = store.root.absolutePath, stream = stream, parts = resources.size, durationMs = rewritten.durationMs, totalBytes = -1)
            }
            changed(save = true)
            checkSpace(store.root)
            try {
                fetchAll(e, store, stream, resources, missing, source.headers)
                return
            } catch (x: Refused) {
                // Play addresses expire (tokens): the episode is resolved once more, and what is there stays.
                if (resolvedAgain) throw Failure(x.message ?: "片源拒绝")
                resolvedAgain = true
                log("download ${e.r.id}: ${x.message}; resolving the episode again")
                source = when (val again = resolve(e)) {
                    is Source.Hls -> again
                    is Source.Plain -> Source.Hls(again.url, again.headers, "")
                }
            }
        }
    }

    /** The media playlist: the one the address names, or the best variant of a master playlist. Cleaned of ads like playing does. */
    private suspend fun mediaPlaylist(e: Entry, source: Source.Hls): Triple<String, String, String> = withContext(Dispatchers.IO) {
        var url = source.url
        repeat(3) {
            val (text, finalUrl) = text(e, url, source.headers)
            if (!text.removePrefix("﻿").trimStart().startsWith("#EXTM3U")) throw Failure("播放地址给的不是 HLS 播放列表")
            if (!M3u8Cleaner.isMaster(text)) return@withContext Triple(url, cleaner(text, url, finalUrl), finalUrl)
            url = bestVariant(text, finalUrl) ?: throw Failure("主播放列表里没有能下载的码率")
        }
        throw Failure("主播放列表套了太多层")
    }

    private fun text(e: Entry, url: String, headers: Map<String, String>): Pair<String, String> =
        execute(e, request(url, headers)) { response ->
            if (!response.isSuccessful) throw Refused("片源拒绝了播放列表（HTTP ${response.code}）", response.code)
            (response.body?.string() ?: "") to response.request.url.toString()
        }

    /**
     * The variant with the most bandwidth. Variants whose audio is a separate rendition are passed over when there
     * are others: only the video playlist is downloaded.
     */
    private fun bestVariant(text: String, baseUrl: String): String? {
        val lines = text.replace("\r\n", "\n").split('\n').map { it.trim() }
        val audioWithUri = lines.filter { it.startsWith("#EXT-X-MEDIA") && it.contains("TYPE=AUDIO") && it.contains("URI=") }
            .mapNotNull { Regex("GROUP-ID=\"([^\"]*)\"").find(it)?.groupValues?.get(1) }.toSet()
        class Variant(val url: String, val bandwidth: Long, val separateAudio: Boolean)
        val variants = ArrayList<Variant>()
        for ((i, line) in lines.withIndex()) {
            if (!line.startsWith("#EXT-X-STREAM-INF")) continue
            val uri = lines.drop(i + 1).firstOrNull { it.isNotEmpty() && !it.startsWith("#") } ?: continue
            val bandwidth = Regex("(?:^|[:,])BANDWIDTH=(\\d+)").find(line)?.groupValues?.get(1)?.toLongOrNull() ?: 0
            val audio = Regex("AUDIO=\"([^\"]*)\"").find(line)?.groupValues?.get(1)
            variants += Variant(if (uri.startsWith("http://") || uri.startsWith("https://")) uri else UriUtil.resolve(baseUrl, uri), bandwidth, audio != null && audio in audioWithUri)
        }
        val candidates = variants.filter { !it.separateAudio }.ifEmpty { variants }
        return candidates.maxByOrNull { it.bandwidth }?.url
    }

    /** Fetches the [missing] resources, [CONNECTIONS] at a time, in playing order. */
    private suspend fun fetchAll(e: Entry, store: StreamStore, stream: String, resources: List<Resource>, missing: List<Int>, headers: Map<String, String>) {
        if (missing.isEmpty()) return
        e.aborted = false
        val next = AtomicInteger()
        val segments = resources.count { it.kind == Kind.SEGMENT }
        try {
            fetchEach(e, store, stream, resources, missing, headers, next, segments)
        } finally {
            // Whatever comes next (resolving the episode again) is not to be stopped by this batch's failure.
            e.aborted = false
        }
        if (e.halted) throw CancellationException("stopped")
    }

    private suspend fun fetchEach(e: Entry, store: StreamStore, stream: String, resources: List<Resource>, missing: List<Int>, headers: Map<String, String>, next: AtomicInteger, segments: Int) {
        coroutineScope {
            repeat(minOf(CONNECTIONS, missing.size)) {
                launch(Dispatchers.IO) {
                    while (true) {
                        val i = next.getAndIncrement()
                        if (i >= missing.size || e.halted) break
                        try {
                            fetchResource(e, store, stream, resources[missing[i]], headers)
                            checkEstimate(e, store, segments)
                        } catch (x: Throwable) {
                            // The others stop too, without waiting for their answers to time out.
                            e.abort()
                            throw x
                        }
                    }
                }
            }
        }
    }

    private fun fetchResource(e: Entry, store: StreamStore, stream: String, r: Resource, headers: Map<String, String>) {
        if (store.has(stream, r.name)) {
            e.partDone(r, 0)
            return
        }
        checkSpace(store.root)
        val work = store.workFile(stream, "dl-${r.name}.part")
        try {
            var tries = 0
            while (true) {
                if (e.halted) throw CancellationException("stopped")
                try {
                    fetchInto(e, r, work, headers)
                    break
                } catch (x: Refused) {
                    // A server error may pass; anything else is the source saying no.
                    if (x.status !in 500..599 || ++tries >= TRIES) throw x
                    e.nap(1000L * tries)
                } catch (x: IOException) {
                    if (e.halted) throw CancellationException("stopped")
                    if (++tries >= TRIES) throw Failure("网络中断：${what(r)}连续 $tries 次没下载完（${x.message ?: x.javaClass.simpleName}）")
                    e.nap(1000L * tries)
                }
            }
            val size = work.length()
            if (!store.adopt(stream, r.name, work) && !store.has(stream, r.name)) throw Failure("写不进下载位置：${store.root.absolutePath}")
            e.partDone(r, size)
            changed(save = false)
        } finally {
            work.delete()
        }
    }

    /** One request for resource [r] into [work], from its first byte. */
    private fun fetchInto(e: Entry, r: Resource, work: File, headers: Map<String, String>) {
        val request = request(r.url, headers) { if (r.start >= 0) header("Range", "bytes=${r.start}-" + if (r.length >= 0) "${r.start + r.length - 1}" else "") }
        execute(e, request) { response ->
            if (!response.isSuccessful) throw Refused("片源拒绝了${what(r)}（HTTP ${response.code}）", response.code)
            val body = response.body ?: throw IOException("the source sent nothing")
            // A source that ignores the range sends the whole file: what comes before the range is skipped.
            var skip = if (r.start >= 0 && response.code != 206) r.start else 0L
            val want = if (r.length >= 0) r.length else body.contentLength()
            var written = 0L
            val buffer = ByteArray(64 * 1024)
            FileOutputStream(work).use { out ->
                val input = body.byteStream()
                while (want < 0 || written < want) {
                    if (e.halted) throw CancellationException("stopped")
                    val n = input.read(buffer)
                    if (n < 0) break
                    var offset = 0
                    var length = n
                    if (skip > 0) {
                        val dropped = minOf(skip, length.toLong()).toInt()
                        skip -= dropped
                        offset += dropped
                        length -= dropped
                    }
                    if (want >= 0) length = minOf(length.toLong(), want - written).toInt()
                    if (length <= 0) continue
                    // A page saying "expired" with status 200 is not video.
                    if (written == 0L && looksLikeText(buffer, offset, length)) throw Refused("片源给的是网页，不是视频（地址可能过期了）", 200)
                    out.write(buffer, offset, length)
                    written += length
                    e.received(length.toLong())
                }
            }
            if (want >= 0 && written < want) throw IOException("the source closed the connection after $written of $want bytes")
            if (r.kind == Kind.KEY && written != 16L) throw Refused("片源给的密钥不是 16 字节（$written 字节）", 200)
            if (written == 0L) throw IOException("the source sent nothing")
        }
    }

    /** Once a few segments are there: will the rest fit? */
    private fun checkEstimate(e: Entry, store: StreamStore, segments: Int) {
        val doneMs = e.doneMs.get()
        val duration = e.r.durationMs
        if (e.estimated || duration <= 0 || doneMs <= 0 || e.partsDone.get() < minOf(4, segments)) return
        e.estimated = true
        val remaining = (e.bytes.get().toDouble() / doneMs * (duration - doneMs)).toLong()
        val free = runCatching { freeSpace(store.root) }.getOrDefault(-1)
        if (free >= 0 && free - remaining < reserveBytes) {
            throw Failure("空间不够下完这一集：大约还要 ${size(remaining)}，${store.root.absolutePath} 只剩 ${size(free)}（下载会给磁盘留 ${size(reserveBytes)}）")
        }
    }

    // -- direct files --

    private suspend fun runFile(e: Entry, first: Source.Plain) = withContext(Dispatchers.IO) {
        var source = first
        var resolvedAgain = false
        val store = storeFor(e)
        val stream = e.r.stream.ifEmpty { "file-" + e.r.id }
        val work = store.workFile(stream, "dl-file.partial")
        var barren = 0
        var name = e.r.file
        var total = e.r.totalBytes
        while (true) {
            if (e.halted) throw CancellationException("stopped")
            var have = if (work.isFile) work.length() else 0L
            if (total in 0 until have) {
                work.delete()
                have = 0
            }
            e.bytes.set(have)
            val request = request(source.url, source.headers) { header("Range", "bytes=$have-") }
            val before = have
            try {
                execute(e, request) { response ->
                    if (response.code == 416 && have > 0 && have == total) return@execute
                    if (response.code == 416) {
                        work.delete()
                        throw IOException("the source does not have the bytes asked for")
                    }
                    if (!response.isSuccessful) throw Refused("片源拒绝了这个文件（HTTP ${response.code}）", response.code)
                    val body = response.body ?: throw IOException("the source sent nothing")
                    val partial = response.code == 206
                    val range = response.header("Content-Range").orEmpty()
                    val whole = if (partial) range.substringAfterLast('/').trim().toLongOrNull() ?: -1 else body.contentLength()
                    val from = if (partial) Regex("bytes\\s+(\\d+)-").find(range)?.groupValues?.get(1)?.toLongOrNull() ?: 0 else 0
                    if (from != have) {
                        // The source starts somewhere else (it ignored the range): start over.
                        work.delete()
                        have = 0
                        if (from != 0L) throw IOException("the source answered from byte $from")
                    }
                    val input = body.byteStream()
                    val buffer = ByteArray(64 * 1024)
                    var n = input.read(buffer)
                    if (n < 0) throw IOException("the source sent nothing")
                    if (have == 0L) {
                        if (String(buffer, 0, minOf(n, 16), Charsets.ISO_8859_1).removePrefix("﻿").trimStart().startsWith("#EXTM3U")) throw IsPlaylist()
                        if (looksLikeText(buffer, 0, n)) throw Refused("片源给的是网页，不是视频（地址可能过期了）", 200)
                    }
                    if (whole < 0) throw Failure("片源没说文件有多大，可能是直播流，不能下载")
                    if (total >= 0 && whole != total && have > 0) {
                        // Another file than the one begun: start over.
                        work.delete()
                        total = whole
                        throw IOException("the file at the source changed")
                    }
                    if (name.isEmpty()) name = "film." + fileExt(buffer, n, source.url, response.header("Content-Type"))
                    total = whole
                    synchronized(lock) { e.r = e.r.copy(kind = FILE, root = store.root.absolutePath, stream = stream, file = name, totalBytes = whole) }
                    store.pin(stream, true)
                    changed(save = true)
                    val free = runCatching { freeSpace(store.root) }.getOrDefault(-1)
                    if (free >= 0 && free - (whole - have) < reserveBytes) {
                        throw Failure("空间不够：这个文件还要 ${size(whole - have)}，${store.root.absolutePath} 只剩 ${size(free)}（下载会给磁盘留 ${size(reserveBytes)}）")
                    }
                    RandomAccessFile(work, "rw").use { out ->
                        out.seek(have)
                        while (n >= 0) {
                            if (e.halted) throw CancellationException("stopped")
                            val length = minOf(n.toLong(), whole - have).toInt()
                            if (length > 0) {
                                out.write(buffer, 0, length)
                                have += length
                                e.bytes.set(have)
                                e.received(length.toLong())
                                changed(save = false)
                            }
                            if (have >= whole) break
                            n = input.read(buffer)
                        }
                    }
                    if (have < whole) throw IOException("the source closed the connection at byte $have of $whole")
                }
            } catch (x: Refused) {
                if (x.status in 500..599 && ++barren <= TRIES) {
                    e.nap(1000L * barren)
                    continue
                }
                if (resolvedAgain) throw Failure(x.message ?: "片源拒绝")
                resolvedAgain = true
                log("download ${e.r.id}: ${x.message}; resolving the episode again")
                source = when (val again = resolve(e)) {
                    is Source.Plain -> again
                    is Source.Hls -> throw IsPlaylist()
                }
                continue
            } catch (x: IOException) {
                if (e.halted) throw CancellationException("stopped")
                have = if (work.isFile) work.length() else 0L
                // Patient with a source that keeps delivering; not with one that delivers nothing.
                barren = if (have > before) 0 else barren + 1
                if (barren > TRIES) throw Failure("网络中断：连续 $barren 次没下载到东西（${x.message ?: x.javaClass.simpleName}）")
                e.nap(1000L * barren)
                continue
            }
            if (total >= 0 && work.isFile && work.length() >= total) break
        }
        if (!store.adopt(stream, name, work) && !store.has(stream, name)) throw Failure("写不进下载位置：${store.root.absolutePath}")
        e.bytes.set(store.file(stream, name)?.length() ?: total)
    }

    // ---- plumbing ----

    private fun request(url: String, headers: Map<String, String>, more: Request.Builder.() -> Unit = {}): Request {
        val builder = try {
            Request.Builder().url(url)
        } catch (x: IllegalArgumentException) {
            throw Failure("播放地址无效：$url")
        }
        headers.forEach { (k, v) -> runCatching { builder.header(k, v) } }
        builder.more()
        return builder.build()
    }

    /** Runs [request]; [stop][Entry.stop] cancels it. */
    private fun <T> execute(e: Entry, request: Request, block: (Response) -> T): T {
        val call = http.newCall(request)
        e.calls += call
        try {
            if (e.halted) throw CancellationException("stopped")
            return call.execute().use(block)
        } catch (x: IOException) {
            if (e.halted) throw CancellationException("stopped")
            throw x
        } finally {
            e.calls -= call
        }
    }

    private fun checkSpace(root: File) {
        val free = runCatching { freeSpace(root) }.getOrDefault(-1)
        if (free in 0 until reserveBytes) throw Failure("磁盘空间不足：${root.absolutePath} 只剩 ${size(free)}，下载会给磁盘至少留 ${size(reserveBytes)}")
    }

    /** Whether everything the download needs is still on disk. */
    private fun intact(e: Entry): Boolean {
        val r = e.r
        if (r.stream.isEmpty() || r.root.isEmpty()) return false
        val store = storeAt(File(r.root))
        // Asking for each file looks at the disk (the user may have emptied the folder).
        if (r.kind == FILE) return store.file(r.stream, r.file) != null
        val note = note(e) ?: return false
        return note.resources.distinctBy { it.n }.all { store.file(r.stream, it.n) != null }
    }

    private fun note(e: Entry): Note? {
        e.note?.let { return it }
        val r = e.r
        if (r.kind != HLS || r.stream.isEmpty() || r.root.isEmpty()) return null
        return runCatching { storeAt(File(r.root)).readNote(r.stream, NOTE)?.let { json.decodeFromString(Note.serializer(), it) } }.getOrNull()?.also { e.note = it }
    }

    private fun currentStore(): StreamStore = if (dir.isEmpty()) defaultStore else storeAt(File(dir))

    /** A download stays where it began; one that has not begun goes where downloads go now. */
    private fun storeFor(e: Entry): StreamStore = if (e.r.root.isNotEmpty()) storeAt(File(e.r.root)) else currentStore()

    private fun storeAt(root: File): StreamStore {
        if (root.absoluteFile == defaultStore.root.absoluteFile) return defaultStore
        return synchronized(stores) { stores.getOrPut(root.absolutePath) { StreamStore(root.absoluteFile, Long.MAX_VALUE) } }
    }

    private fun entry(id: String): Entry = synchronized(lock) { entries[id] } ?: throw EngineException.NotFound("no download $id")

    /** Something changed: listeners hear of it (at most every [TICK_MS] for progress), and with [save] it is written down. */
    private fun changed(save: Boolean) {
        val t = now()
        if (save || t - lastTick >= TICK_MS) {
            lastTick = t
            version.value = version.value + 1
        }
        if (save || t - lastSave >= SAVE_EVERY_MS) save()
    }

    @Volatile private var lastTick = 0L
    @Volatile private var lastSave = 0L
    private val saveLock = Any()

    private fun save() {
        lastSave = now()
        val file = stateFile ?: return
        val state = synchronized(lock) {
            State(dir, concurrency, entries.values.map { e -> e.r.copy(bytes = e.bytes.get(), partsDone = e.partsDone.get(), doneMs = e.doneMs.get()) })
        }
        synchronized(saveLock) {
            runCatching {
                file.parentFile?.mkdirs()
                val tmp = File(file.path + ".tmp")
                tmp.writeText(json.encodeToString(State.serializer(), state))
                if (!tmp.renameTo(file)) {
                    file.delete()
                    tmp.renameTo(file)
                }
            }.onFailure { log("downloads: cannot save ${file.path}: ${it.message}") }
        }
    }

    private fun load() {
        val file = stateFile?.takeIf { it.isFile } ?: return
        val state = runCatching { json.decodeFromString(State.serializer(), file.readText()) }.getOrElse {
            log("downloads: ${file.path} is unreadable (${it.message}); kept as .broken")
            file.renameTo(File(file.path + ".broken"))
            return
        }
        dir = state.dir
        concurrency = state.concurrency.coerceIn(1, MAX_CONCURRENCY)
        for (r in state.items) {
            // What was running when the engine stopped carries on.
            entries[r.id] = Entry(if (r.state == RUNNING) r.copy(state = QUEUED) else r)
        }
    }

    private inner class Entry(@Volatile var r: Record) {
        @Volatile var job: Job? = null
        @Volatile var stopped = false
        @Volatile var note: Note? = null
        @Volatile var estimated = false
        val calls = CopyOnWriteArrayList<Call>()
        val bytes = AtomicLong(r.bytes)
        val partsDone = AtomicInteger(r.partsDone)
        val doneMs = AtomicLong(r.doneMs)
        private val receivedTotal = AtomicLong()
        private val samples = ArrayDeque<LongArray>()

        /** One of its own requests failed for good: the others give up too, without waiting for their answers. */
        @Volatile var aborted = false

        /** Whatever runs for it should end now. */
        val halted: Boolean get() = stopped || aborted

        /** Stops what runs (pause, delete, the engine stopping). */
        fun stop() {
            stopped = true
            calls.forEach { it.cancel() }
            job?.cancel()
        }

        fun abort() {
            aborted = true
            calls.forEach { it.cancel() }
        }

        /** Waits a moment before trying again; ends early when the download is stopped. */
        fun nap(ms: Long) {
            var left = ms
            while (left > 0) {
                if (halted) throw CancellationException("stopped")
                Thread.sleep(minOf(100L, left))
                left -= 100
            }
        }

        fun partDone(res: Resource, size: Long) {
            partsDone.incrementAndGet()
            bytes.addAndGet(size)
            if (res.kind == Kind.SEGMENT) doneMs.addAndGet(res.durationMs)
        }

        fun received(n: Long) {
            receivedTotal.addAndGet(n)
            if (now() - (synchronized(samples) { samples.lastOrNull()?.get(0) } ?: 0L) >= 250) sample()
            changed(save = false)
        }

        fun resetSpeed() = synchronized(samples) {
            samples.clear()
            estimated = false
        }

        private fun sample() = synchronized(samples) {
            val t = now()
            samples.addLast(longArrayOf(t, receivedTotal.get()))
            while (samples.size > 2 && t - samples[1][0] >= SPEED_WINDOW_MS) samples.removeFirst()
        }

        fun speed(): Long {
            if (r.state != RUNNING) return 0
            sample()
            return synchronized(samples) {
                val a = samples.firstOrNull() ?: return 0
                val b = samples.last()
                if (b[0] - a[0] < 200) 0 else (b[1] - a[1]) * 1000 / (b[0] - a[0])
            }
        }

        fun item(): DownloadItem {
            val r = r
            val bytes = bytes.get()
            val progress = when {
                r.state == DONE -> 1.0
                r.kind == HLS && r.durationMs > 0 -> doneMs.get().toDouble() / r.durationMs
                r.kind == HLS && r.parts > 0 -> partsDone.get().toDouble() / r.parts
                r.kind == FILE && r.totalBytes > 0 -> bytes.toDouble() / r.totalBytes
                else -> 0.0
            }.coerceIn(0.0, 1.0)
            return DownloadItem(
                id = r.id, site = r.site, line = r.line, episodeId = r.episodeId, vodId = r.vodId, title = r.title, pic = r.pic,
                episodeName = r.episodeName, episodeIndex = r.episodeIndex, state = r.state, kind = r.kind, bytes = bytes,
                totalBytes = if (r.state == DONE) bytes else r.totalBytes, progress = progress, speed = speed(),
                partsDone = partsDone.get(), parts = r.parts, durationMs = r.durationMs, error = r.error, createdAt = r.createdAt, finishedAt = r.finishedAt,
            )
        }
    }

    /** A download as it is kept in [stateFile]. */
    @Serializable
    private data class Record(
        val id: String,
        val site: String,
        val line: String,
        val episodeId: String,
        val vodId: String = "",
        val title: String = "",
        val pic: String = "",
        val episodeName: String = "",
        val episodeIndex: Int = -1,
        val state: String = QUEUED,
        val kind: String = "",
        /** The store the files are in, and the folder (stream) in it. */
        val root: String = "",
        val stream: String = "",
        /** A direct download's file in the stream's folder. */
        val file: String = "",
        val bytes: Long = 0,
        val totalBytes: Long = -1,
        val parts: Int = 0,
        val partsDone: Int = 0,
        val durationMs: Long = 0,
        val doneMs: Long = 0,
        val error: String = "",
        val createdAt: Long = 0,
        val finishedAt: Long = 0,
    )

    @Serializable
    private data class State(val dir: String = "", val concurrency: Int = DEFAULT_CONCURRENCY, val items: List<Record> = emptyList())

    /** What a downloaded HLS episode keeps next to its files: its playlist (addresses as [DownloadExport.BASE] + number) and its files. */
    @Serializable
    private class Note(val playlist: String, val resources: List<NotedResource>)

    @Serializable
    private class NotedResource(val k: String, val n: String, val e: String, val t: Long = 0, val d: Long = 0)

    companion object {
        const val QUEUED = "queued"
        const val RUNNING = "running"
        const val PAUSED = "paused"
        const val DONE = "done"
        const val FAILED = "failed"
        const val HLS = "hls"
        const val FILE = "file"

        const val DEFAULT_CONCURRENCY = 2
        const val MAX_CONCURRENCY = 5

        /** Files of one HLS download fetched at the same time. */
        const val CONNECTIONS = 4

        /** What a download leaves free on the disk. */
        const val DEFAULT_RESERVE = 500L * 1024 * 1024

        private const val NOTE = "download.json"
        private const val TRIES = 4
        private const val TICK_MS = 300L
        private const val SAVE_EVERY_MS = 5_000L
        private const val SPEED_WINDOW_MS = 3_000L

        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        fun size(bytes: Long): String {
            val mb = bytes / (1024.0 * 1024)
            return if (mb < 1000) "${Math.round(mb)} MB" else String.format(java.util.Locale.ROOT, "%.1f GB", mb / 1024)
        }

        private fun what(r: Resource) = when (r.kind) {
            Kind.SEGMENT -> "分片"
            Kind.KEY -> "密钥"
            Kind.MAP -> "初始化分段"
        }

        private fun describe(x: Throwable): String = when (x) {
            is Refused -> x.message ?: "片源拒绝"
            is java.net.UnknownHostException -> "找不到片源的服务器（${x.message}）"
            is java.net.ConnectException -> "连不上片源（${x.message}）"
            is java.net.SocketTimeoutException -> "片源没有响应（超时）"
            is IOException -> "网络错误：${x.message ?: x.javaClass.simpleName}"
            else -> x.message ?: x.javaClass.simpleName
        }

        private fun query(q: String): Map<String, String> = q.split('&').mapNotNull { part ->
            val i = part.indexOf('=')
            if (i <= 0) null else part.substring(0, i) to runCatching { URLDecoder.decode(part.substring(i + 1), "UTF-8") }.getOrDefault(part.substring(i + 1))
        }.toMap()

        /** The start of a web page or of JSON. Video, audio and keys do not start like this. */
        private fun looksLikeText(bytes: ByteArray, offset: Int, length: Int): Boolean {
            var i = offset
            val end = offset + length
            if (length >= 3 && bytes[i] == 0xEF.toByte() && bytes[i + 1] == 0xBB.toByte() && bytes[i + 2] == 0xBF.toByte()) i += 3
            while (i < end && (bytes[i] == ' '.code.toByte() || bytes[i] == '\n'.code.toByte() || bytes[i] == '\r'.code.toByte() || bytes[i] == '\t'.code.toByte())) i++
            val head = String(bytes, i, minOf(end - i, 9), Charsets.ISO_8859_1).lowercase()
            return head.startsWith("<!doctype") || head.startsWith("<html") || head.startsWith("<?xml") || head.startsWith("<head") || head.startsWith("<body") || head.startsWith("{\"")
        }

        private val VIDEO_EXT = setOf("mp4", "m4v", "mkv", "flv", "f4v", "avi", "mov", "wmv", "webm", "ts", "m2ts", "mpg", "mpeg", "rmvb", "rm", "3gp", "ogv")

        /** What kind of file this is: from its first bytes, its address, or what the source called it. */
        private fun fileExt(head: ByteArray, n: Int, url: String, contentType: String?): String {
            fun at(i: Int, text: String) = n >= i + text.length && String(head, i, text.length, Charsets.ISO_8859_1) == text
            return when {
                at(4, "ftyp") -> "mp4"
                at(0, "FLV") -> "flv"
                n >= 4 && head[0] == 0x1A.toByte() && head[1] == 0x45.toByte() && head[2] == 0xDF.toByte() && head[3] == 0xA3.toByte() ->
                    if (url.substringBefore('?').endsWith(".webm", true)) "webm" else "mkv"
                at(0, "RIFF") -> "avi"
                n >= 1 && head[0] == 0x47.toByte() -> url.substringBefore('?').substringAfterLast('.', "").lowercase().takeIf { it == "mpg" || it == "mpeg" || it == "m2ts" } ?: "ts"
                else -> url.substringBefore('?').substringAfterLast('/').substringAfterLast('.', "").lowercase().takeIf { it in VIDEO_EXT }
                    ?: when {
                        contentType?.contains("mp4") == true -> "mp4"
                        contentType?.contains("flv") == true -> "flv"
                        contentType?.contains("matroska") == true -> "mkv"
                        contentType?.contains("webm") == true -> "webm"
                        contentType?.contains("mp2t") == true -> "ts"
                        else -> "mp4"
                    }
            }
        }

        private fun typeOf(ext: String): String = when (ext.lowercase()) {
            "ts", "m2ts" -> "video/mp2t"
            "mp4", "m4s", "m4v" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "flv" -> "video/x-flv"
            "avi" -> "video/x-msvideo"
            "mpg", "mpeg" -> "video/mpeg"
            "aac" -> "audio/aac"
            "vtt", "webvtt" -> "text/vtt"
            "key" -> "application/octet-stream"
            else -> "application/octet-stream"
        }

        /** A file name that every system takes. */
        fun safeName(text: String): String =
            text.map { c -> if (c < ' ' || c in "\\/:*?\"<>|") '_' else c }.joinToString("").trim().trimEnd('.').take(120).ifBlank { "video" }

        /** [name] in [folder], or "name (2).ext" and so on when it is taken. */
        private fun unused(folder: File, name: String): File {
            val base = name.substringBeforeLast('.')
            val ext = name.substringAfterLast('.', "")
            var candidate = File(folder, name)
            var i = 2
            while (candidate.exists()) candidate = File(folder, "$base ($i)" + if (ext.isEmpty()) "" else ".$ext").also { i++ }
            return candidate.absoluteFile
        }
    }
}
