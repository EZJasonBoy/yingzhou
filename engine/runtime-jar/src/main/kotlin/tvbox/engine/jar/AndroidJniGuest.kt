package tvbox.engine.jar

import com.github.unidbg.AndroidEmulator
import com.github.unidbg.Emulator
import com.github.unidbg.arm.ARMEmulator
import com.github.unidbg.arm.backend.Backend
import com.github.unidbg.arm.backend.BlockHook
import com.github.unidbg.arm.backend.UnHook
import com.github.unidbg.arm.backend.Unicorn2Factory
import com.github.unidbg.file.FileResult
import com.github.unidbg.file.FileSystem
import com.github.unidbg.file.linux.AndroidFileIO
import com.github.unidbg.linux.ARM32SyscallHandler
import com.github.unidbg.linux.ARM64SyscallHandler
import com.github.unidbg.linux.LinuxModule
import com.github.unidbg.linux.android.AndroidARM64Emulator
import com.github.unidbg.linux.android.AndroidARMEmulator
import com.github.unidbg.linux.android.AndroidResolver
import com.github.unidbg.linux.android.dvm.AbstractJni
import com.github.unidbg.linux.android.dvm.DvmObject
import com.github.unidbg.linux.android.dvm.StringObject
import com.github.unidbg.linux.android.dvm.VM
import com.github.unidbg.linux.android.dvm.array.ByteArray as GuestBytes
import com.github.unidbg.memory.SvcMemory
import com.github.unidbg.pointer.UnidbgPointer
import com.github.unidbg.unix.UnixEmulator
import org.objectweb.asm.Type
import unicorn.Arm64Const
import unicorn.ArmConst
import java.io.File
import java.security.MessageDigest
import java.util.IdentityHashMap
import java.util.concurrent.TimeUnit

internal class AndroidJniGuest(is64Bit: Boolean, root: File) : AutoCloseable {
    private val emulator: AndroidEmulator = emulator(is64Bit, root)
    private val vm: VM
    private val loaded = mutableMapOf<String, ByteArray>()
    private val receivers = IdentityHashMap<Any, DvmObject<*>>()
    private var closed = false
    private var failed = false
    private var deadline = 0L

    init {
        try {
            emulator.memory.setLibraryResolver(object : AndroidResolver(23, "libc.so", "libm.so", "libdl.so", "liblog.so", "libstdc++.so", "libz.so") {
                override fun onSetToLoader(emulator: Emulator<*>) = Unit
            })
            vm = emulator.createDalvikVM()
            vm.setJni(object : AbstractJni() {})
            emulator.backend.hook_add_new(object : BlockHook {
                private var hook: UnHook? = null
                private var blocks = 0
                override fun onAttach(unHook: UnHook) { hook = unHook }
                override fun detach() { hook?.unhook() }
                override fun hookBlock(backend: Backend, address: Long, size: Int, user: Any?) {
                    if (++blocks % 256 == 0 && expired()) backend.emu_stop()
                }
            }, 1, 0, null)
        } catch (problem: Throwable) {
            runCatching { emulator.close() }.exceptionOrNull()?.let(problem::addSuppressed)
            throw problem
        }
    }

    @Synchronized
    fun load(name: String, bytes: ByteArray) {
        check(!closed && !failed) { "Android JNI guest unavailable" }
        require(name.matches(LIBRARY_NAME)) { "Invalid Android JNI library name" }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        loaded[name]?.let { previous ->
            require(digest.contentEquals(previous)) { "Conflicting Android JNI library: $name" }
            return
        }
        runGuest {
            val module = vm.loadLibrary(name, bytes, true)
            for (elf in emulator.memory.loadedModules.filterIsInstance<LinuxModule>()) {
                val resolved = elf.neededLibraries.map { it.name }.toSet()
                val missing = elf.dynamicStructure?.neededLibraries?.firstOrNull { it !in resolved }
                if (missing != null) throw UnsatisfiedLinkError("Android JNI dependency missing for ${elf.name}: $missing")
                if (!elf.unresolvedSymbol.isNullOrEmpty()) throw UnsatisfiedLinkError("Android JNI unresolved symbols in ${elf.name}: ${elf.unresolvedSymbol.size}")
            }
            module.callJNI_OnLoad(emulator)
            loaded[name] = digest
        }
    }

