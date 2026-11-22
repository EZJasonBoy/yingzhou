package tvbox.fixture;

public final class NativeMath {
    public static native int add(int left, int right);
    public static native double unsupported();

    public static void load(String path) { System.load(path); }
    public static void loadLibrary(String name) { System.loadLibrary(name); }
    public static String abi() { return android.os.Build.SUPPORTED_ABIS[0]; }
}
