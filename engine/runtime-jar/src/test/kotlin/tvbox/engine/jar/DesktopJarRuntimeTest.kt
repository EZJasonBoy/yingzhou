package tvbox.engine.jar

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.CleanupMode
import org.junit.jupiter.api.io.TempDir
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes.ACC_ABSTRACT
import org.objectweb.asm.Opcodes.ACC_PUBLIC
import org.objectweb.asm.Opcodes.ACC_STATIC
import org.objectweb.asm.Opcodes.ALOAD
import org.objectweb.asm.Opcodes.ARETURN
import org.objectweb.asm.Opcodes.DUP
import org.objectweb.asm.Opcodes.INVOKESPECIAL
import org.objectweb.asm.Opcodes.NEW
import org.objectweb.asm.Opcodes.RETURN
import org.objectweb.asm.Opcodes.V1_6
import tvbox.engine.core.config.ConfigLocator
import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.spider.JarRepository
import tvbox.engine.core.vod.TvboxResult
import java.io.File

class DesktopJarRuntimeTest {
    private lateinit var server: MockWebServer
    // The spider class loader keeps the converted jar open, which Windows will not delete.
    @TempDir(cleanup = CleanupMode.NEVER) lateinit var dir: File

    private val demoJar = listOf("../server/src/main/resources/demo/spider.jar", "server/src/main/resources/demo/spider.jar")
        .map(::File).first { it.isFile }

