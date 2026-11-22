import com.googlecode.d2j.Method;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.dex.DexExceptionHandler;
import com.googlecode.d2j.node.DexMethodNode;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;
import org.objectweb.asm.MethodVisitor;
import tvbox.engine.jar.ClassRepairs;
import tvbox.engine.jar.DexUnits;

public final class TranslateSpider {
    private static final String ANDROID_HELPER = "com/github/catvod/spider/GoProxy";
    private static final String MONITOR_OWNER = "com/github/catvod/spider/merge/o/b";
    private static final String TRACE_OWNER = "com/github/catvod/spider/merge/J/d";

    public static void main(String[] args) throws Exception {
        Path work = Path.of(args[1]);
        try (var original = new ZipFile(args[0])) {
            var dexFiles = original.stream().filter(entry -> entry.getName().matches("classes[0-9]*\\.dex")).toList();
            if (dexFiles.size() != 1 || !dexFiles.get(0).getName().equals("classes.dex")) {
                throw new IllegalArgumentException("Expected a single classes.dex in the pinned spider");
            }
            var dex = Dex2jar.from(original.getInputStream(dexFiles.get(0)).readAllBytes());
            var units = new DexUnits();
            units.scan(dex.getReader());
            Path translated = work.resolve("translated.jar");
            dex.skipDebug(false).dontSanitizeNames(true).topoLogicalSort(true).optimizeSynchronized(true)
                .withExceptionHandler(new DexExceptionHandler() {
                    @Override public void handleFileException(Exception failure) {
                        throw new IllegalStateException("Could not translate DEX", failure);
                    }
                    @Override public void handleMethodTranslateException(Method method, DexMethodNode source, MethodVisitor output, Exception failure) {
                        throw new IllegalStateException("Could not translate " + method, failure);
                    }
                }).to(translated);
            var classes = new LinkedHashMap<String, byte[]>();
            try (var entries = new ZipInputStream(Files.newInputStream(translated))) {
                for (var entry = entries.getNextEntry(); entry != null; entry = entries.getNextEntry()) {
                    String name = entry.getName();
                    if (name.endsWith(".class")) classes.put(name.substring(0, name.length() - 6), entries.readAllBytes());
                }
            }
            ClassRepairs.INSTANCE.repair(classes, units);
            if (classes.remove(ANDROID_HELPER) == null || !classes.containsKey(MONITOR_OWNER) || !classes.containsKey(TRACE_OWNER)) {
                throw new IllegalStateException("Pinned platform-specific class layout did not match");
            }
            classes.put(MONITOR_OWNER, MonitorRegions.repair(classes.get(MONITOR_OWNER)));
            classes.put(TRACE_OWNER, MonitorRegions.repairStackTrace(classes.get(TRACE_OWNER)));
            try (var output = new ZipOutputStream(Files.newOutputStream(work.resolve("desktop.jar")))) {
                var entries = original.entries();
                while (entries.hasMoreElements()) {
                    var entry = entries.nextElement();
                    if (entry.getName().equals("classes.dex")) continue;
                    output.putNextEntry(new ZipEntry(entry.getName()));
                    try (var bytes = original.getInputStream(entry)) {
                        bytes.transferTo(output);
                    }
                    output.closeEntry();
                }
                for (var entry : classes.entrySet()) {
                    output.putNextEntry(new ZipEntry(entry.getKey() + ".class"));
                    output.write(entry.getValue());
                    output.closeEntry();
                }
            }
            System.out.println("Prepared " + classes.size() + " classes for the Windows runtime");
        }
    }
}
