package tvbox.engine.js

import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.config.SiteRuntime
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.spider.ProxyResponse
import tvbox.engine.core.spider.Spider
import tvbox.engine.core.spider.SpiderRuntime
import java.util.concurrent.ConcurrentHashMap

/** Runs `.js` spiders (type-3 sites whose api ends in `.js`). */
class JsRuntime(private val env: JsEnvironment) : SpiderRuntime {
    override val kind = "js"

    private val spiders = ConcurrentHashMap<String, JsSpider>()
    @Volatile private var recent: JsSpider? = null

    override fun supports(site: SiteBean) = site.runtime == SiteRuntime.JS

    override suspend fun create(site: SiteBean, ext: String): Spider {
        val spider = JsSpider.load(site, ext, env)
        spider.onUse = { recent = spider }
        spiders[site.key] = spider
        recent = spider
        return spider
    }

    /** A new config may point at updated scripts; drop the in-memory module cache (the 7-day disk cache stays). */
    override fun onConfig(config: TvboxConfig) {
        env.modules.clearMemory()
        spiders.clear()
        recent = null
    }

    /** `proxy?do=js`: the spider named by `siteKey`, else the most recently used one (TVBox `JsLoader.proxyInvoke`). */
    override suspend fun proxy(params: Map<String, String>): ProxyResponse? {
        if (params["do"] != "js") return null
        val spider = params["siteKey"]?.let { spiders[it] } ?: recent ?: return null
        return spider.proxy(params)
    }
}
