package android.content.res;

/** Resources stub: spiders read getString/getIdentifier/configuration; the desktop returns neutral values. */
public class Resources {
    private static final Resources SYSTEM = new Resources();
    private final Configuration configuration = new Configuration();
    private final AssetManager assets;

    public Resources() { this(new AssetManager()); }
    public Resources(AssetManager assets) { this.assets = assets; }
    public static Resources getSystem() { return SYSTEM; }
    public String getString(int id) { return ""; }
    public String getString(int id, Object... formatArgs) { return ""; }
    public int getIdentifier(String name, String defType, String defPackage) { return 0; }
    public android.util.DisplayMetrics getDisplayMetrics() { return new android.util.DisplayMetrics(); }
    public Configuration getConfiguration() { return configuration; }
    public AssetManager getAssets() { return assets; }
}
