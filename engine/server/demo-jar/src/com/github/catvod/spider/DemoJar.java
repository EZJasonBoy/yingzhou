package com.github.catvod.spider;

import android.content.Context;

import com.github.catvod.crawler.Spider;
import com.github.catvod.net.OkHttp;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URLEncoder;
import java.util.HashMap;
import java.util.List;

/**
 * A minimal TVBox jar spider for development: wraps the demo CMS api through the host's OkHttp helper,
 * so loading, Init, host classes and the proxy can be exercised end to end.
 */
public class DemoJar extends Spider {
    private String api = "";

    @Override
    public void init(Context context, String extend) {
        try {
            api = new JSONObject(extend).optString("api");
        } catch (Exception e) {
            api = extend;
        }
    }

    @Override
    public String homeContent(boolean filter) {
        try {
            JSONObject o = new JSONObject(OkHttp.string(api));
            JSONArray list = o.optJSONArray("list");
            if (list != null) {
                for (int i = 0; i < list.length(); i++) {
                    JSONObject v = list.getJSONObject(i);
                    v.put("vod_remarks", "JAR" + (Init.initialized ? " · " : " (no init) · ") + v.optString("vod_remarks"));
                }
            }
            return o.toString();
        } catch (Exception e) {
            return "";
        }
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        return OkHttp.string(api + "?ac=detail&t=" + tid + "&pg=" + pg);
    }

    @Override
    public String detailContent(List<String> ids) {
        return OkHttp.string(api + "?ac=detail&ids=" + ids.get(0));
    }

    @Override
    public String searchContent(String key, boolean quick) {
        try {
            return OkHttp.string(api + "?ac=detail&wd=" + URLEncoder.encode(key, "UTF-8"));
        } catch (Exception e) {
            return "";
        }
    }

    @Override
    public String searchContent(String key, boolean quick, String pg) {
        return searchContent(key, quick);
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        try {
            return new JSONObject().put("parse", id.contains("/demo/page/") ? 1 : 0).put("url", id).toString();
        } catch (Exception e) {
            return "";
        }
    }
}
