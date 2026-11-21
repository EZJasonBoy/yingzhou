package tvbox.engine.core.vod

import org.w3c.dom.Element
import org.xml.sax.InputSource
import tvbox.engine.core.model.Episode
import tvbox.engine.core.model.HomeResult
import tvbox.engine.core.model.PlayLine
import tvbox.engine.core.model.VodCard
import tvbox.engine.core.model.VodClass
import tvbox.engine.core.model.VodDetail
import tvbox.engine.core.model.VodPage
import java.io.StringReader
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Reads the XML that type-0 (MacCMS XML) sites return:
 *
 * ```
 * <rss><list page="1" pagecount="9" pagesize="20" recordcount="170">
 *   <video><id>1</id><name>…</name><pic>…</pic><note>…</note><dl><dd flag="m3u8">第1集$url#…</dd></dl><des>…</des></video>
 * </list><class><ty id="1">电影</ty></class></rss>
 * ```
 * Port of TVBox `AbsXml` / `AbsSortXml` (XStream mappings in `Movie`, `MovieSort`).
 */
object CmsXml {

    fun parseHome(site: String, text: String): HomeResult {
        val root = parse(text)
        val classes = root.children("class").flatMap { it.children("ty") }.mapNotNull { ty ->
            val id = ty.getAttribute("id").trim()
            val name = ty.textContent.trim()
            if (id.isEmpty() || name.isEmpty()) null else VodClass(id, name)
        }
        return HomeResult(classes = classes, list = cards(site, root))
    }

    fun parseList(site: String, text: String): VodPage {
        val root = parse(text)
        val list = root.children("list").firstOrNull()
        return VodPage(
            page = list?.intAttr("page") ?: 1,
            pageCount = list?.intAttr("pagecount") ?: 0,
            total = list?.intAttr("recordcount") ?: 0,
            list = cards(site, root),
        )
    }

    fun parseDetail(site: String, text: String): VodDetail {
        val video = videos(parse(text)).firstOrNull() ?: throw SiteResultException("detail is empty")
        val lines = video.children("dl").flatMap { it.children("dd") }.mapNotNull { dd ->
            val flag = dd.getAttribute("flag").trim()
            val urls = dd.textContent
            val episodes: List<Episode> = TvboxResult.splitEpisodes(urls.trim())
            if (flag.isEmpty() || urls.isBlank() || episodes.isEmpty()) null else PlayLine(flag, episodes)
        }
        return VodDetail(
            site = site,
            id = video.text("id"),
            name = video.text("name"),
            pic = video.text("pic"),
            year = video.text("year"),
            area = video.text("area"),
            type = video.text("type"),
            actor = video.text("actor"),
            director = video.text("director"),
            content = video.text("des"),
            remarks = video.text("note"),
            lines = lines,
        )
    }

    /** As in [TvboxResult]: a video without an id is kept with the id "" (opened by its title), unless it has no name either. */
    private fun cards(site: String, root: Element): List<VodCard> = videos(root).mapNotNull { v ->
        val id = v.text("id")
        val name = v.text("name")
        if (id.isBlank() && name.isBlank()) null else VodCard(site, id, name, v.text("pic"), v.text("note"))
    }

    private fun videos(root: Element): List<Element> = root.children("list").flatMap { it.children("video") }

    private fun parse(text: String): Element {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = false
            isValidating = false
            // No external entities or DTDs from untrusted sites.
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            isExpandEntityReferences = false
        }
        return try {
            factory.newDocumentBuilder().parse(InputSource(StringReader(text.trim().trimStart('﻿')))).documentElement
        } catch (e: Exception) {
            throw SiteResultException("site returned invalid XML")
        }
    }

    private fun Element.children(tag: String): List<Element> {
        val result = ArrayList<Element>()
        var node = firstChild
        while (node != null) {
            if (node is Element && node.tagName == tag) result += node
            node = node.nextSibling
        }
        return result
    }

    private fun Element.text(tag: String): String = children(tag).firstOrNull()?.textContent?.trim() ?: ""

    private fun Element.intAttr(name: String): Int? = getAttribute(name).trim().toIntOrNull()
}
