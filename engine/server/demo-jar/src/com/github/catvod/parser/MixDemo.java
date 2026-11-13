package com.github.catvod.parser;

import com.github.catvod.net.OkHttp;

import org.json.JSONObject;

import java.net.URLEncoder;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * A minimal "Json聚合" parser (TVBox parse type 3, url "Demo"): asks each JSON parser in turn and returns the first
 * url, naming the parser in jxFrom, the way real Mix parsers in spider jars answer.
 */
public class MixDemo {
    public static JSONObject parse(LinkedHashMap<String, HashMap<String, String>> jx, String nameMe, String flag, String url) {
        try {
            for (Map.Entry<String, HashMap<String, String>> e : jx.entrySet()) {
                if (!"1".equals(e.getValue().get("type"))) continue;
                String text = OkHttp.string(e.getValue().get("url") + URLEncoder.encode(url, "UTF-8"));
                JSONObject r = new JSONObject(text);
                String playUrl = r.optString("url");
                if (playUrl.isEmpty()) continue;
                return new JSONObject().put("url", playUrl).put("jxFrom", e.getKey()).put("flag", flag);
            }
        } catch (Exception ignored) {
        }
        return new JSONObject();
    }
}
