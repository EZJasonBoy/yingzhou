package android.content.res;

import java.util.Locale;

/** A landscape TV. */
public class Configuration {
    public static final int ORIENTATION_UNDEFINED = 0;
    public static final int ORIENTATION_PORTRAIT = 1;
    public static final int ORIENTATION_LANDSCAPE = 2;
    public static final int UI_MODE_TYPE_MASK = 0x0f;
    public static final int UI_MODE_TYPE_NORMAL = 1;
    public static final int UI_MODE_TYPE_TELEVISION = 4;
    public static final int UI_MODE_NIGHT_MASK = 0x30;
    public static final int UI_MODE_NIGHT_NO = 0x10;
    public static final int UI_MODE_NIGHT_YES = 0x20;
    public static final int SCREENLAYOUT_SIZE_MASK = 0x0f;
    public static final int SCREENLAYOUT_SIZE_XLARGE = 4;

    public int orientation = ORIENTATION_LANDSCAPE;
    public int uiMode = UI_MODE_TYPE_TELEVISION | UI_MODE_NIGHT_YES;
    public int screenLayout = SCREENLAYOUT_SIZE_XLARGE;
    public int screenWidthDp = 1920;
    public int screenHeightDp = 1080;
    public int smallestScreenWidthDp = 1080;
    public int densityDpi = 160;
    public float fontScale = 1f;
    public Locale locale = Locale.SIMPLIFIED_CHINESE;

    public Locale getLocales() {
        return locale;
    }
}
