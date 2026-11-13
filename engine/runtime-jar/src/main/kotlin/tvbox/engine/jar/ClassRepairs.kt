package tvbox.engine.jar

import com.googlecode.d2j.Method
import com.googlecode.d2j.reader.BaseDexFileReader
import com.googlecode.d2j.reader.DexFileReader
import com.googlecode.d2j.reader.Op
import com.googlecode.d2j.visitors.DexClassVisitor
import com.googlecode.d2j.visitors.DexCodeVisitor
import com.googlecode.d2j.visitors.DexFileVisitor
import com.googlecode.d2j.visitors.DexMethodVisitor
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.FieldVisitor
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import org.objectweb.asm.Type
import org.objectweb.asm.commons.ClassRemapper
import org.objectweb.asm.commons.Remapper
import org.objectweb.asm.tree.ClassNode
import org.objectweb.asm.tree.InsnNode
import org.objectweb.asm.tree.MethodInsnNode
import org.objectweb.asm.tree.MethodNode
import org.objectweb.asm.tree.TypeInsnNode
import org.objectweb.asm.tree.VarInsnNode
import java.util.TreeSet

/**
 * `new-instance` sites read straight from the dex: which class each `new` creates and whose constructor initialises
 * it. R8 drops trivial constructors, so the dex often says `new-instance X; invoke-direct Y.<init>` with Y an
 * ancestor of X, which dex2jar mistranslates (see [ClassRepairs]).
 */
class DexUnits {
    data class Unit(val type: String, val initOwner: String, val initDesc: String)

    /** "owner.name desc" (internal names) to the method's units, only for methods with a mismatched unit. */
    val byMethod = HashMap<String, List<Unit>>()

    fun scan(reader: BaseDexFileReader) {
        reader.accept(object : DexFileVisitor() {
            override fun visit(access: Int, className: String, superClass: String?, interfaces: Array<out String>?) =
                object : DexClassVisitor() {
                    override fun visitMethod(access: Int, method: Method) = object : DexMethodVisitor() {
                        override fun visitCode() = object : DexCodeVisitor() {
                            private val pending = HashMap<Int, String>()
                            private val units = ArrayList<Unit>()

                            override fun visitTypeStmt(op: Op, a: Int, b: Int, type: String) {
                                if (op == Op.NEW_INSTANCE) pending[a] = type
                            }

                            override fun visitMethodStmt(op: Op, args: IntArray, m: Method) {
                                if ((op == Op.INVOKE_DIRECT || op == Op.INVOKE_DIRECT_RANGE) && m.name == "<init>" && args.isNotEmpty()) {
                                    val type = pending.remove(args[0]) ?: return
                                    units += Unit(internal(type), internal(m.owner), m.desc)
                                }
                            }

                            override fun visitEnd() {
                                if (units.any { it.type != it.initOwner }) {
                                    synchronized(byMethod) { byMethod[key(internal(method.owner), method.name, method.desc)] = units }
                                }
                            }
                        }
                    }
                }
        }, DexFileReader.SKIP_DEBUG or DexFileReader.SKIP_ANNOTATION or DexFileReader.SKIP_FIELD_CONSTANT)
    }

    companion object {
        fun key(owner: String, name: String, desc: String) = "$owner.$name $desc"
        fun internal(descriptor: String) =
            if (descriptor.startsWith("L") && descriptor.endsWith(";")) descriptor.substring(1, descriptor.length - 1) else descriptor
    }
}

/**
 * Fixes for dex2jar output, learned from Win-box (MIT, `classFix.ts` and `DexJarRepair.java`):
 *
 * 1. `super.m()` (dex `invoke-super`) whose method ref names the current class comes out as
 *    `invokespecial <this class>.m`, which the JVM resolves to the method itself: infinite recursion. The owner is
 *    moved to the superclass, which is what javac emits.
 * 2. For `new-instance X; invoke-direct Y.<init>(…)` (Y an ancestor of X, X without that constructor), dex2jar
 *    emits `NEW Y`, creating an object of the wrong class (InstantiationError for abstract Y, crashes later
 *    otherwise). The `NEW` and the constructor call are moved back to X, and X (plus any class between X and Y)
 *    gets a synthetic constructor that delegates up the chain.
 */
