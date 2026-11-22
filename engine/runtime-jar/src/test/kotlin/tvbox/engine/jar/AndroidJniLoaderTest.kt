package tvbox.engine.jar

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.util.Base64
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class AndroidJniLoaderTest {
    @TempDir lateinit var dir: File

    private fun fixture(name: String): ByteArray = javaClass.getResourceAsStream("/jni/$name.base64")!!.use {
        Base64.getMimeDecoder().decode(it.readBytes())
    }

    private fun archive(abi: String): File {
        val source = File(dir, "spider-$abi.jar").also { jar ->
            ZipOutputStream(jar.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("classes.dex"))
                zip.write(fixture("math.dex"))
                zip.putNextEntry(ZipEntry("assets/libs/$abi/libmath.so"))
                zip.write(fixture("libmath-$abi.so"))
            }
        }
        return DexConverter(File(dir, "converted")).convert(source)
    }

    @Test fun `packaged 32 and 64 bit JNI runs through the spider class loader`() {
        for ((abi, expected) in listOf("arm" to "armeabi-v7a", "arm64" to "arm64-v8a")) {
            AndroidJniLoader.open(archive(abi), dir, enabled = true).use { loader ->
                val spider = loader.loadClass("tvbox.fixture.NativeMath")
                assertEquals(expected, spider.getMethod("abi").invoke(null))
                val load = spider.getMethod("loadLibrary", String::class.java)
                load.invoke(null, "math")
                load.invoke(null, "math")
                assertEquals(42, spider.getMethod("add", Int::class.java, Int::class.java).invoke(null, 19, 23))
                val error = assertThrows(InvocationTargetException::class.java) { spider.getMethod("unsupported").invoke(null) }.cause
                assertEquals("Android JNI: unsupported signature", error?.message)
            }
        }
    }

    @Test fun `System load accepts the packaged copy only from spider storage`() {
        val storage = File(dir, "spider").also { it.mkdir() }
        val asset = fixture("libmath-arm64.so")
        AndroidJniLoader.open(archive("arm64"), storage, enabled = true).use { loader ->
            val spider = loader.loadClass("tvbox.fixture.NativeMath")
            val load = spider.getMethod("load", String::class.java)
            for ((file, data) in listOf(File(dir, "elsewhere") to asset, File(storage, "modified") to asset.reversedArray())) {
                file.writeBytes(data)
                assertInstanceOf(UnsatisfiedLinkError::class.java, assertThrows(InvocationTargetException::class.java) { load.invoke(null, file.path) }.cause)
            }
            val copy = File(storage, "generated-filename").also { it.writeBytes(asset) }
            load.invoke(null, copy.path)
            assertEquals(9, spider.getMethod("add", Int::class.java, Int::class.java).invoke(null, 4, 5))
        }
        AndroidJniLoader.open(archive("arm"), storage, enabled = false).use { assertFalse(it is AndroidJniLoader) }
    }
}
