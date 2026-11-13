package android.util;

/** A 1080p TV-like screen. */
public class DisplayMetrics {
    public static final int DENSITY_DEFAULT = 160;
    public static final int DENSITY_XHIGH = 320;

    public int widthPixels = 1920;
    public int heightPixels = 1080;
    public float density = 1f;
    public int densityDpi = DENSITY_DEFAULT;
    public float scaledDensity = 1f;
    public float xdpi = 160f;
    public float ydpi = 160f;

    public void setTo(DisplayMetrics o) {
        widthPixels = o.widthPixels;
        heightPixels = o.heightPixels;
        density = o.density;
        densityDpi = o.densityDpi;
        scaledDensity = o.scaledDensity;
        xdpi = o.xdpi;
        ydpi = o.ydpi;
    }

    public void setToDefaults() {
        setTo(new DisplayMetrics());
    }
}
