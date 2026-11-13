package android.util;

import java.io.PrintWriter;
import java.io.StringWriter;

/** Spider logs go to stderr, tagged; verbose/debug are dropped unless -Dtvbox.spider.debug=true. */
public final class Log {
    public static final int VERBOSE = 2;
    public static final int DEBUG = 3;
    public static final int INFO = 4;
    public static final int WARN = 5;
    public static final int ERROR = 6;
    public static final int ASSERT = 7;

    private static final boolean DEBUG_ON = Boolean.getBoolean("tvbox.spider.debug");

    private Log() {
    }

    private static int print(int level, String tag, String msg, Throwable tr) {
        if (level < INFO && !DEBUG_ON) return 0;
        String text = "spider/" + "VDIWEA".charAt(Math.max(0, Math.min(5, level - 2))) + " " + tag + ": " + msg;
        if (tr != null) text += "\n" + getStackTraceString(tr);
        System.err.println(text);
        return text.length();
    }

    public static int v(String tag, String msg) { return print(VERBOSE, tag, msg, null); }

    public static int v(String tag, String msg, Throwable tr) { return print(VERBOSE, tag, msg, tr); }

    public static int d(String tag, String msg) { return print(DEBUG, tag, msg, null); }

    public static int d(String tag, String msg, Throwable tr) { return print(DEBUG, tag, msg, tr); }

    public static int i(String tag, String msg) { return print(INFO, tag, msg, null); }

    public static int i(String tag, String msg, Throwable tr) { return print(INFO, tag, msg, tr); }

    public static int w(String tag, String msg) { return print(WARN, tag, msg, null); }

    public static int w(String tag, String msg, Throwable tr) { return print(WARN, tag, msg, tr); }

    public static int w(String tag, Throwable tr) { return print(WARN, tag, "", tr); }

    public static int e(String tag, String msg) { return print(ERROR, tag, msg, null); }

    public static int e(String tag, String msg, Throwable tr) { return print(ERROR, tag, msg, tr); }

    public static int wtf(String tag, String msg) { return print(ASSERT, tag, msg, null); }

    public static int wtf(String tag, Throwable tr) { return print(ASSERT, tag, "", tr); }

    public static int wtf(String tag, String msg, Throwable tr) { return print(ASSERT, tag, msg, tr); }

    public static int println(int priority, String tag, String msg) { return print(priority, tag, msg, null); }

    public static boolean isLoggable(String tag, int level) { return level >= INFO || DEBUG_ON; }

    public static String getStackTraceString(Throwable tr) {
        if (tr == null) return "";
        StringWriter sw = new StringWriter();
        tr.printStackTrace(new PrintWriter(sw));
        return sw.toString();
    }
}