    @Synchronized
    fun invoke(owner: String, signature: String, receiver: Any?, arguments: Array<Any?>): Any? {
        check(!closed && !failed) { "Android JNI guest unavailable" }
        val descriptor = signature.substring(signature.indexOf('('))
        val parameterTypes = Type.getArgumentTypes(descriptor)
        val returns = Type.getReturnType(descriptor).descriptor
        require(returns in SUPPORTED || returns == "V") { "Unsupported Android JNI return type $returns" }
        require(parameterTypes.size == arguments.size) { "Android JNI argument count mismatch" }
        val bytes = IdentityHashMap<ByteArray, GuestBytes>()
        val args = Array<Any>(parameterTypes.size) { index ->
            val value = arguments[index]
            when (val type = parameterTypes[index].descriptor) {
                "Z" -> if (value as Boolean) 1 else 0
                "C" -> (value as Char).code
                "B", "S", "I" -> (value as Number).toInt()
                "J" -> value as Long
                "Ljava/lang/String;" -> if (value == null) 0 else StringObject(vm, value as String)
                "[B" -> if (value == null) 0 else bytes.getOrPut(value as ByteArray) { GuestBytes(vm, value.copyOf()) }
                else -> throw UnsupportedOperationException("Unsupported Android JNI parameter type $type")
            }
        }
        val type = vm.resolveClass(owner.replace('.', '/'))
        val instance = receiver?.let {
            receivers.getOrPut(it) {
                check(receivers.size < 256) { "Android JNI receiver limit reached" }
                type.newObject(null)
            }
        }
        return runGuest {
            val result: Any? = when (returns) {
                "V" -> {
                    if (instance == null) type.callStaticJniMethod(emulator, signature, *args) else instance.callJniMethod(emulator, signature, *args)
                    null
                }
                "J" -> if (instance == null) type.callStaticJniMethodLong(emulator, signature, *args) else instance.callJniMethodLong(emulator, signature, *args)
                "Ljava/lang/String;", "[B" -> {
                    val returned: DvmObject<*>? = if (instance == null) type.callStaticJniMethodObject(emulator, signature, *args) else instance.callJniMethodObject(emulator, signature, *args)
                    when {
                        returned == null -> null
                        returns == "[B" && returned is GuestBytes -> bytes.entries.firstOrNull { it.value === returned }?.key ?: returned.value.copyOf()
                        returns == "Ljava/lang/String;" && returned is StringObject -> returned.value
                        else -> throw IllegalStateException("Android JNI returned an unexpected type for $returns")
                    }
                }
                else -> {
                    val value = if (instance == null) type.callStaticJniMethodInt(emulator, signature, *args) else instance.callJniMethodInt(emulator, signature, *args)
                    when (returns) {
                        "B" -> value.toByte()
                        "S" -> value.toShort()
                        "C" -> value.toChar()
                        "Z" -> value != 0
                        else -> value
                    }
                }
            }
            bytes.forEach { (original, guest) -> guest.value.copyInto(original) }
            result
        }
    }

    private fun expired() = deadline != 0L && System.nanoTime() - deadline >= 0

    private fun <T> runGuest(call: () -> T): T {
        deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        try {
            return call().also { check(!expired()) { "Android JNI guest timed out" } }
        } catch (problem: Throwable) {
            failed = true
            if (expired()) throw IllegalStateException("Android JNI guest timed out", problem)
            throw problem
        } finally {
            deadline = 0L
        }
    }

    @Synchronized
    override fun close() {
        if (!closed) {
            closed = true
            receivers.clear()
            emulator.close()
        }
    }