    @BeforeEach
    fun start() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl!!.encodedPath) {
                "/spider.jar" -> MockResponse().setBody(Buffer().write(demoJar.readBytes()))
                "/api" -> MockResponse().setBody(
                    """{"class":[{"type_id":"1","type_name":"电影"}],"list":[{"vod_id":"7","vod_name":"星河","vod_remarks":"HD"}]}""",
                )
                "/jx" -> MockResponse().setBody("""{"url":"https://cdn.test/jx/index.m3u8"}""")
                else -> MockResponse().setResponseCode(404)
            }
        }
        server.start()
    }

    @AfterEach
    fun stop() {
        server.shutdown()
    }

    private fun runtime() = DesktopJarRuntime(
        dataDir = File(dir, "data"),
        jars = JarRepository(OkHttpClient(), ConfigLocator("http://127.0.0.1:9978/file/"), File(dir, "jar")),
        port = { 9978 },
        cacheDir = File(dir, "d2j"),
        log = {},
    )

    @Test
    fun `the demo dex jar runs on the JVM with Init, host OkHttp, org json and the jar proxy`() = runBlocking {
        val runtime = runtime()
        runtime.onConfig(TvboxConfig(spider = server.url("/spider.jar").toString()))
        val site = SiteBean(key = "demo_jar", name = "demo jar", type = 3, api = "csp_DemoJar", ext = """{"api":"${server.url("/api")}"}""")
        assertTrue(runtime.supports(site))
        val spider = runtime.create(site, site.ext)
        try {
            val home = TvboxResult.parseHome("demo_jar", spider.home(true)!!)
            assertEquals(listOf("电影"), home.classes.map { it.name })
            assertEquals("JAR · HD", home.list.single().remarks, "Init.init ran and the spider rewrote the remarks")

            val play = spider.play("x", "https://cdn.test/a.m3u8", emptyList())!!
            assertTrue(play.contains("\"parse\":0"), play)

            val proxied = runtime.proxy(mapOf("do" to "demo", "x" to "42"))
            assertNotNull(proxied)
            assertEquals(200, proxied!!.status)
            assertEquals("jar proxy ok 42", proxied.body!!.readBytes().decodeToString())
            assertNull(runtime.proxy(mapOf("do" to "other")))
        } finally {
            spider.destroy()
        }
        // The conversion is cached by content.
        assertEquals(1, File(dir, "d2j").listFiles()!!.count { it.name.endsWith(".jar") })
    }

    @Test
    fun `a Mix parser in the config's spider jar runs with TVBox's arguments`() = runBlocking {
        val runtime = runtime()
        runtime.onConfig(TvboxConfig(spider = server.url("/spider.jar").toString()))
        val jxs = linkedMapOf(
            "聚合" to hashMapOf("url" to "Demo", "type" to "3", "ext" to ""),
            "演示解析" to hashMapOf("url" to server.url("/jx?url=").toString(), "type" to "1", "ext" to ""),
        )
        val answer = runtime.jsonExtMix("qq111", "Demo", "聚合", jxs, "https://site.test/v/1")!!
        assertTrue(answer.contains("\"url\":\"https:\\/\\/cdn.test\\/jx\\/index.m3u8\""), answer)
        assertTrue(answer.contains("\"jxFrom\":\"演示解析\""), answer)
        assertTrue(answer.contains("\"flag\":\"qq111\""), answer)
        assertNull(runtime.jsonExtMix("qq111", "Nope", "x", jxs, "u"), "unknown parser classes give null")
    }

    @Test
    fun `self invokespecial left by invoke-super is pointed at the superclass`() {
        val classes = linkedMapOf(
            "t/Base" to classBytes("t/Base", "java/lang/Object") { cw ->
                cw.method(ACC_PUBLIC, "who", "()Ljava/lang/String;") { mv ->
                    mv.visitLdcInsn("base")
                    mv.visitInsn(ARETURN)
                }
            },
            // who() { return super.who(); } as dex2jar emits it: invokespecial t/Child.who
            "t/Child" to classBytes("t/Child", "t/Base") { cw ->
                cw.method(ACC_PUBLIC, "who", "()Ljava/lang/String;") { mv ->
                    mv.visitVarInsn(ALOAD, 0)
                    mv.visitMethodInsn(INVOKESPECIAL, "t/Child", "who", "()Ljava/lang/String;", false)
                    mv.visitInsn(ARETURN)
                }
            },
        )
        val report = ClassRepairs.repair(classes, DexUnits())
        assertEquals(1, report.superCalls)
        val child = load(classes).loadClass("t.Child").getDeclaredConstructor().newInstance()
        assertEquals("base", child.javaClass.getMethod("who").invoke(child))
    }

    @Test
    fun `new of an ancestor written by dex2jar is moved back to the real class`() {
        val classes = linkedMapOf(
            "t/Shape" to classBytes("t/Shape", "java/lang/Object", access = ACC_PUBLIC or ACC_ABSTRACT, ctorDesc = "(Ljava/lang/String;)V"),
            // R8 removed Circle's constructor: the dex says new-instance Circle; invoke-direct Shape.<init>(String)
            "t/Circle" to classBytes("t/Circle", "t/Shape", ctorDesc = null),
            "t/Factory" to classBytes("t/Factory", "java/lang/Object") { cw ->
                cw.method(ACC_PUBLIC or ACC_STATIC, "make", "()Ljava/lang/Object;") { mv ->
                    mv.visitTypeInsn(NEW, "t/Shape")
                    mv.visitInsn(DUP)
                    mv.visitLdcInsn("r")
                    mv.visitMethodInsn(INVOKESPECIAL, "t/Shape", "<init>", "(Ljava/lang/String;)V", false)
                    mv.visitInsn(ARETURN)
                }
            },
        )
        val units = DexUnits()
        units.byMethod[DexUnits.key("t/Factory", "make", "()Ljava/lang/Object;")] =
            listOf(DexUnits.Unit("t/Circle", "t/Shape", "(Ljava/lang/String;)V"))
        val report = ClassRepairs.repair(classes, units)
        assertEquals(1, report.newSites)
        assertEquals(1, report.constructors)
        val made = load(classes).loadClass("t.Factory").getMethod("make").invoke(null)
        assertEquals("t.Circle", made.javaClass.name)
    }

    @Test
    fun `android base64 keeps its line wrapping and lenient decoding`() {
        val wrapped = android.util.Base64.encodeToString("abc".toByteArray(), android.util.Base64.DEFAULT)
        assertEquals("YWJj\n", wrapped)
        assertEquals("YWJj", android.util.Base64.encodeToString("abc".toByteArray(), android.util.Base64.NO_WRAP))
        assertEquals("abc", String(android.util.Base64.decode("YW Jj\n", android.util.Base64.DEFAULT)))
        assertEquals("??>", String(android.util.Base64.decode("Pz8-", android.util.Base64.URL_SAFE)))
    }

    private fun load(classes: Map<String, ByteArray>) = object : ClassLoader(javaClass.classLoader) {
        override fun findClass(name: String): Class<*> {
            val bytes = classes[name.replace('.', '/')] ?: throw ClassNotFoundException(name)
            return defineClass(name, bytes, 0, bytes.size)
        }
    }

    private fun classBytes(
        name: String,
        superName: String,
        access: Int = ACC_PUBLIC,
        ctorDesc: String? = "()V",
        body: (ClassWriter) -> Unit = {},
    ): ByteArray {
        val cw = ClassWriter(ClassWriter.COMPUTE_MAXS)
        cw.visit(V1_6, access, name, null, superName, null)
        if (ctorDesc != null) {
            cw.method(ACC_PUBLIC, "<init>", ctorDesc) { mv ->
                mv.visitVarInsn(ALOAD, 0)
                mv.visitMethodInsn(INVOKESPECIAL, superName, "<init>", "()V", false)
                mv.visitInsn(RETURN)
            }
        }
        body(cw)
        cw.visitEnd()
        return cw.toByteArray()
    }

    private fun ClassWriter.method(access: Int, name: String, desc: String, code: (org.objectweb.asm.MethodVisitor) -> Unit) {
        val mv = visitMethod(access, name, desc, null, null)
        mv.visitCode()
        code(mv)
        mv.visitMaxs(0, 0)
        mv.visitEnd()
    }
}
