package tvbox.engine.js

import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.select.Elements
import java.net.URL
import java.util.regex.Pattern

/**
 * The `pdfh` / `pdfa` / `pdfla` / `pd` rule language of drpy / Hiker spiders.
 * Port of TVBox `com.github.catvod.crawler.js.HtmlParser`, kept rule-for-rule (including Java's `split`
 * semantics) so that spiders written against TVBox select the same nodes. One instance per spider:
 * the original cached the last parsed document in static fields, shared across threads.
 */
class HtmlParser {
    private var pdfhHtml = ""
    private var pdfaHtml = ""
    private var pdfhDoc: Document? = null
    private var pdfaDoc: Document? = null

    private class ParseInfo(var rule: String, var index: Int = 0, var excludes: MutableList<String>? = null)

    fun parseDomForUrl(html: String, ruleIn: String, addUrl: String): String {
        if (pdfhHtml != html || pdfhDoc == null) {
            pdfhHtml = html
            pdfhDoc = Jsoup.parse(html)
        }
        val doc = pdfhDoc!!
        var rule = ruleIn
        if (rule == "body&&Text" || rule == "Text") return doc.text()
        if (rule == "body&&Html" || rule == "Html") return doc.html()

        var option = ""
        if (rule.contains("&&")) {
            val rs = split(rule, "&&")
            option = rs.last()
            rule = rs.dropLast(1).joinToString("&&")
        }
        rule = parseHikerToJq(rule, true)
        var ret = Elements()
        for (nparse in split(rule, " ")) {
            ret = parseOneRule(doc, nparse, ret)
            if (ret.isEmpty()) return ""
        }
        if (option.isEmpty()) return ret.outerHtml()
        return when (option) {
            "Text" -> ret.text()
            "Html" -> ret.html()
            else -> {
                var result = ret.attr(option)
                if (option.lowercase().contains("style") && result.contains("url(")) {
                    val m = STYLE_URL.matcher(result)
                    if (m.find()) result = m.group(1)
                    if (result.isNotEmpty()) result = result.replace(Regex("^['|\"](.*)['|\"]$"), "$1")
                }
                if (result.isNotEmpty() && addUrl.isNotEmpty()) {
                    if (URLJOIN_ATTR.matcher(option).find() && !SPECIAL_URL.matcher(result).find()) {
                        result = if (result.contains("http")) result.substring(result.indexOf("http")) else joinUrl(addUrl, result)
                    }
                }
                result
            }
        }
    }

    fun parseDomForArray(html: String, ruleIn: String): List<String> {
        val doc = pdfaDoc(html)
        val rule = parseHikerToJq(ruleIn, false)
        var ret = Elements()
        for (part in split(rule, " ")) {
            ret = parseOneRule(doc, part, ret)
            if (ret.isEmpty()) return emptyList()
        }
        return ret.map { it.outerHtml() }
    }

    fun parseDomForList(html: String, p1In: String, listText: String, listUrl: String, addUrl: String): List<String> {
        val doc = pdfaDoc(html)
        val p1 = parseHikerToJq(p1In, false)
        var ret = Elements()
        for (part in split(p1, " ")) {
            ret = parseOneRule(doc, part, ret)
            if (ret.isEmpty()) return emptyList()
        }
        return ret.map { el ->
            val it = el.outerHtml()
            parseDomForUrl(it, listText, "").trim() + '$' + parseDomForUrl(it, listUrl, addUrl)
        }
    }

    private fun pdfaDoc(html: String): Document {
        if (pdfaHtml != html || pdfaDoc == null) {
            pdfaHtml = html
            pdfaDoc = Jsoup.parse(html)
        }
        return pdfaDoc!!
    }

    private fun parseOneRule(doc: Document, nparse: String, current: Elements): Elements {
        val info = parseInfo(nparse)
        var ret = if (current.isEmpty()) doc.select(info.rule) else current.select(info.rule)
        if (nparse.contains(":eq")) {
            val index = if (info.index < 0) ret.size + info.index else info.index
            ret = if (index < 0) Elements() else ret.eq(index)
        }
        val excludes = info.excludes
        if (excludes != null && ret.isNotEmpty()) {
            ret = ret.clone() // keep the cached document intact
            for (exclude in excludes) ret.select(exclude).remove()
        }
        return ret
    }

    private fun parseInfo(nparse: String): ParseInfo {
        val info = ParseInfo(nparse)
        if (nparse.contains(":eq")) {
            info.rule = split(nparse, ":")[0]
            var pos = split(nparse, ":")[1]
            if (info.rule.contains("--")) {
                val rules = split(info.rule, "--")
                info.excludes = rules.drop(1).toMutableList()
                info.rule = rules[0]
            } else if (pos.contains("--")) {
                val rules = split(pos, "--")
                info.excludes = rules.drop(1).toMutableList()
                pos = rules[0]
            }
            info.index = pos.replace("eq(", "").replace(")", "").toIntOrNull() ?: 0
        } else if (nparse.contains("--")) {
            val rules = split(info.rule, "--")
            info.excludes = rules.drop(1).toMutableList()
            info.rule = rules[0]
        }
        return info
    }

    /** Hiker expression -> jQuery-ish selector: adds `:eq(0)` where Hiker implies "first". */
    private fun parseHikerToJq(parse: String, first: Boolean): String {
        if (parse.contains("&&")) {
            val parses = split(parse, "&&")
            val result = parses.mapIndexed { i, p ->
                val pss = split(p, " ")
                val last = pss.last()
                if (!NOADD_INDEX.matcher(last).find()) {
                    if (!first && i >= parses.size - 1) p else "$p:eq(0)"
                } else {
                    p
                }
            }
            return result.joinToString(" ")
        }
        val pss = split(parse, " ")
        val last = pss.last()
        return if (!NOADD_INDEX.matcher(last).find() && first) "$parse:eq(0)" else parse
    }

    companion object {
        private val STYLE_URL = Pattern.compile("url\\((.*?)\\)", Pattern.MULTILINE or Pattern.DOTALL)
        private val NOADD_INDEX = Pattern.compile(":eq|:lt|:gt|:first|:last|^body$|^#")
        private val URLJOIN_ATTR = Pattern.compile("(url|src|href|-original|-src|-play|-url|style)$", Pattern.MULTILINE or Pattern.CASE_INSENSITIVE)
        private val SPECIAL_URL = Pattern.compile("^(ftp|magnet|thunder|ws):", Pattern.MULTILINE or Pattern.CASE_INSENSITIVE)

        /** `java.lang.String.split` semantics: regex, trailing empty strings removed. */
        private fun split(s: String, regex: String): List<String> = s.split(regex.toRegex()).dropLastWhile { it.isEmpty() }.ifEmpty { listOf("") }

        fun joinUrl(parent: String, child: String): String {
            if (parent.isEmpty()) return child
            return try {
                URL(URL(parent), child).toExternalForm()
            } catch (e: Exception) {
                parent
            }
        }
    }
}