    private companion object {
        const val JNI_EXCEPTION_CHECK_SLOT = 228L
        val LIBRARY_NAME = Regex("[a-zA-Z0-9_+.-]+\\.so")
        val SUPPORTED = setOf("Z", "B", "S", "C", "I", "J", "Ljava/lang/String;", "[B")
        val ARM32_MEMORY_TIME_IDS = setOf(20, 24, 45, 47, 49, 50, 78, 91, 125, 192, 199, 200, 201, 202, 224, 263)
        val ARM64_MEMORY_TIME_IDS = setOf(113, 169, 172, 174, 175, 176, 177, 178, 214, 215, 222, 226)

        fun emulator(is64Bit: Boolean, root: File): AndroidEmulator {
            var allocated: Backend? = null
            val factory = object : Unicorn2Factory(false) {
                override fun newBackendInternal(emulator: Emulator<*>, is64Bit: Boolean): Backend =
                    super.newBackendInternal(emulator, is64Bit).also { allocated = it }
            }
            try {
                return createEmulator(is64Bit, root, listOf(factory))
            } catch (problem: Throwable) {
                runCatching { allocated?.destroy() }.exceptionOrNull()?.let(problem::addSuppressed)
                throw problem
            }
        }

        fun createEmulator(is64Bit: Boolean, root: File, engines: List<Unicorn2Factory>): AndroidEmulator {
            return if (is64Bit) object : AndroidARM64Emulator("yingzhou.spider", root, engines) {
                override fun createFileSystem(rootDir: File) = GuestFiles(rootDir)
                override fun createConsoleDebugger(): Nothing = error("Android JNI guest fault")
                override fun eFunc(begin: Long, vararg arguments: Number) = checkedCall(this, begin, arguments) { address, values -> super.eFunc(address, *values) }
                override fun createSyscallHandler(svcMemory: SvcMemory) = object : ARM64SyscallHandler(svcMemory) {
                    override fun handleSyscall(emulator: Emulator<*>, number: Int): Boolean = denyUnless(emulator, number, ARM64_MEMORY_TIME_IDS, Arm64Const.UC_ARM64_REG_X0)
                    override fun hook(backend: Backend, intno: Int, swi: Int, user: Any?) {
                        if (intno == ARMEmulator.EXCP_SWI) super.hook(backend, intno, swi, user) else backend.emu_stop()
                    }
                }
            } else object : AndroidARMEmulator("yingzhou.spider", root, engines) {
                override fun createFileSystem(rootDir: File) = GuestFiles(rootDir)
                override fun createConsoleDebugger(): Nothing = error("Android JNI guest fault")
                override fun eFunc(begin: Long, vararg arguments: Number) = checkedCall(this, begin, arguments) { address, values -> super.eFunc(address, *values) }
                override fun createSyscallHandler(svcMemory: SvcMemory) = object : ARM32SyscallHandler(svcMemory) {
                    override fun handleSyscall(emulator: Emulator<*>, number: Int): Boolean = denyUnless(emulator, number, ARM32_MEMORY_TIME_IDS, ArmConst.UC_ARM_REG_R0)
                    override fun hook(backend: Backend, intno: Int, swi: Int, user: Any?) {
                        if (intno == ARMEmulator.EXCP_SWI) super.hook(backend, intno, swi, user) else backend.emu_stop()
                    }
                }
            }
        }

        inline fun checkedCall(emulator: AndroidEmulator, begin: Long, arguments: Array<out Number>, invoke: (Long, Array<out Number>) -> Number): Number {
            val environment = emulator.dalvikVM?.jniEnv as UnidbgPointer?
            val exceptionCheck = environment?.let {
                checkNotNull(it.getPointer(0)?.getPointer(JNI_EXCEPTION_CHECK_SLOT * emulator.pointerSize)) { "Android JNI exception check unavailable" }
            }
            val result = invoke(begin, arguments)
            verifyReturn(emulator)
            if (exceptionCheck != null) {
                val address: Number = if (emulator.is64Bit) environment.peer else environment.peer.toInt()
                val pending = invoke(exceptionCheck.peer, arrayOf(address)).toInt()
                verifyReturn(emulator)
                check(pending == 0) { "Android JNI guest left a Java exception pending" }
            }
            return result
        }

        fun verifyReturn(emulator: AndroidEmulator) {
            val pc = if (emulator.is64Bit) emulator.backend.reg_read(Arm64Const.UC_ARM64_REG_PC).toLong()
            else emulator.backend.reg_read(ArmConst.UC_ARM_REG_PC).toLong() and 0xffffffffL
            check(pc == emulator.returnAddress) { "Android JNI guest stopped before returning" }
        }

        fun denyUnless(emulator: Emulator<*>, number: Int, allowed: Set<Int>, resultRegister: Int): Boolean {
            if (number in allowed) return false
            emulator.backend.reg_write(resultRegister, -UnixEmulator.EACCES)
            return true
        }
    }

    private class GuestFiles(private val root: File) : FileSystem<AndroidFileIO> {
        override fun getRootDir() = root
        override fun createWorkDir() = root
        override fun open(pathname: String, oflags: Int): FileResult<AndroidFileIO> = FileResult.failed(UnixEmulator.EACCES)
        override fun mkdir(path: String, mode: Int) = false
        override fun rename(oldPath: String, newPath: String) = -1
        override fun unlink(path: String): Unit = throw UnsupportedOperationException("Guest files are read-only")
        override fun rmdir(path: String): Unit = throw UnsupportedOperationException("Guest files are read-only")
        override fun createSimpleFileIO(file: File, oflags: Int, path: String): AndroidFileIO = throw UnsupportedOperationException("Host files are unavailable")
        override fun createDirectoryFileIO(file: File, oflags: Int, path: String): AndroidFileIO = throw UnsupportedOperationException("Host files are unavailable")
    }
}
