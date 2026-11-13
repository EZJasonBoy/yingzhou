package tvbox.engine.js

import com.dokar.quickjs.ModuleContent
import com.dokar.quickjs.QuickJs
import com.dokar.quickjs.binding.asyncFunction
import com.dokar.quickjs.binding.define
import com.dokar.quickjs.binding.function
import com.dokar.quickjs.moduleLoader
import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.JsonParser
import tvbox.engine.core.spider.ProxyResponse
import tvbox.engine.core.util.Base64Compat
import java.io.ByteArrayInputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.spider.Spider
import tvbox.engine.core.spider.SpiderLoadException
import tvbox.engine.js.legacy.Crypto
import tvbox.engine.js.legacy.RSAEncrypt
import tvbox.engine.js.legacy.Trans
import java.net.URLEncoder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Shared by every JS spider of an engine. */
class JsEnvironment(
    val modules: JsModules,
    val http: JsHttp,
    val local: JsLocalStore,
    /** The engine's spider proxy, e.g. `http://127.0.0.1:9978/proxy`. */
    val proxyUrl: String,
    val log: (String) -> Unit = {},
)

/**
 * A TVBox JS spider on QuickJS. Port of `com.github.catvod.crawler.js.JsSpider`:
 * loads the module through TVBox's module rules, installs the TVBox host API, and calls the exported
 * `init/home/homeVod/category/detail/search/play` functions. Each spider has its own QuickJS instance on its own
 * thread; calls are serialised.
 *
 * Not supported yet: QuickJS bytecode modules (`//bb`, `//DRPY`; they are tied to TVBox's QuickJS build),
 * `jsapi` dex bindings, and the spider proxy.
 */
