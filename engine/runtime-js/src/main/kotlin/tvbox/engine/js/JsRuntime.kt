package tvbox.engine.js

import tvbox.engine.core.config.SiteBean
import tvbox.engine.core.config.SiteRuntime
import tvbox.engine.core.config.TvboxConfig
import tvbox.engine.core.spider.Spider
import tvbox.engine.core.spider.SpiderRuntime

/** Runs `.js` spiders (type-3 sites whose api ends in `.js`). */
class JsRuntime(private val env: JsEnvironment) : SpiderRuntime {
    override val kind = "js"

    override fun supports(site: SiteBean) = site.runtime == SiteRuntime.JS

    override suspend fun create(site: SiteBean, ext: String): Spider = JsSpider.load(site, ext, env)

    /** A new config may point at updated scripts; drop the in-memory module cache (the 7-day disk cache stays). */
    override fun onConfig(config: TvboxConfig) {
        env.modules.clearMemory()
    }
}
