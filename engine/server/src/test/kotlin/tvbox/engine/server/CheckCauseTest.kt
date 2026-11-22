package tvbox.engine.server

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import tvbox.engine.core.model.SpiderDiagnostic

/** Messages taken from real check reports: only what is the engine's goes in the 引擎兼容 column. */
class CheckCauseTest {
    private fun cause(code: String, message: String) = Checker.cause(code, message)

    @Test
    fun `what the engine has to fix stays compat`() {
        assertEquals("compat", cause("SPIDER_INCOMPATIBLE", "NoSuchMethodError: android.os.Build.getSerial()"))
        assertEquals("compat", cause("SPIDER_LOAD_FAILED", "x: cannot read the dex in the spider jar: bad header"))
        assertEquals("compat", cause("SPIDER_LOAD_FAILED", "the spider jar is neither a zip nor a dex file"))
        assertEquals("compat", cause("SPIDER_LOAD_FAILED", "x: QuickJS bytecode spiders are not supported yet"))
    }

    @Test
    fun `dead addresses are network`() {
        assertEquals("network", cause("SPIDER_LOAD_FAILED", "x: cannot download the spider jar: https://a.test/83.jar answered with a web page, not a jar"))
        assertEquals("network", cause("SPIDER_LOAD_FAILED", "零度｜APP: OSError: cannot fetch http://t.test/api: <urlopen error [Errno 11001] getaddrinfo failed>"))
        assertEquals("network", cause("SPIDER_LOAD_FAILED", "⚽310直播: cannot download https://d.test/w.js (SyntaxError: Could not find export 'gbkTool' in module 'https://d.test/w.js')"))
        assertEquals("network", cause("SITE_UNREACHABLE", "HTTP 502"))
    }

    @Test
    fun `a script that throws and a class its jar lacks are the site's`() {
        assertEquals("site", cause("SPIDER_ERROR", "布雷｜影视: SyntaxError: unexpected token: '<' at <input>:1:1 at parse (native)"))
        assertEquals("site", cause("SPIDER_ERROR", "A1｜动漫: SyntaxError: Unexpected end of JSON input at <input>:1:1"))
        assertEquals("site", cause("SPIDER_ERROR", "SVIP｜短剧: TypeError: cannot read property 'token' of null"))
        assertEquals("site", cause("SPIDER_LOAD_FAILED", "天天: com.github.catvod.spider.TTian is not in the jar http://j.test/jar.php?id=ou"))
        assertEquals("site", cause("SPIDER_LOAD_FAILED", "B站直播: com.github.catvod.spider.Feiyang is not in the jar ./svip.jar"))
    }

    @Test
    fun `a script that throws a linkage error is still the engine's`() {
        assertEquals("compat", cause("SPIDER_ERROR", "x: java.lang.NoClassDefFoundError: android/webkit/WebView"))
    }

    @Test
    fun `current cause is classified independently from an earlier failure in shared Init`() {
        val diagnostic = SpiderDiagnostic("spider.create", "source", "missing_spider", "ClassNotFoundException", "64ec3885f822", "UnsatisfiedLinkError")
        assertEquals("site", Checker.cause("SPIDER_LOAD_FAILED", "UnsatisfiedLinkError", diagnostic))
        assertEquals("compat", Checker.cause("SITE_ERROR", "", diagnostic.copy(kind = "missing_class")))
        assertEquals("network", Checker.cause("SPIDER_LOAD_FAILED", "", diagnostic.copy(kind = "network")))
        assertEquals("site", Checker.cause("SITE_ERROR", "UnsatisfiedLinkError", diagnostic.copy(kind = "other", cause = "IllegalArgumentException")))
    }

    @Test
    fun `reports count partial recommendations separately and serialize the actual stage`() {
        val warning = SpiderDiagnostic("spider.recommend", "source", "invalid_result", "SiteResultException")
        val diagnostic = warning.copy(stage = "jar.fetch", kind = "network", cause = "IllegalStateException: HTTP 502")
        val checks = listOf(Checker.ConfigCheck("sub", "sub", "sub", sites = listOf(
            Checker.SiteCheck("source", "source", "jar", "pass", warning = warning),
            Checker.SiteCheck("offline", "offline", "jar", "fail", "network", "home", diagnostic = diagnostic),
        )))
        val sites = Checker.json(checks).single().jsonObject.getValue("sites").jsonArray
        assertEquals("spider.recommend", sites[0].jsonObject.getValue("warning").jsonObject.getValue("stage").jsonPrimitive.content)
        assertEquals("jar.fetch", sites[1].jsonObject.getValue("diagnostic").jsonObject.getValue("stage").jsonPrimitive.content)
        val report = Checker.markdown(checks, emptyList())
        assertTrue("| jar.fetch | 1 | 0 |" in report)
        assertTrue("| spider.recommend | 0 | 1 |" in report)
    }
}
