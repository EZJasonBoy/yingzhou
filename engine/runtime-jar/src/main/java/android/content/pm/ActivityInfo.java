package android.content.pm;

/** ActivityInfo stub（TVBox 蜘蛛极少真正使用，仅为 PackageInfo 字段类型完整性而存在）。 */
public class ActivityInfo {
    public static final int SCREEN_ORIENTATION_UNSPECIFIED = -1;
    public static final int SCREEN_ORIENTATION_LANDSCAPE = 0;
    public static final int SCREEN_ORIENTATION_PORTRAIT = 1;
    public static final int SCREEN_ORIENTATION_SENSOR = 4;
    public static final int SCREEN_ORIENTATION_SENSOR_LANDSCAPE = 6;
    public static final int SCREEN_ORIENTATION_SENSOR_PORTRAIT = 7;

    public String name = "";
    public String packageName = "com.github.tvbox.osc";
    public boolean enabled = true;
    public int flags = 0;
}