class JsSpider private constructor(
    private val site: SiteBean,
    private val env: JsEnvironment,
    private val executor: ExecutorService,
    private val qjs: QuickJs,
) : Spider {
    private val lock = Mutex()

    override suspend fun init(ext: String) {
        call("await globalThis.__tvbox_init(${json(ext)}, ${json(site.key)})")
    }

    override suspend fun home(filter: Boolean) = invoke("home", filter)
    override suspend fun homeVod() = invoke("homeVod")
    override suspend fun category(tid: String, pg: String, filter: Boolean, extend: Map<String, String>) =
        invoke("category", tid, pg, filter, extend)
    override suspend fun detail(id: String) = invoke("detail", id)
    override suspend fun search(key: String, quick: Boolean, pg: String) = invoke("search", key, quick, pg)
    override suspend fun play(flag: String, id: String, vipFlags: List<String>) = invoke("play", flag, id, vipFlags)

    override fun destroy() {
        executor.execute {
            runCatching { qjs.close() }
            executor.shutdown()
        }
    }

    /** Called on every use; the runtime sends `proxy?do=js` to the most recently used JS spider, like TVBox. */
    @Volatile var onUse: (() -> Unit)? = null

    override suspend fun proxy(params: Map<String, String>): ProxyResponse? {
        val text = call("await globalThis.__tvbox_proxy(${gson.toJson(params)})") as? String ?: return null
        val root = runCatching { JsonParser.parseString(text).asJsonObject }.getOrNull() ?: return null
        val value = root.get("value") ?: return null
        return if (root.get("style")?.asInt == 2) proxyStyle2(value) else proxyStyle1(value)
    }

    /** `[code, mime, content, headers?, base64?]`; content is text, a byte array, or base64 when the 5th item is 1. */
    private fun proxyStyle1(value: JsonElement): ProxyResponse? {
        if (!value.isJsonArray) return null
        val a = value.asJsonArray
        if (a.size() < 3) return null
        val code = a[0].asNumberOrNull()?.toInt() ?: 200
        val mime = a[1].takeIf { it.isJsonPrimitive }?.asString ?: "application/octet-stream"
        val content = a[2]
        val base64 = a.size() > 4 && a[4].asNumberOrNull()?.toInt() == 1
        val bytes = when {
            content.isJsonArray -> ByteArray(content.asJsonArray.size()) { i -> content.asJsonArray[i].asInt.toByte() }
            base64 -> Base64Compat.decode(content.asString.let { if (it.contains("base64,")) it.substringAfter("base64,") else it })
            content.isJsonPrimitive -> content.asString.toByteArray()
            else -> ByteArray(0)
        }
        val headers = if (a.size() > 3) jsonHeaders(a[3]) else emptyMap()
        return ProxyResponse(code, mime, ByteArrayInputStream(bytes), headers)
    }

    /** `{ code, buffer, content, headers }`; buffer 2 means base64 content. */
    private fun proxyStyle2(value: JsonElement): ProxyResponse? {
        if (!value.isJsonObject) return null
        val o = value.asJsonObject
        val headers = jsonHeaders(o.get("headers"))
        val content = o.get("content")?.takeIf { it.isJsonPrimitive }?.asString ?: ""
        val bytes = if (o.get("buffer")?.asNumberOrNull()?.toInt() == 2) Base64Compat.decode(content) else content.toByteArray()
        val type = headers.entries.firstOrNull { it.key.equals("Content-Type", true) }?.value ?: "application/octet-stream"
        return ProxyResponse(o.get("code")?.asNumberOrNull()?.toInt() ?: 200, type, ByteArrayInputStream(bytes), headers)
    }

    private fun jsonHeaders(el: JsonElement?): Map<String, String> {
        val obj = when {
            el == null || el.isJsonNull -> return emptyMap()
            el.isJsonObject -> el.asJsonObject
            el.isJsonPrimitive -> runCatching { JsonParser.parseString(el.asString).asJsonObject }.getOrNull() ?: return emptyMap()
            else -> return emptyMap()
        }
        return obj.entrySet().associate { (k, v) -> k to (if (v.isJsonPrimitive) v.asString else v.toString()) }
    }

    private fun JsonElement.asNumberOrNull(): Number? = if (isJsonPrimitive && asJsonPrimitive.isNumber) asNumber else asString.toDoubleOrNull()

    private suspend fun invoke(method: String, vararg args: Any?): String? {
        onUse?.invoke()
        return call("await globalThis.__tvbox_invoke(${json(method)}, ${gson.toJson(args.toList())})") as? String
    }

    private suspend fun call(code: String): Any? = lock.withLock {
        try {
            qjs.evaluate<Any?>(code, "tvbox_call.js")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            env.log("js ${site.key}: ${e.message}")
            throw SpiderLoadException("${site.name}: ${e.message ?: "script error"}", e)
        }
    }

    companion object {
        private val gson = Gson()

        /** TVBox compiles an empty module with these exports when an import cannot be found. */
        private const val EMPTY_MODULE = """
            const empty = null;
            export default empty;
            export const JSEncrypt = empty; export const NodeRSA = empty; export const pako = empty;
            export const JSON5 = empty; export const mb = empty; export const parse = empty;
            export const stringify = empty; export const inflate = empty; export const deflate = empty;
            export const gzip = empty; export const ungzip = empty; export const encrypt = empty;
            export const decrypt = empty;
        """

        private fun rootModule(api: String) = """
            import * as spider from ${json(api)}
            if (!globalThis.__JS_SPIDER__) {
                if (spider.__jsEvalReturn) {
                    globalThis.req = http
                    globalThis.__JS_SPIDER__ = spider.__jsEvalReturn()
                    globalThis.__JS_SPIDER__.is_cat = true
                } else if (spider.default) {
                    globalThis.__JS_SPIDER__ = typeof spider.default === 'function' ? spider.default() : spider.default
                }
            }
        """

        private fun json(s: String): String = gson.toJson(s)

        suspend fun load(site: SiteBean, ext: String, env: JsEnvironment): JsSpider {
            val api = site.api
            val main = env.modules.loadMain(api) ?: throw SpiderLoadException("${site.name}: cannot download $api")
            if (main.startsWith("//bb") || main.startsWith("//DRPY")) {
                throw SpiderLoadException("${site.name}: QuickJS bytecode spiders are not supported yet")
            }
            // TVBox rewrites `__JS_SPIDER__ = {...}` into a default export.
            val mainSource = if (main.contains("__JS_SPIDER__")) main.replace(Regex("__JS_SPIDER__\\s*="), "export default ") else main

            val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "js-spider-${site.key}").apply { isDaemon = true } }
            val loader = moduleLoader {
                normalize { base, requested -> env.modules.normalize(base, requested) }
                load { name ->
                    val source = if (name == api) mainSource else env.modules.load(name)
                    when {
                        source == null -> {
                            env.log("js ${site.key}: module not found, using an empty one: $name")
                            ModuleContent.Source(EMPTY_MODULE)
                        }
                        source.startsWith("//bb") || source.startsWith("//DRPY") -> {
                            env.log("js ${site.key}: bytecode module not supported: $name")
                            ModuleContent.Source(EMPTY_MODULE)
                        }
                        else -> ModuleContent.Source(source)
                    }
                }
            }
            val qjs = try {
                QuickJs.create(executor.asCoroutineDispatcher(), loader)
            } catch (e: Exception) {
                executor.shutdown()
                throw SpiderLoadException("${site.name}: cannot start QuickJS: ${e.message}", e)
            }
            val spider = JsSpider(site, env, executor, qjs)
            try {
                installHost(qjs, site, env)
                qjs.evaluate<Any?>(bootstrap(), "tvbox_bootstrap.js")
                env.modules.bundled("net.js")?.let { qjs.evaluate<Any?>(it, "net.js") }
                runCatching {
                    qjs.evaluate<Any?>(
                        "import tpl from '模板.js';\nglobalThis.muban = tpl.muban;\nglobalThis.getMubans = tpl.getMubans;",
                        "tv_box_template.js",
                        asModule = true,
                    )
                }
                qjs.evaluate<Any?>(rootModule(api), "tv_box_root.js", asModule = true)
                if (qjs.evaluate<Any?>("!!globalThis.__JS_SPIDER__") != true) {
                    throw SpiderLoadException("${site.name}: the script does not export a spider")
                }
                spider.init(ext)
                return spider
            } catch (e: Exception) {
                spider.destroy()
                if (e is SpiderLoadException) throw e
                throw SpiderLoadException("${site.name}: ${e.message ?: "failed to load"}", e)
            }
        }

        private fun bootstrap(): String =
            JsSpider::class.java.getResourceAsStream("/tvbox/js/bootstrap.js")!!.use { String(it.readBytes(), Charsets.UTF_8) }

        /** The TVBox JS host API (`Global`, `local`, console), minus what bootstrap.js builds on top of it. */
        private fun installHost(qjs: QuickJs, site: SiteBean, env: JsEnvironment) {
            val parser = HtmlParser()
            val proxy = env.proxyUrl + "?do=js"

            qjs.function("getProxy") { _ -> proxy }
            qjs.function("joinUrl") { a -> HtmlParser.joinUrl(a.s(0), a.s(1)) }
            qjs.function("__host_pd") { a -> parser.parseDomForUrl(a.s(0), a.s(1), a.s(2)) }
            qjs.function("__host_pdfa") { a -> gson.toJson(parser.parseDomForArray(a.s(0), a.s(1))) }
            qjs.function("__host_pdfla") { a -> gson.toJson(parser.parseDomForList(a.s(0), a.s(1), a.s(2), a.s(3), a.s(4))) }
            qjs.function("s2t") { a -> Trans.s2t(false, a.s(0)) ?: "" }
            qjs.function("t2s") { a -> Trans.t2s(false, a.s(0)) ?: "" }
            qjs.function("aesX") { a -> Crypto.aes(a.s(0), a.b(1), a.s(2), a.b(3), a.s(4), a.s(5), a.b(6)) ?: "" }
            qjs.function("rsaX") { a -> Crypto.rsa(a.b(1), a.b(2), a.s(3), a.b(4), a.s(5), a.b(6)) ?: "" }
            qjs.function("__host_rsa") { a -> rsa(a.b(0), a.s(1), a.s(2), a.s(3)) }
            qjs.function("__host_http") { a -> env.http.request(a.s(0), a.s(1)) }
            qjs.asyncFunction("__host_http_async") { a -> withContext(Dispatchers.IO) { env.http.request(a.s(0), a.s(1)) } }
            qjs.asyncFunction("__host_sleep") { a -> delay((a.getOrNull(0) as? Number)?.toLong() ?: 0L) }
            // The engine serves local and LAN clients from the same address, so `dynamic` makes no difference here.
            qjs.function("__host_js2proxy") { a ->
                proxy + "&from=catvod&siteType=" + a.s(1) + "&siteKey=" + a.s(2) +
                    "&header=" + URLEncoder.encode(a.s(4), "UTF-8") + "&url=" + URLEncoder.encode(a.s(3), "UTF-8")
            }
            qjs.define("local") {
                function("get") { a -> env.local.get("jsRuntime_${a.s(0)}_${a.s(1)}") ?: "" }
                function("set") { a -> env.local.set("jsRuntime_${a.s(0)}_${a.s(1)}", a.s(2)) }
                function("delete") { a -> env.local.delete("jsRuntime_${a.s(0)}_${a.s(1)}") }
            }
            qjs.define("console") {
                for (level in listOf("log", "info", "warn", "error", "debug")) {
                    function(level) { a -> env.log("js ${site.key} [$level] " + a.joinToString(" ")) }
                }
            }
        }

        /** `rsaEncrypt` / `rsaDecrypt` with TVBox's options: config, type (1 public / 2 private), long, block. */
        private fun rsa(encrypt: Boolean, data: String, key: String, optionsJson: String): String = try {
            val o = runCatching { JsonParser.parseString(optionsJson).asJsonObject }.getOrNull()
            val config = o?.get("config")?.takeIf { it.isJsonPrimitive }?.asString
            val type = o?.get("type")?.takeIf { it.isJsonPrimitive }?.asDouble?.toInt() ?: 1
            val long = o?.get("long")?.takeIf { it.isJsonPrimitive }?.asDouble?.toInt() ?: 1
            val block = o?.get("block")?.takeIf { it.isJsonPrimitive }?.asBoolean ?: true
            when {
                encrypt && type == 1 -> if (config != null) RSAEncrypt.encryptByPublicKey(data, key, config, long, block) else RSAEncrypt.encryptByPublicKey(data, key, long, block)
                encrypt && type == 2 -> if (config != null) RSAEncrypt.encryptByPrivateKey(data, key, config, long, block) else RSAEncrypt.encryptByPrivateKey(data, key, long, block)
                !encrypt && type == 1 -> if (config != null) RSAEncrypt.decryptByPrivateKey(data, key, config, long, block) else RSAEncrypt.decryptByPrivateKey(data, key, long, block)
                !encrypt && type == 2 -> if (config != null) RSAEncrypt.decryptByPublicKey(data, key, config, long, block) else RSAEncrypt.decryptByPublicKey(data, key, long, block)
                else -> ""
            } ?: ""
        } catch (e: Exception) {
            ""
        }

        private fun Array<Any?>.s(i: Int): String = when (val v = getOrNull(i)) {
            null -> ""
            is Double -> if (v % 1.0 == 0.0) v.toLong().toString() else v.toString()
            else -> v.toString()
        }

        private fun Array<Any?>.b(i: Int): Boolean = when (val v = getOrNull(i)) {
            is Boolean -> v
            is Number -> v.toInt() != 0
            is String -> v == "true"
            else -> false
        }
    }
}