object ClassRepairs {
    class Report {
        var superCalls = 0
        var newSites = 0
        var constructors = 0
        fun any() = superCalls + newSites + constructors > 0
        override fun toString() = "super calls $superCalls, new sites $newSites, synthetic constructors $constructors"
    }

    fun repair(classes: MutableMap<String, ByteArray>, units: DexUnits): Report {
        val report = Report()
        val nodes = HashMap<String, ClassNode>()
        val modified = LinkedHashSet<String>()
        fun node(name: String): ClassNode? = nodes[name] ?: classes[name]?.let { bytes ->
            ClassNode().also { ClassReader(bytes).accept(it, 0); nodes[name] = it }
        }

        for (name in classes.keys) {
            if (!hasSelfSuperCall(classes.getValue(name))) continue
            val cn = node(name) ?: continue
            val fixed = fixSuperCalls(cn)
            if (fixed > 0) {
                report.superCalls += fixed
                modified += name
            }
        }

        for ((key, dexUnits) in units.byMethod) {
            val owner = key.substringBefore('.')
            val cn = node(owner) ?: continue
            val nameDesc = key.substringAfter('.')
            val mn = cn.methods.firstOrNull { "${it.name} ${it.desc}" == nameDesc } ?: continue
            val byInit = dexUnits.groupBy({ it.initOwner to it.initDesc }, { it.type }).mapValues { it.value.toSet() }
            for ((newInsn, initInsn) in newSites(mn)) {
                val types = byInit[newInsn.desc to initInsn.desc] ?: continue
                // Ambiguous: the same constructor initialises different classes in this method.
                if (types.size != 1) continue
                val real = types.single()
                if (real == newInsn.desc) continue
                val chain = superChain(real, newInsn.desc, ::node) ?: continue
                for (cls in chain) {
                    val c = node(cls)!!
                    if (ensureConstructor(c, initInsn.desc)) {
                        report.constructors++
                        modified += cls
                    }
                }
                newInsn.desc = real
                initInsn.owner = real
                report.newSites++
                modified += owner
            }
        }

        for (name in modified) {
            val writer = ClassWriter(0)
            nodes.getValue(name).accept(writer)
            classes[name] = writer.toByteArray()
        }
        return report
    }

