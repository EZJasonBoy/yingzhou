import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.IincInsnNode;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.LookupSwitchInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TableSwitchInsnNode;
import org.objectweb.asm.tree.TryCatchBlockNode;
import org.objectweb.asm.tree.VarInsnNode;

final class MonitorRegions {
    private static final Set<Integer> NONTHROWING = Set.of(Opcodes.ICONST_0, Opcodes.ISTORE, Opcodes.ASTORE,
        Opcodes.ILOAD, Opcodes.ALOAD, Opcodes.IF_ICMPGE, Opcodes.IFLE, Opcodes.GOTO, Opcodes.IINC);

    static byte[] repair(byte[] original) {
        var parsed = new ClassNode();
        new ClassReader(original).accept(parsed, 0);
        var methods = parsed.methods.stream().filter(method -> method.name.equals("k")
            && method.desc.startsWith("(Ljava/lang/String;Ljava/lang/String;)")).toList();
        require(methods.size() == 1);
        merge(methods.get(0));
        var writer = new ClassWriter(0);
        parsed.accept(writer);
        return writer.toByteArray();
    }

    static byte[] repairStackTrace(byte[] original) {
        var parsed = new ClassNode();
        new ClassReader(original).accept(parsed, 0);
        var methods = parsed.methods.stream().filter(method -> method.name.equals("fillInStackTrace")
            && method.desc.equals("()Ljava/lang/Throwable;")).toList();
        require(methods.size() == 1);
        mergeStackTrace(methods.get(0));
        var writer = new ClassWriter(0);
        parsed.accept(writer);
        return writer.toByteArray();
    }

    private static void mergeStackTrace(MethodNode method) {
        var instructions = method.instructions;
        var code = new ArrayList<AbstractInsnNode>();
        var targets = new HashSet<AbstractInsnNode>();
        for (var instruction : instructions) {
            require(!(instruction instanceof LookupSwitchInsnNode || instruction instanceof TableSwitchInsnNode));
            if (instruction.getOpcode() >= 0) code.add(instruction);
            if (instruction instanceof JumpInsnNode jump) {
                AbstractInsnNode target = jump.label;
                while (target.getOpcode() < 0) target = target.getNext();
                targets.add(target);
            }
        }
        var enters = code.stream().filter(insn -> insn.getOpcode() == Opcodes.MONITORENTER).toList();
        var exits = code.stream().filter(insn -> insn.getOpcode() == Opcodes.MONITOREXIT).toList();
        var loads = code.stream().filter(insn -> insn.getOpcode() == Opcodes.AALOAD).toList();
        require(enters.size() == 1 && exits.size() == 2 && loads.size() == 1);
        int enter = code.indexOf(enters.get(0)), normalExit = code.indexOf(exits.get(0));
        require(enter == 3 && code.get(0) instanceof VarInsnNode receiver && receiver.getOpcode() == Opcodes.ALOAD && receiver.var == 0);
        require(code.get(1).getOpcode() == Opcodes.DUP && code.get(2) instanceof VarInsnNode lock && lock.getOpcode() == Opcodes.ASTORE);
        int lockSlot = ((VarInsnNode) code.get(2)).var;
        require(code.stream().filter(insn -> writesSlot(insn, lockSlot)).count() == 1);
        for (var exit : exits) {
            require(code.get(code.indexOf(exit) - 1) instanceof VarInsnNode lock && lock.getOpcode() == Opcodes.ALOAD && lock.var == lockSlot);
        }
        var regions = method.tryCatchBlocks;
        require(regions.size() == 4 && regions.stream().allMatch(region -> region.type == null && region.handler == regions.get(0).handler));
        var body = code.subList(enter + 1, normalExit);
        for (var current : body) {
            int position = instructions.indexOf(current);
            if (regions.stream().anyMatch(region -> instructions.indexOf(region.start) <= position && position < instructions.indexOf(region.end))) continue;
            require(NONTHROWING.contains(current.getOpcode()) || current == loads.get(0));
        }
        int load = code.indexOf(loads.get(0));
        var guard = code.subList(load - 10, load + 1);
        int[] opcodes = {Opcodes.ALOAD, Opcodes.ARRAYLENGTH, Opcodes.ISTORE, Opcodes.ICONST_0, Opcodes.ISTORE, Opcodes.ILOAD,
            Opcodes.ILOAD, Opcodes.IF_ICMPGE, Opcodes.ALOAD, Opcodes.ILOAD, Opcodes.AALOAD};
        for (int index = 0; index < opcodes.length; index++) {
            require(guard.get(index).getOpcode() == opcodes[index]);
            if (index != 5) require(!targets.contains(guard.get(index)));
        }
        int arraySlot = ((VarInsnNode) guard.get(0)).var;
        int lengthSlot = ((VarInsnNode) guard.get(2)).var;
        int indexSlot = ((VarInsnNode) guard.get(4)).var;
        require(arraySlot == ((VarInsnNode) guard.get(8)).var && lengthSlot == ((VarInsnNode) guard.get(6)).var);
        require(indexSlot == ((VarInsnNode) guard.get(5)).var && indexSlot == ((VarInsnNode) guard.get(9)).var);
        require(code.subList(load - 10, normalExit).stream().noneMatch(insn -> writesSlot(insn, arraySlot)));
        require(body.stream().filter(insn -> writesSlot(insn, lengthSlot)).count() == 1);
        var changes = body.stream().filter(insn -> writesSlot(insn, indexSlot)).toList();
        require(changes.size() == 2 && changes.get(0) == guard.get(4) && changes.get(1) instanceof IincInsnNode increment && increment.incr == 1);
        require(instructions.indexOf(((JumpInsnNode) guard.get(7)).label) > instructions.indexOf(changes.get(1)));
        var start = new LabelNode();
        var end = new LabelNode();
        instructions.insert(enters.get(0), start);
        instructions.insert(exits.get(0), end);
        var joined = new TryCatchBlockNode(start, end, regions.get(0).handler, null);
        regions.clear();
        regions.add(joined);
    }

