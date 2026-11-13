package tvbox.engine.jar

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.dex.DexExceptionHandler
import com.googlecode.d2j.node.DexMethodNode
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import tvbox.engine.core.spider.SpiderLoadException
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Turns Android spider jars (`classes*.dex` inside a zip, or a bare dex) into JVM jars, in-process with dex2jar,
 * then repairs what dex2jar gets wrong (see [ClassRepairs]). Results are cached by content hash; bump [VERSION]
 * whenever the output changes so stale conversions are redone.
 *
 * Non-dex entries (assets, resources) are carried over: some spiders read them from their own class loader.
 */
class DexConverter(private val cacheDir: File, private val log: (String) -> Unit = { System.err.println(it) }) {
    private val locks = ConcurrentHashMap<String, Any>()

    /** Returns a jar of class files for [input]; a jar that has no dex is returned as is. */
    fun convert(input: File): File {
        val bytes = input.readBytes()
        val key = sha1(bytes) + "-v$VERSION"
        val out = File(cacheDir, "$key.jar")
        val plain = File(cacheDir, "$key.plain")
        if (out.isFile && out.length() > 0) return out
        if (plain.isFile) return input
        synchronized(locks.computeIfAbsent(key) { Any() }) {
            if (out.isFile && out.length() > 0) return out
            if (plain.isFile) return input
            val result = convert(bytes)
            cacheDir.mkdirs()
            if (result == null) {
                plain.writeText("")
                return input
            }
            val tmp = File(cacheDir, "$key.tmp")
            tmp.writeBytes(result.jar)
            if (!tmp.renameTo(out)) {
                out.delete()
                if (!tmp.renameTo(out)) throw SpiderLoadException("cannot write ${out.path}")
            }
            if (result.failedMethods.isNotEmpty()) {
                log("dex2jar could not translate ${result.failedMethods.size} methods in ${input.name}: ${result.failedMethods.take(5)}")
            }
            if (result.repairs.any()) log("dex2jar output of ${input.name} repaired: ${result.repairs}")
            if (result.missingAndroidClasses.isNotEmpty()) {
                log("${input.name} uses Android classes the desktop runtime does not provide: ${result.missingAndroidClasses.take(20)}")
            }
            return out
        }
    }

    class Result(
        val jar: ByteArray,
        val failedMethods: List<String>,
        val repairs: ClassRepairs.Report,
        val missingAndroidClasses: List<String>,
    )

    /** Converts jar/dex bytes, or returns null when they hold no dex (already JVM classes). */
    fun convert(bytes: ByteArray): Result? {
        val dexes = ArrayList<ByteArray>()
        val resources = LinkedHashMap<String, ByteArray>()
        when {
            isDex(bytes) -> dexes += bytes
            isZip(bytes) -> {
                val named = sortedMapOf<Int, ByteArray>()
                ZipInputStream(ByteArrayInputStream(bytes)).use { zip ->
                    while (true) {
                        val e = zip.nextEntry ?: break
                        if (e.isDirectory) continue
                        val m = DEX_ENTRY.matchEntire(e.name)
                        when {
                            m != null -> named[m.groupValues[1].ifEmpty { "1" }.toInt()] = zip.readBytes()
                            SIGNATURE.matches(e.name) -> {}
                            else -> resources.putIfAbsent(e.name, zip.readBytes())
                        }
                    }
                }
                dexes += named.values
            }
            else -> throw SpiderLoadException("the spider jar is neither a zip nor a dex file")
        }
        if (dexes.isEmpty()) return null

        val failed = ArrayList<String>()
        val classes = LinkedHashMap<String, ByteArray>()
        val units = DexUnits()
        for (dex in dexes) {
            val d2j = try {
                Dex2jar.from(dex)
            } catch (e: Exception) {
                throw SpiderLoadException("cannot read the dex in the spider jar: ${e.message}", e)
            }
            units.scan(d2j.reader)
            // dex2jar writes a zip when the target path does not exist yet.
            val tmp = File.createTempFile("d2j-", ".jar").also { it.delete() }
            try {
                d2j.skipDebug(false)
                    .dontSanitizeNames(true)
                    .withExceptionHandler(FailedMethods(failed))
                    .to(tmp.toPath())
                ZipInputStream(tmp.inputStream().buffered()).use { zip ->
                    while (true) {
                        val e = zip.nextEntry ?: break
                        if (e.isDirectory || !e.name.endsWith(".class")) continue
                        // Multidex: the first definition wins, like on Android.
                        classes.putIfAbsent(e.name.trimStart('/').removeSuffix(".class"), zip.readBytes())
                    }
                }
            } finally {
                tmp.delete()
            }
        }
        val report = ClassRepairs.repair(classes, units)
        val missing = ClassRepairs.missingAndroidClasses(classes, javaClass.classLoader)

        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, data) in resources) {
                if (name.endsWith(".class") && classes.containsKey(name.removeSuffix(".class"))) continue
                zip.putNextEntry(ZipEntry(name))
                zip.write(data)
                zip.closeEntry()
            }
            for ((name, data) in classes) {
                zip.putNextEntry(ZipEntry("$name.class"))
                zip.write(data)
                zip.closeEntry()
            }
        }
        return Result(out.toByteArray(), failed, report, missing)
    }

    /** A method dex2jar cannot translate throws when called instead of failing the whole jar. */
    private class FailedMethods(private val failed: MutableList<String>) : DexExceptionHandler {
        override fun handleFileException(e: Exception) {
            failed += "file: ${e.message}"
        }

        override fun handleMethodTranslateException(method: Method, node: DexMethodNode?, mv: MethodVisitor, e: Exception) {
            synchronized(failed) { failed += "$method" }
            val message = "dex2jar could not translate $method: ${e.javaClass.simpleName} ${e.message ?: ""}"
            mv.visitCode()
            mv.visitTypeInsn(Opcodes.NEW, "java/lang/RuntimeException")
            mv.visitInsn(Opcodes.DUP)
            mv.visitLdcInsn(message.take(500))
            mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/RuntimeException", "<init>", "(Ljava/lang/String;)V", false)
            mv.visitInsn(Opcodes.ATHROW)
            mv.visitMaxs(3, 0)
            mv.visitEnd()
        }
    }

    companion object {
        /** Bump when the conversion output changes. */
        const val VERSION = 1

        private val DEX_ENTRY = Regex("classes(\\d*)\\.dex")
        private val SIGNATURE = Regex("META-INF/[^/]+\\.(SF|RSA|DSA|EC)")

        fun isDex(b: ByteArray) = b.size > 8 && b[0] == 'd'.code.toByte() && b[1] == 'e'.code.toByte() && b[2] == 'x'.code.toByte() && b[3] == '\n'.code.toByte()
        fun isZip(b: ByteArray) = b.size > 4 && b[0] == 'P'.code.toByte() && b[1] == 'K'.code.toByte()

        private fun sha1(bytes: ByteArray) = MessageDigest.getInstance("SHA-1").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
