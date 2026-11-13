package com.github.catvod.spider;

import android.content.Context;

public class Init {
    public static volatile boolean initialized;

    public static void init(Context context) {
        initialized = context != null;
    }
}
