package tvbox.engine.py

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.spider.SpiderLoadException
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/**
 * Fetches spider scripts (and the scripts they depend on) to disk, where the worker loads them from. Like TVBox,
 * a script is downloaded again each time a config is loaded; when that fails, the copy from last time is used.
 *
 * Addresses: http(s) through the engine's client (so `hosts`, `headers` and the GitHub proxy apply); `clan://` and
 * `file://` through the engine's /file mapping; a plain path to a file on this machine as it is.
 */
class PyScripts(
    private val client: OkHttpClient,
    private val locator: ConfigLocator?,
    private val dir: File,
    private val log: (String) -> Unit = {},
) {
    suspend fun fetch(api: String): File = withContext(Dispatchers.IO) {
        val local = File(api)
        if (!api.contains("://") && local.isFile) return@withContext local
        val address = when {
            api.startsWith("http://") || api.startsWith("https://") -> api
            (api.startsWith("clan://") || api.startsWith("file://")) && locator != null ->
                locator.clanToAddress(api.replace("file://", "clan://localhost/"))
            else -> throw SpiderLoadException("不认识的 Python 蜘蛛地址：$api")
        }
        val target = File(File(dir, md5(api).take(16)), fileName(api))
        val text = try {
            client.newBuilder().callTimeout(30, TimeUnit.SECONDS).build()
                .newCall(Request.Builder().url(address).build()).execute().use { res ->
                    if (!res.isSuccessful) throw java.io.IOException("HTTP ${res.code}")
                    res.body?.bytes()?.toString(Charsets.UTF_8).orEmpty()
                }
        } catch (e: Exception) {
            log("py script $api: $e")
            if (target.isFile) return@withContext target
            throw SpiderLoadException("下载不了 Python 蜘蛛 $api：${e.message}", e)
        }
        if (invalid(text)) {
            if (target.isFile) return@withContext target
            throw SpiderLoadException("下载到的不是 Python 脚本：$api")
        }
        target.parentFile.mkdirs()
        val tmp = File(target.path + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) {
            target.delete()
            tmp.renameTo(target)
        }
        target
    }

    companion object {
        /** TVBox names the file after the last part of the address, up to the first dot (`py_abc.py?x=1` -> `py_abc.py`). */
        fun fileName(api: String): String {
            val last = api.substringBefore('?').substringBefore('#').trimEnd('/').substringAfterLast('/')
            val stem = last.substringBefore('.').replace(Regex("[^\\p{L}\\p{N}_-]"), "_").ifEmpty { "spider" }
            return "$stem.py"
        }

        /** An error page or an empty answer is not a script. */
        fun invalid(text: String): Boolean {
            val t = text.trimStart('﻿').trim().lowercase()
            return t.isEmpty() || t.startsWith("<") || t.startsWith("{\"code\":404") || t.startsWith("404") || t.startsWith("not found")
        }

        /** `?extend=` of a script address, which TVBox passes to init() when the site has no ext. */
        fun extendOf(api: String): String {
            val query = api.substringAfter('?', "").substringBefore('#')
            return query.split('&').firstOrNull { it.startsWith("extend=") }?.removePrefix("extend=")
                ?.let { runCatching { java.net.URLDecoder.decode(it, "UTF-8") }.getOrDefault(it) }.orEmpty()
        }

        private fun md5(s: String): String = MessageDigest.getInstance("MD5").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
