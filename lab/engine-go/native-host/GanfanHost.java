import android.app.Application;
import android.content.Context;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderApi;
import com.github.catvod.spider.AppDrama2;
import com.github.catvod.spider.AppGet;
import com.github.catvod.spider.AppQi;
import com.github.catvod.spider.AppYQK;
import com.github.catvod.spider.GuaziTY;
import com.github.catvod.spider.Gulu;
import com.github.catvod.spider.Gz360;
import com.github.catvod.spider.Hxq;
import com.github.catvod.spider.Init;
import com.github.catvod.spider.Jianpian;
import com.github.catvod.spider.Jpys;
import com.github.catvod.spider.Kanqiu;
import com.github.catvod.spider.SaoHuo;
import com.github.catvod.spider.SP360;
import com.github.catvod.spider.YGP;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import okhttp3.OkHttpClient;
import org.json.JSONArray;
import org.json.JSONObject;
import tvbox.engine.jarhost.HostBridge;

public final class GanfanHost {
    private static final int PROTOCOL = 3;
    private static final String SPIDER_SHA256 = "beaa0c16ecd5257bae7dd680ea145eda9a4385ce384bc02125ab64001940a0fe";
    private record Family(Supplier<Spider> constructor, List<String> keys) {}

    private static final Map<String, Family> FAMILIES = Map.ofEntries(
        Map.entry("csp_AppDrama2", new Family(AppDrama2::new, List.of("干饭", "行动", "再来", "一碗"))),
        Map.entry("csp_AppGet", new Family(AppGet::new, List.of("蔬菜", "方舟", "番薯"))),
        Map.entry("csp_AppQi", new Family(AppQi::new, List.of("肥猫", "光盘"))),
        Map.entry("csp_SP360", new Family(SP360::new, List.of("csp_SP360"))),
        Map.entry("csp_AppYQK", new Family(AppYQK::new, List.of("一起"))),
        Map.entry("csp_GuaziTY", new Family(GuaziTY::new, List.of("瓜子"))),
        Map.entry("csp_Gulu", new Family(Gulu::new, List.of("咕噜"))),
        Map.entry("csp_Gz360", new Family(Gz360::new, List.of("csp_Gz360"))),
        Map.entry("csp_Hxq", new Family(Hxq::new, List.of("韩圈"))),
        Map.entry("csp_Jianpian", new Family(Jianpian::new, List.of("荐片"))),
        Map.entry("csp_Jpys", new Family(Jpys::new, List.of("csp_Jpys"))),
        Map.entry("csp_Kanqiu", new Family(Kanqiu::new, List.of("看球"))),
        Map.entry("csp_SaoHuo", new Family(SaoHuo::new, List.of("csp_SaoHuo"))),
        Map.entry("csp_YGP", new Family(YGP::new, List.of("豆瓣预告"))));

    public static void main(String[] args) throws Exception {
        PrintStream reply = new PrintStream(System.out, true, StandardCharsets.UTF_8);
        System.setOut(System.err);
        var reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        Spider spider = null;
        for (String line; (line = reader.readLine()) != null;) {
            try {
                if (line.length() > 65536) throw new IllegalArgumentException("Request exceeds 65536 characters");
                var request = new JSONObject(line);
                String operation = request.getString("op");
                if (operation.equals("capabilities")) {
                    var families = new JSONObject();
                    for (var family : FAMILIES.entrySet()) families.put(family.getKey(), new JSONArray(family.getValue().keys()));
                    reply.println(new JSONObject().put("protocol", PROTOCOL).put("sha256", SPIDER_SHA256).put("families", families));
                    continue;
                }
                if (operation.equals("init")) {
                    if (spider != null) throw new IllegalStateException("Already initialized");
                    String siteKey = request.has("siteKey") ? request.getString("siteKey") : "干饭";
                    String api = request.has("api") ? request.getString("api") : "csp_AppDrama2";
                    Family family = FAMILIES.get(api);
                    if (family == null || !family.keys().contains(siteKey)) throw new IllegalArgumentException("Unknown site");
                    spider = initialize(family, siteKey, request.get("ext").toString());
                    reply.println(new JSONObject().put("ready", true).put("protocol", PROTOCOL)
                        .put("api", api).put("siteKey", siteKey).put("sha256", SPIDER_SHA256));
                    continue;
                }
                if (spider == null) throw new IllegalStateException("Initialization required");
                String result = switch (operation) {
                    case "home" -> home(spider);
                    case "category" -> spider.categoryContent(request.getString("id"), page(request), true, filters(request));
                    case "search" -> spider.searchContent(request.getString("query"), false, page(request));
                    case "detail" -> spider.detailContent(List.of(request.getString("id")));
                    case "play" -> spider.playerContent(request.getString("line"), request.getString("id"), List.of());
                    default -> throw new IllegalArgumentException("Unknown operation");
                };
                reply.println(new JSONObject(result));
            } catch (Throwable failure) {
                reply.println(new JSONObject().put("error", failure.getClass().getName()));
            }
        }
        System.exit(0);
    }

    private static Spider initialize(Family family, String siteKey, String extension) throws Exception {
        Context.setBaseDir(new File("work"));
        var context = new Application();
        HostBridge.context = context;
        HostBridge.baseClient = new OkHttpClient.Builder().build();
        HostBridge.playbackClient = HostBridge.baseClient;
        try {
            Init.init(context);
        } catch (Throwable unavailable) {
            System.err.println("Jar initialization failed with " + unavailable.getClass().getName());
        }
        Spider spider = family.constructor().get();
        spider.siteKey = siteKey;
        spider.initApi(new SpiderApi());
        spider.init(context, extension);
        return spider;
    }

    private static String home(Spider spider) throws Exception {
        var home = new JSONObject(spider.homeContent(true));
        var list = home.optJSONArray("list");
        if (list == null || list.length() == 0) {
            try {
                var recommendations = new JSONObject(spider.homeVideoContent()).optJSONArray("list");
                if (recommendations != null) home.put("list", recommendations);
            } catch (Exception unavailable) {
                System.err.println("Recommendations failed with " + unavailable.getClass().getName());
            }
        }
        return home.toString();
    }

    private static String page(JSONObject request) {
        return Integer.toString(request.optInt("page", 1));
    }

    private static HashMap<String, String> filters(JSONObject request) throws Exception {
        var result = new HashMap<String, String>();
        JSONObject supplied = request.optJSONObject("filters");
        if (supplied != null) {
            var keys = supplied.keys();
            while (keys.hasNext()) {
                String name = (String) keys.next();
                result.put(name, supplied.getString(name));
            }
        }
        return result;
    }
}
