package android.content.res;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Enumeration;
import java.util.TreeSet;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public class AssetManager {
    public static final int ACCESS_UNKNOWN = 0;
    public static final int ACCESS_RANDOM = 1;
    public static final int ACCESS_STREAMING = 2;
    public static final int ACCESS_BUFFER = 3;

    private final File archive;

    public AssetManager() { this(null); }

    public AssetManager(File archive) { this.archive = archive; }

    public InputStream open(String name) throws IOException {
        String path = assetPath(name);
        if (archive == null) {
            InputStream stream = AssetManager.class.getClassLoader().getResourceAsStream(path);
            if (stream == null) throw new FileNotFoundException(name);
            return stream;
        }
        ZipFile zip = new ZipFile(archive);
        try {
            ZipEntry entry = zip.getEntry(path);
            if (entry == null || entry.isDirectory()) throw new FileNotFoundException(name);
            return new FilterInputStream(zip.getInputStream(entry)) {
                @Override public void close() throws IOException {
                    try { super.close(); } finally { zip.close(); }
                }
            };
        } catch (IOException | RuntimeException failure) {
            zip.close();
            throw failure;
        }
    }

    public InputStream open(String fileName, int accessMode) throws IOException { return open(fileName); }

    public String[] list(String path) throws IOException {
        String prefix = assetPath(path);
        if (!prefix.endsWith("/")) prefix += "/";
        if (archive == null) return new String[0];
        TreeSet<String> children = new TreeSet<>();
        try (ZipFile zip = new ZipFile(archive)) {
            Enumeration<? extends ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements()) {
                String name = entries.nextElement().getName();
                if (!name.startsWith(prefix) || name.length() == prefix.length()) continue;
                int slash = name.indexOf('/', prefix.length());
                String child = name.substring(prefix.length(), slash < 0 ? name.length() : slash);
                if (!child.isEmpty() && !child.equals(".") && !child.equals("..")) children.add(child);
            }
        }
        return children.toArray(new String[0]);
    }

    private static String assetPath(String name) throws FileNotFoundException {
        if (name == null || name.startsWith("/") || name.indexOf('\\') >= 0 || name.indexOf('\0') >= 0) {
            throw new FileNotFoundException(name);
        }
        for (String part : name.split("/")) {
            if (part.equals(".") || part.equals("..")) throw new FileNotFoundException(name);
        }
        return "assets/" + name;
    }

    public void close() { }
}