    /** Cheap pre-check: does any method call `invokespecial <this>.m` (not `<init>`)? */
    private fun hasSelfSuperCall(bytes: ByteArray): Boolean {
        var self = ""
        var found = false
        ClassReader(bytes).accept(object : ClassVisitor(Opcodes.ASM9) {
            override fun visit(version: Int, access: Int, name: String, signature: String?, superName: String?, interfaces: Array<out String>?) {
                self = name
            }

            override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?): MethodVisitor? {
                if (found) return null
                return object : MethodVisitor(Opcodes.ASM9) {
                    override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                        if (opcode == Opcodes.INVOKESPECIAL && owner == self && name != "<init>") found = true
                    }
                }
            }
        }, ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES)
        return found
    }

    private fun fixSuperCalls(cn: ClassNode): Int {
        val superName = cn.superName ?: return 0
        val declared = cn.methods
            .filter { it.access and (Opcodes.ACC_PRIVATE or Opcodes.ACC_STATIC) == 0 && it.name != "<init>" && it.name != "<clinit>" }
            .map { it.name + it.desc }
            .toSet()
        var fixed = 0
        for (m in cn.methods) {
            for (insn in m.instructions) {
                if (insn is MethodInsnNode && insn.opcode == Opcodes.INVOKESPECIAL && insn.owner == cn.name && (insn.name + insn.desc) in declared) {
                    insn.owner = superName
                    fixed++
                }
            }
        }
        return fixed
    }

    /** Pairs every `NEW T` with the `invokespecial T.<init>` that initialises it (they nest). */
    private fun newSites(mn: MethodNode): List<Pair<TypeInsnNode, MethodInsnNode>> {
        val open = HashMap<String, ArrayDeque<TypeInsnNode>>()
        val sites = ArrayList<Pair<TypeInsnNode, MethodInsnNode>>()
        for (insn in mn.instructions) {
            if (insn is TypeInsnNode && insn.opcode == Opcodes.NEW) {
                open.getOrPut(insn.desc) { ArrayDeque() }.addLast(insn)
            } else if (insn is MethodInsnNode && insn.opcode == Opcodes.INVOKESPECIAL && insn.name == "<init>") {
                val pending = open[insn.owner]
                if (!pending.isNullOrEmpty()) sites += pending.removeLast() to insn
            }
        }
        return sites
    }

    /** Classes from [from] up to (not including) its ancestor [to], or null when the chain leaves the jar. */
    private fun superChain(from: String, to: String, node: (String) -> ClassNode?): List<String>? {
        val chain = ArrayList<String>()
        var c = from
        while (c != to) {
            if (chain.size > 32) return null
            val cn = node(c) ?: return null
            if (cn.access and (Opcodes.ACC_INTERFACE or Opcodes.ACC_ABSTRACT) != 0 && c == from) return null
            chain += c
            c = cn.superName ?: return null
        }
        return chain
    }

    /** Adds `<init>(desc)` delegating to the superclass's, unless the class has one. Returns true when added. */
    private fun ensureConstructor(cn: ClassNode, desc: String): Boolean {
        if (cn.methods.any { it.name == "<init>" && it.desc == desc }) return false
        val mn = MethodNode(Opcodes.ACC_PUBLIC or Opcodes.ACC_SYNTHETIC, "<init>", desc, null, null)
        mn.instructions.add(VarInsnNode(Opcodes.ALOAD, 0))
        var slot = 1
        for (arg in Type.getArgumentTypes(desc)) {
            mn.instructions.add(VarInsnNode(arg.getOpcode(Opcodes.ILOAD), slot))
            slot += arg.size
        }
        mn.instructions.add(MethodInsnNode(Opcodes.INVOKESPECIAL, cn.superName, "<init>", desc, false))
        mn.instructions.add(InsnNode(Opcodes.RETURN))
        mn.maxStack = slot
        mn.maxLocals = slot
        cn.methods.add(mn)
        return true
    }

    /** Android classes the jar refers to that neither the jar nor [host] provides. */
    fun missingAndroidClasses(classes: Map<String, ByteArray>, host: ClassLoader): List<String> {
        val refs = TreeSet<String>()
        val collector = object : Remapper(Opcodes.ASM9) {
            override fun map(internalName: String): String {
                if (internalName.startsWith("android/") || internalName.startsWith("androidx/") || internalName.startsWith("dalvik/")) {
                    refs += internalName
                }
                return internalName
            }
        }
        val sink = object : ClassVisitor(Opcodes.ASM9) {
            override fun visitMethod(access: Int, name: String?, descriptor: String?, signature: String?, exceptions: Array<out String>?) =
                object : MethodVisitor(Opcodes.ASM9) {}

            override fun visitField(access: Int, name: String?, descriptor: String?, signature: String?, value: Any?) =
                object : FieldVisitor(Opcodes.ASM9) {}
        }
        for (bytes in classes.values) {
            runCatching { ClassReader(bytes).accept(ClassRemapper(sink, collector), ClassReader.SKIP_FRAMES) }
        }
        return refs.filter { it !in classes && host.getResource("$it.class") == null }.map { it.replace('/', '.') }
    }
}
