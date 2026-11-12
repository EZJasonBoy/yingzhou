// Glue between the TVBox JS host API and the engine's native helpers (__host_*).
// Values cross the boundary as strings/JSON so no QuickJS object conversion is involved.
(function () {
  const g = globalThis;
  const s = (v) => (v === undefined || v === null ? '' : String(v));

  g._http = function (url, options) {
    options = options || {};
    if (typeof options.complete === 'function') {
      const complete = options.complete;
      const copy = Object.assign({}, options);
      delete copy.complete;
      __host_http_async(s(url), JSON.stringify(copy)).then(
        (r) => complete(JSON.parse(r)),
        () => complete({ headers: {}, content: '' }),
      );
      return null;
    }
    return JSON.parse(__host_http(s(url), JSON.stringify(options)));
  };

  g.pdfh = (html, rule) => __host_pd(s(html), s(rule), '');
  g.pd = (html, rule, url) => __host_pd(s(html), s(rule), s(url));
  g.pdfa = (html, rule) => JSON.parse(__host_pdfa(s(html), s(rule)));
  g.pdfla = (html, p1, text, url, add) => JSON.parse(__host_pdfla(s(html), s(p1), s(text), s(url), s(add)));

  g.setTimeout = (fn, delay, ...args) => {
    __host_sleep(Number(delay) || 0).then(() => typeof fn === 'function' && fn(...args));
    return 0;
  };
  g.clearTimeout = () => {};

  g.js2Proxy = (dynamic, siteType, siteKey, url, headers) =>
    __host_js2proxy(!!dynamic, Number(siteType) || 3, s(siteKey), s(url), JSON.stringify(headers || {}));
  g.rsaEncrypt = (data, key, options) => __host_rsa(true, s(data), s(key), JSON.stringify(options || {}));
  g.rsaDecrypt = (data, key, options) => __host_rsa(false, s(data), s(key), JSON.stringify(options || {}));

  // Calls a spider method; results are always strings (objects are stringified) or null.
  g.__tvbox_invoke = async (name, args) => {
    const sp = g.__JS_SPIDER__;
    if (!sp || typeof sp[name] !== 'function') return null;
    const r = await sp[name](...args);
    if (r === undefined || r === null) return null;
    return typeof r === 'string' ? r : JSON.stringify(r);
  };

  // TVBox JsSpider.init: cat-style spiders get { stype, skey, ext }, others the ext (parsed when it is a JSON object).
  g.__tvbox_init = async (ext, skey) => {
    const sp = g.__JS_SPIDER__;
    if (!sp || typeof sp.init !== 'function') return;
    let parsed = ext;
    try {
      const p = JSON.parse(ext);
      if (p && typeof p === 'object' && !Array.isArray(p)) parsed = p;
    } catch (e) {}
    if (sp.is_cat) return await sp.init({ stype: 3, skey, ext: parsed });
    return await sp.init(parsed);
  };
})();
