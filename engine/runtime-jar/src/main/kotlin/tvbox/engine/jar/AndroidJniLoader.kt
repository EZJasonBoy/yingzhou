package tvbox.engine.jar

import java.io.File
import java.net.URLClassLoader
import java.nio.file.Files
import java.nio.file.Path
import java.security.CodeSource
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.jar.JarFile
import java.util.zip.ZipEntry
import java.util.zip.ZipFile

class AndroidJniLoader private constructor(
    private val archive: File,
    private val dataDir: File,
    private val libraries: List<Library>,
) : URLClassLoader(arrayOf(archive.toURI().toURL()), AndroidJniLoader::class.java.classLoader) {
    private data class Library(val entry: String, val size: Long, val arm64: Boolean) {
        val name = entry.substringAfterLast('/')
    }

    private var guest: AndroidJniGuest? = null
    private var guestRoot: Path? = null
    private var guestAbi: Boolean? = null
    private var closed = false
    private val extracted = mutableMapOf<Library, ByteArray>()
    private val entries = JarFile(archive, true, ZipFile.OPEN_READ, JarFile.runtimeVersion())
    private val sourceUrl = archive.toURI().toURL()

    @Synchronized private fun arm64() = guestAbi ?: libraries.any { it.arm64 }

    @Synchronized override fun findClass(name: String): Class<*> {
        if (closed) throw ClassNotFoundException(name)
        val entry = entries.getJarEntry(name.replace('.', '/') + ".class") ?: return super.findClass(name)
        val original = entries.getInputStream(entry).use { it.readBytes() }
        val manifest = entries.manifest
        val packageName = name.substringBeforeLast('.', "")
        val sealed = manifest?.getAttributes(packageName.replace('.', '/') + "/")?.getValue("Sealed")
            ?: manifest?.mainAttributes?.getValue("Sealed")
        if (entry.codeSigners != null || sealed.equals("true", true)) return super.findClass(name)
        if (packageName.isNotEmpty() && getDefinedPackage(packageName) == null) {
            if (manifest != null) definePackage(packageName, manifest, sourceUrl)
            else definePackage(packageName, null, null, null, null, null, null, null)
        }
        val bytes = AndroidJniBytecode.adapt(original)
        return defineClass(name, bytes, 0, bytes.size, CodeSource(sourceUrl, entry.codeSigners))
    }

    private fun bytes(library: Library): ByteArray = ZipFile(archive).use { zip ->
        zip.getInputStream(zip.getEntry(library.entry)).use { input ->
            input.readNBytes(library.size.toInt() + 1).also { if (it.size.toLong() != library.size) fail("incomplete packaged library") }
        }
    }

    private fun selectPath(path: String): Library {
        val file = File(path)
        if (!file.isAbsolute || !file.isFile || !file.toPath().toRealPath().startsWith(dataDir.toPath().toRealPath())) fail("library is outside spider storage")
        val candidates = libraries.filter { it.size == file.length() }
        if (candidates.isEmpty()) fail("library is not packaged in this spider")
        val digest = MessageDigest.getInstance("SHA-256")
        val fingerprint = file.inputStream().use { digest.digest(it.readNBytes(candidates.first().size.toInt() + 1)) }
        return candidates.firstOrNull { fingerprint.contentEquals(extracted.getOrPut(it) { digest.digest(bytes(it)) }) }
            ?: fail("library differs from the packaged copy")
    }

    @Synchronized private fun loadGuest(value: String, byName: Boolean) {
        if (closed) fail("archive is closed")
        val library = if (byName) {
            val candidates = libraries.filter { it.name == "lib$value.so" }
            candidates.firstOrNull { it.arm64 == arm64() } ?: candidates.firstOrNull() ?: fail("library is not packaged in this spider")
        } else selectPath(value)
        if (guestAbi != null && library.arm64 != guestAbi) fail("cannot mix armeabi-v7a and arm64-v8a in one guest")
        val runtime = guest ?: withGuestError("guest initialization failed") {
            val root = Files.createTempDirectory("yingzhou-jni-")
            try {
                AndroidJniGuest(library.arm64, root.toFile()).also { guestRoot = root }
            } catch (error: Throwable) {
                try { Files.deleteIfExists(root) } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
                throw error
            }
        }.also {
            guestAbi = library.arm64
            guest = it
        }
        withGuestError("guest initialization failed") { runtime.load(library.name, bytes(library)) }
    }

    @Synchronized private fun call(owner: Class<*>, signature: String, receiver: Any?, args: Array<Any?>): Any? {
        val runtime = guest ?: fail("guest unavailable")
        return withGuestError("native call failed") { runtime.invoke(owner.name.replace('.', '/'), signature, receiver, args) }
    }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        try { guest?.close() } finally {
            guest = null
            try { guestRoot?.let { Files.deleteIfExists(it) } } finally {
                try { entries.close() } finally { super.close() }
            }
        }
    }

    companion object {
        private const val maxLibrary = 32L * 1024 * 1024
        private val caller = StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE)

        private fun inspect(zip: ZipFile, entry: ZipEntry): Library? {
            if (!entry.name.endsWith(".so") || entry.size !in 20L..maxLibrary) return null
            val header = zip.getInputStream(entry).use { it.readNBytes(20) }
            if (header.size != 20 || !header.copyOfRange(0, 4).contentEquals(byteArrayOf(127, 69, 76, 70)) ||
                header[5].toInt() != 1 || header[16].toInt() != 3 || header[17].toInt() != 0 || header[19].toInt() != 0) return null
            val arm64 = when (header[4].toInt() to (header[18].toInt() and 255)) {
                1 to 40 -> false
                2 to 183 -> true
                else -> return null
            }
            return Library(entry.name, entry.size, arm64)
        }

        internal fun open(archive: File, dataDir: File, enabled: Boolean = System.getenv("YINGZHOU_ANDROID_JNI") == "1"): URLClassLoader {
            if (enabled) {
                val libraries = ZipFile(archive).use { zip -> zip.entries().asSequence().mapNotNull { inspect(zip, it) }.toList() }
                if (libraries.isNotEmpty()) return AndroidJniLoader(archive, dataDir, libraries)
            }
            return URLClassLoader(arrayOf(archive.toURI().toURL()), AndroidJniLoader::class.java.classLoader)
        }

        private fun fail(message: String): Nothing = throw UnsatisfiedLinkError("Android JNI: $message")
        private inline fun <T> withGuestError(operation: String, run: () -> T): T = try {
            run()
        } catch (error: Throwable) {
            if (error is VirtualMachineError || error is ThreadDeath || error is CancellationException || error is InterruptedException) throw error
            val reason = when {
                error.message == "Android JNI guest timed out" -> "guest timed out"
                error.message == "Android JNI guest unavailable" -> "guest unavailable"
                error.message.orEmpty().startsWith("Unsupported Android JNI ") -> "unsupported signature"
                else -> operation
            }
            throw UnsatisfiedLinkError("Android JNI: $reason").also { it.initCause(error) }
        }
        private fun loader(owner: Class<*>) = owner.classLoader as? AndroidJniLoader ?: fail("unknown spider archive")
        @JvmStatic fun callerIs64Bit(): Boolean = caller.walk { frames ->
            frames.map { it.declaringClass.classLoader }.filter { it is AndroidJniLoader }.findFirst().map { (it as AndroidJniLoader).arm64() }.orElse(false)
        }
        @JvmStatic fun abiField(owner: Class<*>, field: String): Any {
            val loader = loader(owner)
            val abi = if (loader.arm64()) "arm64-v8a" else "armeabi-v7a"
            val abis = (listOf(abi) + loader.libraries.map { if (it.arm64) "arm64-v8a" else "armeabi-v7a" }).distinct()
            return when (field) {
                "CPU_ABI" -> abi
                "CPU_ABI2" -> abis.getOrNull(1).orEmpty()
                "SUPPORTED_64_BIT_ABIS" -> abis.filter { it == "arm64-v8a" }.toTypedArray()
                "SUPPORTED_32_BIT_ABIS" -> abis.filter { it == "armeabi-v7a" }.toTypedArray()
                else -> abis.toTypedArray()
            }
        }
        @JvmStatic fun loadLibrary(name: String, owner: Class<*>) = loader(owner).loadGuest(name, true)
        @JvmStatic fun load(path: String, owner: Class<*>) = loader(owner).loadGuest(path, false)
        @JvmStatic fun invokeNative(owner: Class<*>, signature: String, receiver: Any?, args: Array<Any?>): Any? = loader(owner).call(owner, signature, receiver, args)
    }
}