    private static boolean writesSlot(AbstractInsnNode instruction, int slot) {
        return instruction instanceof VarInsnNode variable && variable.var == slot
            && variable.getOpcode() >= Opcodes.ISTORE && variable.getOpcode() <= Opcodes.ASTORE
            || instruction instanceof IincInsnNode increment && increment.var == slot;
    }

    private static void require(boolean matches) {
        if (!matches) throw new IllegalStateException("Unexpected synchronized block layout");
    }

    private static void merge(MethodNode method) {
        var instructions = method.instructions;
        var code = new ArrayList<AbstractInsnNode>();
        var branchTargets = new HashSet<AbstractInsnNode>();
        for (var instruction : instructions) {
            require(!(instruction instanceof LookupSwitchInsnNode || instruction instanceof TableSwitchInsnNode));
            if (instruction.getOpcode() >= 0) code.add(instruction);
            if (instruction instanceof JumpInsnNode jump) {
                AbstractInsnNode target = jump.label;
                while (target.getOpcode() < 0) target = target.getNext();
                branchTargets.add(target);
            }
        }
        var entries = code.stream().filter(insn -> insn.getOpcode() == Opcodes.MONITORENTER).toList();
        var exits = code.stream().filter(insn -> insn.getOpcode() == Opcodes.MONITOREXIT).toList();
        require(entries.size() == 1 && exits.size() == 2);
        var enter = entries.get(0);
        var firstExit = exits.get(0);
        var regions = method.tryCatchBlocks.stream().filter(block -> block.type == null
            && instructions.indexOf(block.start) < instructions.indexOf(firstExit)).toList();
        require(regions.size() == 6 && regions.stream().allMatch(block -> block.handler == regions.get(0).handler));
        var body = code.subList(code.indexOf(enter) + 1, code.indexOf(firstExit) + 1);
        var guardedLoads = new ArrayList<AbstractInsnNode>();
        for (var current : body) {
            int position = instructions.indexOf(current);
            if (regions.stream().anyMatch(block -> instructions.indexOf(block.start) <= position
                    && position < instructions.indexOf(block.end))) continue;
            if (current.getOpcode() == Opcodes.AALOAD) guardedLoads.add(current);
            else require(NONTHROWING.contains(current.getOpcode()));
        }
        require(guardedLoads.size() == 1);
        int loadPosition = code.indexOf(guardedLoads.get(0));
        var guard = code.subList(loadPosition - 6, loadPosition + 1);
        int[] opcodes = {Opcodes.ILOAD, Opcodes.ALOAD, Opcodes.ARRAYLENGTH, Opcodes.IF_ICMPGE, Opcodes.ALOAD, Opcodes.ILOAD, Opcodes.AALOAD};
        for (int index = 0; index < opcodes.length; index++) {
            require(guard.get(index).getOpcode() == opcodes[index]);
            if (index > 0) require(!branchTargets.contains(guard.get(index)));
        }
        int indexSlot = ((VarInsnNode) guard.get(0)).var;
        require(((VarInsnNode) guard.get(5)).var == indexSlot);
        require(((VarInsnNode) guard.get(1)).var == ((VarInsnNode) guard.get(4)).var);
        var initialized = code.get(loadPosition - 7);
        require(initialized.getOpcode() == Opcodes.ISTORE && ((VarInsnNode) initialized).var == indexSlot);
        require(code.get(loadPosition - 8).getOpcode() == Opcodes.ICONST_0);
        var mutations = body.stream().filter(insn -> (insn instanceof VarInsnNode variable
            && variable.var == indexSlot && variable.getOpcode() == Opcodes.ISTORE)
            || (insn instanceof IincInsnNode increment && increment.var == indexSlot)).toList();
        require(mutations.size() == 2 && mutations.get(0) == initialized && mutations.get(1) instanceof IincInsnNode increment && increment.incr == 1);
        require(instructions.indexOf(((JumpInsnNode) guard.get(3)).label) > instructions.indexOf(mutations.get(1)));
        var start = new LabelNode();
        instructions.insert(enter, start);
        var joined = new TryCatchBlockNode(start, regions.get(regions.size() - 1).end, regions.get(0).handler, null);
        int originalIndex = method.tryCatchBlocks.indexOf(regions.get(0));
        method.tryCatchBlocks.removeAll(regions);
        method.tryCatchBlocks.add(originalIndex, joined);
    }
}
