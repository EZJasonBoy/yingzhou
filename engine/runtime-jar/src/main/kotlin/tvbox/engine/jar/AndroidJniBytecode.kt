package tvbox.engine.jar

import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import org.objectweb.asm.Type
import org.objectweb.asm.commons.GeneratorAdapter
import org.objectweb.asm.commons.Method

internal object AndroidJniBytecode {
    private val bridge = Type.getType(AndroidJniLoader::class.java)
    private val invoke = Method("invokeNative", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;")

    fun adapt(bytes: ByteArray): ByteArray {
        val reader = ClassReader(bytes)
        val owner = Type.getObjectType(reader.className)
        val writer = ClassWriter(reader, ClassWriter.COMPUTE_MAXS)
        var changed = false
        reader.accept(object : ClassVisitor(Opcodes.ASM9, writer) {
            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?, exceptions: Array<out String>?): MethodVisitor? {
                if (access and Opcodes.ACC_NATIVE != 0) {
                    changed = true
                    val flags = access and Opcodes.ACC_NATIVE.inv()
                    val target = super.visitMethod(flags, name, descriptor, signature, exceptions)
                    with(GeneratorAdapter(target, flags, name, descriptor)) {
                        visitCode()
                        push(owner)
                        push(name + descriptor)
                        if (access and Opcodes.ACC_STATIC != 0) visitInsn(Opcodes.ACONST_NULL) else loadThis()
                        loadArgArray()
                        invokeStatic(bridge, invoke)
                        if (returnType == Type.VOID_TYPE) pop() else unbox(returnType)
                        returnValue()
                        endMethod()
                    }
                    return null
                }
                return object : MethodVisitor(Opcodes.ASM9, super.visitMethod(access, name, descriptor, signature, exceptions)) {
                    override fun visitFieldInsn(opcode: Int, target: String, field: String, desc: String) {
                        if (opcode == Opcodes.GETSTATIC && target == "android/os/Build" && field in abiFields &&
                            (desc == "Ljava/lang/String;" || desc == "[Ljava/lang/String;")) {
                            changed = true
                            visitLdcInsn(owner)
                            visitLdcInsn(field)
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, bridge.internalName, "abiField", "(Ljava/lang/Class;Ljava/lang/String;)Ljava/lang/Object;", false)
                            visitTypeInsn(Opcodes.CHECKCAST, Type.getType(desc).internalName)
                        } else super.visitFieldInsn(opcode, target, field, desc)
                    }

                    override fun visitMethodInsn(opcode: Int, target: String, method: String, desc: String, isInterface: Boolean) {
                        if (opcode == Opcodes.INVOKESTATIC && target == "java/lang/System" && desc == "(Ljava/lang/String;)V" && method in loadMethods) {
                            changed = true
                            visitLdcInsn(owner)
                            super.visitMethodInsn(opcode, bridge.internalName, method, "(Ljava/lang/String;Ljava/lang/Class;)V", false)
                        } else super.visitMethodInsn(opcode, target, method, desc, isInterface)
                    }
                }
            }
        }, 0)
        return if (changed) writer.toByteArray() else bytes
    }

    private val loadMethods = setOf("load", "loadLibrary")
    private val abiFields = setOf("CPU_ABI", "CPU_ABI2", "SUPPORTED_ABIS", "SUPPORTED_64_BIT_ABIS", "SUPPORTED_32_BIT_ABIS")
}
