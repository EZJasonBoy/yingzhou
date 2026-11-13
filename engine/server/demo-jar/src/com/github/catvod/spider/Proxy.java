package com.github.catvod.spider;

import java.io.ByteArrayInputStream;
import java.util.Map;

/** Answers /proxy?do=demo&x=... so the host's proxy routing can be checked. */
public class Proxy {
    public static Object[] proxy(Map<String, String> params) {
        if (!"demo".equals(params.get("do"))) return null;
        byte[] body = ("jar proxy ok " + params.get("x")).getBytes();
        return new Object[]{200, "text/plain; charset=utf-8", new ByteArrayInputStream(body)};
    }
}
